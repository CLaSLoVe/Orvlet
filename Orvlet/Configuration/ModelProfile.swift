import Foundation

struct ModelProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var endpoint: Endpoint
    // The migrated profile retains its existing credential reference without reading the key.
    var credentialID: String? = UUID().uuidString
    var keyAccount: String { credentialID.map { "main.profile." + $0 } ?? "main" }
}

struct ModelConnection {
    let endpoint: Endpoint
    let keyAccount: String
    func loadKey() async throws -> String {
        if endpoint.options.authentication == .none { return "" }
        return try await SecretStore.load(keyAccount)
    }
}

extension AppSettings {
    var mainConnection: ModelConnection {
        ModelConnection(
            endpoint: main, keyAccount: profiles.first(where: { $0.id == activeProfileID })?.keyAccount ?? "main")
    }
    var fastKeyAccount: String { fastCredentialID.map { "fast." + $0 } ?? "fast" }
    mutating func ensureProfiles() {
        if profiles.isEmpty {
            profiles = [
                ModelProfile(
                    id: "legacy", name: main.model.isEmpty ? "Default" : main.model, endpoint: main, credentialID: nil)
            ]
            activeProfileID = "legacy"
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
            main = profiles[0].endpoint
        }
    }
    mutating func storeActiveProfile() {
        ensureProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        if profiles[index].endpoint.completionURL?.host != main.completionURL?.host {
            profiles[index].credentialID = UUID().uuidString
        }
        profiles[index].endpoint = main
        if profiles[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profiles[index].name = main.model.isEmpty ? "Untitled" : main.model
        }
    }
    @discardableResult mutating func selectProfile(_ id: String) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        storeActiveProfile()
        activeProfileID = id
        main = profiles.first(where: { $0.id == id })!.endpoint
        return true
    }
    mutating func addProfile() {
        storeActiveProfile()
        let profile = ModelProfile(name: "New profile", endpoint: Endpoint())
        profiles.append(profile)
        activeProfileID = profile.id
        main = profile.endpoint
    }
    @discardableResult mutating func removeProfile(_ id: String) -> Bool {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return false }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles[0].id
            main = profiles[0].endpoint
        }
        return true
    }
}
