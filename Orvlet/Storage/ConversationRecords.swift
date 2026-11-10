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
}
