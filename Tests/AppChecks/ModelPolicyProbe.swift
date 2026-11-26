#if DEBUG
    import Foundation

    @MainActor
    enum ModelPolicyProbe {
        static func checkReminderDelivery() async throws {
            let settings = AppSettings.load()
            let connection = settings.mainConnection
            guard connection.endpoint.isConfigured else { throw AppError.message("No configured main model.") }
            let key: String
            do { key = try await connection.loadKey() } catch { throw AppError.message("Configured model credentials unavailable.") }
            let name = "present_results"
            let schema = AgentToolRegistry.definitions.first { ($0["function"] as? [String: Any])?["name"] as? String == name }!
            let system = AgentPrompts.execution(families: ["data"], languageInstruction: settings.interfaceLanguageInstruction)
            let cases: [(title: String, request: String, value: String, trigger: String, delivery: String?)] = [
                ("预约签到", "给我一张预约卡。到了签到时间就叫我，我得回来确认。", "未到点", "已到点", "untilAcknowledged"),
                ("胶片显影槽", "给我一张显影槽卡片。每批胶片一出槽就叫我回来收片登记；设备几秒后就回到待机，我经常不在电脑前。", "待机", "出槽", "untilAcknowledged"),
                ("印刷线废料箱", "做张印刷线废料箱卡片。满箱得有人去倒，同事也会去处理；我只需要知道眼下有哪些箱子还满着。", "已清空", "已满", "whileCondition"),
                ("排版预览", "字体排版预览生成好后，顺手在桌面提示一下就行。漏看也没关系，我随时能在卡片里打开。", "生成中", "已生成", "brief"),
                ("装订机连接", "把装订机的连接状态放进卡片，短暂断线后它会自动连回来，我只想打开卡片时看。", "已连接", "断线", nil),
            ]
            for item in cases {
                let id = UUID().uuidString
                let result: [String: Any] = ["id": id, "title": item.title, "values": ["status": item.value],
                                             "possibleValues": ["status": [item.value, item.trigger]]]
                let messages: [[String: Any]] = [
                    ["role": "system", "content": system + "\nretainedResults: " + JSONText.encode([result])],
                    ["role": "user", "content": item.request]
                ]
                let response: [String: Any]
                do {
                    response = try await ModelClient.complete(endpoint: connection.endpoint, key: key, messages: messages,
                        tools: [schema], requiredTool: name, maximumWait: 50)
                } catch let error as ModelServiceFailure {
                    throw AppError.message("Model HTTP \(error.status) for " + item.title)
                } catch let error as URLError {
                    throw AppError.message("Model transport error \(error.code.rawValue) for " + item.title)
                } catch { throw AppError.message("The configured model request failed for " + item.title) }
                let raw = try StructuredResponse.arguments(response, named: name, allowJSON: false)
                guard let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw AppError.message("Expected card tool arguments.")
                }
                let args = try ToolContract.arguments(name, input)
                let rule = try CardReminderRule.decode(args["reminder"])
                try rule?.validate(available: ["status"])
                let decision = (args["reminder"] as? [String: Any])?["delivery"] as? String
                guard args["results"] as? [String] == [id], decision == item.delivery,
                    item.delivery == nil ? rule == nil : rule?.matches(item.value) == false && rule?.matches(item.trigger) == true else {
                    throw AppError.message("Unexpected reminder for " + item.title + " (" + (decision ?? "omitted") + ")")
                }
                print("PASS " + item.title + " " + (decision ?? "silent"))
            }
        }

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
