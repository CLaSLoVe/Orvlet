import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeWorkspaceTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "run_code":
            guard nativeRequestActive, let code = input["code"] as? String else {
                throw AppError.message("Code execution requires an active task and a function body.")
            }
            if model.requestPageID == nil { attemptedTaskWork = true }
            attemptedCode = true
            codeReceipt = nil
            taskSurfaceReady = false
            let state = model.sideTasks.first(where: { $0.id == activeTaskID })?.liveValues ?? [:]
            let result = try await model.taskCode.run(
                code: code, input: input["input"] as? [String: Any] ?? [:], state: state)
            guard revision == steeringRevision else { return ["superseded": true] }
            let id = UUID().uuidString
            codeReceipt = (id, result)
            return ["verified": true, "run_id": id, "result": result]
        case "present_ui":
            return try await presentWorkspace(input, revision: revision, origin: .generated)
        case "control_task":
            guard nativeRequestActive, let owner = model.activeRequest?.owner,
                let task = model.sideTasks.first(where: { $0.id == owner.id }),
                let operation = input["operation"] as? String
            else {
                throw AppError.message("Resolve an existing task before controlling it.")
            }
            if operation == "inspect" {
                return AgentContext.task(task, definition: input["detail"] as? String == "definition")
            }
            if operation == "invoke" {
                guard let action = input["action"] as? String,
                    let fields = input["fields"] as? [String: String]
                else {
                    throw AppError.message("Supply an observed action ID and named input fields.")
                }
                model.taskActionJobs.removeValue(forKey: owner.id)?.cancel()
                model.taskRuntime.detach(owner.id)
                let ticket = model.beginTaskRevision(owner.id, .execution)
                defer {
                    if model.accepts(ticket) {
                        model.taskRevisions.finish(ticket)
                        model.taskRuntime.attach(owner.id)
                    }
                }
                ToolExecutionScope.current?.effectStarted = true
                let state = try await model.executeTaskCodeAction(
                    owner.id, action: action, fields: fields, ticket: ticket)
                guard revision == steeringRevision else { throw CancellationError() }
                verifyEffect(model.userText("已更新。", "Updated."))
                taskControlReceipt = (owner.id, model.userText("已更新。", "Updated."))
                return [
                    "verified": true, "task_id": owner.id.uuidString, "state": state,
                    "next_step":
                        "The existing action succeeded. If all requested work is complete, use finish(task_ready); do not repeat it.",
                ]
            }
            guard task.taskSurface?.runtime != nil || task.kind == .timer,
                ["pause", "resume", "stop", "restart", "refresh"].contains(operation)
            else {
                throw AppError.message("Use an available control for this task.")
            }
            ToolExecutionScope.current?.effectStarted = true
            if task.kind == .timer {
                guard operation != "refresh" else { throw AppError.message("A countdown updates automatically.") }
                if (operation == "pause" && task.deadline != nil) || (operation == "resume" && task.deadline == nil) {
                    model.timerAction(owner.id, action: "toggle")
                } else if ["stop", "restart"].contains(operation) {
                    model.timerAction(owner.id, action: operation)
                }
                guard let updated = model.sideTasks.first(where: { $0.id == owner.id }),
                    operation != "pause" || updated.deadline == nil,
                    operation != "resume" || updated.deadline != nil || updated.finished
                else { throw AppError.message("The countdown did not confirm the change.") }
                verifyEffect(model.userText("已更新计时器。", "Timer updated."))
                taskControlReceipt = (owner.id, effectReply)
                return [
                    "verified": true, "task_id": owner.id.uuidString, "operation": operation,
                    "next_step":
                        "The control succeeded. If all requested work is complete, use finish(task_ready); do not repeat it.",
                ]
            }
            model.taskRuntime.control(owner.id, operation: operation)
            if ["resume", "restart", "refresh"].contains(operation) { try await model.taskRuntime.verify(owner.id) }
            guard revision == steeringRevision else { return ["superseded": true] }
            verifyEffect(model.sideTasks.first(where: { $0.id == owner.id })?.status ?? "Updated.")
            taskControlReceipt = (owner.id, effectReply)
            return [
                "verified": true, "task_id": owner.id.uuidString, "operation": operation,
                "next_step":
                    "The control succeeded. If all requested work is complete, use finish(task_ready); do not repeat it.",
            ]
        case "reuse_saved_ui":
            guard nativeRequestActive else {
                throw AppError.message("Reusing a task interface requires an active human request.")
            }
            let raw = input["id"] as? String ?? ""
            let recipe = try model.interfaceMemory.recipe(raw)
            if requestIntent.route == .api, recipe.kind == .workspace, recipe.surface?.apiData == nil {
                throw AppError.message(
                    "This request needs fresh API data. Reuse an API-backed recipe or use query_api.")
            }
            if recipe.kind == .web {
                guard model.requestPageID != nil else {
                    throw AppError.message(
                        "Open or resolve this request's source before reusing a webpage design. Reusing its appearance cannot select another task's player."
                    )
                }
                interfaceAttempted = true
                pendingSurface = nil
                let observation = try await model.observation()
                guard revision == steeringRevision else { return ["superseded": true] }
                let readings = try input["readings"].map {
                    try JSONDecoder().decode([CardReading].self, from: JSONSerialization.data(withJSONObject: $0))
                }
                let actions = try input["actions"].map {
                    try JSONDecoder().decode([BoundCardAction].self, from: JSONSerialization.data(withJSONObject: $0))
                }
                do {
                    pendingSurface = try model.interfaceMemory.webPlan(
                        raw, observation: observation, readings: readings, actions: actions)
                } catch {
                    return [
                        "needs_rebinding": true, "reason": error.localizedDescription,
                        "saved_design": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)),
                        "instruction":
                            "Call reuse_saved_ui again with current observed readings/actions. Preserve the saved layout.",
                    ]
                }
                ownCurrentPage()
                return ["ok": true, "reused": true, "pending": "Verify the webpage outcome with finish."]
            }
            guard model.requestPageID == nil else {
                throw AppError.message("Keep this webpage request in its existing live card.")
            }
            var state = input["state"] as? [String: String] ?? [:]
            if var spec = recipe.surface?.apiData {
                let inputKeys = Set((spec.inputs ?? [:]).keys)
                guard inputKeys == Set(state.keys) else {
                    throw AppError.message(
                        "Supply fresh values for every saved API input, and no saved results, in state.")
                }
                spec.inputs = state
                let result = try await executeDataTool(
                    "query_api",
                    [
                        "title": input["title"] as? String ?? recipe.surface!.title,
                        "source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)),
                        "markup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe.markup)),
                        "outcomeEvidence": input["outcomeEvidence"] as? [[String: Any]] ?? [],
                    ], revision: revision)
                guard revision == steeringRevision else { return ["superseded": true] }
                if let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID }) {
                    model.sideTasks[i].interfaceRecipeID = recipe.id
                }
                model.persistSideTasks()
                return result.merging(["reused": true]) { _, new in new }
            }
            if attemptedCode {
                guard let receipt = codeReceipt else {
                    throw AppError.message("Calculate fresh state successfully before reusing this interface.")
                }
                state.merge(try TaskValues.decode(receipt.result)) { _, verified in verified }
            }
            guard var surface = recipe.surface, surface.apiData == nil else {
                throw AppError.message("Refresh an API-backed recipe with query_api and current source evidence.")
            }
            let handlers = surface.actions.filter { $0.kind == .code }
            let initialize = input["initialize"] as? String ?? (handlers.count == 1 ? handlers[0].id : nil)
            if initialize != nil {
                guard Set(surface.fields).isSubset(of: Set(state.keys)) else {
                    throw AppError.message("Supply fresh values for every saved input field before recalculating.")
                }
                surface.state = Dictionary(uniqueKeysWithValues: recipe.stateKeys.map { ($0, "") }).merging(state) {
                    _, new in new
                }
            } else {
                surface = try model.interfaceMemory.taskSurface(
                    raw, title: input["title"] as? String ?? surface.title, state: state)
            }
            surface.title = input["title"] as? String ?? surface.title
            surface.markup = recipe.markup
            if let replacement = input["runtime"] {
                guard surface.preset == "clock" else {
                    throw AppError.message(
                        "Runtime replacement is supported for the built-in clock. Use present_ui for a different running task."
                    )
                }
                surface.runtime = try JSONDecoder().decode(
                    TaskRuntimeSpec.self, from: JSONSerialization.data(withJSONObject: replacement))
            }
            surface.runID = nil
            var specification = try JSONSerialization.jsonObject(with: JSONEncoder().encode(surface)) as! [String: Any]
            specification["initialize"] = initialize
            specification["complete"] = input["complete"] as? Bool ?? true
            let result = try await presentWorkspace(specification, revision: revision, origin: .saved)
            if let ticket = interfaceTicket, model.accepts(ticket),
                let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID })
            {
                model.sideTasks[i].interfaceRecipeID = recipe.id
                model.sideTasks[i].customCompact = true
            }
            model.persistSideTasks()
            return result.merging(["reused": true]) { _, new in new }

        default: throw AppError.message("Unsupported workspace tool.")
        }
    }

    private func presentWorkspace(_ input: [String: Any], revision: Int, origin: TaskVerification.DefinitionOrigin)
        async throws -> [String: Any]
    {
        guard nativeRequestActive else { throw AppError.message("A task interface requires an active user request.") }
        guard model.requestPageID == nil else {
            throw AppError.message(
                "This request already owns a live webpage. Use compose_ui with readings from observation.readables, then finish(page_ready). Do not copy changing webpage values into a separate static present_ui task."
            )
        }
        attemptedTaskWork = true
        var specification = input
        if specification["preset"] as? String == "clock" {
            guard let runtime = specification["runtime"],
                (specification["actions"] as? [[String: Any]] ?? []).allSatisfy({
                    $0["id"] as? String == "configureClock" && $0["operation"] as? String == "configureClock"
                        && $0["kind"] as? String == "runtime"
                }),
                (specification["fields"] as? [String] ?? []).allSatisfy({
                    ["clockZone0", "clockZone1", "clockZone2", "clockHourStyle"].contains($0)
                })
            else {
                throw AppError.message("The built-in clock needs live runtime sources and no form fields or actions.")
            }
            let spec = try JSONDecoder().decode(
                TaskRuntimeSpec.self, from: JSONSerialization.data(withJSONObject: runtime)
            )
            .validated(fields: [], at: requestStartedAt)
            specification["markup"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(BuiltinCards.clock(spec)))
            specification["fields"] = [String]()
            specification["actions"] = [[String: Any]]()
        }
        if specification["markup"] == nil, let form = specification["form"] {
            let composition = try JSONDecoder().decode(
                TaskForm.self, from: JSONSerialization.data(withJSONObject: form))
            specification["markup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(composition.markup()))
            specification["fields"] = composition.inputs.map(\.key)
        }
        var surface = try JSONDecoder().decode(
            TaskSurface.self, from: JSONSerialization.data(withJSONObject: specification))
        guard surface.apiData == nil else {
            throw AppError.message(
                "Use query_api to verify an API-backed task; present_ui cannot attach unverified remote data.")
        }
        if attemptedCode || surface.runID != nil {
            guard let receipt = codeReceipt, surface.runID == nil || surface.runID == receipt.id else {
                throw AppError.message(
                    "Use the latest successful run_code receipt; a failed or old calculation cannot supply this interface."
                )
            }
            surface.runID = receipt.id
            surface.state.merge(try TaskValues.decode(receipt.result)) { _, verified in verified }
        }
        if let initialize = input["initialize"] as? String {
            guard let action = surface.actions.first(where: { $0.id == initialize && $0.kind == .code }),
                let code = action.code,
                Set(surface.fields).isSubset(of: Set(surface.state.keys))
            else {
                throw AppError.message("initialize must name a code action with all initial field values in state.")
            }
            let initial = surface.state.filter { surface.fields.contains($0.key) }
            let output = try TaskValues.decode(
                try await model.taskCode.run(code: code, input: initial, state: surface.state))
            guard !output.isEmpty, output.values.allSatisfy({ !["NaN", "Infinity", "-Infinity"].contains($0) }) else {
                throw AppError.message("Initialization did not produce usable results.")
            }
            surface.state.merge(output) { _, verified in verified }
        }
        if let spec = surface.runtime {
            surface.runtime = try spec.validated(fields: surface.fields, at: requestStartedAt)
        }
        surface = try surface.validated()
        if let interval = requestIntent.updateIntervalSeconds, surface.runtime?.refresh?.intervalSeconds != interval {
            throw AppError.message(
                "Use runtime.refresh.intervalSeconds=\(interval) for the requested schedule. The host owns the schedule; do not implement a second timer in code."
            )
        }
        let exercised = Set((surface.checks ?? []).map(\.action)).union(
            [input["initialize"] as? String].compactMap { $0 })
        // Running a handler also parses it. Only syntax-check code that has
        // not already run and is not about to run its behavioral check.
        try await model.taskCode.validate(
            surface.actions.filter { !exercised.contains($0.id) }.compactMap(\.code)
                + [surface.runtime?.refresh?.code].compactMap { $0 })
        try await TaskVerification.validateActions(
            surface, runtime: model.taskCode, required: requestIntent.behavior == .interactive, origin: origin)
        if [.live, .advancing].contains(requestIntent.behavior), surface.runtime == nil {
            throw AppError.message(
                "A continuing task requires runtime data sources or a scheduled refresh; static state is not sufficient."
            )
        }
        try Task.checkCancellation()
        guard revision == steeringRevision else { return ["superseded": true] }
        let previous = model.sideTasks.first(where: { $0.id == activeTaskID })
        try model.commitTaskSurface(surface, id: activeTaskID, ticket: interfaceTicket)
        taskSurfaceReady = true
        if input["complete"] as? Bool == true {
            model.transitionRequest(to: .verifying)
            let generation = model.taskRuntime.receipts[activeTaskID]?.generation
            do { try await TaskVerification.verify(activeTaskID, intent: requestIntent, model: model) } catch {
                // Roll back this candidate only. A direct user action or a
                // newer request must keep its own state and generation.
                if !(error is CancellationError), revision == steeringRevision,
                    model.taskRuntime.receipts[activeTaskID]?.generation == generation
                {
                    model.taskRuntime.detach(activeTaskID)
                    if let previous, let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID }) {
                        model.sideTasks[i] = previous
                        if previous.taskSurface?.runtime != nil { model.taskRuntime.attach(activeTaskID) }
                    } else {
                        model.sideTasks.removeAll { $0.id == activeTaskID }
                    }
                    model.persistSideTasks()
                    taskSurfaceReady = false
                }
                throw error
            }
            guard revision == steeringRevision else { return ["superseded": true] }
            verifyEffect(
                surface.runtime == nil
                    ? "Your tool is ready."
                    : ((surface.runtime?.refresh?.intervalSeconds ?? 1) > 3
                        ? "Your task is scheduled." : "Your task is running."))
        }
        return ["verified": true, "task_id": activeTaskID.uuidString, "actions": surface.actions.map(\.id)]
    }
}
