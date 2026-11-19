import Foundation

/// Describes behavior requested before the executor chooses a layout.
enum TaskBehavior: String, Codable { case snapshot, live, advancing, interactive }
struct TaskActionCheck: Codable {
    var action: String
    var input: [String: String]
    var expected: [String: String] = [:]
    var expectedError: String? = nil
    static let schema: [String: Any] = [
        "type": "array", "maxItems": 12,
        "items": [
            "type": "object",
            "properties": [
                "action": ["type": "string"], "input": ["type": "object", "additionalProperties": ["type": "string"]],
                "expected": ["type": "object", "additionalProperties": ["type": "string"]],
                "expectedError": [
                    "type": "string",
                    "description":
                        "For an invalid-input check, a nonempty substring of the thrown error message; omit expected. Each handler still needs a successful changed-input check.",
                ],
            ], "required": ["action", "input"],
        ],
    ]
}
extension TaskActionCheck {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        input = try c.decode([String: String].self, forKey: .input)
        expected = try c.decodeIfPresent([String: String].self, forKey: .expected) ?? [:]
        expectedError = try c.decodeIfPresent(String.self, forKey: .expectedError)
    }
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
        guard checks.count <= 12 else { throw ToolArgumentError(path: "$.checks", issue: "use at most twelve representative action checks") }
        let actions = surface.actions.filter { $0.kind == .code }
        if required, !actions.isEmpty {
            guard Set(actions.map(\.id)).isSubset(of: Set(checks.filter { $0.expectedError == nil }.map(\.action)))
            else {
                throw ToolArgumentError(path: "$.checks", issue:
                    "An interactive tool needs checks for every code action: changed input and expected output. Do not test only the initial example."
                )
            }
            for action in actions where !surface.fields.isEmpty && origin == .generated {
                guard
                    checks.contains(where: { check in
                        check.action == action.id && check.expectedError == nil
                            && check.input.contains(where: { surface.state[$0.key] != $0.value })
                    })
                else {
                    throw ToolArgumentError(path: "$.checks", issue: "Exercise " + action.id + " with at least one input different from its initial state.")
                }
            }
        }
        var executed = Set<String>()
        for (index, check) in checks.enumerated() {
            let path = "$.checks[\(index)]"
            let expectedError = check.expectedError?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let action = actions.first(where: { $0.id == check.action }) else {
                throw ToolArgumentError(path: path + ".action", issue: "choose a declared code action: " + actions.map(\.id).joined(separator: ", "))
            }
            guard (!check.expected.isEmpty) != (expectedError != nil),
                expectedError.map({ !$0.isEmpty && $0.count <= 200 }) ?? true else {
                throw ToolArgumentError(path: path + ".expected", issue: "supply visible expected outputs for success, or expectedError for invalid input")
            }
            guard Set(check.input.keys).isSubset(of: Set(surface.fields)), check.input.count <= 12 else {
                throw ToolArgumentError(path: path + ".input", issue: "use the declared inputs: " + surface.fields.joined(separator: ", "))
            }
            let outputs = Set(surface.state.keys).union(surface.runtime?.keys ?? []).union(surface.markup.bindingKeys)
            guard Set(check.expected.keys).isSubset(of: outputs), check.expected.count <= 24 else {
                throw ToolArgumentError(path: path + ".expected", issue: "unknown output keys: " + Set(check.expected.keys).subtracting(outputs).sorted().joined(separator: ", "))
            }
            let signature = JSONText.encode([
                "action": check.action, "input": check.input, "expected": check.expected,
                "expectedError": expectedError ?? "",
            ])
            if !executed.insert(signature).inserted { continue }
            let input = surface.state.filter { surface.fields.contains($0.key) }.merging(check.input) { _, new in new }
            let output: [String: String]
            do {
                output = try TaskValues.decode(
                    try await runtime.run(code: action.code ?? "", input: input, state: surface.state, declaredInputs: surface.fields))
            } catch let error as TaskCodeError {
                if let expectedError, error.localizedDescription.contains(expectedError) { continue }
                throw ToolArgumentError(
                    path: path,
                    issue:
                        "Handler \(check.action) threw: \(error.localizedDescription). This is a check failure, not initialization. If rejection is intended, use expectedError instead of expected outputs."
                )
            }
            guard expectedError == nil else {
                throw ToolArgumentError(
                    path: path, issue: "Handler returned successfully but this check expected an error.")
            }
            guard check.expected.allSatisfy({ output[$0.key] == $0.value }) else {
                let actual = output.filter { check.expected[$0.key] != nil }
                throw ToolArgumentError(
                    path: path,
                    issue:
                        "Handler \(check.action) returned \(JSONText.encode(actual)); expected \(JSONText.encode(check.expected)). Input is an object with declared keys [\(surface.fields.joined(separator: ", "))]. Read input[fieldName]. Correct the logic or expected result without changing the user requirement."
                )
            }
        }
    }
    static func verify(_ id: UUID, intent: RequestIntent, model: AppModel) async throws {
        guard let task = model.sideTasks.first(where: { $0.id == id }), let surface = task.taskSurface else {
            throw PipelineFailure.execution
        }
        let scheduledReading = intent.behavior == .live && surface.apiData?.refreshSeconds != nil
        if [.live, .advancing].contains(intent.behavior), surface.runtime == nil, !scheduledReading {
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
