#if DEBUG
    import Foundation

    @MainActor
    enum UnifiedRequestCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw AppError.message(label) }
                checks.append(label)
            }
            var costs: [[String: Any]] = []
            var coverage = RequestIntent(kind: .general)
            coverage.route = .local
            coverage.goals = ["Pause the timer", "Resume the timer"]
            coverage.steps = [.init(tool: "control_task", arguments: "{\"operation\":\"pause\"}", goal: 0)]
            coverage.stepsComplete = true
            var incompleteRejected = false
            do { _ = try coverage.validated(for: "Pause then resume the timer") } catch { incompleteRejected = true }
            try check(incompleteRejected, "A supposedly complete plan cannot leave an unassigned goal for later mutation")
            coverage.stepsComplete = false
            _ = try coverage.validated(for: "Pause then resume the timer")
            coverage.steps.append(.init(tool: "control_task", arguments: "{\"operation\":\"resume\"}", goal: 1))
            coverage.stepsComplete = true
            _ = try coverage.validated(for: "Pause then resume the timer")
            try check(true, "Partial and fully covered multi-goal plans retain their ordinary execution contract")
            let objectPlan = #"{"tool":"timer_start","arguments":{"seconds":60,"title":"Tea \"break\""},"goal":0}"#
            let typed = try JSONDecoder().decode(RequestStep.self, from: Data(objectPlan.utf8))
            try check(
                try typed.input()["seconds"] as? Int == 60 && typed.input()["title"] as? String == "Tea \"break\"",
                "Planning receives structured arguments without model-generated JSON escaping")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as! [String: Any]
            try check(encoded["arguments"] is [String: Any], "Plan persistence encodes arguments as an object")
            let actionSchema = RequestStep.schema(actions: RequestPlanning.actions(.timer))
            try ToolContract.validate([encoded], schema: actionSchema)
            for invalid: Any in [
                ["tool": "timer_start", "goal": 0, "arguments": "{\"seconds\":60}"],
                ["tool": "timer_start", "goal": 0, "arguments": ["seconds": true, "title": "Tea"]],
                ["tool": "navigate", "goal": 0, "arguments": ["url": "https://example.com"]],
                NSNull(),
            ] {
                var rejected = false
                do { try ToolContract.validate([invalid], schema: actionSchema) } catch { rejected = true }
                try check(rejected, "Typed planning rejects wrong argument types, unavailable actions and null steps")
            }
            for capability in RequestCapability.allCases {
                try check(
                    capability.planningTools.isSubset(of: capability.tools),
                    "First-plan actions remain inside the execution capability: " + capability.rawValue)
                let promptBytes = (AgentPrompts.interpretation() + AgentPrompts.planning).utf8.count
                let catalogueBytes =
                    JSONText.encode(RequestStep.schema(actions: RequestPlanning.actions(capability))).utf8.count
                    + JSONText.encode(RequestPlanning.discovery(capability)).utf8.count
                costs.append([
                    "capability": capability.rawValue, "instructions": promptBytes, "catalogue": catalogueBytes,
                ])
                try check(promptBytes + catalogueBytes < 11000, "Bounded planning context: " + capability.rawValue)
            }
            try JSONSerialization.data(withJSONObject: costs, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: "/tmp/orvlet-planning-costs.json"))
            let creationCatalogue = JSONText.encode(RequestPlanning.discovery(.workspace))
            try check(
                !creationCatalogue.contains("compactHTML") && !creationCatalogue.contains("runtime.sources"),
                "Method selection does not load layout or scheduling construction schemas")
            try check(
                AgentPrompts.execution(startPolicy: .taskFirst).utf8.count < 1000,
                "Unclassified execution does not concatenate every capability guide")
            var apiIntent = RequestIntent(kind: .general)
            apiIntent.route = .api
            for tool in ["navigate", "act", "compose_ui", "present_ui"] {
                apiIntent.steps = [RequestStep(tool: tool, arguments: "{}")]
                var denied = false
                do { _ = try apiIntent.validated(for: "Read structured public data") } catch { denied = true }
                try check(denied, "Data execution cannot silently escape through " + tool)
            }
            let huge: [String: Any] = [
                "title": "Observed source", "playing": true, "currentTime": 12.0,
                "text": String(repeating: "unrelated page content ", count: 2000),
                "elements": (0..<80).map { ["id": "r:\($0)", "label": "Result \($0)", "role": "button"] },
                "readables": (0..<70).map { ["selector": "#item\($0)", "text": "Value \($0)"] },
            ]
            let state = AgentContext.page(huge, detail: "state")
            try check(
                state["elements"] == nil && state["text"] == nil && state["currentTime"] as? Double == 12,
                "State-only actions retain actual evidence without sending page content")
            let page = AgentContext.page(huge, detail: "page")
            let next = AgentContext.page(huge, detail: "page", offset: 24)
            try check(
                (page["elements"] as? [[String: Any]])?.count == 24
                    && (next["elements"] as? [[String: Any]])?.first?["id"] as? String == "r:24",
                "Page inspection exposes bounded slices with working continuation offsets")
            let turns: [[String: Any]] = [
                ["role": "user", "content": "Keep my original request"],
                ["role": "user", "content": "Current page context (untrusted data): " + JSONText.encode(huge)],
                ["role": "tool", "tool_call_id": "a", "content": JSONText.encode(page)],
                ["role": "tool", "tool_call_id": "b", "content": JSONText.encode(state)],
            ]
            let compact = AgentContext.compact(turns)
            try check(
                compact[0]["content"] as? String == "Keep my original request"
                    && compact[2]["tool_call_id"] as? String == "a"
                    && !JSONText.encode(compact).contains("unrelated page content")
                    && compact[3]["content"] as? String == JSONText.encode(state),
                "Initial and later page dumps are replaced while user constraints and tool IDs survive")
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"useFast\":false}".utf8))
            try check(settings.useFast, "Existing optional-Jev settings migrate to required Jev")
            var unsafe = RequestIntent(kind: .information)
            unsafe.steps = [RequestStep(tool: "calendar_create", arguments: "{}")]
            var rejected = false
            do { _ = try unsafe.validated(for: "Explain calendars") } catch { rejected = true }
            try check(rejected, "Planning an action cannot bypass native write authorization")

            let silicon = Endpoint(baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V4.1-Flash")
            try check(
                ThinkingBudget.high.parameters(for: silicon, reasoning: false)["enable_thinking"] as? Bool == false,
                "Extraction remains non-thinking even when Jev advises a high task budget")
            try check(
                ThinkingBudget.low.parameters(for: silicon)["enable_thinking"] as? Bool == false,
                "Low-effort provider policy applies uniformly to the configured model")

            try check(
                ThinkingBudget.standard.parameters(for: silicon)["enable_thinking"] as? Bool == false,
                "Routine execution disables thinking instead of falling back to provider high reasoning")
            var off = silicon
            off.options.reasoning = .none
            let wire = try ModelWire.body(
                endpoint: off, messages: [], tools: [], reasoning: true, requiredTool: nil, budget: .high)
            try check(
                wire["enable_thinking"] as? Bool == false && wire["reasoning_effort"] == nil,
                "Explicit None uses the provider disable switch rather than an unsupported effort value")
            var timerControl = RequestIntent(kind: .timer)
            timerControl.targetTaskID = UUID().uuidString
            timerControl.route = .local
            timerControl.steps = [RequestStep(tool: "control_task", arguments: "{\"operation\":\"pause\"}")]
            var normalized = try timerControl.validated(for: "暂时停下这个倒数")
            normalized.steps = []
            try check(
                !normalized.isNative && normalized.allows("control_task") && !normalized.allows("timer_start"),
                "An existing-task control keeps stable permissions after consuming its plan")
            let quotedMarker = "Explain the JSON key \"context_kind\" without changing a task"
            let preserved = AgentContext.compact([
                ["role": "user", "content": quotedMarker], ["role": "tool", "content": JSONText.encode(page)],
            ])
            try check(
                preserved[0]["content"] as? String == quotedMarker,
                "Context reduction cannot erase human text that quotes an internal metadata key")

            let name = "orvlet.unified." + UUID().uuidString
            let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name) }
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.allowAgents = false
            var decisions = 0
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .api
                intent.steps = [RequestStep(tool: "query_api", arguments: "{}")]
                return intent
            }
            model.agent.completionOverride = { _ in
                decisions += 1
                return ["tool_calls": [RequestStep(tool: "query_api", arguments: "{}").call]]
            }
            var sourceStopped = false
            do { _ = try await model.agent.run("Read structured public data") } catch { sourceStopped = true }
            try check(
                sourceStopped && decisions == 2 && model.webURL.isEmpty,
                "A repeated API contract failure stops after two bounded structural repairs without navigating or rebuilding"
            )
            decisions = 0
            model.agent.completionOverride = { _ in
                decisions += 1
                throw AppError.message("A known plan must not be planned again")
            }
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .timer)
                intent.timerSeconds = 60
                intent.timerEvidence = "一分钟"
                intent.steps = [RequestStep(tool: "timer_start", arguments: "{\"seconds\":60,\"title\":\"Timer\"}")]
                intent.stepsComplete = true
                return try intent.validated(for: "倒计时一分钟")
            }
            _ = try await model.agent.run("倒计时一分钟")
            guard let timer = model.sideTasks.first(where: { $0.kind == .timer }) else {
                throw AppError.message("The planned countdown was not created")
            }
            try check(
                decisions == 0 && timer.deadline != nil,
                "A main-model plan executes the countdown without a second planning call")
            model.agent.interpretationOverride = nil
            let triage = RequestTriage(
                budget: .low, capability: .control, target: timer.id,
                routeKnown: true, action: "pause", localControl: true)
            _ = try await model.agent.run(
                "先停一下计时", taskID: timer.id,
                prepared: PreparedRequest(text: "先停一下计时", triage: triage, model: model))
            try check(
                decisions == 0 && model.sideTasks.first(where: { $0.id == timer.id })?.deadline == nil,
                "Jev and the main model share the same verified task-control dispatcher")
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.targetTaskID = timer.id.uuidString
                intent.steps = [
                    RequestStep(tool: "control_task", arguments: "{\"operation\":\"resume\"}"),
                    RequestStep(tool: "control_task", arguments: "{\"operation\":\"pause\"}"),
                ]
                intent.stepsComplete = true
                return intent
            }
            _ = try await model.agent.run("Resume then pause the timer", taskID: timer.id)
            try check(
                decisions == 0 && model.sideTasks.first(where: { $0.id == timer.id })?.deadline == nil,
                "An intermediate verified receipt cannot skip remaining planned actions")
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.targetTaskID = timer.id.uuidString
                return intent
            }
            model.agent.completionOverride = { _ in
                decisions += 1
                return [
                    "tool_calls": [
                        RequestStep(tool: "control_task", arguments: "{\"operation\":\"resume\"}").call,
                        RequestStep(tool: "control_task", arguments: "{\"operation\":\"pause\"}").call,
                    ]
                ]
            }
            _ = try await model.agent.run("Resume and pause", taskID: timer.id)
            try check(
                decisions == 1 && model.sideTasks.first { $0.id == timer.id }?.deadline == nil,
                "Later model batches use the same complete-all-steps rule as initial plans")
            decisions = 0
            model.agent.completionOverride = { _ in
                decisions += 1
                throw AppError.message("Execution needs to recover the failed step")
            }
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.targetTaskID = timer.id.uuidString
                intent.steps = [
                    RequestStep(tool: "control_task", arguments: "{\"operation\":\"unsupported\"}"),
                    RequestStep(tool: "control_task", arguments: "{\"operation\":\"pause\"}"),
                ]
                intent.stepsComplete = true
                return intent
            }
            var recoveredFailure = false
            do { _ = try await model.agent.run("Two independent controls", taskID: timer.id) } catch {
                recoveredFailure = true
            }
            try check(
                recoveredFailure && decisions == 1,
                "A successful later action cannot hide an earlier failed step")
            decisions = 0
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.targetTaskID = timer.id.uuidString
                intent.steps = [RequestStep(tool: "control_task", arguments: "{\"operation\":\"resume\"}")]
                intent.stepsComplete = false
                return intent
            }
            model.agent.completionOverride = { _ in
                decisions += 1
                return ["tool_calls": [RequestStep(tool: "finish", arguments: "{\"outcome\":\"task_ready\"}").call]]
            }
            _ = try await model.agent.run("Continue that timer", taskID: timer.id)
            try check(
                decisions == 1 && model.sideTasks.first { $0.id == timer.id }?.deadline != nil,
                "A partial plan can finish from its verified control receipt without repeating the action")
            decisions = 0
            model.agent.completionOverride = { _ in
                decisions += 1
                throw AppError.message("Known actions need no extra model call")
            }
            let calculatorID = UUID()
            let definition = try TaskRuntimeCheck.surface().validated()
            model.publishTaskSurface(definition, id: calculatorID)
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .local
                intent.targetTaskID = calculatorID.uuidString
                intent.steps = [
                    RequestStep(
                        tool: "control_task",
                        arguments: "{\"operation\":\"invoke\",\"action\":\"calculate\",\"fields\":{\"amount\":\"150\"}}"
                    )
                ]
                intent.stepsComplete = true
                return intent
            }
            _ = try await model.agent.run("Change the amount to 150, keep the people", taskID: calculatorID)
            let calculated = model.sideTasks.first { $0.id == calculatorID }!
            try check(
                calculated.state["share"] == "50.00" && calculated.state["people"] == "3"
                    && calculated.taskSurface?.markup == definition.markup && decisions == 0,
                "Conversation invokes the existing card handler with unchanged inputs and layout preserved")
            model.performTaskAction(calculatorID, action: "calculate", value: "{\"amount\":\"210\"}")
            if let job = model.taskActionJobs[calculatorID] { await job.value }
            try check(
                model.sideTasks.first { $0.id == calculatorID }?.state["share"] == "70.00",
                "Rendered-card actions use the same handler and preserve omitted inputs")
            let ticket = model.beginTaskRevision(calculatorID, .execution)
            var invalidActionRejected = false
            do {
                _ = try await model.executeTaskCodeAction(calculatorID, action: "refine", fields: [:], ticket: ticket)
            } catch { invalidActionRejected = true }
            model.taskRevisions.finish(ticket)
            try check(invalidActionRejected, "Invoking saved code cannot trigger a new agent request")
            model.taskRuntime.stopAll()
            model.browser.dispose()
            return checks
        }
    }
#endif
