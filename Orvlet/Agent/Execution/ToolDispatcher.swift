import Foundation

@MainActor
extension AgentController {
    func execute(_ name: String, _ input: [String: Any], goal proposedGoal: Int? = nil, requestScoped: Bool = true)
        async throws -> [String: Any]
    {
        try Task.checkCancellation()
        try authorizeTool(name)
        var payload = input
        payload.removeValue(forKey: "goal")
        let arguments: [String: Any]
        do { arguments = try ToolContract.arguments(name, payload) } catch {
            if nativeRequestActive && ["compose_ui", "reuse_ui"].contains(name) {
                interfaceAttempted = true
                pendingSurface = nil
            }
            throw error
        }
        let ledger = requestScoped ? executionLedger : RequestExecutionLedger()
        let goal = try ledger.resolveGoal(proposedGoal ?? input["goal"] as? Int)
        let mutation = AgentToolName(rawValue: name)?.changesState == true
        if ledger.goals.count > 1 && mutation && goal == nil {
            throw ToolArgumentError(path: "goal", issue: "Assign this action to one of the declared goals.")
        }
        let ticket = steeringRevision
        let signature = RequestExecutionLedger.signature(name, arguments, goal: goal)
        func publish(_ receipt: RequestExecutionLedger.Receipt) -> [String: Any] {
            if ticket == steeringRevision && requestScoped { lastToolVerification = receipt.verification }
            return receipt.result
        }
        if mutation, let goal, let receipt = ledger.fulfilled[goal] {
            Diagnostics.record("effect_reused", ["name": name, "goal": goal, "revision": ticket])
            return publish(receipt)
        }
        if mutation, let entry = ledger.entries[signature] {
            switch entry {
            case .running(let work): return publish(try await work.value)
            case .succeeded(let receipt):
                Diagnostics.record("effect_reused", ["name": name, "revision": ticket])
                return publish(receipt)
            case .uncertain:
                throw AppError.message(
                    "This action may already have taken effect. Observe and verify its current result; do not execute it again."
                )
            }
        }
        if mutation, let goal, ledger.uncertainGoals.contains(goal) {
            throw AppError.message(
                "This goal has an unconfirmed effect. Observe and verify it before any further change, or report the blocker."
            )
        }
        if nativeRequestActive && ["compose_ui", "reuse_ui"].contains(name) {
            interfaceAttempted = true
            pendingSurface = nil
        }
        let scope = ToolExecutionContext()
        let operation = Task { @MainActor in
            do {
                let result = try await ToolExecutionScope.$current.withValue(scope) {
                    try await self.dispatch(name, arguments)
                }
                try Task.checkCancellation()
                guard ticket == self.steeringRevision else { throw CancellationError() }
                if name == "finish" { scope.verification?.finalCheck = true }
                let receipt = RequestExecutionLedger.Receipt(result: result, verification: scope.verification)
                if mutation { ledger.entries[signature] = .succeeded(receipt) }
                ledger.record(receipt, goal: goal)
                Diagnostics.record(
                    "effect_receipt",
                    [
                        "name": name, "goal": goal ?? -1,
                        "verified": scope.verification != nil, "complete": ledger.complete, "revision": ticket,
                    ])
                return receipt
            } catch {
                if mutation && scope.effectStarted {
                    ledger.entries[signature] = .uncertain
                    if let goal { ledger.uncertainGoals.insert(goal) }
                } else {
                    ledger.entries.removeValue(forKey: signature)
                }
                throw ToolArgumentError.decoding(error) ?? error
            }
        }
        if mutation { ledger.entries[signature] = .running(operation) }
        let work = Task { @MainActor in
            try await withTaskCancellationHandler(
                operation: {
                    try await operation.value.result
                }, onCancel: { operation.cancel() })
        }
        executionTask = work
        defer { if ticket == steeringRevision { executionTask = nil } }
        _ = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        return publish(try await operation.value)
    }

    /// A stored receipt never grants permission to a later or unrelated caller.
    private func authorizeTool(_ name: String) throws {
        if nativeRequestActive && unavailableTools.contains(name) {
            throw AppError.message("This path is unavailable for the current request. Use the suggested fallback.")
        }
        guard !nativeRequestActive || requestIntent.allows(name) else {
            throw AppError.message(
                "This action does not match the current human request. Use the appropriate tool or ask for clarification."
            )
        }
        if ["calendar_create", "calendar_clarify", "timer_start"].contains(name), !nativeRequestActive {
            throw AppError.message("Native actions require an active human request.")
        }
    }

    func dispatch(_ name: String, _ input: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        model.transitionRequest(
            to: name == "finish"
                ? .verifying
                : ["compose_ui", "present_ui", "reuse_ui", "reuse_saved_ui"].contains(name) ? .presenting : .executing)
        let revision = steeringRevision
        if nativeRequestActive {
            let action = input["action"] as? String ?? name
            let operation = input["operation"] as? String ?? ""
            if requestIntent.needsBrowserContext && model.hasMedia && requestIntent.playbackIntent != "play",
                name == "navigate" || ["reload", "back", "forward"].contains(action)
                    || (action == "media" && ["seek", "next", "previous"].contains(operation)),
                requestIntent.mediaSetting == "loop" || requestIntent.mediaSetting == "unloop"
            {
                throw AppError.message(
                    "Loop settings must not navigate, reload, seek or restart playback. Use the media loop operation, or report that it is unavailable."
                )
            }
        }
        try authorizeTool(name)
        if ["navigate", "observe", "act", "screenshot", "compose_ui", "reuse_ui", "reuse_saved_ui", "finish"].contains(
            name), let owner = model.requestPageID
        {
            try await model.prepareTaskSource(owner)
        }
        guard let tool = AgentToolName(rawValue: name) else { throw AppError.message("Unknown action.") }
        if name == "control_media" {
            return try await executeMediaControl(input)
        }
        switch tool.domain {
        case .data: return try await executeDataTool(name, input, revision: revision)
        case .workspace: return try await executeWorkspaceTool(name, input, revision: revision)
        case .native: return try await executeNativeTool(name, input, revision: revision)
        case .browser: return try await executeBrowserTool(name, input, revision: revision)
        case .completion: return try await executeCompletionTool(name, input, revision: revision)
        }
    }

}
