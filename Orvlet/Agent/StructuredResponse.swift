import Foundation

/// A provider format error is repairable internal work, never a new human task.
/// This boundary is only for interpretation/design: it never retries side effects.
@MainActor
enum StructuredResponse {
    static func arguments(_ response: [String: Any], named name: String, allowJSON: Bool = true) throws -> String {
        if let raw = response["tool_calls"], !(raw is NSNull), !(raw is [[String: Any]]) {
            throw AppError.message("Invalid tool call envelope.")
        }
        if let calls = response["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            guard response["function_call"] == nil || response["function_call"] is NSNull else {
                throw AppError.message("Conflicting function responses.")
            }
            guard calls.count == 1, let function = calls[0]["function"] as? [String: Any],
                function["name"] as? String == name,
                let arguments = function["arguments"] as? String
            else {
                throw AppError.message("Return exactly one \(name) result.")
            }
            return arguments
        }
        if let function = response["function_call"] as? [String: Any] {
            guard function["name"] as? String == name, let arguments = function["arguments"] as? String else {
                throw AppError.message("Unexpected function response.")
            }
            return arguments
        }
        guard allowJSON, let content = response["content"] as? String else {
            throw AppError.message("The structured result is missing.")
        }
        return InterfaceComposer.jsonBody(content)
    }

    static func generate<Value>(
        name: String, messages: [[String: Any]], schema: [String: Any],
        complete: ([[String: Any]], [[String: Any]], String?) async throws -> [String: Any],
        validate: (String) throws -> Value
    ) async throws -> Value {
        var turns = messages
        for attempt in 0..<3 {
            try Task.checkCancellation()
            // Transport/authentication failures are not schema errors. Do not hide
            // them in a long retry loop or repeat a possibly completed action.
            let response = try await complete(turns, attempt < 2 ? [schema] : [], attempt < 2 ? name : nil)
            try Task.checkCancellation()
            do {
                let value = try validate(arguments(response, named: name))
                Diagnostics.record("structured_result", ["stage": name, "attempt": attempt + 1])
                return value
            } catch is CancellationError { throw CancellationError() } catch {
                Diagnostics.record("structured_repair", ["stage": name, "attempt": attempt + 1])
                guard attempt < 2 else { throw PipelineFailure.presentation }
                let parameters = (schema["function"] as? [String: Any])?["parameters"] ?? [:]
                // Failed markup stays inside this bounded repair conversation.
                if let raw = try? arguments(response, named: name) {
                    turns.append(["role": "assistant", "content": String(raw.prefix(36000))])
                }
                turns.append([
                    "role": "system",
                    "content": "Repair the previous result. Validation: " + error.localizedDescription
                        + ". Return one complete replacement matching " + JSONText.encode(parameters)
                        + (attempt == 0 ? ". Call \(name)." : ". Return only JSON, without tools or prose."),
                ])
            }
        }
        throw CancellationError()
    }
}

enum PipelineFailure: LocalizedError, Equatable {
    case interpretation, presentation, execution, targetUnavailable
    var errorDescription: String? {
        switch self {
        case .interpretation:
            return "The model service could not prepare this request. Your message is saved; please try again shortly."
        case .presentation: return "The view could not be updated. Your existing card and task are still available."
        case .execution: return "The requested result could not be verified. Your task is saved so you can continue."
        case .targetUnavailable:
            return "The task this message belongs to is no longer available. Open the intended task to continue."
        }
    }
}
