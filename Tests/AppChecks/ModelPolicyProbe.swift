#if DEBUG
    import Foundation

    @MainActor
    enum ModelPolicyProbe {
        static func run(_ model: AppModel) async {
            do {
                let useActive = CommandLine.arguments.contains("--active-profile")
                let profile = model.settings.profiles.first {
                    useActive ? $0.id == model.settings.activeProfileID : $0.name.lowercased() == "siliconflow"
                }
                guard let profile else { throw AppError.message("The selected saved profile is missing.") }
                let endpoint = useActive ? model.settings.main : profile.endpoint
                let messages: [[String: Any]] = [
                    ["role": "system", "content": "Select the requested music category. Only call select_category."],
                    ["role": "user", "content": "Switch from lofi to EDM."],
                ]
                let schemas = [
                    ToolSchema.function(
                        "select_category", "Select a category.",
                        ["category": ["type": "string", "enum": ["lofi", "EDM"]]], required: ["category"])
                ]
                func policy(_ endpoint: Endpoint) throws -> [String: Any] {
                    let body = try ModelWire.body(
                        endpoint: endpoint, messages: messages, tools: schemas,
                        reasoning: false, requiredTool: "select_category", budget: .low)
                    return body.filter {
                        ["enable_thinking", "thinking", "reasoning", "reasoning_effort", "tool_choice"].contains($0.key)
                    }
                }
                print(
                    JSONText.encode([
                        "configuration": [
                            "host": endpoint.completionURL?.host ?? "",
                            "model": endpoint.model, "api": endpoint.options.api.rawValue,
                            "reasoningOption": endpoint.options.reasoning.rawValue,
                            "effectivePolicy": try policy(endpoint),
                        ]
                    ]))
                if CommandLine.arguments.contains("--configuration-only") { exit(0) }
                Diagnostics.begin("/tmp/orvlet-model-policy-probe.jsonl")
                let key = try await ModelConnection(endpoint: endpoint, keyAccount: profile.keyAccount).loadKey()
                let probes =
                    endpoint.completionURL?.host == "api.x.ai" ? ["none", "low"] : ["current", "explicit_off"]
                for probe in probes {
                    var candidate = endpoint
                    if probe != "current" {
                        var parameters = try candidate.options.object(
                            candidate.options.parameters, label: "Request parameters")
                        if candidate.options.api == .responses {
                            parameters["reasoning"] = ["effort": probe == "low" ? "low" : "none"]
                        } else if candidate.completionURL?.host == "api.x.ai" {
                            parameters["reasoning_effort"] = probe
                        } else if candidate.completionURL?.host?.contains("siliconflow") == true {
                            parameters["enable_thinking"] = false
                        } else {
                            parameters["thinking"] = ["type": "disabled"]
                            parameters["reasoning_effort"] = NSNull()
                        }
                        candidate.options.parameters = JSONText.encode(parameters)
                    }
                    let start = Date()
                    do {
                        let response = try await ModelClient.complete(
                            endpoint: candidate, key: key, messages: messages,
                            tools: schemas, reasoning: false, requiredTool: "select_category", budget: .low)
                        print(
                            JSONText.encode([
                                "probe": probe,
                                "seconds": Date().timeIntervalSince(start), "effectivePolicy": try policy(candidate),
                                "reasoningCharacters": (response["reasoning_content"] as? String ?? "").count,
                                "toolCalls": (response["tool_calls"] as? [Any] ?? []).count,
                            ]))
                    } catch {
                        print(
                            JSONText.encode([
                                "probe": probe, "seconds": Date().timeIntervalSince(start),
                                "error": error.localizedDescription,
                            ]))
                    }
                }
                exit(0)
            } catch {
                print(JSONText.encode(["error": error.localizedDescription]))
                exit(1)
            }
        }
    }
#endif
