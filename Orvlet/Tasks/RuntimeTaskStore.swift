import Foundation

/// The scheduler can read and change only runtime-owned fields of an existing task.
/// It cannot create cards, select windows, route requests, access credentials or browse.
struct RuntimeTask {
    var spec: TaskRuntimeSpec
    var fields: [String]
    var values: [String: String]
    var state: TaskRuntimeState
    var status: String
    var dataIssue: String?
    var dataUpdatedAt: Date?
    var resumeOnHistoryRestore: Bool?
}

@MainActor
protocol RuntimeTaskStore: AnyObject {
    func runtimeTask(_ id: UUID) -> RuntimeTask?
    @discardableResult func updateRuntimeTask(_ id: UUID, _ change: (inout RuntimeTask) -> Void) -> Bool
    func hasTaskAction(_ id: UUID) -> Bool
    func checkpointRuntime()
}
