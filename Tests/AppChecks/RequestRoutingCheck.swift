#if DEBUG
    import Foundation

    @MainActor
    enum RequestRoutingCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message(label) }
                checks.append(label)
            }
            let notice =
                "Date:\u{00a0} 18 February 2027 (Thursday)\nTime: 10:00 AM – 11:00 AM\nVenue: [Example Room](https://example.com/room), Example Library & Online"
            // No source-text classifier: interpretation is supplied by the model.
            let interpretation = RequestIntent(kind: .calendar, missingFields: ["title"])
            try check(
                !interpretation.allows("timer_start") && !interpretation.allows("navigate"),
                "An AI calendar interpretation grants only its relevant native capability")
            try check(
                !RequestIntent(kind: .information).allows("calendar_create")
                    && !RequestIntent(kind: .information).allows("timer_start"),
                "An AI read-only interpretation does not grant native side effects")
            try check(
                RequestIntent(kind: .timer).allows("timer_start")
                    && !RequestIntent(kind: .timer).allows("calendar_create"),
                "An AI countdown interpretation has its own native capability")
            try check(
                AppModel.timerSeconds(notice) == nil,
                "The optional exact-command timer shortcut does not consume an event notice")
            let wire: [String: Any] = [
                "tool_calls": [
                    [
                        "function": [
                            "name": "interpret_request",
                            "arguments":
                                "{\"kind\":\"calendar\",\"missingFields\":[\"title\"],\"continuesClarification\":false}",
                        ]
                    ]
                ]
            ]
            try check(
                try RequestIntent.decode(wire).needsEventTitle,
                "Structured AI interpretation is decoded and validated before execution")
            var malformedRejected = false
            do { _ = try RequestIntent.decode(["content": "This looks like a timer"]) } catch {
                malformedRejected = true
            }
            try check(malformedRejected, "Unstructured or invalid model interpretations never authorize an action")

            let schema = ToolSchema.function(
                "interpret_request", "Interpret",
                [
                    "kind": ["type": "string"], "answer": ["type": "string"],
                    "playbackIntent": ["type": "string"], "timerSeconds": ["type": "number"],
                    "timerEvidence": ["type": "string"],
                ], required: ["kind"])
            var jsonCalls = 0
            let jsonIntent = try await RequestIntent.interpret("Explain photosynthesis", messages: [], schema: schema) {
                _, _, _ in
                jsonCalls += 1
                return ["content": "{\"kind\":\"information\",\"answer\":\"Plants use light to make sugars.\"}"]
            }
            try check(
                jsonCalls == 1 && jsonIntent.kind == .information,
                "A valid JSON response uses the same semantic validation without a format-only retry")
            var transportAttempts = 0
            let afterDisconnect = try await RequestIntent.interpret("Explain a concept", messages: [], schema: schema) {
                _, tools, required in
                transportAttempts += 1
                if transportAttempts == 1 { throw URLError(.timedOut) }
                try check(
                    tools.isEmpty && required == nil,
                    "Transient interpretation failure switches to the same bounded JSON recovery")
                return ["content": "{\"kind\":\"information\",\"answer\":\"Recovered answer\"}"]
            }
            try check(
                transportAttempts == 2 && afterDisconnect.answer == "Recovered answer",
                "One interrupted interpretation recovers without executing or repeating a tool")
            for failure in [URLError(.timedOut), URLError(.cancelled), URLError(.userAuthenticationRequired)] {
                var count = 0
                do {
                    _ = try await RequestIntent.interpret("Explain a concept", messages: [], schema: schema) {
                        _, _, _ in
                        count += 1
                        throw failure
                    }
                    throw AppError.message("Transport failure unexpectedly succeeded")
                } catch is URLError {}
                try check(
                    count == (failure.code == .timedOut ? 2 : 1),
                    "Interpretation recovery is bounded and does not retry cancellation or credentials")
            }
            var attempts = 0
            let recovered = try await RequestIntent.interpret("播放 dream funk", messages: [], schema: schema) {
                turns, tools, required in
                attempts += 1
                if attempts == 1 {
                    try check(
                        required == "interpret_request" && tools.count == 1,
                        "Interpretation first requests its required tool")
                    return ["content": "I will play that for you."]
                }
                try check(
                    required == nil && tools.isEmpty && turns.last?["role"] as? String == "system",
                    "Malformed tool responses recover using a separate JSON response mode")
                return ["tool_calls": [], "content": "{\"kind\":\"general\",\"playbackIntent\":\"play\"}"]
            }
            try check(
                attempts == 2 && recovered.playbackIntent == "play",
                "A missing tool call recovers the music request without asking the user to repeat it")
            for content in [
                "Sure, playing now", "{\"kind\":\"timer\",\"timerSeconds\":60,\"timerEvidence\":\"one minute\"}",
            ] {
                var rejected = false
                var count = 0
                do {
                    _ = try await RequestIntent.interpret("播放 dream funk", messages: [], schema: schema) { _, _, _ in
                        count += 1
                        return ["content": content]
                    }
                } catch { rejected = true }
                try check(
                    rejected && count == 2,
                    "Recovery is bounded and rejects prose or invented countdown authorization: \(content.prefix(12))")
            }
            var conflictingRejected = false
            do {
                _ = try RequestIntent.decode(
                    [
                        "tool_calls": [["function": ["name": "timer_start", "arguments": "{}"]]],
                        "content": "{\"kind\":\"general\"}",
                    ], allowJSON: true)
            } catch { conflictingRejected = true }
            try check(conflictingRejected, "JSON recovery cannot conceal an unexpected tool call")

            let suite = "orvlet-routing-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings = AppSettings()
            defer {
                model.taskClock?.invalidate()
                model.dismissFeedback()
            }
            func tool(_ name: String, _ args: [String: Any]) -> [String: Any] {
                [
                    "id": UUID().uuidString, "type": "function",
                    "function": ["name": name, "arguments": JSONText.encode(args)],
                ]
            }
            func response(_ tools: [[String: Any]]) -> [String: Any] { ["role": "assistant", "tool_calls": tools] }
            var interpretations = 0
            model.agent.interpretationOverride = { text in
                interpretations += 1
                guard text == notice else { throw AppError.message("Lost original user text") }
                return interpretation
            }
            var calls = 0
            model.agent.completionOverride = { _ in
                calls += 1
                throw AppError.message("Unexpected model call")
            }
            let question = try await model.agent.run(notice)
            try check(
                calls == 0 && interpretations == 1 && question.contains("What would you like to call the event?")
                    && model.agent.replyKind == .needsInput
                    && model.sideTasks.contains(where: { $0.status == "Waiting for reply" }),
                "A bare notice reaches AI understanding, then asks for a title without an execution-model round or native write"
            )

            model.agent.interpretationOverride = { _ in RequestIntent(kind: .calendar, continuesClarification: true) }
            model.agent.completionOverride = { turns in
                calls += 1
                let context = turns.compactMap { $0["content"] as? String }.joined(separator: "\n")
                guard context.contains("Example Library") && context.contains("Example event") else {
                    throw AppError.message("Lost notice context")
                }
                if calls == 1 {
                    return response([
                        tool("timer_start", ["seconds": 3600, "title": "Wrong timer"]),
                        tool("navigate", ["url": "https://example.com/room"]),
                    ])
                }
                return response([tool("calendar_clarify", ["fields": ["timeZone"]])])
            }
            guard let clarificationID = model.sideTasks.last?.id else {
                throw AppError.message("Missing saved clarification task")
            }
            _ = model.restoreHistoryTask(clarificationID, showCard: false)
            _ = try await model.agent.run("Example event", taskID: clarificationID)
            try check(
                calls == 2 && model.sideTasks.allSatisfy { $0.kind == .result } && model.webURL.isEmpty,
                "Executor rejects a model-selected timer and navigation for a Calendar notice, and retains its own task's clarification context"
            )

            // A separate request revokes the previous native capability, even with history.
            calls = 0
            model.agent.completionOverride = { turns in
                guard !JSONText.encode(turns).contains("Example Library") else {
                    throw AppError.message("Another task leaked calendar clarification context")
                }
                calls += 1
                if calls == 1 {
                    return response([
                        tool("calendar_create", ["title": "Unauthorized"]),
                        tool("timer_start", ["seconds": 60, "title": "Unauthorized"]),
                    ])
                }
                return ["role": "assistant", "content": "An ordinary answer"]
            }
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .information) }
            let answer = try await model.agent.run("Tell me a joke")
            try check(
                answer == "An ordinary answer" && model.sideTasks.allSatisfy { $0.kind == .result },
                "Old Calendar conversation cannot authorize native actions for a new request")
            model.closeTask(clarificationID)

            calls = 0
            model.agent.completionOverride = { _ in
                calls += 1
                var bridgeRejected = false
                do {
                    _ = try await model.bridge.route("/rpc", ["tool": "timer_start", "arguments": ["seconds": 60]])
                } catch { bridgeRejected = true }
                try check(bridgeRejected, "The bridge cannot borrow an active human request to start native tasks")
                return response([
                    tool("timer_start", ["seconds": 600, "title": "Example timer"]),
                    tool("timer_start", ["seconds": 600, "title": "Duplicate timer"]),
                    tool("finish", ["outcome": "answer", "reply": "Overwritten"]),
                ])
            }
            model.agent.interpretationOverride = { _ in
                RequestIntent(kind: .timer, goals: ["Start the requested timer"])
            }
            let received = Date().addingTimeInterval(-90)
            let timerReply = try await model.agent.run("Start a timer for ten minutes", receivedAt: received)
            try check(
                timerReply.hasPrefix("Timer running") && model.sideTasks.filter({ $0.kind == .timer }).count == 1
                    && abs(
                        model.sideTasks.first(where: { $0.kind == .timer })!.deadline!.timeIntervalSince(received) - 600
                    ) < 0.01, "Timer receipt is terminal, starts at submission and rejects duplicate trailing calls")
            var rejected = false
            do { _ = try await model.agent.execute("timer_start", ["seconds": 60]) } catch { rejected = true }
            try check(
                rejected && model.sideTasks.filter({ $0.kind == .timer }).count == 1,
                "Completed native authorization cannot be reused by a bridge or later tool call")

            model.sideTasks.removeAll()
            model.collapsed = true
            var shows = 0
            var focusRequests = 0
            model.onShow = { shows += 1 }
            model.onCommandPanel = { _, _ in focusRequests += 1 }
            model.deliverReply(question, kind: .needsInput)
            try check(
                model.feedback?.text == question && model.feedback?.kind == .needsInput && model.shellContentSize != nil
                    && shows == 1 && focusRequests == 0 && model.collapsed && !model.commandPanelVisible,
                "Clarification is readable outside chat in the same compact shell without taking focus")
            try check(model.stackOpacity == 1 && model.hasUnreadReply, "Unread feedback wakes the dimmed stack")
            model.deliverReply("Simulated permission failure", kind: .failure)
            try check(
                model.feedback?.kind == .failure && model.messages.count == 2,
                "A new result replaces the visible receipt while retaining both messages")
            model.dismissFeedback()
            try check(
                model.feedback == nil && model.shellContentSize == nil && model.hasUnreadReply,
                "Dismissing feedback restores compact dimensions and preserves unread history")
            let conversation = model.messages.last!.taskID!
            model.openTaskConversation(conversation)
            model.deliverReply("Already visible", kind: .success, taskID: conversation)
            try check(
                model.feedback == nil && !model.hasUnreadReply,
                "A reply in its own open conversation does not receive a duplicate notification")
            return checks
        }

        static func live(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            Diagnostics.begin("/tmp/orvlet-intent-live.jsonl")
            do {
                let key = try await model.loadModelKey()
                model.messages = []
                model.archivedTaskHistory = []
                model.sideTasks = []
                if CommandLine.arguments.contains("--ownership-only") {
                    Diagnostics.benchmarkEvents = []
                    func report(_ row: [String: Any]) {
                        FileHandle.standardOutput.write(Data((JSONText.encode(row) + "\n").utf8))
                    }
                    var currency = SideTask(kind: .workspace, title: "Currency converter")
                    currency.intent = "100港币兑rmb"
                    currency.taskSurface =
                        BundledMethods.recipes.first { $0.surface?.apiData?.card?.kind == .currency }?.surface
                    var music = SideTask(kind: .web, title: "Nocturne")
                    music.listening = true
                    music.playing = true
                    music.intent = "播放夜曲"
                    model.sideTasks = [currency, music]
                    var weather = SideTask(kind: .workspace, title: "Hong Kong weather")
                    weather.intent = "明天香港天气"
                    let cases: [(String, UUID?)] = [
                        ("明天香港天气", nil), ("香港现在几点", nil),
                        ("放晴天", music.id), ("我想听 lofi", music.id),
                        ("200港币兑rmb", currency.id),
                        ("看看后天北京天气", weather.id),
                    ]
                    for (index, item) in cases.enumerated() {
                        if index == cases.count - 1 { model.sideTasks.append(weather) }
                        let prepared = await model.prepareFastRequest(item.0, explicit: nil)
                        model.agent.preparedRequest = prepared
                        let intent = try await model.agent.understand(
                            item.0, clarification: nil, key: key, globalRouting: true)
                        let correct = intent.targetTaskID.flatMap(UUID.init(uuidString:)) == item.1
                        Diagnostics.record(
                            "ownership_probe",
                            ["request": item.0, "correct": correct, "target": intent.targetTaskID ?? "new"])
                        report([
                            "request": item.0, "correct": correct, "actual": intent.targetTaskID ?? "new",
                            "expected": item.1?.uuidString ?? "new",
                            "capability": prepared.triage?.capability.rawValue ?? "general",
                        ])
                        guard correct else { throw AppError.message("Wrong activity owner: " + item.0) }
                    }
                    model.agent.preparedRequest = PreparedRequest(
                        text: "明天香港天气", triage: RequestTriage(capability: .data, target: currency.id, routeKnown: true),
                        model: model)
                    let corrected = try await model.agent.understand(
                        "明天香港天气", clarification: nil, key: key, globalRouting: true)
                    guard corrected.targetTaskID == weather.id.uuidString else {
                        throw AppError.message("Main model could not correct a wrong Jev target")
                    }
                    report(["request": "Incorrect Jev owner can be corrected", "correct": true])
                    // These functions never appear in the ownership prompt.
                    // Same material can support distinct operations and outcomes.
                    var resize = SideTask(kind: .workspace, title: "Image resizing")
                    resize.intent = "按指定像素尺寸调整用户提供的图片，输出缩放后的图片"
                    var palette = SideTask(kind: .workspace, title: "Image palette")
                    palette.intent = "提取用户提供图片的主要颜色，输出颜色列表"
                    model.sideTasks = [resize, palette]
                    let unseen: [(String, UUID?)] = [
                        ("把另一张图片 landscape.png 缩放到 800×600。", resize.id),
                        ("识别 landscape.png 中的文字并输出文本。", nil),
                        ("提取 portrait.png 的五个主要颜色。", palette.id),
                        ("另建一个独立的图片缩放任务，将 portrait.png 缩放到 400×400，保留原来的缩放任务。", nil),
                    ]
                    for item in unseen {
                        let intent = try await model.agent.understand(
                            item.0, clarification: nil, key: key, globalRouting: true)
                        let correct = intent.targetTaskID.flatMap(UUID.init(uuidString:)) == item.1
                        report(["request": item.0, "correct": correct, "unseenFunction": true])
                        guard correct else { throw AppError.message("Wrong owner for unseen function: " + item.0) }
                    }
                    let api = (Diagnostics.benchmarkEvents ?? []).filter { $0["event"] as? String == "api" }
                    let tokens = api.reduce(0) { $0 + (($1["usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0) }
                    report([
                        "ok": true, "requests": cases.count + unseen.count + 1, "mainCalls": api.count,
                        "totalTokens": tokens,
                    ])
                    exit(0)
                }
                let probe = ToolSchema.function(
                    "connection_check", "Confirm availability", ["ok": ["type": "boolean"]], required: ["ok"])
                let response = try await ModelClient.complete(
                    endpoint: model.settings.main, key: key,
                    messages: [["role": "user", "content": "Call connection_check with ok=true."]], tools: [probe],
                    reasoning: false, requiredTool: "connection_check", timeout: 12)
                let raw = try StructuredResponse.arguments(response, named: "connection_check")
                guard (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["ok"] as? Bool == true
                else { throw AppError.message("Connection probe failed") }
                var calendar = SideTask(kind: .result, title: "Team meeting")
                calendar.status = "Waiting for reply"
                var music = SideTask(kind: .web, title: "Dream Funk")
                music.listening = true
                music.playing = true
                model.sideTasks = [calendar, music]
                model.appendMessage("Add a team meeting to my calendar", isUser: true, taskID: calendar.id)
                model.appendMessage("When should the meeting start?", isUser: false, taskID: calendar.id)
                model.appendMessage("Play Dream Funk", isUser: true, taskID: music.id)
                model.appendMessage("Playing Dream Funk.", isUser: false, taskID: music.id)
                let cases: [(String, RequestIntent.TaskAction, UUID?)] = [
                    ("oh, the team meeting is cancelled", .cancel, calendar.id),
                    ("那个会议不加了", .cancel, calendar.id),
                    ("明天下午三点到四点，会议时间", .perform, calendar.id),
                    ("暂停刚才的音乐", .perform, music.id),
                    ("新开一个计算器", .perform, nil),
                    ("我想听 lofi 了", .perform, music.id),
                    ("Play some jazz instead", .perform, music.id),
                    ("另外开一个 lofi 播放器，保留 Dream Funk", .perform, nil),
                ]
                for (prompt, action, target) in cases {
                    let intent = try await model.agent.understand(
                        prompt, clarification: nil, key: key, globalRouting: true)
                    guard intent.taskAction == action, intent.targetTaskID.flatMap(UUID.init(uuidString:)) == target
                    else { throw AppError.message("Incorrect lifecycle or conversation routing") }
                }
                let looping = try await model.agent.understand(
                    "DREAM FUNK 能不能单曲循环", clarification: nil, key: key, globalRouting: true)
                guard looping.mediaSetting == "loop", looping.playbackIntent != "play",
                    looping.targetTaskID == music.id.uuidString
                else { throw AppError.message("Repeat must be interpreted as a setting, not restarting playback") }
                var weather = SideTask(kind: .web, title: "Hong Kong weather")
                weather.intent = "Check Hong Kong weather"
                model.sideTasks.append(weather)
                model.appendMessage("看看香港天气", isUser: true, taskID: weather.id)
                model.appendMessage("香港天气已打开。", isUser: false, taskID: weather.id)
                for (prompt, target) in [("我现在想看北京天气", Optional(weather.id)), ("再开一个北京天气，和香港并排看", nil)] {
                    let intent = try await model.agent.understand(
                        prompt, clarification: nil, key: key, globalRouting: true)
                    guard intent.targetTaskID.flatMap(UUID.init(uuidString:)) == target, !intent.presentationOnly,
                        intent.requiresFreshData
                    else {
                        throw AppError.message(
                            "Weather content replacement vs independent comparison routed incorrectly")
                    }
                }
                var secondMusic = SideTask(kind: .web, title: "Saved jazz")
                secondMusic.listening = true
                model.sideTasks.append(secondMusic)
                let recentMusic = try await model.agent.understand(
                    "我想听古典音乐了", clarification: nil, key: key, globalRouting: true)
                guard recentMusic.targetTaskID == music.id.uuidString else {
                    throw AppError.message("Currently playing task must disambiguate a content replacement")
                }
                Diagnostics.record("complete", ["ok": true, "requests": 13])
                exit(0)
            } catch {
                Diagnostics.record("failed", ["reason": error.localizedDescription])
                if CommandLine.arguments.contains("--ownership-only") {
                    print(JSONText.encode(["ok": false, "error": error.localizedDescription]))
                }
                exit(1)
            }
        }
    }
#endif
