import Foundation

@MainActor
enum JevClient {
    static func judge(
        endpoint: Endpoint, key: String, state: Any, questions: [String: String], timeout: TimeInterval = 4
    ) async throws -> [String: Double] {
        guard endpoint.isConfigured else { return [:] }
        let base = endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base.hasSuffix("/systemone") ? base : base + "/systemone") else { return [:] }
        let typed = questions.mapValues { ["type": "noul", "instructions": $0] }
        let result = try await ModelClient.request(
            url: url, key: key, body: ["model": endpoint.model, "state": state, "questions": typed], timeout: timeout)
        let answers = result["answers"] as? [String: [String: Any]] ?? [:]
        return answers.compactMapValues { $0["noul"] as? Double }
    }
}
