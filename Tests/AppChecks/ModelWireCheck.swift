#if DEBUG
    import Foundation

    @MainActor
    enum ModelWireCheck {
        static func launch() async {
            let url = URL(fileURLWithPath: "/tmp/orvlet-model-api-checks.json")
            do {
                let checks = try await run()
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: url)
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]).write(
                    to: url)
                exit(1)
            }
        }
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw AppError.message("Model API check: " + name) }
                checks.append(name)
            }
            func rejects(_ operation: () throws -> Void) -> Bool {
                do {
                    try operation()
                    return false
                } catch { return true }
            }
            let tool = ToolSchema.function("connection_check", "Check", ["ok": ["type": "boolean"]], required: ["ok"])
            let messages: [[String: Any]] = [
                ["role": "system", "content": "Fixture instructions"], ["role": "user", "content": "Check tools"],
            ]
            var endpoint = Endpoint(baseURL: "https://gateway.example/v1/?api-version=2026-01-01", model: "any-model")
            try check(
                endpoint.completionURL?.path == "/v1/chat/completions"
                    && endpoint.completionURL?.query == "api-version=2026-01-01",
                "Base URL appends the protocol path before preserving query parameters")
            endpoint.options.exactURL = true
            try check(
                endpoint.completionURL?.absoluteString == "https://gateway.example/v1/?api-version=2026-01-01",
                "Exact URL mode never appends a path")
            endpoint.options = ModelOptions()
            endpoint.baseURL = "https://gateway.example/v1/chat/completions"
            try check(
                endpoint.completionURL?.path == "/v1/chat/completions", "Complete protocol paths are never duplicated")
            endpoint.options.api = .responses
            endpoint.baseURL = "https://gateway.example/v1"
            try check(
                endpoint.completionURL?.path == "/v1/responses",
                "Protocol selects the correct endpoint path without host or model whitelists")
            endpoint.baseURL = "http://192.168.1.5/v1"
            try check(endpoint.completionURL == nil, "Network HTTP requires an explicit per-profile choice")
            endpoint.options.allowInsecureHTTP = true
            try check(endpoint.completionURL != nil, "Explicit HTTP choice supports local network servers")
            endpoint.options.authentication = .none
            try check(
                try await ModelConnection(endpoint: endpoint, keyAccount: "unused-wire-fixture").loadKey() == "",
                "No-auth connections do not require or read a saved credential")
            endpoint.options.parameters = #"{"reasoning":{"summary":"auto"},"include":null}"#
            endpoint.options.reasoning = .low
            let merged = try ModelWire.body(
                endpoint: endpoint, messages: messages, tools: [tool], reasoning: true, requiredTool: nil,
                budget: .standard)
            let reasoning = merged["reasoning"] as? [String: String]
            try check(
                reasoning?["effort"] == "low" && reasoning?["summary"] == "auto" && merged["include"] == nil,
                "Custom parameters deep-merge and null removes defaults")
            endpoint.options.parameters = #"{"messages":[]}"#
            try check(rejects { try endpoint.options.validate() }, "Overrides cannot silently replace the conversation")
            endpoint.options.parameters = "{invalid"
            try check(rejects { try endpoint.options.validate() }, "Malformed JSON is rejected before sending")
            endpoint.options.parameters = ""
            endpoint.options.headers = #"{"X-Test":"value\nInjected: bad"}"#
            try check(rejects { try endpoint.options.validate() }, "Header injection is rejected before sending")
            endpoint.options.headers = ""
            endpoint.options.timeout = "-1"
            try check(rejects { try endpoint.options.validate() }, "Invalid timeout is rejected before sending")
            endpoint.options = ModelOptions()
            endpoint.options.reasoning = .none
            endpoint.options.authentication = .custom
            endpoint.options.authHeader = "api-key"
            endpoint.options.outputTokens = "512"
            endpoint.options.tokenParameter = "max_tokens"
            endpoint.options.temperature = "0"
            endpoint.options.timeout = "7"
            endpoint.options.parameters = #"{"top_p":0.9,"parallel_tool_calls":null}"#
            endpoint.options.headers = #"{"X-Provider-Feature":"tools"}"#
            endpoint.baseURL = "http://127.0.0.1:19244/api-wire/chat"
            let chat = try await ModelClient.complete(
                endpoint: endpoint, key: "TEST_WIRE_KEY", messages: messages, tools: [tool],
                requiredTool: "connection_check")
            try check(
                (chat["tool_calls"] as? [[String: Any]])?.count == 1,
                "Chat transport sends custom authentication, reasoning, zero temperature, legacy token limit and JSON overrides"
            )
            var settings = AppSettings()
            settings.main = endpoint
            settings.ensureProfiles()
            settings.storeActiveProfile()
            let originalID = settings.activeProfileID
            settings.addProfile()
            settings.main.options.api = .responses
            settings.storeActiveProfile()
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            var restored = decoded
            _ = restored.selectProfile(originalID)
            try check(
                restored.main == endpoint, "All advanced options survive profile switches and settings serialization")

            endpoint.options = ModelOptions()
            endpoint.options.api = .responses
            endpoint.options.reasoning = .none
            endpoint.baseURL = "http://127.0.0.1:19244/api-wire/responses"
            let first = try await ModelClient.complete(
                endpoint: endpoint, key: "TEST_WIRE_KEY", messages: messages, tools: [tool],
                requiredTool: "connection_check")
            let next = messages + [first, ["role": "tool", "tool_call_id": "call_resp", "content": "{\"ok\":true}"]]
            let second = try await ModelClient.complete(
                endpoint: endpoint, key: "TEST_WIRE_KEY", messages: next, tools: [tool],
                requiredTool: "connection_check")
            try check(
                second["content"] as? String == "done",
                "Responses completes two HTTP rounds with encrypted reasoning, function calls and matching tool results"
            )
            var other = endpoint
            other.options.api = .chatCompletions
            let switched = try ModelWire.body(
                endpoint: other, messages: next, tools: [tool], reasoning: false, requiredTool: nil, budget: .standard)
            try check(
                !(switched["messages"] as? [[String: Any]] ?? []).contains { $0[ModelWire.historyKey] != nil },
                "Protocol-private history never leaks into Chat Completions messages")
            var newModel = endpoint
            newModel.model = "different-model"
            try check(
                ModelWire.history(first, endpoint: newModel) == nil,
                "Provider reasoning is not replayed to a different model")
            let imageMessage: [[String: Any]] = [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Look"],
                        ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA", "detail": "low"]],
                    ],
                ]
            ]
            let responseImages = try ModelWire.responsesInput(imageMessage, endpoint: endpoint)
            try check(
                (responseImages.first?["content"] as? [[String: Any]])?.last?["type"] as? String == "input_image",
                "Responses preserves multimodal image input")
            endpoint.options = ModelOptions()
            endpoint.options.api = .messages
            endpoint.baseURL = "http://127.0.0.1:19244/api-wire/messages"
            let anthropicImages = try ModelWire.anthropicInput(imageMessage, endpoint: endpoint)
            let imageSource =
                ((anthropicImages.messages.first?["content"] as? [[String: Any]])?.last?["source"] as? [String: Any])
            try check(
                imageSource?["type"] as? String == "base64" && imageSource?["media_type"] as? String == "image/png",
                "Messages converts data URL screenshots into native image blocks")
            let anthropic = try await ModelClient.complete(
                endpoint: endpoint, key: "TEST_WIRE_KEY", messages: messages, tools: [tool])
            let toolResults: [[String: Any]] = ["tool_one", "tool_two"].map {
                ["role": "tool", "tool_call_id": $0, "content": "{\"ok\":true}"]
            }
            let finished = try await ModelClient.complete(
                endpoint: endpoint, key: "TEST_WIRE_KEY", messages: messages + [anthropic] + toolResults, tools: [tool])
            try check(
                finished["content"] as? String == "done",
                "Messages completes two HTTP rounds preserving signed thinking and grouped parallel tool results")
            endpoint.options.forceTools = false
            let automatic = try ModelWire.body(
                endpoint: endpoint, messages: messages, tools: [tool], reasoning: true,
                requiredTool: "connection_check", budget: .standard)
            try check(
                (automatic["tool_choice"] as? [String: String])?["type"] == "auto",
                "Providers without forced tool choice can use automatic selection")
            try check(
                rejects {
                    _ = try ModelWire.message(["stop_reason": "max_tokens", "content": []], endpoint: endpoint)
                }, "Incomplete tool output is rejected before execution")
            endpoint.baseURL = "http://127.0.0.1:19244/api-wire/error"
            do {
                _ = try await ModelClient.complete(
                    endpoint: endpoint, key: "TEST_WIRE_KEY", messages: messages, tools: [])
                throw AppError.message("Expected HTTP failure")
            } catch {
                try check(
                    error.localizedDescription.contains("HTTP 400")
                        && error.localizedDescription.contains("Unsupported temperature")
                        && !error.localizedDescription.contains("TEST_WIRE_KEY"),
                    "HTTP errors show actionable provider details with credentials redacted")
            }
            return checks
        }
    }
#endif
