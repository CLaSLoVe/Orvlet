#if DEBUG
    import Foundation

    /// Exercises services without constructing AppModel, windows, a browser or a model connection.
    @MainActor
    enum ServiceBoundaryCheck {
        private final class MemoryStore: RuntimeTaskStore {
            var tasks: [UUID: RuntimeTask] = [:]
            var blocked = Set<UUID>()
            func runtimeTask(_ id: UUID) -> RuntimeTask? { tasks[id] }
            func updateRuntimeTask(_ id: UUID, _ change: (inout RuntimeTask) -> Void) -> Bool {
                guard var task = tasks[id] else { return false }
                change(&task)
                tasks[id] = task
                return true
            }
            func hasTaskAction(_ id: UUID) -> Bool { blocked.contains(id) }
            func checkpointRuntime() {}
        }
        private final class Calculator: TaskCodeExecuting {
            var wrongOutput = false
            func run(code: String, input: [String: Any], state: [String: String]) async throws -> [String: Any] {
                guard state["amount"] == input["amount"] as? String else {
                    throw AppError.message("Initial and edited calculations need the same current input state")
                }
                return [
                    "state": [
                        wrongOutput ? "unexpected" : "converted": String(
                            format: "%.2f", Double(state["amount"]!)! * Double(state["rate"]!)!)
                    ]
                ]
            }
        }
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ message: String) throws {
                guard ok else { throw AppError.message(message) }
                checks.append(message)
            }
            let store = MemoryStore()
            let code = Calculator()
            let runtime = TaskRuntimeEngine(store: store, code: code)
            defer { runtime.stopAll() }
            let id = UUID()
            let start = Date().addingTimeInterval(-30)
            store.tasks[id] = RuntimeTask(
                spec: TaskRuntimeSpec(sources: [
                    TaskDataSource(
                        key: "elapsed", kind: .elapsed, format: .seconds, anchor: start.timeIntervalSince1970)
                ]), fields: [], values: [:], state: TaskRuntimeState(), status: "", dataIssue: nil, dataUpdatedAt: nil,
                resumeOnHistoryRestore: nil)
            runtime.attach(id)
            try check(
                Int(store.tasks[id]?.values["elapsed"] ?? "") ?? 0 >= 30,
                "Runtime advances through a narrow store without application or window state")
            let generation = runtime.receipts[id]?.generation
            runtime.control(id, operation: "unsupported")
            try check(
                runtime.receipts[id]?.generation == generation && store.tasks[id]?.state.phase == .running,
                "Unknown runtime controls leave active work and generation intact")
            runtime.control(id, operation: "pause")
            let pausedAt = Date().addingTimeInterval(-10)
            store.tasks[id]?.state.pausedAt = pausedAt
            runtime.control(id, operation: "pause")
            runtime.control(id, operation: "stop")
            try check(
                store.tasks[id]?.state.pausedAt == pausedAt,
                "Repeated pause and stop retain the original paused interval")
            runtime.control(id, operation: "resume")
            let anchor = store.tasks[id]!.spec.sources[0].anchor!
            try check(
                abs(anchor - start.timeIntervalSince1970 - 10) < 1,
                "Resume excludes the entire paused interval after repeated controls")
            store.tasks[id] = nil
            runtime.tick()
            try check(
                runtime.receipts[id] == nil && store.tasks.isEmpty,
                "Removing a task from the store disposes its runtime without recreating it")

            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let day = ISO8601DateFormatter().string(from: now)
            var fetches = 0
            let data = APIDataService(
                code: code,
                fetch: { _ in
                    fetches += 1
                    return ["date": day, "base": "HKD", "quote": "CNY", "rate": 0.85]
                }, now: { now })
            var spec = APIDataCheck.currency()
            let first = try await data.read(spec)
            spec.inputs?["amount"] = "100"
            let edited = try await data.calculate(spec, state: first)
            try check(
                first["converted"] == "47.60" && edited["converted"] == "85.00" && fetches == 1,
                "Initial API results and edited values share one calculator contract without another fetch")
            try check(
                data.canReuse(spec, state: first, fetchedAt: now)
                    && !data.canReuse(spec, state: first, fetchedAt: now.addingTimeInterval(30)),
                "A future cache timestamp cannot be treated as freshly fetched data")
            code.wrongOutput = true
            var rejected = 0
            do { _ = try await data.read(spec) } catch { rejected += 1 }
            do { _ = try await data.calculate(spec, state: first) } catch { rejected += 1 }
            try check(rejected == 2, "Fresh and cached calculations both reject undeclared output keys")
            return checks
        }
    }
#endif
