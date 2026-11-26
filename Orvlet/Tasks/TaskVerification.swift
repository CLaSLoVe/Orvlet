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
    static func checkedActionOutput(_ response: [String: Any], at path: String) throws -> [String: String] {
        do { _ = try GeneratedReminder.fromAction(response) }
        catch { throw ToolArgumentError(path: path, issue: "Invalid reminder from the handler. " + error.localizedDescription) }
        return try TaskValues.decode(response)
    }

    static func validateActions(
        _ surface: TaskSurface, runtime: any TaskCodeExecuting, required: Bool, origin: DefinitionOrigin = .generated
    ) async throws {
        let checks = surface.checks ?? []
        guard checks.count <= 12 else { throw ToolArgumentError(path: "$.checks", issue: "use at most twelve representative action checks") }
        let actions = surface.actions.filter { $0.kind == .code }
        if required, !actions.isEmpty {
            let missing = Set(actions.map(\.id)).subtracting(checks.filter { $0.expectedError == nil }.map(\.action))
            guard missing.isEmpty else {
                throw ToolArgumentError(path: "$.checks", issue:
                    "Add a successful check for each missing action: \(missing.sorted().joined(separator: ", ")). Exercise a changed input, or for a state-only operation use empty input and expect the changed output."
                )
            }
            for action in actions where !surface.fields.isEmpty && origin == .generated {
                guard
                    checks.contains(where: { check in
                        check.action == action.id && check.expectedError == nil
                            && (check.input.contains(where: { surface.state[$0.key] != $0.value })
                                || check.input.isEmpty && check.expected.contains(where: {
                                    surface.markup.bindingKeys.contains($0.key) && surface.state[$0.key] != $0.value
                                }))
                    })
                else {
                    throw ToolArgumentError(path: "$.checks", issue: "Exercise " + action.id + " with changed input, or verify a visible state change with empty input.")
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
                let response = try await runtime.run(code: action.code ?? "", input: input, state: surface.state, declaredInputs: surface.fields)
                output = try checkedActionOutput(response, at: path)
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
            // Buttons and control_task apply a state patch. An action check may also
            // assert that other displayed values survived the operation.
            let base = surface.state.merging(input) { _, new in new }
            try surface.journal?.validatePatch(output, base: base)
            let result = base.merging(output) { _, new in new }
            guard output.keys.contains(where: { check.expected[$0] != nil }),
                check.expected.allSatisfy({ result[$0.key] == $0.value }) else {
                let actual = output.filter { check.expected[$0.key] != nil }
                throw ToolArgumentError(
                    path: path,
                    issue:
                        "Handler \(check.action) returned \(JSONText.encode(actual)); resulting checked values are \(JSONText.encode(result.filter { check.expected[$0.key] != nil })). Expected \(JSONText.encode(check.expected)). Verify at least one returned output. Input is an object with declared keys [\(surface.fields.joined(separator: ", "))]. Read input[fieldName]. Correct the logic or expected result without changing the user requirement."
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
            let runtimeID = model.work.view(id)?.selected ?? id
            for zone in intent.timeZones {
                guard
                    spec.sources.contains(where: { $0.kind == .clock && $0.timeZone == zone && $0.format != .seconds })
                else {
                    throw AppError.message(
                        "The runtime must use the requested IANA time zone \(zone), with a zoned display format (time includes seconds); Unix epoch seconds ignore time zones."
                    )
                }
            }
            try await model.taskRuntime.verify(runtimeID)
            if intent.behavior == .advancing && (spec.refresh?.intervalSeconds ?? 1) <= 3 {
                let bound = surface.markup.bindingKeys
                let before = model.taskRuntime.receipts[runtimeID]
                try await Task.sleep(for: .seconds(max(2.1, (spec.refresh?.intervalSeconds ?? 1) + 0.4)))
                let after = model.taskRuntime.receipts[runtimeID]
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
