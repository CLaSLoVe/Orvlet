import Foundation

/// The actor serializes commits. Each asynchronous command inherits just its own execution state.
@MainActor
final class RequestRun {
    @TaskLocal static var current: RequestRun?
    unowned let model: AppModel
    let goalID = UUID()
    let runID = UUID()
    private(set) var resultIDs: [UUID] = []
    var publishedViewIDs = Set<UUID>()
    private(set) var awaitingPresentation = false
    func retainResult(_ id: UUID, needsView: Bool = false) {
        if !resultIDs.contains(id) { resultIDs.append(id) }
        model.work.link(id,to:goalID)
        if needsView { awaitingPresentation = true }
    }
    func markPresented(_ ids: [UUID]) {
        for id in ids { retainResult(id, needsView: false) }
        // Delivery belongs to the goal. An interactive tool can use several
        // retained sources without exposing each source as a separate view.
        awaitingPresentation = false
    }
    lazy var agent = AgentController(model: model)
    var context: TaskRequestContext?
    var reviewedReadings = Set<String>()
    var editsInterface = false
    var conversationReference: UUID?
    var assignment: CardAssignment?
    var attachments: [String: String] = [:]
    var initialFamilies = Set<String>()
    let forceNewTask: Bool
    let initialCandidates: Set<UUID>
    let initialResources: Set<UUID>
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
        initialResources = Set((model.sideTasks + model.archivedTaskHistory).map(\.id))
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
