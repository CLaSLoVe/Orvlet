import Foundation
import SQLite3

/// Explicit, local-only snapshot. Never imports passwords, history or open tabs.
enum BrowserProfileImporter {
    struct Profile: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let directory: URL
    }
    nonisolated static func profiles(in userData: URL) -> [Profile] {
        guard let bytes = try? Data(contentsOf: userData.appendingPathComponent("Local State")),
            let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let profile = state["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.keys.sorted().compactMap { id in
            guard id == "Default" || (id.hasPrefix("Profile ") && Int(id.dropFirst(8)) != nil),
                let value = cache[id] as? [String: Any] else { return nil }
            return Profile(id: id, name: value["name"] as? String ?? id, directory: userData.appendingPathComponent(id))
        }
    }

    nonisolated private static func copyTree(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let values = try from.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw AppError.message("Browser data contains a redirected file; import was cancelled.") }
        if values.isDirectory == true {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: Array(keys)) {
                try copyTree(file, to.appendingPathComponent(file.lastPathComponent))
            }
        } else if values.isRegularFile == true { try fm.copyItem(at: from, to: to) }
        else { throw AppError.message("Browser data contains an unsupported file; import was cancelled.") }
    }

    /// SQLite's online backup includes committed WAL data without locking or modifying the source browser.
    nonisolated static func snapshotDatabase(_ source: URL, to target: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            throw AppError.message("The browser cookies could not be read.")
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(target.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw AppError.message("The browser cookie snapshot could not be created.")
        }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw AppError.message("The browser cookie snapshot could not start.")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw AppError.message("The browser is changing its cookies. Try importing again.")
        }
    }

    nonisolated static func stage(profile: Profile, applicationData: URL, destination: URL,
        includeExtensions: Bool = true) throws -> URL {
        let fm = FileManager.default
        guard profile.directory.deletingLastPathComponent().standardizedFileURL == applicationData.standardizedFileURL,
            profile.directory.resolvingSymlinksInPath() == profile.directory.standardizedFileURL else {
            throw AppError.message("Choose a browser profile from the list.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent("import-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let target = staging.appendingPathComponent("Default")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for relative in ["Cookies", "Network/Cookies"] {
                let source = profile.directory.appendingPathComponent(relative)
                if fm.fileExists(atPath: source.path) {
                    guard source.resolvingSymlinksInPath() == source.standardizedFileURL else {
                        throw AppError.message("Browser cookies are redirected; import was cancelled.")
                    }
                    let copy = target.appendingPathComponent(relative)
                    try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try snapshotDatabase(source, to: copy)
                }
            }
            // Import enabled store-installed code as an independent unpacked copy. Do not copy protected
            // browser preferences or silently re-enable extensions the person had disabled.
            var installations: [String: Any] = [:]
            for name in includeExtensions ? ["Preferences", "Secure Preferences"] : [] {
                let file = profile.directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { continue }
                guard file.resolvingSymlinksInPath() == file.standardizedFileURL else {
                    throw AppError.message("Browser settings are redirected; import was cancelled.")
                }
                if let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                    let extensions = value["extensions"] as? [String: Any], let settings = extensions["settings"] as? [String: Any] {
                    installations.merge(settings) { _, new in new }
                }
            }
            let extensionRoot = profile.directory.appendingPathComponent("Extensions").standardizedFileURL
            var extensionCount = 0
            for (id, raw) in installations {
                guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
                    let entry = raw as? [String: Any], entry["state"] as? Int == 1,
                    let relative = entry["path"] as? String,
                    (entry["disable_reasons"] as? [Any] ?? []).isEmpty else { continue }
                let source = extensionRoot.appendingPathComponent(relative).standardizedFileURL
                guard source.path.hasPrefix(extensionRoot.path + "/"),
                    source.resolvingSymlinksInPath() == source,
                    fm.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { continue }
                let code = staging.appendingPathComponent("UnpackedExtensions/" + id)
                try copyTree(source, code)
                extensionCount += 1
            }
            try JSONSerialization.data(withJSONObject: ["session": ["restore_on_startup": 5]]).write(to: target.appendingPathComponent("Preferences"))
            try JSONSerialization.data(withJSONObject: ["extensionsImported": extensionCount]).write(to: staging.appendingPathComponent("orvlet-import.json"))
            let localState = applicationData.appendingPathComponent("Local State")
            guard localState.resolvingSymlinksInPath() == localState.standardizedFileURL else {
                throw AppError.message("Browser settings are redirected; import was cancelled.")
            }
            if let data = try? Data(contentsOf: localState),
                let original = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Preserve the browser's encrypted-key envelope as-is. No decryption or keychain extraction.
                let selected = original.filter { $0.key == "os_crypt" }
                try JSONSerialization.data(withJSONObject: selected).write(to: staging.appendingPathComponent("Local State"))
            }
            try Data("Orvlet isolated browser profile\n".utf8).write(to: staging.appendingPathComponent(".orvlet-profile"))
            return staging
        } catch { try? fm.removeItem(at: staging); throw error }
    }
}
