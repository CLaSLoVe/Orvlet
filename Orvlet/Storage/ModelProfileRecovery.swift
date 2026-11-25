import Foundation

/// User-authorized, local-only migration from the previous sandboxed build.
/// Never logs values, changes the source, or uses recovered keys for provider requests.
enum ModelProfileRecovery {
    struct Snapshot {
        let settings: AppSettings
        let credentials: [String: String]
    }
    struct Result {
        let settings: AppSettings
        let profiles: Int
        let savedAccounts: Set<String>
    }
    static var previousLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.orvlet.desktop/Data/Library", isDirectory: true)
    }
    static func read(library: URL) throws -> Snapshot {
        func readFile(_ relative: String, limit: Int) throws -> Data {
            let url = library.appendingPathComponent(relative).standardizedFileURL
            guard url.resolvingSymlinksInPath() == url,
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber, size.intValue <= limit else {
                throw AppError.message("Choose the previous Orvlet Library folder and allow access to its files.")
            }
            do { return try Data(contentsOf: url) }
            catch { throw AppError.message("macOS did not allow access to the previous Orvlet data. Choose its Library folder again.") }
        }
        let preferences = try readFile("Preferences/app.orvlet.desktop.plist", limit: 16_777_216)
        let secrets = try readFile("Application Support/Orvlet/Private/credentials-v1.json", limit: 1_048_576)
        do {
            guard let plist = try PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any],
                let data = plist["modelSettings"] as? Data else { throw ModelAccessError.authorizationRequired }
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            let credentials = try JSONDecoder().decode([String: String].self, from: secrets)
            return Snapshot(settings: settings, credentials: credentials)
        } catch { throw AppError.message("The previous model settings could not be read. No saved data was changed.") }
    }

    static func restore(_ snapshot: Snapshot, into current: AppSettings, store: LocalCredentials) throws -> Result {
        var merged = current
        merged.storeActiveProfile()
        var legacy = snapshot.settings
        legacy.storeActiveProfile()
        var keys: [String: String] = [:]
        var activeID: String?
        var count = 0
        let keepActive = try merged.main.isConfigured && (merged.main.options.authentication == .none
            || !store.load(merged.mainConnection.keyAccount).isEmpty)
        for previous in legacy.profiles where previous.endpoint.isConfigured {
            // Match complete endpoints, never attach a key to a changed provider URL.
            let match = merged.profiles.first {
                $0.endpoint == previous.endpoint && ($0.id == previous.id || $0.name == previous.name
                    || $0.name == previous.name + " (restored)")
            }
            let target: ModelProfile
            if let match { target = match }
            else {
                var recovered = previous
                if merged.profiles.contains(where: { $0.id == recovered.id }) {
                    recovered.id = UUID().uuidString
                    recovered.name += " (restored)"
                }
                recovered.credentialID = UUID().uuidString
                merged.profiles.append(recovered)
                target = recovered
            }
            if let value = snapshot.credentials[previous.keyAccount], !value.isEmpty {
                keys[target.keyAccount] = value
            }
            if previous.id == legacy.activeProfileID { activeID = target.id }
            count += 1
        }
        if !keepActive, let activeID, let profile = merged.profiles.first(where: { $0.id == activeID }) {
            merged.activeProfileID = activeID
            merged.main = profile.endpoint
        }
        if try store.load(merged.fastKeyAccount).isEmpty,
            let value = snapshot.credentials[legacy.fastKeyAccount], !value.isEmpty, legacy.fast.isConfigured {
            merged.fast = legacy.fast
            merged.fastProtocol = legacy.fastProtocol
            merged.fastKeyReference = nil
            merged.fastCredentialID = UUID().uuidString
            keys[merged.fastKeyAccount] = value
        }
        guard count > 0 || !keys.isEmpty else {
            throw AppError.message("No saved model profiles were found. Current settings were kept.")
        }
        try store.importMissing(keys)
        var saved: Set<String> = []
        for account in merged.profiles.map(\.keyAccount) + [merged.fastKeyAccount] {
            if try !store.load(account).isEmpty { saved.insert(account) }
        }
        return Result(settings: merged, profiles: count, savedAccounts: saved)
    }
}
