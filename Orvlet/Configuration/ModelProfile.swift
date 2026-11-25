import Foundation

enum ModelProvider: String, CaseIterable {
    case gpt, custom
    var title: String { self == .gpt ? "GPT" : "Custom" }
    static func provider(for endpoint: Endpoint) -> Self {
        let url = endpoint.completionURL
        return url?.host == "api.openai.com" && url?.scheme == "https" && url?.port == nil
            && !endpoint.options.exactURL ? .gpt : .custom
    }
    // Official tool-capable models; retain saved model IDs outside this list.
    static let gptModels = ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna"]
}

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
    var modelProvider: ModelProvider { ModelProvider.provider(for: main) }
    mutating func selectModelProvider(_ provider: ModelProvider) {
        storeActiveProfile()
        preferredModelProfiles[modelProvider.rawValue] = activeProfileID
        let matching = profiles.filter { ModelProvider.provider(for: $0.endpoint) == provider }
        if let selected = matching.first(where: { $0.id == preferredModelProfiles[provider.rawValue] }) ?? matching.first {
            _ = selectProfile(selected.id)
        } else {
            var endpoint = Endpoint()
            if provider == .gpt {
                endpoint = Endpoint(baseURL: "https://api.openai.com/v1", model: ModelProvider.gptModels[0])
                endpoint.options.api = .responses
                endpoint.vision = true
            }
            let profile = ModelProfile(name: provider == .gpt ? "GPT" : "Custom", endpoint: endpoint)
            profiles.append(profile)
            activeProfileID = profile.id
            main = endpoint
        }
        configureModelProvider()
    }
    mutating func configureModelProvider() {
        storeActiveProfile()
        preferredModelProfiles[modelProvider.rawValue] = activeProfileID
        selectDecisionAPI(modelProvider == .gpt ? .openAI : .jev)
        if modelProvider == .gpt {
            main.options.api = .responses
            storeActiveProfile()
            fast = DecisionAPI.openAI.defaultEndpoint
            fastKeyReference = mainConnection.keyAccount
        }
        useFast = true
    }
    var mainConnection: ModelConnection {
        ModelConnection(
            endpoint: main.toolCompatible, keyAccount: profiles.first(where: { $0.id == activeProfileID })?.keyAccount ?? "main")
    }
    var fastKeyAccount: String { decisionKeyReference ?? fastCredentialID.map { "fast." + $0 } ?? "fast" }
    mutating func ensureProfiles() {
        main = main.toolCompatible
        for index in profiles.indices { profiles[index].endpoint = profiles[index].endpoint.toolCompatible }
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
