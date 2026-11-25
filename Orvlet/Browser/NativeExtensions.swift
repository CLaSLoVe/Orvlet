import AppKit
import Combine
import CryptoKit

/// Extension packages belong to the native profile, never to the signed bundle.
@MainActor
final class NativeExtensions: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let version: String
        var enabled: Bool
        let digest: String
    }
    struct Pending {
        let entry: Entry
        let directory: URL
        let permissions: String
    }
    let root: URL
    @Published private(set) var keepLogins = false
    static let loginOptIn = "remember-website-logins"
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var pending: Pending?
    @Published private(set) var restartRequired = false
    @Published var issue: String?
    private var index: URL { root.appendingPathComponent("extensions.json") }
    init(root: URL) {
        self.root = root
        keepLogins = FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.loginOptIn).path)
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do {
            let loaded = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))
            guard loaded.allSatisfy({ Self.validID($0.id) }), Set(loaded.map(\.id)).count == loaded.count else {
                throw AppError.message("The saved extension list is invalid.")
            }
            entries = loaded
        }
        catch { issue = error.localizedDescription }
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    func directory(_ entry: Entry) -> URL { root.appendingPathComponent("Extensions").appendingPathComponent(entry.id) }
    static func removeBundledRegistrations(in root: URL) throws {
        let index = root.appendingPathComponent("extensions.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))
        let installed = entries.filter { $0.digest != "bundled" }
        if installed.count != entries.count { try JSONEncoder().encode(installed).write(to: index, options: .atomic) }
    }
    func setKeepLogins(_ enabled: Bool) throws {
        guard enabled != keepLogins else { return }
        let file = root.appendingPathComponent(Self.loginOptIn)
        if enabled { try Data().write(to: file, options: .atomic) }
        else { try FileManager.default.removeItem(at: file) }
        keepLogins = enabled
        if NativeChromium.running { restartRequired = true }
    }
    private func save(_ next: [Entry]) throws {
        try JSONEncoder().encode(next).write(to: index, options: .atomic)
        entries = next
        restartRequired = true
    }
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries
        next[index].enabled = enabled
        try save(next)
    }
    func remove(_ id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        // Keep files until restart: a worker may still be using this package.
        try save(entries.filter { $0.id != id })
    }
    static func manifest(at directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard data.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["manifest_version"] as? Int == 3, value["version"] is String, value["name"] is String else {
            throw AppError.message("Choose an unpacked Manifest V3 extension folder.")
        }
        return value
    }
    static func fingerprint(_ directory: URL) throws -> String {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try directory.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true,
            let walker = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            throw AppError.message("Choose an unpacked extension folder.")
        }
        _ = try manifest(at: directory)
        var files: [URL] = [], total = 0
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw AppError.message("Extension folders cannot contain links or special files.")
            }
            if values.isRegularFile == true {
                files.append(file.standardizedFileURL.resolvingSymlinksInPath()); total += values.fileSize ?? 0
                guard files.count <= 20000, total <= 512 * 1024 * 1024 else { throw AppError.message("The extension exceeds the 512 MB import limit.") }
            }
        }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.dropFirst(directory.path.count).utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(SHA256.hash(data: try Data(contentsOf: file))))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func prepare(_ source: URL) throws {
        guard pending == nil else { throw AppError.message("Finish the pending extension install first.") }
        let digest = try Self.fingerprint(source)
        guard !entries.contains(where: { $0.digest == digest }) else { throw AppError.message("This extension is already installed.") }
        let manifest = try Self.manifest(at: source)
        var name = manifest["name"] as! String
        if name.hasPrefix("__MSG_"), name.hasSuffix("__"), let locale = manifest["default_locale"] as? String,
            locale.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
            let data = try? Data(contentsOf: source.appendingPathComponent("_locales/\(locale)/messages.json")),
            let messages = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            name = messages[String(name.dropFirst(6).dropLast(2))]?["message"] as? String ?? name
        }
        let entry = Entry(id: UUID().uuidString.lowercased(), name: name, version: manifest["version"] as! String, enabled: true, digest: digest)
        let target = root.appendingPathComponent("Staging").appendingPathComponent(entry.id)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            guard try Self.fingerprint(target) == digest else { throw AppError.message("The extension changed during import. Try again.") }
            let permissions = ((manifest["permissions"] as? [String] ?? []) + (manifest["host_permissions"] as? [String] ?? []))
                + ((manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] })
            pending = Pending(entry: entry, directory: target, permissions: Array(Set(permissions)).sorted().joined(separator: "\n"))
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    func cancel() {
        if let pending { try? FileManager.default.removeItem(at: pending.directory) }
        pending = nil
    }
    func install() throws {
        guard let pending else { return }
        guard try Self.fingerprint(pending.directory) == pending.entry.digest else { throw AppError.message("The extension changed during review. Import it again.") }
        let target = directory(pending.entry)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: pending.directory, to: target)
        do { try save(entries + [pending.entry]); self.pending = nil }
        catch { try? FileManager.default.moveItem(at: target, to: pending.directory); throw error }
    }
    func pageURL(_ entry: Entry) throws -> URL? {
        guard Self.validID(entry.id) else { return nil }
        let folder = directory(entry)
        let manifest = try Self.manifest(at: folder)
        let relative = (manifest["options_ui"] as? [String: Any])?["page"] as? String
            ?? manifest["options_page"] as? String
            ?? (manifest["action"] as? [String: Any])?["default_popup"] as? String
        guard let relative, !relative.hasPrefix("/"), !relative.contains(":"), !relative.split(separator: "/").contains("..") else { return nil }
        let identifier = try Self.chromiumID(manifest: manifest, folder: folder)
        return URL(string: "chrome-extension://\(identifier)/")!.appendingPathComponent(relative)
    }
    static func chromiumID(manifest: [String: Any], folder: URL) throws -> String {
        let data: Data
        if let key = manifest["key"] as? String, let decoded = Data(base64Encoded: key) { data = decoded }
        else {
            guard let canonical = realpath(folder.path, nil) else { throw AppError.message("The extension folder is missing.") }
            defer { free(canonical) }
            data = Data(String(cString: canonical).utf8)
        }
        return SHA256.hash(data: data).prefix(16).map { String(UnicodeScalar(97 + Int($0 >> 4))!) + String(UnicodeScalar(97 + Int($0 & 15))!) }.joined()
    }
    func owns(_ url: URL) -> Bool {
        url.scheme == "chrome-extension" && entries.contains { entry in
            guard let manifest = try? Self.manifest(at: directory(entry)), let id = try? Self.chromiumID(manifest: manifest, folder: directory(entry)) else { return false }
            return entry.enabled && url.host == id
        }
    }
}
