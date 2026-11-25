import AppKit
import Combine
import CryptoKit
import WebKit

/// One extension controller per Orvlet profile. Generated cards never join it.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensions: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let name: String
        let version: String
        let digest: String
        var enabled: Bool
        var archive: Bool? = nil
    }
    struct Pending {
        let entry: Entry
        let directory: URL
        let webExtension: WKWebExtension
        var permissions: String {
            let names = webExtension.requestedPermissions.map(\.rawValue).sorted()
            let sites = webExtension.allRequestedMatchPatterns.union(webExtension.requestedPermissionMatchPatterns).map(
                \.string
            ).sorted()
            return (names + sites).joined(separator: "\n")
        }
    }
    let controller: WKWebExtensionController
    let root: URL
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var busy = true
    @Published var issue: String?
    @Published private(set) var pending: Pending?
    private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    private var tabs: [ObjectIdentifier: ExtensionTab] = [:]
    private let window = ExtensionWindow()
    private var popup: NSPanel?
    private var popupOwner: UUID?
    private var restoration: Task<Void, Never>?

    init(root: URL, persistent: Bool) {
        self.root = root
        controller = WKWebExtensionController(configuration: persistent ? .default() : .nonPersistent())
        super.init()
        controller.delegate = self
        window.host = self
        restoration = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false
                restoration = nil
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let index = root.appendingPathComponent("extensions.json")
                if FileManager.default.fileExists(atPath: index.path) {
                    entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))
                }
                for entry in entries where entry.enabled {
                    do { try await load(entry) } catch { issue = "\(entry.name): \(error.localizedDescription)" }
                }
            } catch { issue = error.localizedDescription }
        }
    }
    func ready() async { await restoration?.value }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func resourceURL(_ entry: Entry) -> URL {
        entry.archive == true ? directory(entry.id).appendingPathComponent("package.zip") : directory(entry.id)
    }
    private func save() throws {
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("extensions.json"), options: .atomic)
    }
    /// Reject links and special files before copying; the imported snapshot is immutable to its source.
    static func fingerprint(_ input: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues = try input.resourceValues(forKeys: keys)
        let directory = input.standardizedFileURL.resolvingSymlinksInPath()
        if rootValues.isRegularFile == true, rootValues.isSymbolicLink != true,
            directory.pathExtension.lowercased() == "zip", (rootValues.fileSize ?? Int.max) <= 128 * 1024 * 1024
        {
            return SHA256.hash(data: try Data(contentsOf: directory)).map { String(format: "%02x", $0) }.joined()
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
            let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))
        else { throw AppError.message("Choose an extension ZIP or an unpacked folder containing manifest.json.") }
        var paths: [URL] = []
        var total = 0
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw AppError.message("Extension folders cannot contain links or special files.")
            }
            if values.isRegularFile == true {
                paths.append(file.standardizedFileURL.resolvingSymlinksInPath())
                total += values.fileSize ?? 0
                guard paths.count <= 20000, total <= 128 * 1024 * 1024 else {
                    throw AppError.message("This extension exceeds the 128 MB import limit.")
                }
            }
        }
        guard paths.contains(where: { $0.path == directory.appendingPathComponent("manifest.json").path }) else {
            throw AppError.message("Choose the folder directly containing manifest.json.")
        }
        var hash = SHA256()
        for file in paths.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.dropFirst(directory.path.count).utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(SHA256.hash(data: try Data(contentsOf: file))))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func prepareImport(_ source: URL) async throws {
        guard !busy, pending == nil else { throw AppError.message("Finish the current extension change first.") }
        busy = true
        issue = nil
        defer { busy = false }
        let digest = try Self.fingerprint(source)
        guard !entries.contains(where: { $0.digest == digest }) else {
            throw AppError.message("This extension is already installed.")
        }
        let id = UUID()
        let target = directory(id)
        do {
            let archive = try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            let resource: URL
            if archive {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                resource = target.appendingPathComponent("package.zip")
            } else {
                resource = target
            }
            try FileManager.default.copyItem(at: source, to: resource)
            guard try Self.fingerprint(resource) == digest else {
                throw AppError.message("The extension changed during import. Try again.")
            }
            let ext = try await WKWebExtension(resourceBaseURL: resource)
            guard ext.errors.isEmpty else {
                throw AppError.message(ext.errors.map(\.localizedDescription).joined(separator: "\n"))
            }
            let entry = Entry(
                id: id, name: ext.displayName ?? source.lastPathComponent,
                version: ext.version ?? "", digest: digest, enabled: true, archive: archive)
            pending = Pending(entry: entry, directory: target, webExtension: ext)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
    func cancelImport() {
        guard !busy, let pending else { return }
        try? FileManager.default.removeItem(at: pending.directory)
        self.pending = nil
    }
    func approveImport() throws {
        guard !busy, let pending else { return }
        guard try Self.fingerprint(resourceURL(pending.entry)) == pending.entry.digest else {
            throw AppError.message("The extension changed while awaiting approval. Import it again.")
        }
        let context = makeContext(pending.webExtension, id: pending.entry.id)
        try controller.load(context)
        entries.append(pending.entry)
        do { try save() } catch {
            entries.removeAll { $0.id == pending.entry.id }
            try? controller.unload(context)
            throw error
        }
        contexts[pending.entry.id] = context
        self.pending = nil
    }
    private func makeContext(_ ext: WKWebExtension, id: UUID) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: ext)
        context.hasAccessToPrivateData = !controller.configuration.isPersistent
        context.uniqueIdentifier = id.uuidString
        context.baseURL = URL(string: "webkit-extension://\(id.uuidString.lowercased())/")!
        // Only the required permissions shown at installation are granted. Optional requests default to denied.
        for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in ext.allRequestedMatchPatterns.union(ext.requestedPermissionMatchPatterns) {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        return context
    }
    private func load(_ entry: Entry) async throws {
        let path = resourceURL(entry)
        guard try Self.fingerprint(path) == entry.digest else {
            throw AppError.message("Extension files changed. Remove and import again to review permissions.")
        }
        let ext = try await WKWebExtension(resourceBaseURL: path)
        guard ext.errors.isEmpty else {
            throw AppError.message(ext.errors.map(\.localizedDescription).joined(separator: "\n"))
        }
        let context = makeContext(ext, id: entry.id)
        try controller.load(context)
        contexts[entry.id] = context
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) async throws {
        guard !busy, pending == nil, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].enabled == enabled && (contexts[id] != nil) == enabled { return }
        busy = true
        defer { busy = false }
        if enabled {
            if contexts[id] == nil { try await load(entries[i]) }
        } else if let context = contexts[id] {
            closePopup(id)
            try controller.unload(context)
            contexts[id] = nil
        }
        let old = entries[i].enabled
        entries[i].enabled = enabled
        do { try save() } catch {
            entries[i].enabled = old
            if enabled, let context = contexts.removeValue(forKey: id) {
                try? controller.unload(context)
            } else if old {
                try? await load(entries[i])
            }
            throw error
        }
    }
    func remove(_ id: UUID) async throws {
        guard !busy, pending == nil, entries.contains(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        let old = entries
        if let context = contexts[id] {
            closePopup(id)
            try controller.unload(context)
            contexts[id] = nil
        }
        entries.removeAll { $0.id == id }
        do { try save() } catch {
            entries = old
            if let entry = old.first(where: { $0.id == id && $0.enabled }) { try? await load(entry) }
            throw error
        }
        if FileManager.default.fileExists(atPath: directory(id).path) {
            try FileManager.default.removeItem(at: directory(id))
        }
        // Remove storage as well as scripts/rules. A later import gets a new identity.
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id.uuidString }
        await controller.removeData(ofTypes: types, from: records)
    }
    func configure(_ config: WKWebViewConfiguration) { config.webExtensionController = controller }
    func register(_ web: WKWebView) {
        reapTabs()
        let tab = ExtensionTab(web: web, window: window)
        tabs[ObjectIdentifier(web)] = tab
        controller.didOpenTab(tab)
    }
    func unregister(_ web: WKWebView) {
        if let tab = tabs.removeValue(forKey: ObjectIdentifier(web)) { controller.didCloseTab(tab) }
    }
    private func reapTabs() {
        for (key, tab) in tabs where tab.web == nil {
            controller.didCloseTab(tab)
            tabs[key] = nil
        }
    }
    fileprivate var liveTabs: [ExtensionTab] {
        reapTabs()
        return tabs.values.sorted { $0.identity < $1.identity }
    }
    func changed(_ web: WKWebView) {
        if let tab = tabs[ObjectIdentifier(web)] {
            controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
        }
    }
    func perform(_ id: UUID, on web: WKWebView?) {
        guard let context = contexts[id] else { return }
        let tab = web.flatMap { tabs[ObjectIdentifier($0)] }
        window.selected = tab
        if let tab {
            controller.didActivateTab(tab)
            context.userGesturePerformed(in: tab)
        }
        context.performAction(for: tab)
    }
    private func closePopup(_ id: UUID) {
        guard popupOwner == id else { return }
        popup?.close()
        popup = nil
        popupOwner = nil
    }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext)
        -> [any WKWebExtensionWindow]
    { [window] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext)
        -> (any WKWebExtensionWindow)?
    { window }
    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        guard let web = action.popupWebView else {
            completionHandler(AppError.message("This extension has no popup."))
            return
        }
        popup?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        panel.title = context.webExtension.displayName ?? "Extension"
        panel.contentView = web
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        popup = panel
        popupOwner = UUID(uuidString: context.uniqueIdentifier)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
private final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var host: BrowserExtensions?
    weak var selected: ExtensionTab?
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { host?.liveTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { selected ?? host?.liveTabs.first }
}

@available(macOS 15.4, *)
@MainActor
private final class ExtensionTab: NSObject, WKWebExtensionTab {
    let identity = UUID().uuidString
    weak var web: WKWebView?
    weak var owner: ExtensionWindow?
    init(web: WKWebView, window: ExtensionWindow) {
        self.web = web
        owner = window
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { web?.isLoading == false }
}

extension AppModel {
    @available(macOS 15.4, *)
    var extensions: BrowserExtensions {
        if let host = extensionStorage as? BrowserExtensions { return host }
        let isolated = isLiveTest || preferences !== UserDefaults.standard
        let root =
            isolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-extensions-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Orvlet/Extensions", isDirectory: true)
        let host = BrowserExtensions(root: root, persistent: !isolated)
        extensionStorage = host
        return host
    }
}
