#if DEBUG
    import Foundation

    @MainActor
    private final class UnavailableRuntime: TaskCodeExecuting {
        func run(code: String, input: [String: Any], state: [String: String]) async throws -> [String: Any] {
            throw URLError(.timedOut)
        }
    }

    @MainActor
    enum GenerationRecoveryCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw AppError.message(label) }
                checks.append(label)
            }
            let suite = "orvlet.generation." + UUID().uuidString
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            defer { model.browser.dispose() }
            let code =
                "const x=Number(input.value); if(!Number.isFinite(x))throw Error('Enter a number'); return {state:{result:String(x*2)}};"
            let spec: [String: Any] = [
                "title": "Scale", "state": ["value": "3", "result": ""], "fields": ["value"],
                "markup": [
                    "html":
                        "<input data-field='value'><button data-action='calculate'>Calculate</button><span data-bind='result'></span>",
                    "compactHTML": "<span data-bind='result'></span>", "css": "", "height": 150,
                ],
                "actions": [["id": "calculate", "kind": "code", "code": code]],
                "checks": [["action": "calculate", "input": ["value": "5"], "expected": ["result": "10"]]],
                "initialize": "calculate", "complete": true,
            ]
            for exploration in ["throw Error('Exploration failed');", "return {state:{value:'999',result:'999'}};"] {
                model.agent.interpretationOverride = { _ in
                    var intent = RequestIntent(kind: .general, behavior: .interactive, route: .local)
                    intent.goals = ["Create a scale tool"]
                    intent.steps = [.init(tool: "run_code", arguments: JSONText.encode(["code": exploration]), goal: 0)]
                    return intent
                }
                var turn = 0
                model.agent.completionOverride = { _ in
                    turn += 1
                    let steps = [RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "workspace"])),
                                 RequestStep(tool: "run_code", arguments: JSONText.encode(["code": exploration])),
                                 RequestStep(tool: "present_ui", arguments: JSONText.encode(spec))]
                    return ["tool_calls": [steps[min(turn, 3) - 1].call]]
                }
                _ = try await model.agent.run("Create a scale tool")
                let task = model.sideTasks.first { $0.id == model.agent.activeTaskID }
                try check(
                    task?.state["result"] == "6" && task?.state["value"] == "3" && model.agent.lastToolVerification != nil,
                    "Self-contained initialization supersedes failed or stale exploration: " + exploration)
            }
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general, behavior: .interactive, route: .local)
                intent.goals = ["Create a scale tool"]
                return intent
            }
            var repairTurns = 0
            model.agent.completionOverride = { _ in
                repairTurns += 1
                var step = RequestStep(tool: "present_ui", arguments: JSONText.encode(spec))
                if repairTurns == 1 {
                    step = RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "workspace"]))
                } else if repairTurns == 2 {
                    var broken = spec
                    broken["checks"] = [["action": "calculate", "input": ["value": "5"], "expected": ["result": "12"]]]
                    step = RequestStep(tool: "present_ui", arguments: JSONText.encode(broken))
                } else {
                    let patch = JSONText.encode(["$.checks[0].expected.result": "10"])
                    step = RequestStep(tool: "repair_step", arguments: JSONText.encode(["changes": patch]))
                }
                return ["tool_calls": [step.call]]
            }
            _ = try await model.agent.run("Create a scale tool")
            try check(repairTurns == 3 && model.agent.lastToolVerification != nil, "A failed changed-input check is repaired without resending the card or handler")
            // Replay a wire-format form: top-level component keys, numeric assertions and
            // a long compact reading. Repair exactly the field path returned by the host.
            var glanceTurns = 0
            let longValue = "This expanded reading is much too long for the capsule"
            model.agent.completionOverride = { turns in
                glanceTurns += 1
                let step: RequestStep
                switch glanceTurns {
                case 1: step = RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "workspace"]))
                case 2:
                    var definition = spec
                    definition.removeValue(forKey: "markup")
                    definition["form"] = ["inputs": [["key": "value", "label": "Value", "kind": "number"]],
                                          "outputs": [["key": "result", "label": "Result"]]]
                    definition["title"] = "North Pier water level"
                    definition["compactSubject"] = "Water level in cm"
                    definition["compactKey"] = "summary"
                    definition["state"] = ["value": 3, "summary": longValue]
                    definition["checks"] = [["action": "calculate", "input": ["value": 5], "expected": ["result": 10]]]
                    step = RequestStep(tool: "present_ui", arguments: JSONText.encode(definition))
                case 3:
                    try check(turns.contains { ($0["content"] as? String)?.contains("$.form.compactKey") == true },
                              "Overflow identifies the repairable compact field in its form")
                    step = RequestStep(tool: "repair_step", arguments: JSONText.encode(["changes": ["$.form.compactKey": "result"]]))
                default: throw AppError.message("Unexpected extra model call during compact-field repair")
                }
                return ["tool_calls": [step.call]]
            }
            _ = try await model.agent.run("Create a scale tool with a short glance")
            let corrected = model.sideTasks.first { $0.id == model.agent.activeTaskID }
            try check(glanceTurns == 3 && corrected?.state["result"] == "6"
                      && corrected?.taskSurface?.markup.compactHTML.contains("data-bind='result'") == true,
                      "One field patch repairs the retained form and its numeric verification passes")
            try check(corrected?.taskSurface?.markup.compactHTML.contains("data-bind='title'") == true,
                      "A metric sharing words with the task title cannot replace the named instance")
            let ranking = TaskForm(inputs: [], outputs: [.init(key: "winner", label: "Winner"),
                .init(key: "east", label: "East"), .init(key: "west", label: "West")], buttons: [],
                compactSubject: "East / West", compactKey: "winner")
            let rankedMarkup = try ranking.markup()
            var nameOnlyRejected = false
            do {
                try rankedMarkup.validateMeasuredResult(primary: "winner", subjects: ["East / West"],
                    state: ["winner": "East", "east": "32 min", "west": "47 min"], fieldPath: "$.form.compactKey")
            } catch let issue as ToolArgumentError { nameOnlyRejected = issue.path == "$.form.compactKey" }
            try check(nameOnlyRejected, "An option name alone cannot summarize two measured outcomes")
            try rankedMarkup.validateMeasuredResult(primary: "winner", subjects: ["East / West"],
                state: ["winner": "East", "east": "Open", "west": "Closed"], fieldPath: "$.form.compactKey")
            let oneOutput = try ToolContract.arguments("present_ui", [
                "title": "Result", "state": ["result": 10], "form": ["outputs": [["key": "result", "label": "Result"]]]
            ])
            try check((oneOutput["form"] as? [String: Any])?["compactKey"] as? String == "result",
                      "A single declared output supplies the missing compact binding without a model retry")
            // Explicit provenance must still reject an invalid run reference.
            model.agent.nativeRequestActive = true
            model.agent.executionLedger = RequestExecutionLedger()
            var stale = spec
            stale["run_id"] = "missing-run"
            var refused = false
            do { _ = try await model.agent.execute("present_ui", stale) } catch { refused = true }
            try check(refused, "An explicit stale run receipt cannot be bypassed by initialization")
            model.agent.nativeRequestActive = false

            for route in [RequestIntent.Route.local, .api, .web] {
                model.agent.interpretationOverride = { _ in
                    var intent = RequestIntent(requiresFreshData: route == .api, kind: .general, route: route)
                    intent.goals = ["Complete the requested tool"]
                    return intent
                }
                var decisions = 0
                model.agent.completionOverride = { _ in
                    decisions += 1
                    return [
                        "tool_calls": [
                            RequestStep(
                                tool: "finish",
                                arguments: JSONText.encode([
                                    "outcome": "needs_input", "reply": "Which input should this tool use?",
                                ])
                            ).call
                        ]
                    ]
                }
                let reply = try await model.agent.run("Make a tool")
                try check(
                    decisions == 1 && model.agent.replyKind == .needsInput && !model.taskFailed
                        && !model.agent.executionLedger.complete && reply.contains("Which input"),
                    "Execution clarification stops without failure or fabricated success on " + route.rawValue)
            }
            var surface = try JSONDecoder().decode(TaskSurface.self, from: JSONSerialization.data(withJSONObject: spec))
            surface.state["unit"] = "cm"
            surface.checks![0].expected["unit"] = "cm"
            surface.checks!.append(
                TaskActionCheck(action: "calculate", input: ["value": "invalid"], expectedError: "Enter a number"))
            try await TaskVerification.validateActions(surface, runtime: model.taskCode, required: true)
            try check(true, "Invalid-input rejection is verified alongside successful changed inputs")
            var withReset = surface
            withReset.actions.append(.init(id: "reset", kind: .code, code: "return {state:{result:'0'}};"))
            withReset.checks!.append(.init(action: "reset", input: [:], expected: ["result": "0", "unit": "cm"]))
            try await TaskVerification.validateActions(withReset, runtime: model.taskCode, required: true)
            try check(true, "A state-only action updates a visible output while preserving other values")
            var negativeOnly = surface
            negativeOnly.checks = [surface.checks!.last!]
            var negativeRejected = false
            do {
                try await TaskVerification.validateActions(negativeOnly, runtime: model.taskCode, required: true)
            } catch { negativeRejected = true }
            try check(negativeRejected, "Error-only checks cannot replace working behavior")
            var incorrect = surface
            incorrect.checks![1].expectedError = nil
            incorrect.checks![1].expected = ["result": ""]
            var preciseFailure = false
            do {
                try await TaskVerification.validateActions(incorrect, runtime: model.taskCode, required: true)
            } catch let error as ToolArgumentError { preciseFailure = error.path == "$.checks[1]" }
            try check(preciseFailure, "A thrown check error identifies its check instead of blaming initialization")
            var unexpectedSuccess = surface
            unexpectedSuccess.checks![1].input = ["value": "4"]
            var successRejected = false
            do {
                try await TaskVerification.validateActions(unexpectedSuccess, runtime: model.taskCode, required: true)
            } catch { successRejected = true }
            try check(successRejected, "A negative check fails if the handler accepts its input")
            var infrastructurePropagated = false
            do {
                try await TaskVerification.validateActions(negativeOnly, runtime: UnavailableRuntime(), required: false)
            } catch is URLError { infrastructurePropagated = true }
            try check(infrastructurePropagated, "Infrastructure failures never satisfy expected script errors")
            let names = RequestPlanning.actions(.workspace).compactMap { $0["name"] as? String }
            try check(
                !names.contains("run_code")
                    && RequestPlanning.discovery(.workspace).contains { $0["name"] as? String == "run_code" },
                "Exploration remains discoverable without becoming the only inline construction step")
            let schema = ToolSchema.function(
                "interpret_request", "Interpret", ["kind": ["type": "string"]], required: ["kind"])
            var attempts = 0
            _ = try await RequestIntent.interpret("Make a tool", messages: [], schema: schema) { turns, _, _ in
                attempts += 1
                if attempts == 2 {
                    try check(
                        turns.contains {
                            ($0["content"] as? String ?? "").contains("Rejected interpretation (untrusted data):")
                        },
                        "Bounded interpretation repair receives the rejected candidate")
                }
                return ["content": attempts == 1 ? "{\"kind\":\"invalid\"}" : "{\"kind\":\"general\"}"]
            }
            for key in ["amount", "sourceText", "任意字段", "constructor"] {
                let result = try await model.taskCode.run(code: "return {state:{result:input[Object.keys(input)[0]]}};", input: [key: "sample"], state: [:], declaredInputs: [key])
                try check((result["state"] as? [String: String])?["result"] == "sample", "Named input contract accepts arbitrary field: " + key)
            }
            for badCode in [
                "return {state:{result:String(input)}};",
                "return {state:{result:input.wrongName || ''}};",
                "try { input.wrongName; } catch (_) {} return {state:{result:'masked'}};"
            ] {
                var rejected = false
                do { _ = try await model.taskCode.run(code: badCode, input: ["source": "sample"], state: [:], declaredInputs: ["source"]) }
                catch is TaskCodeError { throw AppError.message("Contract failure was misclassified as a business error") }
                catch { rejected = error.localizedDescription.contains("input") }
                try check(rejected, "Input contract rejects invalid access even if caught: " + badCode)
            }
            let serialized = try await model.taskCode.run(code: "return {state:{result:JSON.stringify(input)}};", input: ["source": "sample"], state: [:], declaredInputs: ["source"])
            try check((serialized["state"] as? [String:String])?["result"] == "{\"source\":\"sample\"}", "Input enumeration and JSON serialization remain valid")
            var missingRejected = false
            do { _ = try await model.taskCode.run(code: "return {};", input: [:], state: [:], declaredInputs: ["source"]) }
            catch { missingRejected = error.localizedDescription.contains("declared input fields") }
            try check(missingRejected, "Missing declared field is caught before handler execution")
            var contractNegative = surface
            contractNegative.actions[0].code = "return {state:{result:input.wrongName}};"
            contractNegative.checks = [.init(action: "calculate", input: ["value": "4"], expectedError: "Undeclared input")]
            var negativeContractRejected = false
            do { try await TaskVerification.validateActions(contractNegative, runtime: model.taskCode, required: false) }
            catch { negativeContractRejected = true }
            try check(negativeContractRejected, "Input contract violations never satisfy expected business errors")
            let emptySteps = RequestStep.schema(actions: [])
            try ToolContract.validate([], schema: emptySteps)
            try check((emptySteps["description"] as? String)?.contains("Return []") == true, "Empty planning schema explicitly requires empty steps")
            var timer = RequestIntent(kind: .timer)
            var missingDuration = false
            do { _ = try timer.validated(for: "Wait 2 minutes") }
            catch let error as ToolArgumentError { missingDuration = error.path == "$.timerSeconds" }
            try check(missingDuration, "Missing timer duration identifies the repair field")
            timer.timerSeconds = 120
            timer.timerEvidence = "2 minutes"
            _ = try timer.validated(for: "Wait 2 minutes")
            timer.timerEvidence = "invented phrase"
            var invalidQuote = false
            do { _ = try timer.validated(for: "Wait 2 minutes") }
            catch let error as ToolArgumentError { invalidQuote = error.path == "$.timerEvidence" }
            try check(invalidQuote, "Timer evidence still requires an exact user quote")
            let object: [String: Any] = ["title": "Reading"]
            let doubleEncoded = String(decoding: try JSONEncoder().encode(JSONText.encode(object)), as: UTF8.self)
            try check(try ToolContract.payload(doubleEncoded, tool: "present_ui")["title"] as? String == "Reading", "Extra JSON encoding is repaired at the shared tool boundary")
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
            var calls = 0
            model.agent.completionOverride = { _ in
                calls += 1
                if calls == 1 { return ["tool_calls": [RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "workspace"])).call]] }
                let args: [String: Any] = ["title": "Trial", "state": ["best": "8", "samples": [3, 8]],
                    "form": ["outputs": [["key": "best", "label": "Best"]], "visuals": [
                        ["kind": "table", "columns": [" SAMPLES "]], ["kind": "line", "columns": ["missing"]]]],
                    "complete": true]
                return ["tool_calls": [["id": "trial", "type": "function", "function": ["name": "present_ui", "arguments": args]]]]
            }
            let reply = try await model.agent.run("Show the best trial")
            let trial = model.sideTasks.first { $0.id == model.agent.activeTaskID }
            try check(calls == 2 && trial?.presentation.html.contains("data-column='samples'") == true
                && trial?.state["best"] == "8" && reply.lowercased().contains("omitted"), "A local card repairs its table, reports an unusable chart and completes in one creation step")
            return checks
        }
    }
#endif
