import Foundation

@MainActor
enum ModelClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ModelRedirectPolicy(), delegateQueue: nil)
    }()
    static func complete(
        endpoint: Endpoint, key: String, messages: [[String: Any]], tools: [[String: Any]], reasoning: Bool = true,
        requiredTool: String? = nil, timeout: TimeInterval? = nil, budget: ThinkingBudget = .standard
    ) async throws -> [String: Any] {
        guard let url = endpoint.completionURL else { throw AppError.message("Enter a model endpoint in Settings.") }
        let body = try ModelWire.body(
            endpoint: endpoint, messages: messages, tools: tools,
            reasoning: reasoning, requiredTool: requiredTool, budget: budget)
        let headers = try ModelWire.headers(endpoint: endpoint, key: key)
        let started = Date()
        let callID = UUID().uuidString
        #if DEBUG
            // Explicit isolated live harness only, including opt-in saved-context replay. Never log headers.
            let capture =
                CommandLine.arguments.contains("--request-pipeline-live")
                && CommandLine.arguments.contains("--capture-routing-prompt") && requiredTool == "interpret_request"
            if capture {
                let payload: [String: Any] = [
                    "routingPrompt": [
                        "callID": callID, "model": endpoint.model,
                        "messages": body["messages"] ?? body["input"] ?? [], "tools": body["tools"] ?? [],
                    ]
                ]
                FileHandle.standardOutput.write(Data((JSONText.encode(payload) + "\n").utf8))
            }
        #endif
        Diagnostics.record(
            "model_request",
            [
                "modelCallID": callID, "model": endpoint.model, "host": url.host ?? "",
                "reasoningRequested": reasoning, "reasoningPolicy": ModelWire.reasoningPolicy(body),
                "messageBytes": JSONText.encode(messages).utf8.count,
                "toolBytes": JSONText.encode(tools).utf8.count, "toolCount": tools.count,
                "inputBytes": JSONText.encode(body).utf8.count,
            ])
        let json: [String: Any]
        do {
            json = try await request(
                url: url, key: key, body: body,
                timeout: Double(endpoint.options.timeout) ?? timeout ?? (reasoning ? 90 : 40),
                headers: headers)
        } catch {
            try Task.checkCancellation()
            Diagnostics.record(
                "model_error",
                [
                    "seconds": Date().timeIntervalSince(started), "stage": "completion",
                    "category": Diagnostics.category(error),
                    "reasonCode": (error as? URLError).map { "transport_" + String($0.code.rawValue) }
                        ?? "provider_response",
                ])
            throw error
        }
        let message = try ModelWire.message(json, endpoint: endpoint)
        #if DEBUG
            if capture {
                FileHandle.standardOutput.write(
                    Data(
                        (JSONText.encode([
                            "routingResponse": ["callID": callID, "message": message]
                        ]) + "\n").utf8))
            }
        #endif
        var receipt: [String: Any] = [
            "modelCallID": callID, "host": url.host ?? "",
            "reasoningCharacters": (message["reasoning_content"] as? String ?? "").count,
            "seconds": Date().timeIntervalSince(started), "model": endpoint.model, "usage": json["usage"] ?? [:],
        ]
        if let usage = json["usage"] as? [String: Any] {
            for (output, keys) in [
                ("inputTokens", ["prompt_tokens", "input_tokens"]),
                ("outputTokens", ["completion_tokens", "output_tokens"]),
                ("totalTokens", ["total_tokens"]),
            ] {
                if let count = keys.compactMap({ usage[$0] as? NSNumber }).first { receipt[output] = count }
            }
        }
        if let usage = json["usage"] as? [String: Any],
            let details = (usage["completion_tokens_details"] ?? usage["output_tokens_details"]) as? [String: Any],
            let count = details["reasoning_tokens"] as? NSNumber
        {
            receipt["reasoningTokens"] = count
        }
        Diagnostics.record("api", receipt)
        return message
    }
    static func request(
        url: URL, key: String, body: [String: Any], timeout: TimeInterval = 40, headers: [String: String]? = nil
    ) async throws -> [String:
        Any]
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let headers {
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Reuse connections for fast repeated operations, without persistent cookies or caches.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("The model service did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError.message(
                providerError(
                    status: http.statusCode, data: data,
                    secrets: [key] + Array((headers ?? [:]).values)))
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("The model returned an unreadable response.")
        }
        return result
    }
    static func providerError(status: Int, data: Data, secrets: [String]) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        var detail = error?["message"] as? String ?? json?["message"] as? String ?? json?["error"] as? String ?? ""
        // Redact before truncation so a partially displayed credential can never survive the limit.
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            detail = detail.replacingOccurrences(of: secret, with: "[redacted]")
        }
        detail = String(detail.prefix(1200))
        let hint: String
        switch status {
        case 301..<400: hint = "The endpoint redirected. Enter its final URL in Connection details."
        case 401, 403: hint = "Check your API key, authentication method and model permissions."
        case 429: hint = "Rate limit or quota reached. Check your provider account."
        case 400, 404, 422: hint = "Check API format, model ID and request parameters."
        default: hint = "The model service could not complete the request."
        }
        return "HTTP \(status) · " + (detail.isEmpty ? hint : detail)
    }

}

private final class ModelRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
