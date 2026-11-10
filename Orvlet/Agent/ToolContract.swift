import CoreFoundation
import Foundation

/// One boundary for model arguments. Errors describe structure, never argument values.
struct ToolArgumentError: LocalizedError {
    let path: String
    let issue: String
    var errorDescription: String? {
        "Invalid tool arguments at \(path): \(issue). Correct the arguments using the tool schema."
    }

    static func decoding(_ error: Error) -> ToolArgumentError? {
        func path(_ context: DecodingError.Context) -> String {
            "$" + context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return .init(path: path(context) + "." + key.stringValue, issue: "required field is missing")
        case DecodingError.typeMismatch(_, let context):
            return .init(path: path(context), issue: "incorrect value type")
        case DecodingError.valueNotFound(_, let context):
            return .init(path: path(context), issue: "a non-null value is required")
        case DecodingError.dataCorrupted(let context):
            return .init(path: path(context), issue: "invalid encoded value")
        default: return nil
        }
    }
}

@MainActor
enum ToolContract {
    static func arguments(_ name: String, _ input: [String: Any]) throws -> [String: Any] {
        try validate(name, input)
        let function = AgentToolRegistry.definitions.compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == name }!
        return omittingNullOptions(input, schema: function["parameters"] as! [String: Any]) as! [String: Any]
    }

    /// Optional null means absent at every named-record boundary; dynamic dictionaries keep their values.
    private static func omittingNullOptions(_ value: Any, schema: [String: Any]) -> Any {
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            var result: [String: Any] = [:]
            for (key, value) in object {
                if let property = properties[key] {
                    if value is NSNull && !required.contains(key) { continue }
                    result[key] = omittingNullOptions(value, schema: property)
                } else if let additional = schema["additionalProperties"] as? [String: Any] {
                    result[key] = omittingNullOptions(value, schema: additional)
                } else {
                    result[key] = value
                }
            }
            return result
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            return array.map { omittingNullOptions($0, schema: items) }
        }
        return value
    }

    static func validate(_ name: String, _ input: [String: Any]) throws {
        guard
            let function = AgentToolRegistry.definitions.compactMap({ $0["function"] as? [String: Any] })
                .first(where: { $0["name"] as? String == name }),
            let schema = function["parameters"] as? [String: Any]
        else { throw ToolArgumentError(path: "$", issue: "unknown tool") }
        try validate(input, schema: schema)
    }

    static func validate(_ value: Any, schema: [String: Any], path: String = "$") throws {
        func fail(_ issue: String, at field: String? = nil) throws {
            throw ToolArgumentError(path: field ?? path, issue: issue)
        }
        let types = (schema["type"] as? String).map { [$0] } ?? schema["type"] as? [String] ?? []
        let number = value as? NSNumber
        let boolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        func matches(_ type: String) -> Bool {
            switch type {
            case "null": return value is NSNull
            case "string": return value is String
            case "object": return value is [String: Any]
            case "array": return value is [Any]
            case "boolean": return boolean
            case "number": return !boolean && number?.doubleValue.isFinite == true
            case "integer":
                return !boolean && number?.doubleValue.isFinite == true
                    && number!.doubleValue.rounded() == number!.doubleValue
            default: return true
            }
        }
        if !types.isEmpty && !types.contains(where: matches) { try fail("expected " + types.joined(separator: " or ")) }
        if let options = schema["enum"] as? [Any],
            !options.contains(where: { ($0 as? NSObject)?.isEqual(value) == true })
        {
            try fail("value is outside the declared options")
        }
        if value is NSNull, types.contains("null") { return }
        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            var accepted = false
            for alternative in alternatives {
                do {
                    try validate(value, schema: alternative, path: path)
                    accepted = true
                    break
                } catch {}
            }
            guard accepted else {
                try fail("does not match a declared action and its argument schema")
                return
            }
        }
        if value is NSNull { return }
        if let object = value as? [String: Any] {
            if let max = schema["maxProperties"] as? Int, object.count > max { try fail("too many object fields") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in (schema["required"] as? [String] ?? []).sorted() where object[key] == nil {
                try fail("required field is missing", at: path + "." + key)
            }
            for key in object.keys.sorted(by: {
                (properties[$0] == nil ? 1 : 0, $0) < (properties[$1] == nil ? 1 : 0, $1)
            }) {
                if let child = properties[key] {
                    try validate(object[key]!, schema: child, path: path + "." + key)
                } else if let child = schema["additionalProperties"] as? [String: Any] {
                    // Dynamic keys may contain user data; never include them in diagnostics.
                    try validate(object[key]!, schema: child, path: path + ".*")
                } else if schema["additionalProperties"] as? Bool == false {
                    try fail(
                        "unexpected field; use the declared nesting. Allowed here: "
                            + properties.keys.sorted().joined(separator: ", "))
                }
            }
        }
        if let array = value as? [Any] {
            if let max = schema["maxItems"] as? Int, array.count > max { try fail("too many items") }
            if let min = schema["minItems"] as? Int, array.count < min { try fail("too few items") }
            if let child = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() { try validate(item, schema: child, path: path + "[\(index)]") }
            }
        }
        if let string = value as? String {
            if let max = schema["maxLength"] as? Int, string.count > max { try fail("text is too long") }
            if let min = schema["minLength"] as? Int, string.count < min { try fail("text is too short") }
        }
        if let number, !boolean {
            if let min = (schema["minimum"] as? NSNumber)?.doubleValue, number.doubleValue < min {
                try fail("below minimum")
            }
            if let max = (schema["maximum"] as? NSNumber)?.doubleValue, number.doubleValue > max {
                try fail("above maximum")
            }
        }
    }
}
