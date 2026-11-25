import AppKit
import Foundation
import Security

enum BrowserEngine: String, Codable, CaseIterable {
    case builtIn, systemBrowser
    var title: String {
        #if NATIVE_CHROMIUM
        self == .builtIn ? "Built-in Chromium" : "Default browser"
        #else
        self == .builtIn ? "Built-in" : "Default browser"
        #endif
    }
}

struct SystemBrowserApplication {
    static var sandboxed: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }
    let id: String
    let name: String
    let executable: URL
    let userData: URL
    // Branded Chrome removed command-line unpacked extension loading in version 137.
    var supportsExtensionImport: Bool { id != "com.google.Chrome" }

    @MainActor static func current() -> Self? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.org")!),
            let bundle = Bundle(url: app), let id = bundle.bundleIdentifier,
            let executable = bundle.executableURL else { return nil }
        let paths = ["com.microsoft.edgemac": "Microsoft Edge", "com.google.Chrome": "Google/Chrome",
            "com.brave.Browser": "BraveSoftware/Brave-Browser", "org.chromium.Chromium": "Chromium"]
        guard let path = paths[id] else { return nil }
        return Self(id: id, name: app.deletingPathExtension().lastPathComponent, executable: executable,
            userData: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(path))
    }
}

/// A private browser process, never the user's running browser or its profile.
@MainActor
final class SystemBrowserHost {
    let native: Bool
    private var nativePages: [String: NativeBrowser] = [:]
    let application: SystemBrowserApplication?
    let root: URL
    private(set) var process: Process?
    private var starting: Task<URL, Error>?
    private var endpoint: URL?
    private var browserSocket: URL?
    private(set) var closing = false
    private var log: FileHandle?
    private var retiring: Process?
    private var generation = 0
    var revision: Int { generation }
    private(set) var importing = false
    var pendingImport: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".pending") }
    var isRunning: Bool { native ? NativeChromium.running : process?.isRunning == true || starting != nil }
    let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    init(root: URL? = nil, application: SystemBrowserApplication? = nil, native: Bool = false) {
        self.native = native
        let application = application ?? SystemBrowserApplication.current()
        self.application = application
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(native ? "Orvlet/Chromium" : "Orvlet/BrowserProfiles/" + (application?.id ?? "unsupported"))
    }

    func start() async throws -> URL {
        guard !closing else { throw AppError.message("The private browser is closing. Try again shortly.") }
        if native {
            let fm = FileManager.default
            let marker = root.appendingPathComponent(".orvlet-profile")
            if fm.fileExists(atPath: root.path), !fm.fileExists(atPath: marker.path),
                !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty {
                throw AppError.message("This folder is not an Orvlet browser profile.")
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("Orvlet native Chromium profile\n".utf8).write(to: marker)
            let url = try await NativeChromium.start(profile: root)
            endpoint = url
            return url
        }
        guard !SystemBrowserApplication.sandboxed else {
            throw AppError.message("Default browser needs the Orvlet-Browser build. This sandboxed build supports Built-in.")
        }
        guard !closing else { throw AppError.message("The private browser is closing. Try again shortly.") }
        guard !importing else { throw AppError.message("Finish importing browser data before opening a new page.") }
        if let endpoint, process?.isRunning == true { return endpoint }
        if let starting { return try await starting.value }
        let revision = generation
        let task = Task { @MainActor [self] () throws -> URL in
            for _ in 0..<50 {
                if retiring?.isRunning != true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard retiring?.isRunning != true else { throw AppError.message("The previous task browser is still closing. Try again shortly.") }
            retiring = nil
            guard let application else {
                throw AppError.message("Choose Edge, Chrome, Brave or Chromium as the default browser, or use Built-in.")
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: pendingImport.path) {
                guard fm.fileExists(atPath: pendingImport.appendingPathComponent(".orvlet-profile").path) else {
                    throw AppError.message("The imported profile could not be verified.")
                }
                let backup = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".backup-" + UUID().uuidString)
                let existed = fm.fileExists(atPath: root.path)
                if existed { try fm.moveItem(at: root, to: backup) }
                do { try fm.moveItem(at: pendingImport, to: root) }
                catch { if existed { try? fm.moveItem(at: backup, to: root) }; throw error }
            }
            // A caller cannot accidentally point automation at an ordinary browser profile.
            let marker = root.appendingPathComponent(".orvlet-profile")
            if fm.fileExists(atPath: root.path), !fm.fileExists(atPath: marker.path) {
                guard (try fm.contentsOfDirectory(atPath: root.path)).isEmpty else {
                    throw AppError.message("This folder is not an Orvlet browser profile.")
                }
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("Orvlet isolated browser profile\n".utf8).write(to: marker)
            let portFile = root.appendingPathComponent("DevToolsActivePort")
            try? fm.removeItem(at: portFile)
            let logURL = root.appendingPathComponent("browser.log")
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try FileHandle(forWritingTo: logURL)
            let child = Process()
            child.executableURL = application.executable
            child.arguments = ["--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
                "--user-data-dir=" + root.path, "--profile-directory=Default", "--no-first-run",
                "--no-default-browser-check", "--disable-background-networking", "--disable-sync",
                "--disable-background-mode", "--disable-session-crashed-bubble", "--window-size=1000,700",
                "--autoplay-policy=no-user-gesture-required", "about:blank"]
            let unpacked = root.appendingPathComponent("UnpackedExtensions")
            let extensions = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            if !extensions.isEmpty { child.arguments?.append("--load-extension=" + extensions.map(\.path).joined(separator: ",")) }
            #if DEBUG
                if root.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    child.arguments?.append("--disable-gpu")
                    child.arguments?.append("--use-mock-keychain")
                    child.arguments?.append("--disable-features=DialMediaRouteProvider")
                }
            #endif
            child.standardOutput = log
            child.standardError = log
            try child.run()
            process = child
            for _ in 0..<150 {
                try Task.checkCancellation()
                guard generation == revision, child.isRunning else { throw AppError.message("The background browser stopped.") }
                if let text = try? String(contentsOf: portFile, encoding: .utf8),
                    let first = text.split(separator: "\n").first, let port = Int(first), (1...65535).contains(port) {
                    let lines = text.split(separator: "\n")
                    if lines.count > 1, lines[1].hasPrefix("/devtools/browser/") {
                        browserSocket = URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
                    }
                    return URL(string: "http://127.0.0.1:\(port)")!
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppError.message("The background browser did not start. Try again or select Built-in.")
        }
        starting = task
        do {
            let url = try await task.value
            guard revision == generation else { throw CancellationError() }
            endpoint = url
            starting = nil
            return url
        } catch {
            if revision == generation { stop() }
            throw error
        }
    }

    func newPage() async throws -> (String, URL) {
        let base = try await start()
        if native {
            let revision = generation
            let identifier = UUID().uuidString.lowercased()
            let browser = try NativeChromium.create(identifier)
            do {
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    guard generation == revision, !closing, !browser.closed else { throw CancellationError() }
                    let (data, _) = try await http.data(from: base.appendingPathComponent("json/list"))
                    let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                    if let target = targets.first(where: { ($0["url"] as? String)?.contains(identifier) == true }),
                        let id = target["id"] as? String, let raw = target["webSocketDebuggerUrl"] as? String,
                        let socket = URL(string: raw), socket.host == "127.0.0.1", socket.port == base.port {
                        nativePages[id] = browser
                        return (id, socket)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw AppError.message("The native browser did not finish opening.")
            } catch { browser.close(); throw error }
        }
        guard let browserSocket else {
            throw AppError.message("The background browser could not create a task page.")
        }
        let control = BrowserDevTools(url: browserSocket, session: http)
        defer { control.close() }
        let targets = try await control.call("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        guard let profile = targets.first(where: { $0["type"] as? String == "page" })?["browserContextId"] as? String else {
            throw AppError.message("The private browser profile could not be identified.")
        }
        // Give each task its own virtual window in the windowless browser. A
        // never-activated background tab can defer media and compositor work.
        // These are not desktop windows: the owned process is always headless.
        let result = try await control.call("Target.createTarget", ["url": "about:blank", "newWindow": true,
            "background": true, "browserContextId": profile])
        guard let id = result["targetId"] as? String else {
            throw AppError.message("The background browser could not create a task page.")
        }
        do {
            let (data, response) = try await http.data(from: base.appendingPathComponent("json/list"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                let value = targets.first(where: { $0["id"] as? String == id }),
                let raw = value["webSocketDebuggerUrl"] as? String,
                let url = URL(string: raw), url.host == "127.0.0.1", url.port == base.port else {
                throw AppError.message("The background browser could not connect to the task page.")
            }
            return (id, url)
        } catch {
            Task { await self.closePage(id) }
            throw error
        }
    }

    func closePage(_ id: String) async {
        if native { nativePages.removeValue(forKey: id)?.close(); return }
        guard let endpoint, process?.isRunning == true else { return }
        _ = try? await http.data(from: endpoint.appendingPathComponent("json/close/" + id))
    }

    func stop() {
        generation += 1
        if native {
            nativePages.values.forEach { $0.close() }
            nativePages.removeAll()
            return
        }
        starting?.cancel()
        starting = nil
        endpoint = nil
        browserSocket = nil
        if let child = process, child.isRunning { retiring = child; child.terminate() }
        process = nil
        try? log?.close()
        log = nil
    }

    /// Let Chromium flush cookies and extension state before normal app termination.
    func shutdown() async {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        if native {
            stop()
            await NativeChromium.flush()
            return
        }
        generation += 1
        if let browserSocket, process?.isRunning == true {
            let control = BrowserDevTools(url: browserSocket, session: http)
            _ = try? await control.call("Browser.close", timeout: .seconds(3))
            control.close()
            // Extension workers and multiple task windows may take several
            // seconds to flush cookies. Do not kill a normal close after 2 s.
            for _ in 0..<200 {
                if process?.isRunning != true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        stop()
    }

    func nativeBrowser(_ id: String) -> NativeBrowser? { nativePages[id] }

    func importProfile(_ profile: BrowserProfileImporter.Profile) async throws -> Int {
        guard !importing, let application else { throw AppError.message("A supported default browser is required.") }
        importing = true
        defer { importing = false }
        let destination = root
        let source = application.userData
        let includeExtensions = application.supportsExtensionImport
        let staging = try await Task.detached {
            try BrowserProfileImporter.stage(profile: profile, applicationData: source, destination: destination,
                includeExtensions: includeExtensions)
        }.value
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: pendingImport.path) { try fm.removeItem(at: pendingImport) }
            try fm.moveItem(at: staging, to: pendingImport)
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: pendingImport.appendingPathComponent("orvlet-import.json"))) as? [String: Int]
            return report?["extensionsImported"] ?? 0
        } catch { try? fm.removeItem(at: staging); throw error }
    }
}

/// Request IDs and bounded continuations keep cancellation and process loss local to a task.
@MainActor
final class BrowserDevTools {
    private let socket: URLSessionWebSocketTask
    private var reader: Task<Void, Never>?
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private(set) var closed = false
    var event: ((String, [String: Any]) -> Void)?
    var failed: ((Error) -> Void)?
    init(url: URL, session: URLSession) {
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
        reader = Task { [weak self] in
            while let self, !closed {
                do {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let id = object["id"] as? Int, let reply = waiting.removeValue(forKey: id) {
                        deadlines.removeValue(forKey: id)?.cancel()
                        if let error = object["error"] as? [String: Any] {
                            reply.resume(throwing: AppError.message(error["message"] as? String ?? "Browser command failed."))
                        } else { reply.resume(returning: object["result"] as? [String: Any] ?? [:]) }
                    } else if let method = object["method"] as? String {
                        event?(method, object["params"] as? [String: Any] ?? [:])
                    }
                } catch {
                    if !closed { close(error); failed?(error) }
                }
            }
        }
    }
    func call(_ method: String, _ params: [String: Any] = [:], timeout: Duration = .seconds(15)) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !closed else { throw AppError.message("The task browser is disconnected. Reload to reconnect.") }
        nextID += 1
        let id = nextID
        let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, error: AppError.message("The background browser did not respond in time."))
                }
                Task { [weak self] in
                    guard let self, waiting[id] != nil, !closed else { return }
                    do { try await socket.send(.string(String(decoding: bytes, as: UTF8.self))) } catch { finish(id, error: error) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(id, error: CancellationError()) } }
    }
    private func finish(_ id: Int, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }
    func close(_ error: Error = CancellationError()) {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        socket.cancel(with: .goingAway, reason: nil)
        for id in Array(waiting.keys) { finish(id, error: error) }
    }
}
