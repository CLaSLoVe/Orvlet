import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var url: String
    var kind: String
}
struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var taskID: UUID? = nil
    var requestID: UUID? = nil
    let text: String
    let isUser: Bool
    var editsInterface: Bool? = nil
    var issueSource: String? = nil
    var issueResource: UUID? = nil
    var issueResolved: Bool? = nil
}
