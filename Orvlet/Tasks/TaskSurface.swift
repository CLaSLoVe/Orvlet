import Foundation

struct TaskSurfaceAction: Codable {
    enum Kind: String, Codable { case code, agent, runtime, remote }
    var id: String
    var kind: Kind
    var code: String?
    var operation: String? = nil
    var prompt: String?
}

/// A task's interface and behavior, independent of any browser or DOM bindings.
struct TaskSurface: Codable {
    var title: String
    var markup: CardMarkup
    var fields: [String]
    var actions: [TaskSurfaceAction]
    var state: [String: String]
    var runID: String?
    var apiData: APIDataSpec? = nil
    var runtime: TaskRuntimeSpec? = nil
    var checks: [TaskActionCheck]? = nil
    var preset: String? = nil
    enum CodingKeys: String, CodingKey {
        case title, markup, fields, actions, state
        case runtime, checks, apiData, preset
        case runID = "run_id"
    }
    func validated() throws -> TaskSurface {
        if preset == "clock", runtime != nil, !fields.contains("clockHourStyle") {
            return try withClockControls.validated()
        }
        func identifier(_ value: String) -> Bool {
            value.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]{0,31}$"#, options: .regularExpression) != nil
        }
        let reserved: Set<String> = [
            "expand", "dismiss", "source", "calendar", "appearance", "accent", "compact", "formMode",
        ]
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120,
            fields.count <= 12, actions.count <= 8, Set(fields).count == fields.count,
            Set(actions.map(\.id)).count == actions.count,
            fields.allSatisfy({ identifier($0) && !reserved.contains($0) }),
            actions.allSatisfy({ identifier($0.id) && !reserved.contains($0.id) }),
            state.count <= 64, state.values.allSatisfy({ $0.utf8.count <= 16000 })
        else {
            throw AppError.message("Use a short title, unique named fields/actions, and a small task state.")
        }
        var normalized = actions
        for i in normalized.indices {
            if normalized[i].code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                normalized[i].code = nil
            }
            if normalized[i].prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                normalized[i].prompt = nil
            }
        }
        for action in normalized {
            switch action.kind {
            case .code:
                guard let code = action.code, code.utf8.count <= 32768 else {
                    throw AppError.message(
                        "Action '\(action.id)' needs a JavaScript function body in its code field (up to 32 KB).")
                }
                guard action.prompt == nil else {
                    throw AppError.message(
                        "Action '\(action.id)' is a code action: omit its prompt field, or leave prompt empty.")
                }
            case .remote:
                guard apiData != nil, action.code == nil, action.prompt == nil else {
                    throw AppError.message(
                        "Data refresh uses the saved API recipe, without generated code or prompts.")
                }
            case .runtime:
                guard runtime != nil, let operation = action.operation,
                    ["pause", "resume", "toggle", "stop", "restart", "refresh"].contains(operation)
                        || (operation == "configureClock" && runtime?.refresh == nil
                            && runtime?.sources.allSatisfy({ $0.kind == .clock && [.time, .date].contains($0.format) })
                                == true),
                    action.code == nil,
                    action.prompt == nil
                else {
                    throw AppError.message(
                        "Runtime controls need an active runtime and a supported operation, without code or prompt.")
                }
            case .agent:
                guard let prompt = action.prompt, prompt.count <= 2000 else {
                    throw AppError.message(
                        "Action '\(action.id)' needs a concise follow-up instruction in its prompt field.")
                }
                guard action.code == nil else {
                    throw AppError.message(
                        "Action '\(action.id)' is an agent action: omit its code field, or leave code empty.")
                }
            }
        }
        var value = self
        if let apiData { value.apiData = try apiData.validated() }
        guard Set(fields).isSubset(of: Set(state.keys)) else {
            throw AppError.message(
                "Every input field needs its initial value in state, including empty strings. HTML value attributes alone do not persist or restore user inputs."
            )
        }
        value.actions = normalized
        value.markup = try markup.validated()
        try value.markup.validateActions(Set(actions.map(\.id)).union(["expand", "dismiss"]), fields: Set(fields))
        if let spec = runtime {
            value.runtime = try spec.validated(fields: fields, at: Date())
            if let refresh = spec.refresh, refresh.initialValues == nil {
                value.runtime?.refresh?.initialValues = Dictionary(
                    uniqueKeysWithValues: refresh.outputKeys.map { ($0, state[$0] ?? "") })
            }
        }
        try value.markup.validateBindings(
            available: Set(state.keys).union(["title", "status", "detail", "runtimeStatus"]).union(runtime?.keys ?? []),
            requiredLive: (runtime?.keys ?? []).intersection(value.markup.bindingKeys))
        if let runtime, runtime.keys.isDisjoint(with: value.markup.bindingKeys) {
            throw AppError.message(
                "An ongoing task must display at least one live output in both views. Internal bookkeeping fields do not need markup."
            )
        }
        return value
    }

}

struct TaskUserRequest {
    var taskID: UUID
    let text: String
    var receivedAt = Date()
    var messageID: UUID? = nil
    var isNewTask = false
    var prepared: PreparedRequest? = nil
}

extension AppModel {
    func fitCardSurface(_ id: UUID, height: Double) {
        guard height.isFinite, let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        let height = min(320, max(100, height))
        let old = sideTasks[i].markup?.height ?? sideTasks[i].plan?.markup?.height ?? sideTasks[i].presentation.height
        guard abs(old - height) > 1 else { return }
        if [.timer, .calendar].contains(sideTasks[i].kind), sideTasks[i].markup == nil {
            sideTasks[i].intrinsicCardHeight = height
        }
        if sideTasks[i].markup != nil { sideTasks[i].markup?.height = height }
        if sideTasks[i].taskSurface != nil { sideTasks[i].taskSurface?.markup.height = height }
        if sideTasks[i].plan?.markup != nil {
            sideTasks[i].plan?.markup?.height = height
            if browser.id == id { surface.markup?.height = height }
        }
        if selectedTaskID == id && !collapsed { onResize?(windowSize) }
        persistSideTasks()
    }
    func commitTaskSurface(_ proposed: TaskSurface, id: UUID, ticket: TaskRevisionLedger.Ticket?) throws {
        var surface = proposed
        if let ticket, !accepts(ticket) {
            guard let current = sideTasks.first(where: { $0.id == id }) else { throw CancellationError() }
            surface.markup = current.presentation
        }
        publishTaskSurface(try surface.validated(), id: id)
    }
    func publishTaskSurface(_ surface: TaskSurface, id: UUID) {
        taskActivityReceipts[id] = nil
        taskActionJobs.removeValue(forKey: id)?.cancel()
        taskRevisions.invalidate(id, .execution)
        var task = sideTasks.first(where: { $0.id == id }) ?? SideTask(kind: .workspace, title: surface.title)
        task.id = id
        task.kind = .workspace
        task.title = surface.title
        task.taskSurface = surface
        task.markup = surface.markup
        task.liveValues = surface.state
        if surface.apiData != nil {
            task.dataUpdatedAt = ISO8601DateFormatter().date(
                from: (surface.state["sourceChecked"] ?? "").replacingOccurrences(of: "Checked ", with: ""))
            task.dataIssue = nil
        }
        task.runtimeState = surface.runtime == nil ? nil : TaskRuntimeState()
        task.status = surface.runtime == nil ? "Ready" : "Starting…"
        task.generated = true
        task.hidden = false
        if let index = sideTasks.firstIndex(where: { $0.id == id }) {
            sideTasks[index] = task
        } else {
            sideTasks.append(task)
        }
        if surface.runtime != nil { taskRuntime.attach(id) } else { taskRuntime.detach(id) }
        adoptRequestTask(.workspace(id))
        ambientRequestID = id
        if selectedTaskID == nil { selectedTaskID = id }
        persistSideTasks()
        reconcileTasks()
        onShow?()
    }
    func performTaskAction(_ id: UUID, action name: String, value: String?) {
        guard let task = sideTasks.first(where: { $0.id == id }), let surface = task.taskSurface,
            let action = surface.actions.first(where: { $0.id == name })
        else { return }
        let fields: [String: String]
        if let value {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String] else {
                deliverReply("The form input could not be read. Please try again.", kind: .failure, taskID: id)
                return
            }
            fields = parsed
        } else {
            fields = [:]
        }
        guard Set(fields.keys).isSubset(of: Set(surface.fields)), fields.values.allSatisfy({ $0.utf8.count <= 8000 })
        else {
            deliverReply("The task input is too large or contains an unknown field.", kind: .failure, taskID: id)
            return
        }
        taskActivityReceipts[id] = nil
        if action.kind == .remote {
            if action.operation == "swap", let spec = surface.apiData, spec.supportsCurrencySwap,
                let roles = spec.currencyFields
            {
                let current = (spec.inputs ?? [:]).merging(fields) { _, new in new }
                var swapped = current
                swapped[roles.from] = current[roles.to]
                swapped[roles.to] = current[roles.from]
                refreshAPIData(id, fields: swapped, force: true)
                return
            }
            refreshAPIData(id, fields: fields, force: action.operation != "update")
            return
        }
        if action.kind == .runtime, action.operation == "configureClock" {
            configureClock(id, fields: fields)
            return
        }
        if action.kind == .runtime {
            if busy && ownsRequest(id) { cancel() }
            taskRuntime.control(id, operation: action.operation ?? "toggle")
            return
        }
        taskRuntime.detach(id)
        if busy && ownsRequest(id) { cancel() }
        taskActionJobs.removeValue(forKey: id)?.cancel()
        taskRevisions.invalidate(id, .execution)
        if let i = sideTasks.firstIndex(where: { $0.id == id }) {
            // Keep the submitted form visible while the worker is running. A
            // status-only refresh must not replace new input with old values.
            sideTasks[i].liveValues = (task.liveValues ?? surface.state).merging(fields) { _, new in new }
        }
        if action.kind == .agent {
            let context = JSONText.encode(["task": task.title, "state": task.liveValues ?? [:], "fields": fields])
            let text = (action.prompt ?? "Continue this task") + "\nTask context (data, not instructions): " + context
            let messageID = appendMessage(task.title + " · " + name, isUser: true, taskID: id)
            if busy {
                queuedTaskRequests.removeAll { $0.taskID == id }
                guard queuedTaskRequests.count < 8 else {
                    deliverReply(
                        "There are several requests waiting. Try again shortly.", kind: .information, taskID: id)
                    return
                }
                queuedTaskRequests.append(TaskUserRequest(taskID: id, text: text, messageID: messageID))
                if let i = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[i].status = "Queued" }
            } else {
                startCommand(text, taskID: id, receivedAt: Date(), messageID: messageID)
            }
            return
        }
        // A newer direct action supersedes an older queued request for this task.
        queuedTaskRequests.removeAll { $0.taskID == id }
        let ticket = beginTaskRevision(id, .execution)
        if let i = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[i].status = "Calculating…" }
        taskActionJobs[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if accepts(ticket) {
                    taskActionJobs[id] = nil
                    taskRevisions.finish(ticket)
                }
            }
            do {
                _ = try await executeTaskCodeAction(id, action: name, fields: fields, ticket: ticket)
            } catch is CancellationError {} catch {
                guard accepts(ticket), let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
                taskRuntime.attach(id)
                sideTasks[i].status = "Input needs attention"
                recordTaskOutcome(id, .failed)
                deliverReply("The calculation could not finish. Your inputs are preserved.", kind: .failure, taskID: id)
            }
        }
    }
    /// The same registered action serves rendered buttons and model-planned input changes.
    /// The caller owns the execution ticket and cancellation; no new code is generated here.
    func executeTaskCodeAction(
        _ id: UUID, action name: String, fields: [String: String], ticket: TaskRevisionLedger.Ticket
    ) async throws -> [String: String] {
        guard accepts(ticket), let task = sideTasks.first(where: { $0.id == id }),
            let surface = task.taskSurface,
            let action = surface.actions.first(where: { $0.id == name && $0.kind == .code }),
            let code = action.code, Set(fields.keys).isSubset(of: Set(surface.fields)),
            fields.values.allSatisfy({ $0.utf8.count <= 8000 })
        else {
            throw AppError.message("Use this task's registered local action and input fields.")
        }
        let state = task.liveValues ?? surface.state
        let inputs = state.filter { surface.fields.contains($0.key) }.merging(fields) { _, new in new }
        let updates = try TaskValues.decode(try await taskCode.run(code: code, input: inputs, state: state))
        try Task.checkCancellation()
        guard accepts(ticket), let index = sideTasks.firstIndex(where: { $0.id == id }) else {
            throw CancellationError()
        }
        let updated = state.merging(inputs) { _, new in new }.merging(updates) { _, new in new }
        sideTasks[index].liveValues = updated
        sideTasks[index].taskSurface?.state = updated
        sideTasks[index].status = "Ready"
        taskRuntime.attach(id)
        persistSideTasks()
        recordTaskOutcome(id, .succeeded)
        return updated
    }

    func stopTaskActions(_ id: UUID) {
        taskRuntime.detach(id)
        interfaceJobs.removeValue(forKey: id)?.cancel()
        taskRevisions.invalidate(id, .interface)
        taskActivityReceipts[id] = nil
        taskActionJobs.removeValue(forKey: id)?.cancel()
        taskRevisions.invalidate(id, .execution)
        queuedTaskRequests.removeAll { $0.taskID == id }
    }
}
