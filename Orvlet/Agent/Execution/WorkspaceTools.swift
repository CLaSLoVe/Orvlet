import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeWorkspaceTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "load_tools":
            guard let family = input["family"] as? String, let names = Self.toolFamilies[family] else {
                throw AppError.message("Choose an available capability.")
            }
            loadedToolFamilies.insert(family)
            var result: [String: Any] = ["tools": names.sorted()]
            if family == "workspace" {
                result["composition"] = "Use host form components by default. For each visual, put one aligned array per column key in state or return it from initialize. Do not generate scripts, SVG, HTML tables or CSS to draw host components. Prefer the minimum controls and outputs that fulfill this request."
            }
            if ["workspace", "data", "web"].contains(family) {
                result["saved_methods"] = model.interfaceMemory.catalogue(language: model.settings.preferredInterfaceLanguage)
            }
            return result
        case "manage_task":
            guard nativeRequestActive, let owner = model.activeRequest?.owner else {
                throw PipelineFailure.targetUnavailable
            }
            if input["operation"] as? String == "revise_view" {
                guard let instruction = input["instruction"] as? String, !instruction.isEmpty else {
                    throw ToolArgumentError(path: "instruction", issue: "supply the requested appearance change")
                }
                let ticket = model.beginTaskRevision(owner.id, .interface)
                defer { model.taskRevisions.finish(ticket) }
                let key = try await model.loadModelKey(for: requestConnection)
                try await model.reviseTaskInterface(
                    owner.id, instruction: instruction, userEdit: true,
                    ticket: ticket, connection: requestConnection ?? model.settings.mainConnection, key: key)
                guard revision == steeringRevision else { throw CancellationError() }
                verifyEffect(model.userText("已更新界面。", "Updated the view."))
                if requestShape != .dependent { ToolExecutionScope.current?.verification?.finalCheck = true }
            } else {
                guard let raw = input["action"] as? String, let action = RequestIntent.TaskAction(rawValue: raw),
                    action != .perform
                else {
                    throw ToolArgumentError(path: "action", issue: "choose cancel or complete")
                }
                ToolExecutionScope.current?.effectStarted = true
                let reply = try await model.endTask(owner.id, action: action)
                taskControlReceipt = (owner.id, reply)
                verifyEffect(reply)
            }
            return ["verified": true, "task_id": owner.id.uuidString]
        case "write_document":
            guard nativeRequestActive, let filename = input["filename"] as? String, let code = input["code"] as? String else {
                throw AppError.message("Supply a document filename and a script.")
            }
            var values = try observations.inputs(input)
            values["files"] = RequestRun.current?.attachments ?? [:]
            let result: [String: Any]
            do { result = try await model.taskCode.run(code: code, input: values, state: [:]) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Script errors can quote user-selected file contents.
                throw ToolArgumentError(path: "$.code", issue: "read the attached text from input.files and return {content: string}")
            }
            guard let content = result["content"] as? String else {
                throw ToolArgumentError(path: "$.code", issue: "return {content: string} with the complete document")
            }
            try Task.checkCancellation()
            guard revision == steeringRevision else { throw CancellationError() }
            let file = try model.publishWorkFile(name: filename, content: content, id: activeTaskID, ticket: interfaceTicket)
            taskSurfaceReady = true
            verifyEffect(model.userText("文件已生成：", "Created ") + file.name)
            ToolExecutionScope.current?.verification?.finalCheck = true
            return ["verified": true, "filename": file.name]
        case "run_code":
            guard nativeRequestActive, let code = input["code"] as? String else {
                throw AppError.message("Code execution requires an active task and a function body.")
            }
            let quote = (input["answerEvidence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answerOnly = requestedDelivery == .answer || !quote.isEmpty && currentRequest.contains(quote)
            let mayReply = answerOnly && requestedDelivery != .card && requestIntent.behavior == .snapshot
                && !unresolvedCalendar && !taskSurfaceReady && !interfaceAttempted && !operatedPage
                && taskControlReceipt == nil && RequestRun.current?.assignment == nil
            let replyKey = mayReply ? input["replyKey"] as? String : nil
            if model.requestPageID == nil { attemptedTaskWork = true }
            attemptedCode = true
            codeReceipt = nil
            taskSurfaceReady = false
            let state = model.sideTasks.first(where: { $0.id == activeTaskID })?.liveValues ?? [:]
            let values = try observations.inputs(input)
            let bindings = input["bindings"] as? [[String: String]] ?? []
            if unavailableTools.contains("read_value"), observations.hasSeveralSources,
                RequestRun.current?.assignment == nil, bindings.isEmpty {
                throw ToolArgumentError(path: "$.bindings", issue: "bind the actual contributing measurements from the observed responses; do not copy source values into the code or literal input")
            }
            let sourceValues = bindings.compactMap { $0["name"].flatMap { APIDataSpec.scalar(values[$0]) } }
            if replyKey != nil, !bindings.isEmpty || recovery.needsSourceReading {
                guard !bindings.isEmpty else {
                    throw ToolArgumentError(path: "$.bindings", issue: "use actual source inputs to answer this calculation")
                }
                try recovery.validateSnapshot(sourceValues, requirements: requestIntent.requirements)
            }
            let result = try await model.taskCode.run(code: code, input: values, state: state)
            if !bindings.isEmpty {
                Diagnostics.record("calculation_bound_inputs", ["candidateCount": bindings.count, "requestID": model.activeRequest?.id.uuidString ?? ""])
            }
            guard revision == steeringRevision else { return ["superseded": true] }
            let id = UUID().uuidString
            codeReceipt = (id, result, bindings.isEmpty ? nil : sourceValues, observations.sourceNotes(for: bindings))
            if let run = RequestRun.current, let values = try? TaskValues.decode(result), !values.isEmpty {
                let artifact = model.work.retain(title: String(currentRequest.prefix(80)), values: values,
                    definition: WorkDefinition(), design: WorkDesign(), goalID: run.goalID,
                    source: observations.sourceNotes(for: bindings))
                run.retainResult(artifact, needsView: false)
            }
            if let key = input["replyKey"] as? String, !bindings.isEmpty {
                _ = retainObservedSnapshot(["title": String(currentRequest.prefix(100)), "form": ["compactKey": key]])
            }
            if let key = replyKey {
                guard let raw = (result["state"] as? [String: Any] ?? result)[key],
                    let answer = APIDataSpec.scalar(raw), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw ToolArgumentError(path: "$.replyKey", issue: "choose a nonempty scalar output for a completed informational calculation; verify pending actions or readings separately") }
                replyKind = .information
                verifyEffect(answer)
                ToolExecutionScope.current?.verification?.finalCheck = true
            }
            var receipt: [String: Any] = ["verified": true, "run_id": id, "result": result]
            if input["replyKey"] != nil && !mayReply {
                receipt["next"] = wantsEditableTool ? "Use the verified result on the card and bind the next useful operation to a visible control." : "The calculation is verified. Use this receipt with present_ui for the requested card or continue the outstanding work. If the human explicitly requests text only, include verbatim answerEvidence for replyKey."
            }
            return receipt
        case "present_ui":
            let verifiedSnapshot = retainObservedSnapshot(input)
            if recovery.needsSourceReading && !freshSourceLoaded {
                guard requestIntent.behavior == .snapshot, let values = codeReceipt?.sourceValues, input["initialize"] == nil else {
                    throw AppError.message("The external reading is still unverified. Bind a live source or verify the observed page before presenting its values.")
                }
                try recovery.validateSnapshot(values, requirements: requestIntent.requirements)
            } else if let values = codeReceipt?.sourceValues, input["initialize"] == nil {
                try recovery.validateSnapshot(values, requirements: requestIntent.requirements)
            }
            let specification = try TaskForm.expandingStateView(input)
            if let view = input["stateView"] as? [String: Any] {
                try await reviewLocalChoices(view)
                try Task.checkCancellation()
                guard revision == steeringRevision else { throw CancellationError() }
            }
            do {
                #if DEBUG
                if verifiedSnapshot != nil && model.isLiveTest && CommandLine.arguments.contains("--reject-reading-layout") {
                    throw ToolArgumentError(path: "$.markup", issue: "Injected presentation failure after verification")
                }
                #endif
                return try await presentWorkspace(specification, revision: revision, origin: .generated)
            } catch {
                try Task.checkCancellation()
                guard revision == steeringRevision, let snapshot = verifiedSnapshot, let summary = retainedReading,
                    requestIntent.behavior == .snapshot, requestShape != .dependent, !wantsEditableTool,
                    model.activeRequest?.owner == nil, model.requestPageID == nil,
                    (input["actions"] as? [[String: Any]] ?? []).isEmpty, input["runtime"] == nil,
                    input["stateView"] == nil, input["complete"] as? Bool == true,
                    let form = input["form"] as? [String: Any], (form["inputs"] as? [[String: Any]] ?? []).isEmpty,
                    (form["visuals"] as? [[String: Any]] ?? []).isEmpty, (form["buttons"] as? [[String: Any]] ?? []).isEmpty,
                    (form["outputs"] as? [[String: Any]] ?? []).allSatisfy({ row in
                        (row["key"] as? String).flatMap { snapshot.state[$0] } != nil && row["sourceAction"] == nil
                    })
                else { throw error }
                try model.commitTaskSurface(snapshot, id: activeTaskID, ticket: interfaceTicket)
                taskSurfaceReady = true
                freshSourceLoaded = true
                verifyEffect(summary)
                Diagnostics.record("verified_reading_fallback", ["taskID": activeTaskID.uuidString])
                return ["verified": true, "task_id": activeTaskID.uuidString]
            }
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
            if let surface = task.taskSurface, surface.apiData != nil,
                operation == "refresh" || operation == "invoke" {
                let registered = surface.actions.filter { $0.kind == .remote }
                let action = registered.first {
                    operation == "refresh" ? $0.operation == "refresh" : $0.id == input["action"] as? String
                }
                guard let request = model.activeRequest, let action else {
                    throw ToolArgumentError(path: "$.action", issue: "choose an available action: " + registered.map(\.id).joined(separator: ", "))
                }
                let fields = input["fields"] as? [String: String] ?? [:]
                guard let job = model.performDataAction(owner.id, action: action, fields: fields, requestID: request.id) else {
                    throw ToolArgumentError(path: "$.fields", issue: "use valid inputs for this card: " + surface.fields.joined(separator: ", "))
                }
                await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation()
                guard !job.isCancelled, revision == steeringRevision, model.activeRequest?.id == request.id,
                    let updated = model.sideTasks.first(where: { $0.id == owner.id })
                else { throw CancellationError() }
                guard updated.status == "Ready", updated.dataIssue == nil else {
                    throw AppError.message(updated.dataIssue ?? updated.state["resultStatus"] ?? "The update could not be verified.")
                }
                freshSourceLoaded = freshSourceLoaded || task.dataUpdatedAt != updated.dataUpdatedAt
                let reply = surface.apiData?.readingSummary(title: updated.title, state: updated.state) ?? updated.title
                verifyEffect(reply)
                taskControlReceipt = (owner.id, reply)
                return ["verified": true, "task_id": owner.id.uuidString, "state": AgentContext.displayState(updated.state, source: surface.apiData)]
            }
            if operation == "invoke" {
                guard let action = input["action"] as? String,
                    task.taskSurface?.actions.contains(where: { $0.id == action && $0.kind == .code }) == true
                else {
                    throw AppError.message("Supply an observed action ID and named input fields.")
                }
                let fields = input["fields"] as? [String: String] ?? [:]
                model.taskActionJobs.removeValue(forKey: owner.id)?.cancel()
                model.taskRuntime.detach(owner.id)
                let ticket = model.beginTaskRevision(owner.id, .execution)
                defer {
                    if model.accepts(ticket) {
                        model.taskRevisions.finish(ticket)
                        model.taskRuntime.attach(owner.id)
                    }
                }
                let state = try await model.executeTaskCodeAction(
                    owner.id, action: action, fields: fields, ticket: ticket)
                ToolExecutionScope.current?.effectStarted = true
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
            let runtimeID = model.work.view(owner.id)?.selected ?? owner.id
            model.taskRuntime.control(runtimeID, operation: operation)
            if ["resume", "restart", "refresh"].contains(operation) { try await model.taskRuntime.verify(runtimeID) }
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
            if recipe.kind == .web && model.requestPageID == nil {
                throw AppError.message("Open or resolve this request's source before reusing a webpage design.")
            }
            guard recipe.markup.matchesLanguage(model.settings.preferredInterfaceLanguage) else {
                return ["needs_localization": true, "instruction": "Use this method to generate a fresh presentation in the configured language. Use query_api for data, compose_ui for webpages or present_ui for a local tool.",
                        "method": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe))]
            }
            if requestIntent.route == .api, recipe.kind == .workspace, recipe.surface?.apiData == nil {
                throw AppError.message(
                    "This request needs fresh API data. Reuse an API-backed recipe or use query_api.")
            }
            if recipe.kind == .web {
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
            // A saved method is reusable regardless of which source resource was inspected.
            var state = input["state"] as? [String: String] ?? [:]
            if var spec = recipe.surface?.apiData {
                let inputKeys = Set((spec.inputs ?? [:]).keys)
                guard inputKeys == Set(state.keys) else {
                    throw AppError.message(
                        "Supply fresh values for every saved API input, and no saved results, in state.")
                }
                spec.inputs = state
                let title = input["title"] as? String ?? recipe.surface!.title
                if title != recipe.surface!.title, spec.card?.kind == .reading,
                    spec.card?.displayNameKey == nil, spec.card?.subject != nil {
                    spec.card?.subject = title
                }
                let result = try await executeDataTool(
                    "query_api",
                    [
                        "title": title,
                        "source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)),
                        "markup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe.markup)),
                        "outcomeEvidence": input["outcomeEvidence"] as? [[String: Any]] ?? [],
                        "requirements": input["requirements"] as? [[String: Any]] ?? [],
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
            let initialize = input["initialize"] as? String ?? (!surface.fields.isEmpty && handlers.count == 1 ? handlers[0].id : nil)
            if initialize != nil {
                guard Set(surface.fields).isSubset(of: Set(state.keys)) else {
                    throw AppError.message("Supply fresh values for every saved input field before recalculating.")
                }
                surface.state = Dictionary(uniqueKeysWithValues: Set(recipe.stateKeys).map { ($0, "") }).merging(state) {
                    _, new in new
                }
            } else {
                surface = try model.interfaceMemory.taskSurface(
                    raw, title: input["title"] as? String ?? surface.title, state: state)
            }
            surface.title = input["title"] as? String ?? surface.title
            surface.markup = recipe.markup
            if surface.title != recipe.surface?.title {
                surface.markup.bindReusedGlanceTitle()
            }
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

    /// A source-backed observation can survive a broken layout or schedule.
    /// Only a fully verified recipe may advertise continuing updates.
    private func retainObservedSnapshot(_ input: [String: Any]) -> TaskSurface? {
        guard let receipt = codeReceipt, let values = receipt.sourceValues, !receipt.sourceNotes.isEmpty,
            input["initialize"] == nil, input["run_id"] == nil || input["run_id"] as? String == receipt.id,
            (try? recovery.validateIdentity(values, requirements: requestIntent.requirements)) != nil,
            let verified = try? TaskValues.decode(receipt.result), let title = input["title"] as? String else { return nil }
        let form = input["form"] as? [String: Any]
        let markup = input["markup"] as? [String: Any]
        let glance = markup?["glance"] as? [String: Any]
        let bound = CardMarkup.bindingKeys(in: markup?["compactHTML"] as? String ?? "").intersection(verified.keys)
        guard let key = form?["compactKey"] as? String ?? glance?["valueKey"] as? String ?? (bound.count == 1 ? bound.first : nil),
            let value = verified[key], !value.isEmpty, value.count <= 120 else { return nil }
        let unit = form?["compactUnit"] as? String ?? glance?["unit"] as? String
        let summary = title + " · " + value + (unit.flatMap { value.hasSuffix($0) ? nil : " " + $0 } ?? "")
        retainedReading = summary + "\n" + receipt.sourceNotes
        let subject = String(title.prefix(100))
        // A broken generated form may have invalid keys, duplicate rows or oversized labels.
        // Keep a small, host-owned snapshot even if none of its proposed markup is usable.
        let basic = TaskForm(inputs: [], outputs: [.init(key: "observedValue",label: "")], buttons: [],
            compactUnit: unit, compactSubject: subject, compactKey: "observedValue")
        if var markup = try? basic.markup() {
            markup.html += "<footer><small data-bind='observedSource'></small></footer>"
            retainedSnapshot = try? TaskSurface(title: subject, markup: markup, fields: [], actions: [],
                state: ["observedValue":value, "observedSource":receipt.sourceNotes], runID:receipt.id).validated()
        }
        var rows = (form?["outputs"] as? [[String: Any]] ?? []).compactMap { item -> TaskForm.Output? in
            guard let k = item["key"] as? String, verified[k] != nil, let label = item["label"] as? String else { return nil }
            return .init(key: k, label: label)
        }
        if !rows.contains(where: { $0.key == key }) { rows.insert(.init(key: key, label: title), at: 0) }
        let standard = TaskForm(inputs: [], outputs: rows, buttons: [], compactUnit: unit, compactSubject: title, compactKey: key)
        guard var layout = try? standard.markup() else { return nil }
        let displayed = Set(rows.map(\.key))
        var state = verified.filter { displayed.contains($0.key) }
        var noteKey = "verifiedSource"
        while state[noteKey] != nil { noteKey += "_" }
        state[noteKey] = receipt.sourceNotes
        layout.html += "<footer><small data-bind='" + noteKey + "'></small></footer>"
        guard let surface = try? TaskSurface(title: title, markup: layout, fields: [], actions: [],
            state: state, runID: receipt.id).validated() else { return nil }
        retainedSnapshot = surface
        return surface
    }

    /// Verify meaning independently of the mechanical reachability and action checks.
    private func reviewLocalChoices(_ view: [String: Any]) async throws {
        let decision = model.settings
        guard decision.useFast, Date() >= model.fastTriageRetryAfter,
            !model.isLiveTest || CommandLine.arguments.contains("--allow-live-services"),
            let values = view["values"] as? [String], let buttons = view["buttons"] as? [[String: Any]],
            JevRequestTriage.eligible(currentRequest), values.allSatisfy(JevRequestTriage.eligible),
            decision.decisionAPI.allowsBackground(decision.fast)
        else { return }
        let controls = buttons.map { $0.filter { ["label", "to", "move", "targets"].contains($0.key) } }
        guard controls.flatMap({ $0.values.compactMap { $0 as? String } }).allSatisfy(JevRequestTriage.eligible),
            let key = try? await SecretStore.loadAvailable(decision.fastKeyAccount), !key.isEmpty else { return }
        let scores = try? await DecisionClient.judge(endpoint: decision.fast, api: decision.decisionAPI, key: key,
            state: ["request": currentRequest, "valuesInOrder": values, "buttons": controls] as [String: Any],
            questions: ["contradiction": "Do the offered values or transitions clearly contradict the human's goal? Check that pressing a button visibly achieves its named effect, and that the workflow uses the human's supplied content. Differences in interface language alone are fine."], timeout: 2)
        if let score = scores?["contradiction"], (0.9...1).contains(score) {
            throw ToolArgumentError(path: "$.stateView", issue: "Rebuild the values around the actual requested result. Include a visible destination for each outcome. Map each button directly to what its label promises. Keep the human's supplied items and order.")
        }
    }

    private func presentWorkspace(_ input: [String: Any], revision: Int, origin: TaskVerification.DefinitionOrigin)
        async throws -> [String: Any]
    {
        guard nativeRequestActive else { throw AppError.message("A task interface requires an active user request.") }
        // A browser is an execution resource, not the mandatory destination of
        // every result produced after visiting it. Evidence checks still apply.
        attemptedTaskWork = true
        var specification = input
        if (specification["actions"] as? [[String: Any]])?.contains(where: { $0["kind"] as? String == "openRecord" }) == true {
            throw ToolArgumentError(path: "$.actions", issue: "bind source destinations from observed records with read_value or show_readings")
        }
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
        let formProposal = input["form"] as? [String: Any]
        let tableProposed = (formProposal?["visuals"] as? [[String: Any]])?.contains { $0["kind"] as? String == "table" } == true
        let joint = requestIntent.placement?.layout == .together || requestShape == .dependent || tableProposed
        func supportedSubject(_ subject: String) -> Bool {
            guard let title = specification["title"] as? String else { return true }
            let name = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            // A joint result may identify a winner or a pair in a different order from the full title.
            if joint { return true }
            // A result or an individual row can share words with the task title. Only the
            // complete instance name can shorten that title on the collapsed card.
            return title.range(of: name, options: [.anchored, .caseInsensitive]) != nil
                || (title.localizedCaseInsensitiveContains(name) && currentRequest.localizedCaseInsensitiveContains(name))
        }
        if var markup = specification["markup"] as? [String: Any], var glance = markup["glance"] as? [String: Any],
            let subject = glance["subject"] as? String, !supportedSubject(subject), let title = specification["title"] as? String {
            glance["subject"] = String(title.prefix(40))
            markup["glance"] = glance
            specification["markup"] = markup
        }
        var formVisuals: (form: TaskForm, blocks: [CardVisual], count: Int)?
        if specification["markup"] == nil, var form = specification["form"] as? [String: Any] {
            let proposed = CardVisual.decodeProposals(form.removeValue(forKey: "visuals"))
            var composition = try JSONDecoder().decode(
                TaskForm.self, from: JSONSerialization.data(withJSONObject: form))
            if let subject = composition.compactSubject, !supportedSubject(subject) {
                composition.compactSubject = nil
            }
            specification["markup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(composition.markup()))
            if proposed.count > 0 || joint { formVisuals = (composition, proposed.blocks, proposed.count) }
            specification["fields"] = composition.inputs.map(\.key)
        }
        var surface = try JSONDecoder().decode(
            TaskSurface.self, from: JSONSerialization.data(withJSONObject: specification))
        guard surface.apiData == nil else {
            throw AppError.message(
                "Use query_api to verify an API-backed task; present_ui cannot attach unverified remote data.")
        }
        if origin == .generated, input["markup"] != nil, surface.preset == nil,
            (input["markup"] as? [String: Any])?["glance"] == nil {
            // Older model clients supply compactHTML. Preserve its selected live reading, but
            // always render the compact surface with the same host component as a declared glance.
            var shared = CardMarkup.bindingKeys(in: surface.markup.compactHTML)
                .intersection(CardMarkup.bindingKeys(in: surface.markup.html)).subtracting(["title", "status", "detail"])
            if shared.isEmpty {
                let expanded = CardMarkup.bindingKeys(in: surface.markup.html)
                if let preferred = (input["form"] as? [String: Any])?["compactKey"] as? String, expanded.contains(preferred) {
                    shared = [preferred]
                } else {
                    shared = expanded.intersection(surface.state.keys).subtracting(surface.fields).subtracting(["title", "status", "detail"])
                }
            }
            if shared.count == 1, let key = shared.first {
                surface.markup.compactHTML = "<div class='calm-glance'><small class='calm-label' data-bind='title'></small><strong class='calm-value' data-bind='" + key + "'></strong></div>"
            } else {
                throw ToolArgumentError(path: "$.markup.glance", issue: "Add glance with subject (short object name) and valueKey (primary state field bound in html). Keep the verified expanded markup.")
            }
        }
        let initializes = input["initialize"] is String
        // A self-contained handler is fresh evidence, independent of earlier exploration.
        // An explicit run_id still binds the candidate to that exact successful run.
        if surface.runID != nil || (attemptedCode && !initializes) {
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
                let code = action.code
            else {
                throw ToolArgumentError(
                    path: "$.initialize",
                    issue:
                        "name a declared code action"
                )
            }
            let missing = Set(surface.fields).subtracting(surface.state.keys).sorted()
            guard missing.isEmpty else {
                throw ToolArgumentError(
                    path: "$.state",
                    issue:
                        "missing initial values for declared input fields: \(missing.joined(separator: ", ")). Match form.inputs keys exactly; do not rename inputs in only one part of the definition"
                )
            }
            let initial = surface.state.filter { surface.fields.contains($0.key) }
            let output: [String: String]
            do {
                output = try TaskValues.decode(try await definitionChecks.run(
                    code: code, input: initial, state: surface.state, declaredInputs: surface.fields))
            } catch let error as TaskCodeError {
                let index = surface.actions.firstIndex { $0.id == initialize }!
                throw ToolArgumentError(path: "$.actions[\(index)].code", issue: "Initialization in " + initialize + " failed: " + error.localizedDescription + " Supply a function body with a top-level return {state:{...}}. Keep inputs, layout and checks.")
            }
            guard !output.isEmpty, output.values.allSatisfy({ !["NaN", "Infinity", "-Infinity"].contains($0) }) else {
                throw AppError.message("Initialization did not produce usable results.")
            }
            surface.state.merge(output) { _, verified in verified }
            if let run = RequestRun.current {
                // A successful initialization is evidence even if the proposed
                // interface or a different action later fails validation.
                let result = model.work.retain(title:surface.title,values:surface.state,definition:WorkDefinition(),
                    design:WorkDesign(),goalID:run.goalID)
                run.retainResult(result,needsView:false)
            }
        }
        var omittedVisuals = 0
        if let proposal = formVisuals {
            var form = proposal.form
            let columns = surface.state.compactMap { key, raw -> CardVisual.Column? in
                guard raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
                    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) is [Any] else { return nil }
                return .init(key: key, label: form.outputs.first { $0.key == key }?.label ?? key)
            }
            form.visuals = Array(proposal.blocks.compactMap { $0.bound(to: columns) }.prefix(3))
            omittedVisuals = proposal.count - (form.visuals?.count ?? 0)
            if joint, omittedVisuals > 0, (form.visuals ?? []).isEmpty {
                throw ToolArgumentError(path: "$.form.visuals", issue: "The comparison layout has no usable data columns. Bind the table to existing array columns, or remove the visual and put every compared subject and measurement in form.outputs.")
            }
            if joint, let result = form.outputs.first(where: { $0.key == form.compactKey }),
                let value = surface.state[result.key], value.contains(where: \.isNumber) {
                // A numeric row labeled with a verified option carries its own identity.
                // A generic compact title would detach the number from that option.
                let names = surface.state.values.filter { name in
                    name.count >= 2 && name.count <= 32 && name.contains(where: \.isLetter)
                        && !value.localizedCaseInsensitiveContains(name)
                        && (result.label.caseInsensitiveCompare(name) == .orderedSame ||
                            result.label.range(of: NSRegularExpression.escapedPattern(for: name) + #"(?=[\s(（·—:])"#,
                                options: [.anchored, .regularExpression, .caseInsensitive]) != nil)
                }
                if let name = names.max(by: { $0.count < $1.count }),
                    form.compactSubject?.localizedCaseInsensitiveContains(name) != true { form.compactSubject = name }
            }
            surface.markup = try form.markup()
            formVisuals = (form, proposal.blocks, proposal.count)
        }
        try surface.markup.validateLanguage(model.settings.preferredInterfaceLanguage, path: input["form"] == nil ? "$.markup" : "$.form")
        surface.markup.interfaceLanguage = model.settings.preferredInterfaceLanguage
        if let spec = surface.runtime {
            surface.runtime = try spec.validated(fields: surface.fields, at: requestStartedAt)
        }
        if origin == .generated {
            let markup = input["markup"] as? [String: Any]
            let field = markup == nil && input["form"] != nil ? "$.form.compactKey"
                : markup?["glance"] == nil ? "$.markup.compactHTML" : "$.markup.glance.valueKey"
            try surface.markup.validateExpandedPurpose(state: surface.state, subject: surface.title, hasActions: !surface.actions.isEmpty || !surface.fields.isEmpty)
            try surface.markup.validateGlance(state: surface.state, fieldPath: field, runtimeKeys: Set(surface.runtime?.sources.map(\.key) ?? []))
            if let key = CardMarkup.bindingKeys(in: surface.markup.compactHTML).subtracting(["title", "status"]).first {
                let form = input["form"] as? [String: Any]
                let glance = (input["markup"] as? [String: Any])?["glance"] as? [String: Any]
                if joint {
                    let label = formVisuals?.form.compactSubject ?? glance?["subject"] as? String ?? surface.title
                    let labelWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)])
                    if labelWidth.width > 82 {
                        throw ToolArgumentError(path: form != nil ? "$.form.compactSubject" : "$.markup.glance.subject", issue: "Use a short identifiable subject or leader that fits 82px. Put the identifying words first.")
                    }
                    if let value = surface.state[key], Double(value) != nil,
                        !surface.markup.compactHTML.contains("raw-value-unit"),
                        surface.state.values.contains(where: { $0.range(of: #"(?<![\d.])"# + NSRegularExpression.escapedPattern(for: value) + #"\s*(?:[%‰°]|[\p{L}]+)"#, options: .regularExpression) != nil }) {
                        throw ToolArgumentError(path: field, issue: "This result shows a bare number while the same measurement has a unit in state. Include the unit in the compact value or supply form.compactUnit / markup.glance.unit.")
                    }
                }
                let outputs = form?["outputs"] as? [[String: Any]] ?? []
                let labels = outputs.filter { $0["key"] as? String != key }.compactMap { $0["label"] as? String }
                try surface.markup.validateMeasuredResult(primary: key, subjects: [surface.title] + labels, state: surface.state, fieldPath: field)
            }
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
            surface, runtime: definitionChecks, required: surface.actions.contains(where: { $0.kind == .code }),
            origin: origin)
        if [.live, .advancing].contains(requestIntent.behavior), surface.runtime == nil {
            throw AppError.message(
                "A continuing task requires runtime data sources or a scheduled refresh; static state is not sufficient."
            )
        }
        try Task.checkCancellation()
        guard revision == steeringRevision else { return ["superseded": true] }
        try await reviewAssignedReading(surface)
        try Task.checkCancellation()
        guard revision == steeringRevision else { return ["superseded": true] }
        // Keep the original destination even after borrowing a page to do work.
        let destination = presentationDestination()
        if let destination, destination != activeTaskID {
            if let ticket = interfaceTicket { model.taskRevisions.finish(ticket) }
            activeTaskID = destination
            interfaceTicket = model.beginTaskRevision(destination,.interface)
        } else if destination == nil && (activeTaskID == model.activeRequest?.browserResourceID
            || resolvedResultView != nil || RequestRun.current?.publishedViewIDs.contains(activeTaskID) == true) {
            if let ticket = interfaceTicket { model.taskRevisions.finish(ticket) }
            activeTaskID = UUID()
            interfaceTicket = nil
        }
        try model.commitTaskSurface(surface, id: activeTaskID, ticket: interfaceTicket)
        if initializes && input["run_id"] == nil {
            attemptedCode = false
            codeReceipt = nil
        }
        taskSurfaceReady = true
        if input["complete"] as? Bool == true {
            model.transitionRequest(to: .verifying)
            do { try await TaskVerification.verify(activeTaskID, intent: requestIntent, model: model) } catch {
                // Verification failure does not roll back observed values. Keep the
                // durable result and repair the execution or presentation separately.
                if !(error is CancellationError), revision == steeringRevision,
                    let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID }) {
                    model.sideTasks[i].interfaceIssue = error.localizedDescription
                    model.persistSideTasks()
                    taskSurfaceReady = false
                }
                throw error
            }
            guard revision == steeringRevision else { return ["superseded": true] }
            var reply = surface.runtime == nil
                    ? "Your tool is ready."
                    : ((surface.runtime?.refresh?.intervalSeconds ?? 1) > 3
                        ? "Your task is scheduled." : "Your task is running.")
            if omittedVisuals > 0 {
                reply += "\n" + model.userText("部分图表无法与数据列匹配，已略过。", "Some visuals could not be matched to the data and were omitted.")
            }
            verifyEffect(reply)
        }
        finishWorkPresentation(keeping:[activeTaskID])
        return ["verified": true, "task_id": activeTaskID.uuidString, "actions": surface.actions.map(\.id)]
    }
}
