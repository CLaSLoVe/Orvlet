import Foundation

/// Protocol translation lives at the boundary; the agent keeps one tool/conversation representation.
enum ModelWire {
    static let historyKey = "_orvletWire"

    /// Only allowlisted scalar policy fields; never log arbitrary provider overrides.
    static func reasoningPolicy(_ body: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let value = body["enable_thinking"] as? Bool { result["enable_thinking"] = value }
        if let value = (body["thinking"] as? [String: Any])?["type"] as? String,
            ["enabled", "disabled", "adaptive"].contains(value)
        {
            result["thinking"] = value
        }
        let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        if let value = body["reasoning_effort"] as? String, efforts.contains(value) {
            result["reasoning_effort"] = value
        }
        if let value = (body["reasoning"] as? [String: Any])?["effort"] as? String,
            efforts.contains(value)
        {
            result["reasoning"] = value
        }
        return result
    }

    static func body(
        endpoint: Endpoint, messages: [[String: Any]], tools: [[String: Any]],
        reasoning: Bool, requiredTool: String?, budget: ThinkingBudget
    ) throws -> [String: Any] {
        let options = endpoint.options
        try options.validate()
        if let requiredTool,
            !tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == requiredTool })
        {
            throw AppError.message("The required model tool is unavailable.")
        }
        let forced = options.forceTools ? requiredTool : nil
        var body: [String: Any] = ["model": endpoint.model, "stream": false]
        switch options.api {
        case .chatCompletions:
            body["messages"] = messages.map { $0.filter { $0.key != historyKey } }
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }
            if let forced {
                body["tool_choice"] = ["type": "function", "function": ["name": forced]]
                body["parallel_tool_calls"] = false
            }
            if options.reasoning == .automatic {
                body.merge(budget.parameters(for: endpoint, reasoning: reasoning)) { _, new in new }
            } else if options.reasoning != .provider {
                let disabled = ThinkingBudget.low.parameters(for: endpoint, reasoning: false)
                if options.reasoning == .none, disabled["enable_thinking"] != nil {
                    body.merge(disabled) { _, new in new }
                } else {
                    body["reasoning_effort"] = options.reasoning.rawValue
                }
            }
        case .responses:
            body["input"] = try responsesInput(messages, endpoint: endpoint)
            body["store"] = false
            body["include"] = ["reasoning.encrypted_content"]
            if !tools.isEmpty {
                body["tools"] = tools.compactMap { tool -> [String: Any]? in
                    guard var function = tool["function"] as? [String: Any] else { return nil }
                    function["type"] = "function"
                    // Responses otherwise normalizes optional tool fields into required fields.
                    if function["strict"] == nil { function["strict"] = false }
                    return function
                }
                body["tool_choice"] = "auto"
            }
            if let forced {
                body["tool_choice"] = ["type": "function", "name": forced]
                body["parallel_tool_calls"] = false
            }
            if ![ModelReasoning.automatic, .provider].contains(options.reasoning) {
                body["reasoning"] = ["effort": options.reasoning.rawValue]
            }
        case .messages:
            let converted = try anthropicInput(messages, endpoint: endpoint)
            body["messages"] = converted.messages
            if !converted.system.isEmpty { body["system"] = converted.system.joined(separator: "\n\n") }
            body["max_tokens"] = 8192
            if !tools.isEmpty {
                body["tools"] = tools.compactMap { tool -> [String: Any]? in
                    guard let function = tool["function"] as? [String: Any] else { return nil }
                    return [
                        "name": function["name"] ?? "", "description": function["description"] ?? "",
                        "input_schema": function["parameters"] ?? [:],
                    ]
                }
                body["tool_choice"] = ["type": "auto"]
            }
            if let forced { body["tool_choice"] = ["type": "tool", "name": forced, "disable_parallel_tool_use": true] }
        }
        if let limit = Int(options.outputTokens) {
            let field =
                options.api == .responses
                ? "max_output_tokens" : options.api == .messages ? "max_tokens" : options.tokenParameter
            body[field] = limit
        }
        if let temperature = Double(options.temperature) { body["temperature"] = temperature }
        return merge(body, overrides: try options.object(options.parameters, label: "Request parameters"))
    }

    /// Recursive overrides; null explicitly omits a default, for compatibility with lean gateways.
    static func merge(_ base: [String: Any], overrides: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overrides {
            if value is NSNull {
                result.removeValue(forKey: key)
            } else if let nested = value as? [String: Any] {
                result[key] = merge(result[key] as? [String: Any] ?? [:], overrides: nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func headers(endpoint: Endpoint, key: String) throws -> [String: String] {
        try endpoint.options.validate()
        let options = endpoint.options
        var headers: [String: String] = [:]
        if options.api == .messages { headers["anthropic-version"] = "2023-06-01" }
        let auth =
            options.authentication == .automatic
            ? (options.api == .messages ? ModelAuthentication.apiKey : .bearer) : options.authentication
        if !key.isEmpty {
            switch auth {
            case .automatic, .bearer: headers["Authorization"] = "Bearer " + key
            case .apiKey: headers["x-api-key"] = key
            case .custom: headers[options.authHeader] = options.authPrefix + key
            case .none: break
            }
        }
        for (name, value) in try options.object(options.headers, label: "Request headers") {
            let value = (value as? String ?? "").replacingOccurrences(of: "${API_KEY}", with: key)
            for old in Array(headers.keys) where old.lowercased() == name.lowercased() {
                headers.removeValue(forKey: old)
            }
            headers[name] = value
        }
        return headers
    }

    static func history(_ message: [String: Any], endpoint: Endpoint) -> [[String: Any]]? {
        guard let saved = message[historyKey] as? [String: Any],
            saved["api"] as? String == endpoint.options.api.rawValue,
            saved["model"] as? String == endpoint.model,
            saved["host"] as? String == endpoint.completionURL?.host
        else { return nil }
        return saved["items"] as? [[String: Any]]
    }
    static func text(_ content: Any?) -> String {
        if let content = content as? String { return content }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func responsesInput(_ messages: [[String: Any]], endpoint: Endpoint) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            if role == "tool" {
                result.append([
                    "type": "function_call_output", "call_id": message["tool_call_id"] ?? "",
                    "output": text(message["content"]),
                ])
            } else if role == "assistant", let items = history(message, endpoint: endpoint) {
                result += items
            } else {
                if let content = message["content"] as? String, !content.isEmpty {
                    result.append(["role": role, "content": content])
                } else if let content = message["content"] as? [[String: Any]] {
                    let converted: [[String: Any]] = content.compactMap { part in
                        if let value = part["text"] as? String {
                            return ["type": role == "assistant" ? "output_text" : "input_text", "text": value]
                        }
                        if let image = part["image_url"] as? [String: Any], let url = image["url"] as? String {
                            return ["type": "input_image", "image_url": url, "detail": image["detail"] ?? "auto"]
                        }
                        return nil
                    }
                    result.append(["role": role, "content": converted])
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    result.append([
                        "type": "function_call", "call_id": call["id"] ?? "", "name": function["name"] ?? "",
                        "arguments": function["arguments"] ?? "{}",
                    ])
                }
            }
        }
        return result
    }
    static func anthropicInput(_ messages: [[String: Any]], endpoint: Endpoint) throws -> (
        system: [String], messages: [[String: Any]]
    ) {
        var system: [String] = []
        var result: [[String: Any]] = []
        for message in messages {
            let sourceRole = message["role"] as? String ?? "user"
            if ["system", "developer"].contains(sourceRole) {
                system.append(text(message["content"]))
                continue
            }
            let role = sourceRole == "assistant" ? "assistant" : "user"
            var blocks: [[String: Any]] = []
            if sourceRole == "tool" {
                blocks = [
                    [
                        "type": "tool_result", "tool_use_id": message["tool_call_id"] ?? "",
                        "content": text(message["content"]),
                    ]
                ]
            } else if role == "assistant", let items = history(message, endpoint: endpoint) {
                blocks = items
            } else {
                if let value = message["content"] as? String, !value.isEmpty {
                    blocks.append(["type": "text", "text": value])
                }
                for part in message["content"] as? [[String: Any]] ?? [] {
                    if let value = part["text"] as? String {
                        blocks.append(["type": "text", "text": value])
                    } else if let image = part["image_url"] as? [String: Any], let url = image["url"] as? String {
                        var source: [String: Any] = ["type": "url", "url": url]
                        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                            let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<comma]).replacingOccurrences(
                                of: ";base64", with: "")
                            source = [
                                "type": "base64", "media_type": mime, "data": String(url[url.index(after: comma)...]),
                            ]
                        }
                        blocks.append(["type": "image", "source": source])
                    }
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    guard let arguments = function["arguments"] as? String,
                        let input = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
                    else { throw AppError.message("A saved tool call has invalid arguments. Start a new request.") }
                    blocks.append([
                        "type": "tool_use", "id": call["id"] ?? "", "name": function["name"] ?? "", "input": input,
                    ])
                }
            }
            if blocks.isEmpty { continue }
            if result.last?["role"] as? String == role {
                let index = result.count - 1
                result[index]["content"] = (result[index]["content"] as? [[String: Any]] ?? []) + blocks
            } else {
                result.append(["role": role, "content": blocks])
            }
        }
        return (system, result)
    }

    static func message(_ json: [String: Any], endpoint: Endpoint) throws -> [String: Any] {
        if endpoint.options.api == .chatCompletions {
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                let message = choice["message"] as? [String: Any]
            else {
                throw AppError.message(
                    "Expected a Chat Completions response. Check the API format in Connection details.")
            }
            if choice["finish_reason"] as? String == "length" { throw truncated() }
            return message
        }
        let api = endpoint.options.api
        if json["status"] as? String == "incomplete" || json["stop_reason"] as? String == "max_tokens" {
            throw truncated()
        }
        guard json["error"] == nil || json["error"] is NSNull,
            let items = json[api == .responses ? "output" : "content"] as? [[String: Any]]
        else { throw AppError.message("Expected a \(api.title) response. Check the API format and provider error.") }
        var content: [String] = []
        var calls: [[String: Any]] = []
        for item in items {
            switch item["type"] as? String {
            case "message":
                content.append(text(item["content"]))
            case "text", "output_text": content.append(item["text"] as? String ?? "")
            case "function_call", "tool_use":
                calls.append([
                    "id": item[api == .responses ? "call_id" : "id"] ?? "", "type": "function",
                    "function": [
                        "name": item["name"] ?? "",
                        "arguments": api == .responses
                            ? (item["arguments"] as? String ?? "{}") : JSONText.encode(item["input"] ?? [:]),
                    ],
                ])
            default: break
            }
        }
        var message: [String: Any] = [
            "role": "assistant", "content": content.joined(separator: "\n"),
            historyKey: [
                "api": api.rawValue, "model": endpoint.model, "host": endpoint.completionURL?.host ?? "",
                "items": items,
            ],
        ]
        if !calls.isEmpty { message["tool_calls"] = calls }
        return message
    }
    static func truncated() -> AppError {
        .message(
            "The model reached its output limit before finishing. Increase the output token limit in Advanced settings."
        )
    }
}
