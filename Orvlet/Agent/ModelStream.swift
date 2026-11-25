import Foundation

extension ModelClient {
    /// Only public text and recognized tool names leave the transport. Arguments are assembled before execution.
    static func stream(_ request: URLRequest, key: String, headers: [String: String]?,
                       notify: (String, String?) -> Void) async throws -> [String: Any] {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Missing model response.") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes.prefix(16384) { data.append(byte) }
            throw serviceFailure(http, data: data, secrets: [key] + Array((headers ?? [:]).values))
        }
        if response.mimeType?.contains("event-stream") != true {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.message("Unreadable model response.") }
            return object
        }
        var publicText = "", reasoning = "", finish: String?
        var calls: [Int: [String: String]] = [:], usage: [String: Any] = [:]
        var blocks: [Int: [String: Any]] = [:], blockInputs: [Int: String] = [:], message: [String: Any] = [:]
        var lastPaint = Date.distantPast
        func emit(_ tool: String? = nil) {
            if tool != nil || Date().timeIntervalSince(lastPaint) > 0.1 {
                lastPaint = Date()
                notify(String(publicText.suffix(1600)), tool)
            }
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { break }
            guard let event = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { continue }
            if event["error"] != nil || event["type"] as? String == "response.failed" { throw AppError.message("The model stopped while sending its response.") }
            if let received = event["usage"] as? [String: Any] { usage = received }
            if let choice = (event["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let text = delta["content"] as? String { publicText += text; emit() }
                reasoning += delta["reasoning_content"] as? String ?? ""
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let i = call["index"] as? Int ?? 0
                    if let id = call["id"] as? String { calls[i, default: [:]]["id"] = id }
                    if let f = call["function"] as? [String: Any] {
                        if let name = f["name"] as? String { calls[i, default: [:]]["name", default: ""] += name; emit(calls[i]?["name"]) }
                        calls[i, default: [:]]["arguments", default: ""] += f["arguments"] as? String ?? ""
                    }
                }
                if let reason = choice["finish_reason"] as? String {
                    // A completed choice is terminal even if a gateway keeps SSE
                    // heartbeats alive or omits its optional trailing [DONE] marker.
                    finish = reason
                    break
                }
                continue
            }
            let i = event["index"] as? Int ?? 0
            switch event["type"] as? String {
            case "response.output_text.delta": publicText += event["delta"] as? String ?? ""; emit()
            case "response.output_item.added": emit((event["item"] as? [String: Any])?["name"] as? String)
            case "response.completed", "response.incomplete":
                if let result = event["response"] as? [String: Any] { return result }
            case "message_start": message = event["message"] as? [String: Any] ?? [:]
            case "content_block_start":
                blocks[i] = event["content_block"] as? [String: Any]
                if let name = blocks[i]?["name"] as? String { emit(name) }
            case "content_block_delta":
                let d = event["delta"] as? [String: Any] ?? [:]
                for key in ["text", "thinking", "signature"] {
                    if let fragment = d[key] as? String {
                        let previous = blocks[i]?[key] as? String ?? ""
                        blocks[i]?[key] = previous + fragment
                        if key == "text" { publicText += fragment; emit() }
                    }
                }
                if let json = d["partial_json"] as? String { blockInputs[i, default: ""] += json }
            case "message_delta":
                if let d = event["delta"] as? [String: Any] { message.merge(d) { _, new in new } }
            case "message_stop":
                for (index, raw) in blockInputs { blocks[index]?["input"] = try JSONSerialization.jsonObject(with: Data(raw.utf8)) }
                message["content"] = blocks.sorted { $0.key < $1.key }.map(\.value)
                message["usage"] = (message["usage"] as? [String: Any] ?? [:]).merging(usage) { _, new in new }
                return message
            default: break
            }
        }
        guard let finish else { throw AppError.message("The model response ended before the step was complete.") }
        var result: [String: Any] = ["role": "assistant", "content": publicText]
        if !reasoning.isEmpty { result["reasoning_content"] = reasoning }
        if !calls.isEmpty {
            result["tool_calls"] = calls.sorted { $0.key < $1.key }.map { _, c in
                ["id": c["id"] ?? "", "type": "function", "function": ["name": c["name"] ?? "", "arguments": c["arguments"] ?? ""] ] as [String: Any]
            }
        }
        return ["choices": [["message": result, "finish_reason": finish]], "usage": usage]
    }
}
