#if DEBUG
    import Foundation

    /// Real providers, ordinary sendCommand entry point, isolated task and recipe writes.
    @MainActor
    enum RequestPipelineLiveCheck {
        static func run(_ configured: AppModel) async {
            let suite = DebugHarness.pipelineSuite!
            let store = configured.preferences
            let model = configured
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            if CommandLine.arguments.contains("--force-main") { model.fastTriageRetryAfter = .distantFuture }
            let traceURL = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-pipeline-live.jsonl")
            Diagnostics.begin(traceURL.path)
            var rows: [[String: Any]] = []
            func events() -> [[String: Any]] {
                ((try? String(contentsOf: traceURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
            }
            func emit(_ row: [String: Any]) {
                try? FileHandle.standardOutput.write(contentsOf: Data((JSONText.encode(row) + "\n").utf8))
            }
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw AppError.message(message) }
            }
            func send(_ text: String, owner: UUID? = nil) {
                if let owner { model.openTaskConversation(owner) } else { model.selectChat(true) }
                model.command = text
                model.sendCommand()
            }
            func settle(_ label: String, since: Int, start: Date) async throws {
                while model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
                    guard Date().timeIntervalSince(start) < 150 else {
                        model.cancel()
                        throw AppError.message("Live request timeout")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let trace = Array(events().dropFirst(since))
                let row: [String: Any] = [
                    "case": label, "seconds": Date().timeIntervalSince(start), "failed": model.taskFailed,
                    "events": trace, "reply": model.messages.last?.text ?? "",
                ]
                rows.append(row)
                emit(["step": row])
                try check(!model.taskFailed, "Live request failed: " + (model.messages.last?.text ?? label))
                let tokens = events().reduce(0) { $0 + (($1["usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0) }
                try check(tokens < 100000, "Live test token ceiling reached")
            }
            func submit(_ text: String, owner: UUID? = nil) async throws -> [[String: Any]] {
                let index = events().count
                let start = Date()
                send(text, owner: owner)
                try await settle(text, since: index, start: start)
                return Array(events().dropFirst(index))
            }
            do {
                emit([
                    "configuration": [
                        "mainHost": model.settings.main.completionURL?.host ?? "", "model": model.settings.main.model,
                        "methodCount": model.interfaceMemory.planningCatalogue().count,
                    ]
                ])
                if CommandLine.arguments.contains("--catalogue-only") {
                    emit(["catalogue": model.interfaceMemory.planningCatalogue()])
                    store.removePersistentDomain(forName: suite)
                    exit(0)
                }
                if CommandLine.arguments.contains("--routing-context-probe") {
                    let saved = UserDefaults.standard
                    model.archivedTaskHistory =
                        saved.data(forKey: "taskHistory.v1").flatMap {
                            try? JSONDecoder().decode([SideTask].self, from: $0)
                        } ?? []
                    model.messages =
                        saved.data(forKey: "conversation.v1").flatMap {
                            try? JSONDecoder().decode([ChatMessage].self, from: $0)
                        } ?? []
                    let savedTasks =
                        saved.data(forKey: "sideTasks.v1").flatMap {
                            try? JSONDecoder().decode([SideTask].self, from: $0)
                        } ?? []
                    guard
                        let player = savedTasks.first(where: { $0.isMediaTask && ($0.intent ?? "").contains("lofi") })
                            ?? savedTasks.first(where: \.isMediaTask)
                    else { throw AppError.message("No saved player") }
                    model.sideTasks = [player]
                    for text in ["放dream funk", "放 EDM", "另外开一个独立播放器听古典音乐"] {
                        // Reproduce the observed path: capability known, task ownership unresolved.
                        model.agent.preparedRequest = PreparedRequest(
                            text: text,
                            triage: RequestTriage(capability: .music), model: model)
                        let intent = try await model.agent.understand(
                            text, clarification: nil, key: nil, globalRouting: true)
                        emit([
                            "routingCase": [
                                "request": text, "expectedExisting": player.id.uuidString,
                                "actualTarget": intent.targetTaskID as Any? ?? NSNull(),
                            ]
                        ])
                        try check(
                            text.hasPrefix("另外")
                                ? intent.targetTaskID == nil : intent.targetTaskID == player.id.uuidString,
                            "Routing chose a new or archived task instead of the current activity")
                    }
                    var weather = SideTask(kind: .web, title: "Hong Kong weather")
                    weather.intent = "查看香港天气"
                    weather.status = "Ready"
                    model.sideTasks = [weather]
                    for text in ["查上海天气", "再开一张独立天气卡查看东京"] {
                        model.agent.preparedRequest = PreparedRequest(
                            text: text,
                            triage: RequestTriage(capability: .data), model: model)
                        let intent = try await model.agent.understand(
                            text, clarification: nil, key: nil, globalRouting: true)
                        let expected: String? = text.hasPrefix("再开") ? nil : weather.id.uuidString
                        emit([
                            "routingCase": [
                                "request": text, "expectedTarget": expected as Any? ?? NSNull(),
                                "actualTarget": intent.targetTaskID as Any? ?? NSNull(),
                            ]
                        ])
                        try check(intent.targetTaskID == expected, "Weather routing did not preserve instance intent")
                    }
                    var timer = SideTask(kind: .timer, title: "Tea countdown")
                    timer.intent = "泡茶倒计时三分钟"
                    timer.deadline = Date().addingTimeInterval(180)
                    model.sideTasks = [timer]
                    let text = "另外给烤箱定时20分钟"
                    model.agent.preparedRequest = PreparedRequest(
                        text: text,
                        triage: RequestTriage(capability: .timer), model: model)
                    let intent = try await model.agent.understand(
                        text, clarification: nil, key: nil, globalRouting: true)
                    emit(["routingCase": ["request": text, "actualTarget": intent.targetTaskID as Any? ?? NSNull()]])
                    try check(intent.targetTaskID == nil && intent.isTimer, "Independent countdown was merged")
                    var archive = SideTask(kind: .web, title: "Archived Kyoto weather")
                    archive.intent = "查看京都天气"
                    model.archivedTaskHistory.insert(archive, at: 0)
                    model.sideTasks = [weather]
                    let restoreText = "恢复历史里已归档的京都天气任务，继续查看京都"
                    model.agent.preparedRequest = PreparedRequest(
                        text: restoreText, triage: RequestTriage(capability: .data), model: model)
                    let restored = try await model.agent.understand(
                        restoreText, clarification: nil, key: nil, globalRouting: true)
                    emit(["routingCase": ["request": restoreText, "expectedTarget": archive.id.uuidString,
                        "actualTarget": restored.targetTaskID as Any? ?? NSNull()]])
                    try check(restored.targetTaskID == archive.id.uuidString, "Explicit archive restoration was lost")
                } else if CommandLine.arguments.contains("--routing-multiple") {
                    var older = SideTask(kind: .web, title: "Earlier player")
                    older.listening = true
                    older.intent = "放phonk"
                    var current = SideTask(kind: .web, title: "Current player")
                    current.listening = true
                    current.playing = true
                    current.intent = "听lofi"
                    model.sideTasks = [older, current]
                    model.selectedTaskID = older.id
                    let continued = try await model.agent.understand(
                        "jazz hiphop", clarification: nil, key: nil, globalRouting: true)
                    try check(
                        continued.targetTaskID == current.id.uuidString && continued.clarificationQuestion == nil,
                        "Real routing did not continue the current matching activity")
                    emit(["routing": ["case": "changed content with two existing instances", "ok": true]])
                    let additional = try await model.agent.understand(
                        "另外开一个独立播放器听古典音乐", clarification: nil, key: nil, globalRouting: true)
                    try check(
                        additional.targetTaskID == nil && additional.clarificationQuestion == nil,
                        "Real routing merged an explicitly additional instance")
                    emit(["routing": ["case": "explicit additional instance", "ok": true]])
                } else if CommandLine.arguments.contains("--continuity-only")
                    || CommandLine.arguments.contains("--continuity-multiple")
                {
                    _ = try await submit("放phonk")
                    guard let first = model.sideTasks.first(where: \.isMediaTask) else {
                        throw AppError.message("Missing initial player")
                    }
                    for command
                        in (CommandLine.arguments.contains("--continuity-multiple") ? [] : ["切换成lofi", "jazz hiphop"])
                    {
                        _ = try await submit(command)
                        let players = model.sideTasks.filter(\.isMediaTask)
                        try check(
                            players.count == 1 && players[0].id == first.id, "Changed content created another task")
                    }
                    _ = try await submit("另外开一个独立播放器听古典音乐")
                    let separate = model.sideTasks.filter(\.isMediaTask)
                    try check(separate.count == 2, "Explicit additional instance was merged")
                    let active = model.playbackCoordinator.owner
                    _ = try await submit("jazz hiphop")
                    try check(
                        model.agent.replyKind != .needsInput,
                        "A matching active activity unnecessarily asked for an instance choice")
                    try check(
                        model.sideTasks.filter(\.isMediaTask).count == 2 && model.playbackCoordinator.owner == active,
                        "Ambiguous matching instances created a third player or replaced the wrong owner")
                    var audible = 0
                    for browser in model.liveBrowsers {
                        if try await browser.observe()["playing"] as? Bool == true { audible += 1 }
                    }
                    try check(audible == 1, "Content switching left overlapping players")
                } else if CommandLine.arguments.contains("--weather-clarification") {
                    let requestedAt = Date()
                    _ = try await submit("后天天气咋样")
                    if CommandLine.arguments.contains("--empty-catalogue") {
                        try check(model.agent.replyKind == .needsInput, "Missing city was not clarified")
                    }
                    let owner = model.messages.last?.taskID
                    try check(owner != nil, "Initial request did not retain its conversation")
                    _ = try await submit("香港", owner: owner)
                    guard let forecast = model.sideTasks.first(where: { $0.taskSurface?.apiData != nil }) else {
                        throw AppError.message("Missing verified forecast card after clarification")
                    }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    let expected = formatter.string(
                        from: Calendar.current.date(byAdding: .day, value: 2, to: requestedAt)!)
                    try check(
                        forecast.id == owner
                            && forecast.taskSurface?.apiData?.fields.contains(where: {
                                forecast.state[$0.key] == expected
                            }) == true,
                        "Clarification lost the original date or task owner")
                    try check(
                        model.sideTasks.filter { $0.taskSurface?.apiData != nil }.count == 1,
                        "Clarification created duplicate data cards")
                    emit(["forecast": forecast.state])
                } else if !CommandLine.arguments.contains("--music-only")
                    && !CommandLine.arguments.contains("--controls-only")
                {
                    let first = try await submit("100美元对多少rmb")
                    try check(
                        !first.contains { ($0["name"] as? String) == "navigate" }, "Structured data opened a browser")
                    guard let original = model.sideTasks.first(where: { $0.taskSurface?.apiData != nil }),
                        let spec = original.taskSurface?.apiData
                    else {
                        throw AppError.message("Missing verified data card")
                    }
                    let signature = SavedMethod.signature(original.taskSurface)
                    try check(spec.inputs?.values.contains("100") == true, "Requested amount was lost")
                    let next = try await submit("换算金额改成200美元，仍然换人民币")
                    try check(
                        model.sideTasks.filter { $0.taskSurface?.apiData != nil }.count == 1,
                        "Follow-up duplicated its data card")
                    let updated = model.sideTasks.first { $0.id == original.id }
                    try check(
                        updated?.taskSurface?.apiData?.inputs?.values.contains("200") == true,
                        "Fresh inputs were not applied")
                    try check(
                        SavedMethod.signature(updated?.taskSurface) == signature,
                        "Input change rebuilt the saved method")
                    try check(
                        !next.contains {
                            ["compose_ui", "present_ui", "run_code", "navigate"].contains($0["name"] as? String ?? "")
                        }, "Reuse rebuilt or navigated")
                    if !CommandLine.arguments.contains("--data-only") {
                        let start = Date()
                        let index = events().count
                        send("做一个长方形面积计算器，长12宽7，两个输入都能修改")
                        try await Task.sleep(for: .milliseconds(300))
                        send("把长改成18，宽保持7")
                        send("这个计算器还要显示周长")
                        try await settle("Three overlapping calculator inputs", since: index, start: start)
                        let calculators = model.sideTasks.filter {
                            $0.kind == .workspace && $0.taskSurface?.apiData == nil
                        }
                        try check(calculators.count == 1, "Overlapping requests created duplicate calculators")
                        func containsNumber(_ expected: Double) -> Bool {
                            calculators[0].state.values.contains { value in
                                Double(value).map { abs($0 - expected) < 0.01 } ?? false
                            }
                        }
                        try check(
                            containsNumber(126) && containsNumber(50),
                            "Merged request lost dimensions or the added perimeter requirement")
                    }
                }
                if CommandLine.arguments.contains("--everyday") {
                    _ = try await submit("倒计时5分钟")
                    guard let timer = model.sideTasks.first(where: { $0.kind == .timer }), timer.deadline != nil else {
                        throw AppError.message("Countdown did not start")
                    }
                    _ = try await submit("暂停计时", owner: timer.id)
                    try check(model.sideTasks.first { $0.id == timer.id }?.deadline == nil, "Countdown did not pause")
                    _ = try await submit("给我东京和伦敦的时钟")
                    guard let clock = model.sideTasks.first(where: { $0.taskSurface?.preset == "clock" }),
                        let sources = clock.taskSurface?.runtime?.sources
                    else {
                        throw AppError.message("Missing host clock")
                    }
                    try check(
                        sources.contains { $0.timeZone == "Asia/Tokyo" }
                            && sources.contains { $0.timeZone == "Europe/London" },
                        "Clock omitted a requested time zone")
                }
                if CommandLine.arguments.contains("--with-music") || CommandLine.arguments.contains("--music-only") {
                    let start = Date()
                    let index = events().count
                    let natural = CommandLine.arguments.contains("--natural-request")
                    send(natural ? "想听lofi" : "放一些轻音乐")
                    if !natural {
                        try await Task.sleep(for: .milliseconds(300))
                        send("换成适合看书的lofi")
                    }
                    try await settle(
                        natural ? "想听lofi" : "Replace while playback request is running", since: index, start: start)
                    let media = model.sideTasks.filter(\.isMediaTask)
                    try check(media.count == 1, "Concurrent replacement created multiple media owners")
                    var playing = 0
                    for browser in model.liveBrowsers {
                        if try await browser.observe()["playing"] as? Bool == true { playing += 1 }
                    }
                    try check(playing == 1, "Expected exactly one playing source")
                    if natural {
                        let owner = media[0].id
                        let changed = try await submit("想听爵士")
                        try check(
                            changed.contains {
                                $0["event"] as? String == "tool" && $0["name"] as? String == "find_music"
                            }, "Natural follow-up did not search for the requested music")
                        try check(
                            model.sideTasks.filter(\.isMediaTask).map(\.id) == [owner],
                            "Changing the requested style duplicated the player")
                        _ = try await submit("另外开一个独立播放器听lofi")
                        let players = model.sideTasks.filter(\.isMediaTask)
                        try check(players.count == 2, "Explicitly additional player was not kept independently")
                        playing = 0
                        for browser in model.liveBrowsers {
                            if try await browser.observe()["playing"] as? Bool == true { playing += 1 }
                        }
                        try check(
                            playing == 1 && model.playbackCoordinator.owner != owner,
                            "Separate player did not take exclusive audio ownership")
                        try await model.performMusicControl(owner, operation: "play")
                        playing = 0
                        for browser in model.liveBrowsers {
                            if try await browser.observe()["playing"] as? Bool == true { playing += 1 }
                        }
                        try check(
                            playing == 1 && model.playbackCoordinator.owner == owner,
                            "Resuming the previous player left overlapping audio")
                    }
                    if CommandLine.arguments.contains("--execution-replace") {
                        let owner = media[0].id
                        let replaceIndex = events().count
                        let replaceStart = Date()
                        send("换成轻爵士音乐")
                        func replacementStarted() -> Bool {
                            events().dropFirst(replaceIndex).contains {
                                $0["event"] as? String == "tool" && $0["name"] as? String == "find_music"
                            }
                        }
                        while !replacementStarted() {
                            guard Date().timeIntervalSince(replaceStart) < 90 else {
                                throw AppError.message("Replacement did not enter source execution")
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        send("还是换成适合看书的lofi")
                        try await settle("Replace during source execution", since: replaceIndex, start: replaceStart)
                        let retained = model.sideTasks.filter(\.isMediaTask)
                        try check(
                            retained.count == 1 && retained[0].id == owner, "Executing replacement lost its media owner"
                        )
                        playing = 0
                        for browser in model.liveBrowsers {
                            if try await browser.observe()["playing"] as? Bool == true { playing += 1 }
                        }
                        try check(playing == 1, "Executing replacement left duplicate or stopped playback")
                    }
                }
                emit(["report": ["ok": true, "cases": rows.count]])
                for browser in model.liveBrowsers { browser.dispose() }
                store.removePersistentDomain(forName: suite)
                exit(0)
            } catch {
                emit(["failureTrace": events()])
                emit(["report": ["ok": false, "error": error.localizedDescription, "cases": rows.count]])
                model.cancel()
                for browser in model.liveBrowsers { browser.dispose() }
                store.removePersistentDomain(forName: suite)
                exit(1)
            }
        }
    }
#endif
