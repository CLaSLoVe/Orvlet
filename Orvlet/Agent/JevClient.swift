import Foundation

@MainActor
enum JevClient {
    static func judge(
        endpoint: Endpoint, key: String, state: Any, questions: [String: String], timeout: TimeInterval = 4
    ) async throws -> [String: Double] {
        return try await DecisionClient.judge(endpoint: endpoint, api: .jev, key: key, state: state, questions: questions, timeout: timeout)
    }
}
