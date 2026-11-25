import Foundation

enum DecisionAPI: String, Codable, CaseIterable {
    case jev, openAI
    var title: String { self == .jev ? "Jev" : "OpenAI Decisions" }
    var path: String { self == .jev ? "systemone" : "decisions" }
    var host: String { self == .jev ? "api.typesafe.ai" : "api.openai.com" }
    var defaultModel: String { self == .jev ? "jev-latest" : "gpt-6-luna" }
    var defaultEndpoint: Endpoint { Endpoint(baseURL: "https://\(host)/v1", model: defaultModel) }
    func url(for endpoint: Endpoint) -> URL? {
        // Reuse the endpoint's transport validation and preserve query parameters.
        var checked = endpoint
        checked.options.exactURL = true
        guard let url = checked.completionURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !endpoint.options.exactURL {
            var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for suffix in ModelAPI.allCases.map(\.path) + DecisionAPI.allCases.map(\.path) {
                if path == suffix { path = ""; break }
                if path.hasSuffix("/" + suffix) { path = String(path.dropLast(suffix.count + 1)); break }
            }
            parts.path = "/" + (path.isEmpty ? "" : path + "/") + self.path
        }
        return parts.url
    }
    func allowsBackground(_ endpoint: Endpoint) -> Bool {
        let url = url(for: endpoint)
        return url?.scheme == "https" && url?.host == host && url?.port == nil
    }
}

struct DecisionConfiguration: Codable {
    var endpoint: Endpoint
    var credentialID: String?
    var keyReference: String?
}

extension AppSettings {
    var decisionAPI: DecisionAPI { DecisionAPI(rawValue: fastProtocol) ?? .jev }
    var decisionKeyReference: String? {
        guard let reference = fastKeyReference,
            let profile = profiles.first(where: { $0.keyAccount == reference }),
            profile.endpoint.completionURL?.host == decisionAPI.url(for: fast)?.host,
            decisionAPI.allowsBackground(fast) else { return nil }
        return reference
    }
    mutating func selectDecisionAPI(_ api: DecisionAPI) {
        guard api != decisionAPI else { return }
        decisionConfigurations[decisionAPI.rawValue] = DecisionConfiguration(endpoint: fast, credentialID: fastCredentialID, keyReference: fastKeyReference)
        let saved = decisionConfigurations[api.rawValue]
        fast = saved?.endpoint ?? api.defaultEndpoint
        fastCredentialID = saved == nil ? UUID().uuidString : saved?.credentialID
        fastKeyReference = saved?.keyReference
        fastProtocol = api.rawValue
        if saved == nil, api == .openAI {
            // Reference the existing key without reading, copying or exposing it.
            let matching = profiles.filter { $0.endpoint.completionURL?.host == api.host && $0.endpoint.completionURL?.scheme == "https" }
            fastKeyReference = (matching.first(where: { $0.id == activeProfileID }) ?? matching.first)?.keyAccount
        }
    }
}
