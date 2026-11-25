import AppKit
import SwiftUI
import Darwin

/// Compiled only into the native-browser distribution; ordinary builds retain WebKit.
@MainActor
enum NativeChromium {
    static var available: Bool {
        #if NATIVE_CHROMIUM
        true
        #else
        false
        #endif
    }
    static var enabled: Bool {
        available && (!CommandLine.arguments.contains("--background-checks")
            || CommandLine.arguments.contains("--native-browser-check"))
    }
    private static var endpoint: URL?
    private static var guestDirectory: URL?
    private static var activeProfile: URL?
    private static var bootstrapError: Error?
    private static var preparedProfile: URL?
    private static var startWaiters: [CheckedContinuation<URL, Error>] = []
    private static var stopping = false
    private static var afterRun: (() -> Void)?
    private static func prepareProfile(_ profile: URL) throws {
        let fm = FileManager.default
        let marker = profile.appendingPathComponent(".orvlet-profile")
        if fm.fileExists(atPath: profile.path), !fm.fileExists(atPath: marker.path),
            !(try fm.contentsOfDirectory(atPath: profile.path)).isEmpty {
            throw AppError.message("This folder is not an Orvlet browser profile.")
        }
        try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("Orvlet native Chromium profile\n".utf8).write(to: marker)
        try NativeExtensions.removeBundledRegistrations(in: profile)
    }
    static var running: Bool {
        #if NATIVE_CHROMIUM
        ORNativeChromium.isRunning()
        #else
        false
        #endif
    }
    static func prepareApplication() {
        #if NATIVE_CHROMIUM
        ORNativeChromium.prepareApplication()
        #endif
    }
    static func runApplication() -> Bool {
        #if NATIVE_CHROMIUM
        guard enabled else { return false }
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--background-checks") ? .prohibited : .accessory)
        prepareConfiguredProfile()
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        var quitting = false
        ORNativeChromium.setTermination {
            guard !quitting else { return }
            quitting = true
            delegate.model.saveSession(force: true)
            Task {
                await delegate.model.systemBrowserHost.shutdown()
                await delegate.model.nativeBrowserHost.shutdown()
                stopApplication()
            }
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        if !CommandLine.arguments.contains("--background-checks") { installMenu(delegate) }
        withExtendedLifetime(delegate) {
            while true {
                NSApp.run()
                guard !startWaiters.isEmpty, !stopping, !quitting, let profile = preparedProfile else { break }
                // CEF installs run-loop observers and its own delegate. Initialize
                // between AppKit loops, then return control to the same Orvlet windows.
                let result = Result { try initialize(profile: profile) }
                if case .failure(let error) = result { bootstrapError = error }
                NSApp.delegate = delegate
                if !CommandLine.arguments.contains("--background-checks") { installMenu(delegate) }
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume(with: result) }
            }
        }
        for waiter in startWaiters { waiter.resume(throwing: CancellationError()) }
        startWaiters.removeAll()
        if !CommandLine.arguments.contains("--background-checks") {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        shutdown()
        afterRun?()
        return true
        #else
        return false
        #endif
    }
    static func stopApplication(completion: (() -> Void)? = nil) {
        stopping = true
        afterRun = completion
        interruptEventLoop()
    }
    private static func interruptEventLoop() {
        NSApp.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
    }
    private static func installMenu(_ delegate: AppDelegate) {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String)]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for (label, action, key) in items {
                let child = NSMenuItem(title: label, action: action, keyEquivalent: key)
                if action == #selector(AppDelegate.showSettings) || action == #selector(AppDelegate.openNativeAddress) { child.target = delegate }
                menu.addItem(child)
            }
            item.submenu = menu; main.addItem(item)
        }
        submenu("Orvlet", [("Settings…", #selector(AppDelegate.showSettings), ","), ("Quit Orvlet", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [("Open address…", #selector(AppDelegate.openNativeAddress), "l")])
        submenu("Edit", [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")])
        NSApp.mainMenu = main
    }
    private static func prepareConfiguredProfile() {
        #if NATIVE_CHROMIUM
        guard enabled else { return }
        do {
            let root: URL
            if CommandLine.arguments.contains("--native-browser-check") {
                guard let path = ProcessInfo.processInfo.environment["ORVLET_NATIVE_CHECK_PROFILE"] else {
                    throw AppError.message("Native browser checks require an isolated profile.")
                }
                root = URL(fileURLWithPath: path)
                guard root.lastPathComponent.hasPrefix("orvlet-native-check-"),
                    root.deletingLastPathComponent().resolvingSymlinksInPath()
                        == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
                    throw AppError.message("Native checks may only use their isolated temporary profile.")
                }
            } else {
                root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Orvlet/Chromium")
            }
            try prepareProfile(root)
            preparedProfile = root.resolvingSymlinksInPath()
        } catch { bootstrapError = error }
        #endif
    }
    static func start(profile: URL) async throws -> URL {
        #if NATIVE_CHROMIUM
        let profile = profile.resolvingSymlinksInPath()
        if let endpoint {
            guard profile == activeProfile else { throw AppError.message("The native browser is already using another profile.") }
            return endpoint
        }
        if let bootstrapError { throw bootstrapError }
        guard !stopping, profile == preparedProfile else { throw AppError.message("The native browser profile is unavailable.") }
        return try await withCheckedThrowingContinuation { waiter in
            startWaiters.append(waiter)
            if startWaiters.count == 1 { interruptEventLoop() }
        }
        #else
        throw AppError.message("Use the native Chromium build to open this browser.")
        #endif
    }
    #if NATIVE_CHROMIUM
    private static func initialize(profile: URL) throws -> URL {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError.message("Could not reserve the browser control port.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        Darwin.close(descriptor)
        guard bound == 0, read == 0 else { throw AppError.message("Could not reserve the browser control port.") }
        let port = Int32(UInt16(bigEndian: address.sin_port))
        let keepLogins = FileManager.default.fileExists(atPath: profile.appendingPathComponent(NativeExtensions.loginOptIn).path)
        var storage = profile
        if !keepLogins {
            storage = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-guest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            guestDirectory = storage
        }
        try ORNativeChromium.start(withProfile: storage.path, extensions: profile.path, guest: !keepLogins, port: port)
        let url = URL(string: "http://127.0.0.1:\(port)")!
        endpoint = url
        activeProfile = profile
        return url
    }
    #endif
    static func create(_ identifier: String) throws -> NativeBrowser {
        #if NATIVE_CHROMIUM
        guard let page = ORNativeChromium.createBrowser(identifier) else {
            throw AppError.message("Could not create the native browser view.")
        }
        return NativeBrowser(page)
        #else
        throw AppError.message("The native browser is not included in this build.")
        #endif
    }
    static func flush() async {
        #if NATIVE_CHROMIUM
        await withCheckedContinuation { continuation in ORNativeChromium.flushCookies { continuation.resume() } }
        #endif
    }
    static func shutdown() {
        #if NATIVE_CHROMIUM
        ORNativeChromium.shutdown()
        if !running, let guestDirectory {
            try? FileManager.default.removeItem(at: guestDirectory)
            self.guestDirectory = nil
        }
        #endif
        endpoint = nil
        activeProfile = nil
    }
}

@MainActor
final class NativeBrowser {
    #if NATIVE_CHROMIUM
    private let page: ORNativeBrowser
    init(_ page: ORNativeBrowser) { self.page = page }
    var view: NSView { page.view }
    var closed: Bool { page.closed }
    func park() { page.park() }
    func close() { page.close() }
    func focusRenderer() { page.focusRenderer() }
    #else
    var view: NSView { NSView() }
    var closed: Bool { true }
    func park() {}
    func close() {}
    func focusRenderer() {}
    #endif
}

struct NativeChromiumSurface: NSViewRepresentable {
    let page: SystemBrowserPage
    let browser: NativeBrowser
    let visible: Bool
    func makeNSView(context: Context) -> NativeChromiumViewport {
        NativeChromiumViewport(page: page, browser: browser)
    }
    func updateNSView(_ view: NativeChromiumViewport, context: Context) {
        view.presented = visible
        view.needsLayout = true
    }
    static func dismantleNSView(_ view: NativeChromiumViewport, coordinator: ()) {
        if view.browser.view.superview === view.canvas {
            view.browser.park()
            view.page.setVisible(false, size: view.bounds.size)
        }
    }
}

final class NativeChromiumViewport: NSView {
    let page: SystemBrowserPage
    let browser: NativeBrowser
    let canvas = NSView()
    var presented = false
    override var isFlipped: Bool { true }
    init(page: SystemBrowserPage, browser: NativeBrowser) {
        self.page = page
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        canvas.autoresizesSubviews = false
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard presented, window != nil, bounds.width > 1, bounds.height > 1, !browser.closed else {
            if browser.view.superview === canvas {
                browser.park()
                page.setVisible(false, size: bounds.size)
            }
            return
        }
        if browser.view.superview !== canvas { canvas.addSubview(browser.view) }
        canvas.frame = bounds
        canvas.setBoundsSize(bounds.size)
        // Chromium's compositor uses the physical NSView bounds. Scaling an
        // ancestor changes hit testing without scaling its accelerated surface.
        browser.view.frame = NSRect(origin: .zero, size: bounds.size)
        page.setVisible(true, size: bounds.size)
    }
}

struct BrowserPageSurface: View {
    let page: SystemBrowserPage
    let visible: Bool
    var body: some View {
        if page.host.native {
            NativeBrowserPageSurface(page: page, visible: visible)
        } else {
            SystemBrowserSurface(page: page, visible: visible)
        }
    }
}

private struct NativeBrowserPageSurface: View {
    @ObservedObject var page: SystemBrowserPage
    let visible: Bool
    var body: some View {
        if let native = page.nativeBrowser {
            NativeChromiumSurface(page: page, browser: native, visible: visible)
        } else {
            Color.clear.task(id: visible) { if visible { try? await page.ready() } }
        }
    }
}
