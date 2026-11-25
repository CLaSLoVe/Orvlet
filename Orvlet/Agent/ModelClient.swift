import Foundation

struct ModelServiceFailure: LocalizedError {
    let status: Int
    let detail: String
    let retryAfter: Bool
    var errorDescription: String? { detail }
}

@MainActor
enum ModelClient {
    nonisolated static let defaultTimeout: TimeInterval = 600
    // A transport fallback is temporary and local to this process. User-specified
    // stream parameters remain authoritative; no profile or model is changed.
    private static var bufferedUntil: [String: Date] = [:]
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ModelRedirectPolicy(), delegateQueue: nil)
    }()
    static func complete(
        endpoint: Endpoint, key: String, messages: [[String: Any]], tools: [[String: Any]], reasoning: Bool = true,
        requiredTool: String? = nil, timeout: TimeInterval? = nil, maximumWait: TimeInterval? = nil, budget: ThinkingBudget = .standard,
        onStream: ((String, String?) -> Void)? = nil
    ) async throws -> [String: Any] {
        let endpoint = endpoint.toolCompatible
        guard let url = endpoint.completionURL else { throw AppError.message("Enter a model endpoint in Settings.") }
        var body = try ModelWire.body(
            endpoint: endpoint, messages: messages, tools: tools,
            reasoning: reasoning, requiredTool: requiredTool, budget: budget)
        let streamingKey = url.absoluteString + "|" + endpoint.model
        let streamOption = try endpoint.options.object(endpoint.options.parameters, label: "Request parameters")["stream"]
        let automaticStream = onStream != nil && streamOption == nil
        if automaticStream {
            bufferedUntil = bufferedUntil.filter { $0.value > Date() }
            body["stream"] = bufferedUntil[streamingKey] == nil
        }
        let headers = try ModelWire.headers(endpoint: endpoint, key: key)
        let started = Date()
        let callID = UUID().uuidString
        let configuredTimeout = Double(endpoint.options.timeout) ?? timeout ?? defaultTimeout
        let requestTimeout = maximumWait.map { min(configuredTimeout, $0) } ?? configuredTimeout
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
                "timeoutSeconds": requestTimeout, "stage": requiredTool ?? "execution",
            ])
        let json: [String: Any]
        do {
            func decisionRequest() async throws -> [String: Any] {
                guard let maximumWait else {
                    return try await request(url: url, key: key, body: body, timeout: requestTimeout, headers: headers, onStream: onStream)
                }
                // URLSession's timeout is an inactivity timeout. A stalled stream
                // can keep it alive with heartbeats, so advisory stages need a wall limit.
                var expired = false
                let payload = body
                let network = Task { @MainActor in
                    try await request(url: url, key: key, body: payload, timeout: requestTimeout, headers: headers, onStream: onStream)
                }
                let deadline = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(maximumWait))
                        expired = true
                        network.cancel()
                    } catch {}
                }
                defer { deadline.cancel() }
                do {
                    return try await withTaskCancellationHandler(operation: { try await network.value }, onCancel: { network.cancel() })
                } catch {
                    try Task.checkCancellation()
                    if expired { throw URLError(.timedOut) }
                    throw error
                }
            }
            do { json = try await decisionRequest() }
            catch {
                try Task.checkCancellation()
                let service = error as? ModelServiceFailure
                let transport = (error as? URLError)?.code
                guard (service.map { [502, 503, 504].contains($0.status) && !$0.retryAfter } ?? false)
                    || transport == .networkConnectionLost || (maximumWait != nil && onStream != nil && transport == .timedOut) else { throw error }
                // Tool calls are dispatched only after an entire decision has arrived.
                Diagnostics.record("decision_retry", ["category": Diagnostics.category(error)])
                try await Task.sleep(for: .milliseconds(300))
                // A stalled streamed decision can use one buffered retry. No
                // returned tool has been dispatched yet, so this cannot replay a write.
                if transport == .timedOut {
                    if automaticStream, body["stream"] as? Bool == true {
                        if bufferedUntil.count >= 32 { bufferedUntil.removeAll() }
                        bufferedUntil[streamingKey] = Date().addingTimeInterval(300)
                    }
                    body["stream"] = false
                }
                json = try await decisionRequest()
            }
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
        url: URL, key: String, body: [String: Any], timeout: TimeInterval = defaultTimeout,
        headers: [String: String]? = nil, onStream: ((String, String?) -> Void)? = nil
    ) async throws -> [String:
        Any]
    {
        #if DEBUG
            let studyCallID = try ContinuationStudy.beginProvider(url: url, body: body)
            defer { ContinuationStudy.endProvider(studyCallID) }
        #endif
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
        if let onStream, body["stream"] as? Bool == true {
            do { return try await stream(request, key: key, headers: headers, notify: onStream) }
            catch {
                let reason = error.localizedDescription.lowercased()
                guard reason.contains("stream"), reason.contains("http 400") || reason.contains("http 422") else { throw error }
                var buffered = body
                buffered["stream"] = false
                request.httpBody = try JSONSerialization.data(withJSONObject: buffered)
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("The model service did not respond.")
        }
        #if DEBUG
            ContinuationStudy.endProvider(studyCallID, status: http.statusCode, json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        #endif
        guard (200..<300).contains(http.statusCode) else {
            throw serviceFailure(http, data: data, secrets: [key] + Array((headers ?? [:]).values))
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("The model returned an unreadable response.")
        }
        return result
    }
    static func serviceFailure(_ response: HTTPURLResponse, data: Data, secrets: [String]) -> ModelServiceFailure {
        ModelServiceFailure(status: response.statusCode, detail: providerError(status: response.statusCode, data: data, secrets: secrets),
                            retryAfter: response.value(forHTTPHeaderField: "Retry-After") != nil)
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
