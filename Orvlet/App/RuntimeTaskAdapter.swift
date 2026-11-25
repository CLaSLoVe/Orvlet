import Foundation

/// Maps runtime-owned fields into observable/persisted tasks at the composition boundary.
/// Updates are synchronous and never create a missing task.
extension AppModel: RuntimeTaskStore {
    func runtimeTask(_ id: UUID) -> RuntimeTask? {
        if let artifact = work.artifact(id), let spec = artifact.definition.runtime {
            return RuntimeTask(spec: spec, fields: artifact.definition.fields, values: artifact.values,
                state: artifact.runtimeState ?? TaskRuntimeState(), status: artifact.status,
                dataIssue: artifact.issue, dataUpdatedAt: artifact.checked, resumeOnHistoryRestore: nil)
        }
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
        if let artifact = work.artifact(id), var runtime = runtimeTask(id) {
            change(&runtime)
            let phaseChanged = runtime.state.phase != (artifact.runtimeState?.phase ?? .running)
            let updated = work.update(id, expecting: artifact.revision, persist:false, advanceRevision:phaseChanged) {
                $0.definition.runtime = runtime.spec; $0.values = runtime.values; $0.runtimeState = runtime.state
                $0.status = runtime.status; $0.issue = runtime.dataIssue
                if let date = runtime.dataUpdatedAt { $0.checked = date }
            }
            if updated {
                projectWorkResult(id)
                if runtime.dataIssue == nil { resolveTaskIssue(id, source: .runtime) }
            }
            return updated
        }
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
        if runtime.dataIssue == nil { resolveTaskIssue(id, source: .runtime) }
        return true
    }
    func hasTaskAction(_ id: UUID) -> Bool { workJobs[id] != nil || taskActionJobs[id] != nil }
    func checkpointRuntime() { persistSideTasks() }
}
