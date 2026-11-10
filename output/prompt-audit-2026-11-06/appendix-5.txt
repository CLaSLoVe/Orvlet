import Foundation

@MainActor
enum ToolSchema {
    static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [])
        -> [String: Any]
    {
        [
            "type": "function",
            "function": [
                "name": name, "description": description,
                "parameters": closed(["type": "object", "properties": properties, "required": required]),
            ],
        ]
    }

    /// Named records are closed; explicitly typed dictionaries and free-form state stay open.
    static func closed(_ schema: [String: Any]) -> [String: Any] {
        var result = schema
        if let alternatives = schema["anyOf"] as? [[String: Any]] { result["anyOf"] = alternatives.map(closed) }
        if let properties = schema["properties"] as? [String: [String: Any]] {
            let required = Set(schema["required"] as? [String] ?? [])
            var normalized: [String: [String: Any]] = [:]
            for (key, value) in properties {
                var child = closed(value)
                if !required.contains(key) {
                    var types = (child["type"] as? String).map { [$0] } ?? child["type"] as? [String] ?? []
                    if !types.isEmpty && !types.contains("null") {
                        types.append("null")
                        child["type"] = types
                    }
                    if var options = child["enum"] as? [Any], !options.contains(where: { $0 is NSNull }) {
                        options.append(NSNull())
                        child["enum"] = options
                    }
                }
                normalized[key] = child
            }
            result["properties"] = normalized
            if schema["additionalProperties"] == nil { result["additionalProperties"] = false }
        }
        if let items = schema["items"] as? [String: Any] { result["items"] = closed(items) }
        if let additional = schema["additionalProperties"] as? [String: Any] {
            result["additionalProperties"] = closed(additional)
        }
        return result
    }
}
