import Foundation

/// The actor serializes commits. Each asynchronous command inherits just its own execution state.
@MainActor
final class RequestRun {
    @TaskLocal static var current: RequestRun?
    unowned let model: AppModel
    lazy var agent = AgentController(model: model)
    var context: TaskRequestContext?
    var reviewedReadings = Set<String>()
    var conversationReference: UUID?
    var assignment: CardAssignment?
    var initialFamilies = Set<String>()
    let forceNewTask: Bool
    let initialCandidates: Set<UUID>
    var ambientID: UUID?
    var receivedAt = Date()
    var intent = ""
    var streamText = ""
    var activity = ""
    var failed = false
    var stopping = false
    var job: Task<Void, Never>?
    init(model: AppModel, forceNewTask: Bool = false) {
        self.model = model
        self.forceNewTask = forceNewTask
        initialCandidates = forceNewTask ? [] : Set((model.sideTasks + model.archivedTaskHistory).map(\.id))
    }
    func owns(_ id: UUID) -> Bool {
        context?.owner?.id == id || context?.placeholderID == id
    }
}

extension AppModel {
    func runOwning(_ id: UUID) -> RequestRun? { commandRuns.first { $0.owns(id) } }

    var currentRun: RequestRun {
        if let run = RequestRun.current, run.model === self { return run }
        if let id = conversationTaskID, let run = runOwning(id) { return run }
        return commandRuns.last ?? idleRun
    }

    func stopCommand(for id: UUID) {
        if let run = runOwning(id) {
            RequestRun.$current.withValue(run) { cancel() }
        } else if commandRuns.isEmpty && ownsRequest(id) { cancel() }
    }

    // The shared browser stays with one command through tool execution and verification.
    func acquireBrowserForCommand() async throws {
        guard let run = RequestRun.current, commandRuns.contains(where: { $0 === run }) else { return }
        if let owner = browserRun, owner !== run { activity = "Waiting for the browser…" }
        while let owner = browserRun, owner !== run {
            try await Task.sleep(for: .milliseconds(80))
        }
        try Task.checkCancellation()
        browserRun = run
    }
}
