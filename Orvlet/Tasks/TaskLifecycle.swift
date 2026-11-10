import Foundation

/// Request ownership is independent of the window the human is looking at.
struct TaskRequestContext {
    enum Stage: String { case understanding, executing, presenting, verifying }
    struct Owner: Equatable {
        let id: UUID
        let kind: SideTaskKind
        static func web(_ id: UUID) -> Owner { Owner(id: id, kind: .web) }
        static func workspace(_ id: UUID) -> Owner { Owner(id: id, kind: .workspace) }
    }
    let id = UUID()
    var input: String
    let receivedAt: Date
    let startPolicy: TaskStartPolicy
    var submittedTaskID: UUID?
    var sourceCandidateID: UUID?
    var messageID: UUID?
    var stage: Stage = .understanding
    var stageStartedAt = Date()
    var placeholderID: UUID?
    var owner: Owner?
    var presentationFailure: String?
}

/// Execution and presentation advance independently. A result can only commit
/// to the task and lane that issued it, and never after a newer operation.
struct TaskRevisionLedger {
    enum Lane: Hashable { case execution, interface }
    struct Ticket: Equatable {
        let taskID: UUID
        let lane: Lane
        let revision = UUID()
    }
    private var current: [UUID: [Lane: Ticket]] = [:]
    mutating func begin(_ id: UUID, _ lane: Lane) -> Ticket {
        let ticket = Ticket(taskID: id, lane: lane)
        current[id, default: [:]][lane] = ticket
        return ticket
    }
    func accepts(_ ticket: Ticket) -> Bool { current[ticket.taskID]?[ticket.lane] == ticket }
    mutating func finish(_ ticket: Ticket) {
        guard accepts(ticket) else { return }
        invalidate(ticket.taskID, ticket.lane)
    }
    mutating func invalidate(_ id: UUID, _ lane: Lane? = nil) {
        if let lane {
            current[id]?[lane] = nil
            if current[id]?.isEmpty == true { current[id] = nil }
        } else {
            current[id] = nil
        }
    }
}

extension AppModel {
    func transitionRequest(to stage: TaskRequestContext.Stage) {
        guard var request = activeRequest, request.stage != stage else { return }
        Diagnostics.record(
            "request_stage",
            [
                "requestID": request.id.uuidString, "stage": request.stage.rawValue,
                "seconds": Date().timeIntervalSince(request.stageStartedAt),
            ])
        request.stage = stage
        request.stageStartedAt = Date()
        activeRequest = request
    }
    // Read-only projections keep rendering code simple; mutations belong here.
    var requestCardID: UUID? { activeRequest?.placeholderID }
    var requestPageID: UUID? {
        activeRequest?.owner?.kind == .web ? activeRequest?.owner?.id : nil
    }
    var requestTaskID: UUID? {
        activeRequest?.owner?.kind != .web ? activeRequest?.owner?.id : nil
    }
    func adoptRequestTask(_ owner: TaskRequestContext.Owner) {
        guard var request = activeRequest else { return }
        let prior = request.placeholderID ?? (request.owner?.kind == .result ? request.owner?.id : nil)
        if let prior, prior != owner.id {
            taskAliases[prior] = owner.id
            for index in queuedTaskRequests.indices where queuedTaskRequests[index].taskID == prior {
                queuedTaskRequests[index].taskID = owner.id
                queuedTaskRequests[index].isNewTask = false
                queuedTaskRequests[index].prepared = nil
            }
            for index in messages.indices where messages[index].taskID == prior { messages[index].taskID = owner.id }
            if conversationTaskID == prior { conversationTaskID = owner.id }
            if let draft = conversationDrafts.removeValue(forKey: prior) { conversationDrafts[owner.id] = draft }
            archivedTaskHistory.removeAll { $0.id == prior }
            persistTaskHistory()
            if request.submittedTaskID == prior { request.submittedTaskID = owner.id }
            request.placeholderID = prior
        }
        request.owner = owner
        associateMessages(requestID: request.id, messageID: request.messageID, taskID: owner.id)
        if let placeholder = request.placeholderID {
            if conversationTaskID == placeholder { conversationTaskID = owner.id }
            archivedTaskHistory.removeAll { $0.id == placeholder }
            if placeholder != owner.id, let index = sideTasks.firstIndex(where: { $0.id == placeholder }) {
                if sideTasks.contains(where: { $0.id == owner.id }) {
                    sideTasks.remove(at: index)
                } else {
                    // Move the preparation card into the resolved task in place.
                    sideTasks[index].id = owner.id
                    sideTasks[index].kind = owner.kind
                }
            }
            request.placeholderID = nil
        }
        activeRequest = request
        ambientRequestID = owner.id
    }
    func beginTaskRevision(_ id: UUID, _ lane: TaskRevisionLedger.Lane) -> TaskRevisionLedger.Ticket {
        switch lane {
        case .interface: interfaceJobs.removeValue(forKey: id)?.cancel()
        case .execution: taskActionJobs.removeValue(forKey: id)?.cancel()
        }
        return taskRevisions.begin(id, lane)
    }
    func accepts(_ ticket: TaskRevisionLedger.Ticket) -> Bool {
        taskRevisions.accepts(ticket) && sideTasks.contains { $0.id == ticket.taskID }
    }
    func resolvedTaskID(_ id: UUID) -> UUID {
        var value = id
        var seen = Set<UUID>()
        while seen.insert(value).inserted, let next = taskAliases[value] { value = next }
        return value
    }
    func ownsRequest(_ id: UUID) -> Bool {
        activeRequest?.owner?.id == id || requestCardID == id
    }
}
