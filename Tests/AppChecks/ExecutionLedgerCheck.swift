#if DEBUG
    import Foundation

    @MainActor
    enum ExecutionLedgerCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw AppError.message(label) }
                checks.append(label)
            }
            let suite = "orvlet.execution." + UUID().uuidString
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            defer { model.browser.dispose() }
            var decisions = 0
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .timer)
                intent.timerSeconds = 60
                intent.timerEvidence = "one minute"
                intent.goals = ["Start a one minute timer"]
                intent.steps = [.init(tool: "timer_start", arguments: "{\"seconds\":60}", goal: 0)]
                intent.stepsComplete = false  // Reproduce the original partial-plan trigger with a different capability.
                return intent
            }
            model.agent.completionOverride = { _ in
                decisions += 1
                return ["tool_calls": [RequestStep(tool: "timer_start", arguments: "{\"seconds\":60}").call]]
            }
            _ = try await model.agent.run("Start a one minute timer")
            try check(
                decisions == 0 && model.sideTasks.filter { $0.kind == .timer }.count == 1,
                "Verified goal ends a partial plan without another model decision or repeated effect")
            let ledger = model.agent.executionLedger
            model.agent.nativeRequestActive = true
            _ = try await model.agent.execute("timer_start", ["seconds": 60, "title": "Another generated label"])
            try check(
                model.sideTasks.filter { $0.kind == .timer }.count == 1,
                "A completed goal cannot be replayed with changed arguments")
            model.agent.nativeRequestActive = false
            _ = try await model.agent.run("Start another one minute timer")
            try check(
                model.sideTasks.filter { $0.kind == .timer }.count == 2 && model.agent.executionLedger !== ledger,
                "A new human request may intentionally repeat the same effect")

            let timer = model.sideTasks.first { $0.kind == .timer }!
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.targetTaskID = timer.id.uuidString
                intent.route = .local
                intent.goals = ["Pause this timer", "Resume this timer"]
                intent.steps = [.init(tool: "control_task", arguments: "{\"operation\":\"pause\"}", goal: 0)]
                return intent
            }
            model.agent.completionOverride = { _ in
                decisions += 1
                return [
                    "tool_calls": [
                        [
                            "id": UUID().uuidString, "type": "function",
                            "function": [
                                "name": "control_task", "arguments": "{\"operation\":\"resume\",\"goal\":1}",
                            ],
                        ]
                    ]
                ]
            }
            _ = try await model.agent.run("Pause then resume this timer", taskID: timer.id)
            try check(
                decisions == 1 && model.agent.executionLedger.complete
                    && model.sideTasks.first(where: { $0.id == timer.id })?.deadline != nil,
                "An intermediate verified goal retains its receipt while a later goal still executes")

            model.agent.executionLedger = RequestExecutionLedger()
            model.agent.nativeRequestActive = true
            let computation: [String: Any] = ["code": "return {state:{value:'42'}};"]
            let firstWork = Task { @MainActor in try await model.agent.execute("run_code", computation) }
            let secondWork = Task { @MainActor in try await model.agent.execute("run_code", computation) }
            let firstResult = try await firstWork.value
            let secondResult = try await secondWork.value
            try check(
                firstResult["run_id"] as? String == secondResult["run_id"] as? String
                    && firstResult["run_id"] is String,
                "Concurrent copies of an operation share one real execution and receipt")

            let independent = try await model.agent.execute("run_code", computation, requestScoped: false)
            model.agent.nativeRequestActive = false
            try check(
                independent["run_id"] as? String != firstResult["run_id"] as? String,
                "Separate integration commands do not inherit another request's deduplication ledger")

            let pending = RequestExecutionLedger()
            pending.configure(goals: ["Change a setting"])
            model.agent.executionLedger = pending
            pending.uncertainGoals.insert(0)
            var blocked = false
            do { _ = try await model.agent.execute("control_task", ["operation": "restart"]) } catch { blocked = true }
            try check(
                blocked && pending.fulfilled.isEmpty, "Uncertain effects require verification before further mutation")
            let first = RequestExecutionLedger.signature(
                "control_task", ["operation": "pause", "complete": false], goal: 0)
            let second = RequestExecutionLedger.signature(
                "control_task", ["complete": true, "operation": "pause"], goal: 0)
            try check(first == second, "Completion hints and JSON key order cannot bypass effect identity")
            model.agent.steer("Use a different task")
            try check(
                model.agent.executionLedger !== pending && model.agent.lastToolVerification == nil,
                "Steering gives the new request separate evidence and invalidates old completion")
            return checks
        }
    }
#endif
