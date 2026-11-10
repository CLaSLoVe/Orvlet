import Foundation

/// Describes behavior requested before the executor chooses a layout.
enum TaskBehavior: String, Codable { case snapshot, live, advancing, interactive }
struct TaskActionCheck: Codable {
    var action: String
    var input: [String: String]
    var expected: [String: String]
    static let schema: [String: Any] = [
        "type": "array", "maxItems": 12,
        "items": [
            "type": "object",
            "properties": [
                "action": ["type": "string"], "input": ["type": "object", "additionalProperties": ["type": "string"]],
                "expected": ["type": "object", "additionalProperties": ["type": "string"]],
            ], "required": ["action", "input", "expected"],
        ],
    ]
}
@MainActor
enum TaskVerification {
    /// Saved definitions already passed the changed-input gate when first published.
    /// Their checks still execute; fresh inputs may legitimately equal a saved check.
    enum DefinitionOrigin { case generated, saved }
    static func validateActions(
        _ surface: TaskSurface, runtime: any TaskCodeExecuting, required: Bool, origin: DefinitionOrigin = .generated
    ) async throws {
        let checks = surface.checks ?? []
        guard checks.count <= 12 else { throw AppError.message("Use at most twelve representative action checks.") }
        let actions = surface.actions.filter { $0.kind == .code }
        if required, !actions.isEmpty {
            guard Set(actions.map(\.id)).isSubset(of: Set(checks.map(\.action))) else {
                throw AppError.message(
                    "An interactive tool needs checks for every code action: changed input and expected output. Do not test only the initial example."
                )
            }
            for action in actions where !surface.fields.isEmpty && origin == .generated {
                guard
                    checks.contains(where: { check in
                        check.action == action.id && check.input.contains(where: { surface.state[$0.key] != $0.value })
                    })
                else {
                    throw AppError.message(
                        "Exercise each code action with at least one input different from its initial state.")
                }
            }
        }
        var executed = Set<String>()
        for check in checks {
            guard let action = actions.first(where: { $0.id == check.action }),
                !check.expected.isEmpty, Set(check.input.keys).isSubset(of: Set(surface.fields)),
                Set(check.expected.keys).isSubset(
                    of: Set(surface.state.keys).union(surface.runtime?.keys ?? []).union(surface.markup.bindingKeys)),
                check.input.count <= 12, check.expected.count <= 24
            else {
                throw AppError.message(
                    "Action checks must use registered code actions, input fields and visible result keys.")
            }
            let signature = JSONText.encode([
                "action": check.action, "input": check.input, "expected": check.expected,
            ])
            if !executed.insert(signature).inserted { continue }
            let output = try TaskValues.decode(
                try await runtime.run(code: action.code ?? "", input: check.input, state: surface.state))
            guard check.expected.allSatisfy({ output[$0.key] == $0.value }) else {
                throw AppError.message(
                    "The actual handler failed its changed-input check for \(check.action). Correct its logic or expected result before presenting it."
                )
            }
        }
    }
    static func verify(_ id: UUID, intent: RequestIntent, model: AppModel) async throws {
        guard let task = model.sideTasks.first(where: { $0.id == id }), let surface = task.taskSurface else {
            throw PipelineFailure.execution
        }
        if [.live, .advancing].contains(intent.behavior), surface.runtime == nil {
            throw AppError.message(
                "The request needs continuing updates. A one-time run_code result or Refresh button is insufficient. Supply runtime sources/refresh and bind the live output keys in both views."
            )
        }
        if let spec = surface.runtime {
            for zone in intent.timeZones {
                guard
                    spec.sources.contains(where: { $0.kind == .clock && $0.timeZone == zone && $0.format != .seconds })
                else {
                    throw AppError.message(
                        "The runtime must use the requested IANA time zone \(zone), with a zoned display format (time includes seconds); Unix epoch seconds ignore time zones."
                    )
                }
            }
            try await model.taskRuntime.verify(id)
            if intent.behavior == .advancing && (spec.refresh?.intervalSeconds ?? 1) <= 3 {
                let bound = surface.markup.bindingKeys
                let before = model.taskRuntime.receipts[id]
                try await Task.sleep(for: .seconds(max(2.1, (spec.refresh?.intervalSeconds ?? 1) + 0.4)))
                let after = model.taskRuntime.receipts[id]
                guard before?.generation == after?.generation,
                    before?.values.filter({ bound.contains($0.key) })
                        != after?.values.filter({ bound.contains($0.key) })
                else {
                    throw AppError.message(
                        "The requested advancing value stayed unchanged. Use a running time/elapsed source, not frozen state or a manual refresh."
                    )
                }
            }
        }
        if intent.behavior == .interactive {
            guard !surface.actions.isEmpty else {
                throw AppError.message("The requested interactive tool has no actions.")
            }
            // Code actions already executed their checks before commit. Runtime controls
            // are host implementations, while agent actions explicitly request new work.
        }
    }
}
