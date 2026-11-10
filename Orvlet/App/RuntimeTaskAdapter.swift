import Foundation

/// Maps runtime-owned fields into observable/persisted tasks at the composition boundary.
/// Updates are synchronous and never create a missing task.
extension AppModel: RuntimeTaskStore {
    func runtimeTask(_ id: UUID) -> RuntimeTask? {
        guard let task = sideTasks.first(where: { $0.id == id }), let surface = task.taskSurface,
            let spec = surface.runtime
        else { return nil }
        return RuntimeTask(
            spec: spec, fields: surface.fields, values: task.liveValues ?? surface.state,
            state: task.runtimeState ?? TaskRuntimeState(), status: task.status,
            dataIssue: task.dataIssue, dataUpdatedAt: task.dataUpdatedAt,
            resumeOnHistoryRestore: task.resumeOnHistoryRestore)
    }
    @discardableResult
    func updateRuntimeTask(_ id: UUID, _ change: (inout RuntimeTask) -> Void) -> Bool {
        guard var runtime = runtimeTask(id), let index = sideTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        change(&runtime)
        // One published update; unrelated conversation, source and presentation fields stay owned by the app.
        var task = sideTasks[index]
        task.taskSurface?.runtime = runtime.spec
        task.liveValues = runtime.values
        task.runtimeState = runtime.state
        task.status = runtime.status
        task.dataIssue = runtime.dataIssue
        task.dataUpdatedAt = runtime.dataUpdatedAt
        task.resumeOnHistoryRestore = runtime.resumeOnHistoryRestore
        sideTasks[index] = task
        return true
    }
    func hasTaskAction(_ id: UUID) -> Bool { taskActionJobs[id] != nil }
    func checkpointRuntime() { persistSideTasks() }
}
