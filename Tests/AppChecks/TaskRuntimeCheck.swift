#if DEBUG
    import Foundation

    @MainActor
    enum TaskRuntimeCheck {
        static let splitCode = """
            const amount = Number(input.amount ?? state.amount);
            const people = Number(input.people ?? state.people);
            if (!Number.isFinite(amount) || amount < 0 || !Number.isInteger(people) || people < 1) throw new Error('Enter a valid amount and at least one person.');
            return {state:{amount:String(amount),people:String(people),share:(amount/people).toFixed(2)}};
            """
        static func surface() -> TaskSurface {
            TaskSurface(
                title: "Split the bill",
                markup: CardMarkup(
                    html:
                        "<section class='calm-surface'><div class='calm-result'><small class='calm-label'>Per person</small><strong class='calm-value' data-bind='share'></strong></div><div class='calm-fields'><label class='calm-field'>Amount<input type='number' data-field='amount'></label><label class='calm-field'>People<input type='number' data-field='people'></label></div><div class='calm-actions'><button class='calm-primary' data-action='calculate'>Calculate</button><button class='calm-secondary' data-action='refine'>Adjust with agent</button></div></section>",
                    compactHTML:
                        "<div class='calm-glance'><small class='calm-label'>Per person</small><strong class='calm-value' data-bind='share'></strong></div>",
                    css: "", height: 200),
                fields: ["amount", "people"],
                actions: [
                    TaskSurfaceAction(id: "calculate", kind: .code, code: splitCode),
                    TaskSurfaceAction(
                        id: "refine", kind: .agent, prompt: "Adjust this bill-splitting task using the supplied fields."
                    ),
                ], state: ["amount": "120", "people": "3", "share": "40.00"])
        }
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message(label) }
                checks.append(label)
            }
            var optionalFields = surface()
            optionalFields.actions[0].prompt = ""
            optionalFields.actions[1].code = "  "
            let normalized = try optionalFields.validated()
            try check(
                normalized.actions[0].prompt == nil && normalized.actions[1].code == nil,
                "Empty optional action fields from a model are normalized rather than rejected")
            let runtime = TaskCodeRuntime()
            let first = try await runtime.run(code: splitCode, input: ["amount": "120", "people": "3"])
            try check(
                try TaskValues.decode(first)["share"] == "40.00",
                "A separate code worker executes real generated calculation logic")
            let globals = try await runtime.run(
                code: "return {value:[typeof fetch,typeof require,typeof process,typeof window,typeof ObjC].join(',')};"
            )
            try check(
                globals["value"] as? String == "undefined,undefined,undefined,undefined,undefined",
                "Generated code has no browser, network, shell, process or Objective-C bridge")
            _ = try await runtime.run(code: "globalThis.hiddenValue=42; return {ok:true};")
            let isolated = try await runtime.run(code: "return {value:typeof hiddenValue};")
            try check(
                isolated["value"] as? String == "undefined",
                "Each execution receives a fresh process and cannot inherit another task's globals")
            var rejected = false
            do { try await runtime.validate(["return ; unexpected syntax ???"]) } catch { rejected = true }
            try check(rejected, "Invalid generated handlers are rejected before publishing their interface")
            rejected = false
            do { _ = try await runtime.run(code: "return Promise.resolve({value:42});") } catch { rejected = true }
            try check(rejected, "A Promise cannot be mistaken for a completed calculation")
            runtime.timeout = 0.4
            rejected = false
            do { _ = try await runtime.run(code: "while(true) {}") } catch { rejected = true }
            try check(
                rejected && runtime.runningCount == 0, "An infinite calculation times out and its worker is terminated")
            runtime.timeout = 3
            let cancelled = Task { try await runtime.run(code: "while(true) {}") }
            for _ in 0..<100 {
                if runtime.runningCount > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            cancelled.cancel()
            rejected = false
            do { _ = try await cancelled.value } catch is CancellationError { rejected = true }
            try check(
                rejected && runtime.runningCount == 0,
                "Cancellation terminates a running calculation without leaving a worker")

            let suite = "orvlet-task-runtime-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings = AppSettings()
            defer {
                model.dismissFeedback()
                model.taskClock?.invalidate()
                for job in model.taskActionJobs.values { job.cancel() }
            }
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
            var calls = 0
            func tool(_ name: String, _ args: [String: Any]) -> [String: Any] {
                [
                    "id": UUID().uuidString, "type": "function",
                    "function": ["name": name, "arguments": JSONText.encode(args)],
                ]
            }
            func response(_ tools: [[String: Any]]) -> [String: Any] { ["role": "assistant", "tool_calls": tools] }
            model.agent.completionOverride = { turns in
                calls += 1
                try check(
                    !turns.contains(where: { ($0["content"] as? String ?? "").hasPrefix("Current page context") }),
                    "Independent task decisions do not receive an unrelated browser observation")
                if calls == 1 {
                    var bridgeRejected = false
                    do {
                        _ = try await model.bridge.route(
                            "/rpc", ["tool": "run_code", "arguments": ["code": "return {value:1};"]])
                    } catch { bridgeRejected = true }
                    try check(bridgeRejected, "An external bridge cannot borrow an active task to execute code")
                    return response([tool("run_code", ["code": splitCode, "input": ["amount": "120", "people": "3"]])])
                }
                let results = turns.filter { $0["role"] as? String == "tool" }.compactMap { row -> [String: Any]? in
                    guard let text = row["content"] as? String else { return nil }
                    return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                }
                guard results.first(where: { $0["run_id"] != nil })?["run_id"] is String else {
                    throw AppError.message("Missing code receipt")
                }
                var ui = surface()
                ui.runID = nil
                ui.state["share"] = "fabricated"
                let args = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ui)) as! [String: Any]
                return response([
                    tool("present_ui", args),
                    tool("finish", ["outcome": "task_ready", "reply": "Your bill split is ready."]),
                ])
            }
            let reply = try await model.agent.run(
                "Split a bill of 120 between three people and let me change the numbers")
            guard let task = model.sideTasks.first else { throw AppError.message("No task interface") }
            try check(
                reply == "Your bill split is ready." && task.kind == .workspace && task.sourceURL == nil
                    && model.webURL.isEmpty,
                "Agent execution and a generated task interface complete without navigating any webpage")
            try check(
                task.state["share"] == "40.00" && calls == 2,
                "The interface uses verified code output rather than a fabricated model state value")
            model.cardAction(task.id, action: "calculate", value: "{\"amount\":\"90\",\"people\":\"2\"}")
            for _ in 0..<150 {
                if model.taskActionJobs[task.id] == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(
                model.sideTasks.first?.state["share"] == "45.00" && calls == 2,
                "Card inputs run their generated calculation directly without an additional model request")
            let saved = try JSONEncoder().encode(model.sideTasks)
            let restored = try JSONDecoder().decode([SideTask].self, from: saved)
            try check(
                restored.first?.taskSurface?.actions.first?.code == splitCode
                    && restored.first?.state["share"] == "45.00",
                "Task behavior and updated state survive serialization independently of web sessions")
            model.cardAction(task.id, action: "calculate", value: "{\"amount\":\"90\",\"people\":\"0\"}")
            for _ in 0..<150 {
                if model.taskActionJobs[task.id] == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(
                model.sideTasks.first?.state["share"] == "45.00" && model.feedback?.kind == .failure,
                "A calculation error preserves the last valid state and produces visible feedback")
            model.busy = true
            model.cardAction(task.id, action: "refine", value: "{\"amount\":\"100\",\"people\":\"5\"}")
            try check(
                model.queuedTaskRequests.first?.taskID == task.id && model.sideTasks.first?.status == "Queued",
                "Agent actions queue against their own task rather than steering unrelated work")
            model.busy = false
            model.sideTasks[0].taskSurface?.actions[0].code =
                "if(input.amount==='slow'){while(true){}} return {state:{share:input.amount}};"
            model.cardAction(task.id, action: "calculate", value: "{\"amount\":\"slow\"}")
            try await Task.sleep(for: .milliseconds(80))
            model.cardAction(task.id, action: "calculate", value: "{\"amount\":\"latest\"}")
            for _ in 0..<150 {
                if model.taskActionJobs[task.id] == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(
                model.queuedTaskRequests.isEmpty,
                "A newer local calculation supersedes an older queued agent update for the same task")
            try check(
                model.sideTasks.first?.state["share"] == "latest",
                "Rapid edits cancel old calculations so stale output cannot overwrite the latest input")
            model.cardAction(task.id, action: "calculate", value: "{\"amount\":\"slow\"}")
            try await Task.sleep(for: .milliseconds(80))
            model.closeTask(task.id)
            for _ in 0..<100 {
                if model.taskCode.runningCount == 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(
                model.sideTasks.isEmpty && model.taskCode.runningCount == 0 && model.queuedTaskRequests.isEmpty,
                "Closing a task cancels both code and queued agent work without resurrecting its card")
            var failures = 0
            model.agent.completionOverride = { _ in
                failures += 1
                var invalid = surface()
                invalid.actions[0].code = ""
                let args = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)) as! [String: Any]
                return response([tool("present_ui", args)])
            }
            rejected = false
            do { _ = try await model.agent.run("Create a small calculation tool") } catch { rejected = true }
            try check(
                rejected && failures == 3
                    && model.sideTasks.allSatisfy({ $0.kind == .result && $0.status == "Needs attention" }),
                "Repeated identical generation failures stop promptly instead of spending all rounds retrying")
            // One terminal call initializes the same handler that later edits use.
            calls = 0
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.behavior = .interactive
                return intent
            }
            model.agent.completionOverride = { _ in
                calls += 1
                var ui = surface()
                ui.state["share"] = "unverified"
                ui.checks = [
                    TaskActionCheck(
                        action: "calculate", input: ["amount": "150", "people": "5"], expected: ["share": "30.00"])
                ]
                var args = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ui)) as! [String: Any]
                args.removeValue(forKey: "markup")
                args["form"] = [
                    "inputs": [
                        ["key": "amount", "label": "Amount", "kind": "number"],
                        ["key": "people", "label": "People", "kind": "number"],
                    ], "outputs": [["key": "share", "label": "Per person"]],
                    "buttons": [["action": "calculate", "label": "Calculate"]], "compactKey": "share",
                ]
                args["initialize"] = "calculate"
                args["complete"] = true
                return response([tool("present_ui", args)])
            }
            _ = try await model.agent.run("Create an editable equal-share tool")
            try check(
                calls == 1 && model.sideTasks.contains(where: { $0.taskSurface?.state["share"] == "40.00" }),
                "One terminal execution call initializes real outputs and validates changed inputs using the same reusable handler"
            )
            if let reusable = model.sideTasks.first(where: { $0.taskSurface?.state["share"] == "40.00" }) {
                model.interfaceMemory.remember(reusable, purpose: "Editable arithmetic")
                calls = 0
                model.agent.completionOverride = { _ in
                    calls += 1
                    return response([
                        tool(
                            "reuse_saved_ui", ["id": reusable.id.uuidString, "state": ["amount": "90", "people": "2"]])
                    ])
                }
                _ = try await model.agent.run("Reuse the tool with fresh inputs")
                try check(
                    calls == 1 && model.sideTasks.contains(where: { $0.state["share"] == "45.00" }),
                    "Saved local tools recompute fresh inputs through their own handler and finish in one execution call"
                )
            }
            // A saved representative input is also a valid future user input.
            if let reusable = model.interfaceMemory.recipes.first(where: {
                $0.kind != .web && $0.surface?.checks?.first?.input["amount"] == "150"
            }) {
                calls = 0
                model.agent.completionOverride = { _ in
                    calls += 1
                    return response([
                        tool(
                            "reuse_saved_ui",
                            ["id": reusable.id.uuidString, "state": ["amount": "150", "people": "5"]])
                    ])
                }
                _ = try await model.agent.run("Recalculate with the saved example inputs")
                try check(
                    calls == 1 && model.sideTasks.contains(where: { $0.state["share"] == "30.00" }),
                    "Saved checks matching fresh inputs do not cause a false rejection or extra model round")
            } else {
                throw AppError.message("Expected a saved arithmetic definition")
            }
            model.agent.operatedPage = true
            model.agent.steer("Use a public data source for this request")
            try check(
                !model.agent.operatedPage,
                "Steering clears the previous browser route before selecting tools for the new request")
            let apiIntent = RequestIntent(kind: .general, route: .api)
            let offered = model.agent.offeredTools(for: apiIntent)
            let names = Set(offered.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            try check(
                names.contains("query_api") && !names.contains("navigate") && !names.contains("compose_ui")
                    && JSONText.encode(offered).utf8.count < JSONText.encode(AgentToolRegistry.definitions)
                        .utf8.count / 2,
                "API decisions keep the data route and omit webpage/layout schemas")
            let apiPrompt = AgentPrompts.execution(startPolicy: .taskFirst, intent: apiIntent)
            try check(
                !apiPrompt.contains("runtime.sources") && !apiPrompt.contains("media_playing"),
                "API execution context omits unrelated scheduling and playback instructions")
            print(
                JSONText.encode([
                    "contextBudget": [
                        "apiPromptBytes": apiPrompt.utf8.count,
                        "apiToolBytes": JSONText.encode(offered).utf8.count,
                        "allToolBytes": JSONText.encode(AgentToolRegistry.definitions).utf8.count,
                    ]
                ]))
            return checks
        }
    }
#endif
