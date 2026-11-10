#if DEBUG
    import Foundation

    @MainActor
    enum UnifiedRequestLiveCheck {
        static func run(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.sideTasks = []
            model.archivedTaskHistory = []
            model.messages = []
            Diagnostics.file = URL(fileURLWithPath: MusicCheck.artifact("orvlet-unified-live.jsonl"))
            FileManager.default.createFile(atPath: Diagnostics.file!.path, contents: nil)
            Diagnostics.started = Date()
            if CommandLine.arguments.contains("--configuration-only") {
                print(
                    JSONText.encode([
                        "mainHost": model.settings.main.completionURL?.host ?? "",
                        "mainModel": model.settings.main.model,
                        "jevHost": model.settings.fast.completionURL?.host ?? "", "jevModel": model.settings.fast.model,
                    ]))
                exit(0)
            }
            var results: [[String: Any]] = []
            func events() -> [[String: Any]] {
                ((try? String(contentsOf: Diagnostics.file!, encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            }
            func emit(_ object: [String: Any]) {
                FileHandle.standardOutput.write(Data((JSONText.encode(object) + "\n").utf8))
            }
            func submit(_ text: String, owner: UUID? = nil) async throws {
                let previous = events().count
                let start = Date()
                if let owner { model.openTaskConversation(owner) } else { model.selectChat(true) }
                model.command = text
                model.sendCommand()
                while model.busy && Date().timeIntervalSince(start) < 100 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if model.busy {
                    model.cancel()
                    throw AppError.message("Request timed out")
                }
                let trace = Array(events().dropFirst(previous))
                let api = trace.filter { $0["event"] as? String == "api" }
                let tokens = api.reduce(0) { $0 + (($1["usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0) }
                let row: [String: Any] = [
                    "request": text, "seconds": Date().timeIntervalSince(start),
                    "mainCalls": api.count, "tokens": tokens, "failed": model.taskFailed,
                    "reply": model.messages.last?.text ?? "",
                    "events": trace.filter {
                        [
                            "api", "request_triage", "decision_context", "tool", "intent_validated", "intent_invalid",
                            "tool_error",
                        ]
                        .contains(
                            $0["event"] as? String ?? "")
                    },
                ]
                results.append(row)
                emit(["unifiedStep": row])
                guard !model.taskFailed else { throw AppError.message(model.messages.last?.text ?? "Request failed") }
                guard tokens < 30000 else {
                    throw AppError.message("Stopped the live suite after exceeding its per-request token allowance")
                }
            }
            do {
                let musicOnly = CommandLine.arguments.contains("--music-only")
                let coreOnly = CommandLine.arguments.contains("--core-only")
                if !musicOnly {
                    try await submit("帮我倒数 75 秒")
                    guard let timer = model.sideTasks.first(where: { $0.kind == .timer }), timer.deadline != nil else {
                        throw AppError.message("Countdown did not start")
                    }
                    try await submit("先暂停一下计时", owner: timer.id)
                    guard model.sideTasks.first(where: { $0.id == timer.id })?.deadline == nil else {
                        throw AppError.message("Countdown did not pause")
                    }
                    if CommandLine.arguments.contains("--timer-only") {
                        emit(["unifiedReport": ["ok": true, "results": results]])
                        exit(0)
                    }
                    let messages = model.messages.filter { $0.taskID == timer.id }.count
                    model.closeTask(timer.id)
                    guard !model.sideTasks.contains(where: { $0.id == timer.id }),
                        model.archivedTaskHistory.contains(where: { $0.id == timer.id }),
                        model.messages.filter({ $0.taskID == timer.id }).count == messages
                    else {
                        throw AppError.message("Removing a task lost its history")
                    }
                    try await submit("继续刚才的倒数，别重新开始", owner: timer.id)
                    guard model.sideTasks.first(where: { $0.id == timer.id })?.deadline != nil,
                        model.sideTasks.filter({ $0.kind == .timer }).count == 1
                    else {
                        throw AppError.message("History did not resume the same countdown")
                    }
                    try await submit("先别创建新任务。用一句话解释什么是光合作用")
                    guard model.sideTasks.filter({ $0.kind != .result }).count == 1 else {
                        throw AppError.message("An explanation unexpectedly created a working task")
                    }
                    try await submit("做一个小费计算器：账单 83 元，小费 12%，显示小费和总额；这两个输入都要能改")
                    guard
                        let calculator = model.sideTasks.first(where: { $0.taskSurface != nil && $0.kind == .workspace }
                        )
                    else {
                        throw AppError.message("Calculation did not create an interactive task")
                    }
                    func hasNumber(_ task: SideTask, _ expected: Double) -> Bool {
                        (Array(task.state.values) + Array((task.liveValues ?? [:]).values)).contains {
                            let value = $0.replacingOccurrences(
                                of: #"[^0-9.\-]"#, with: "", options: .regularExpression)
                            return Double(value).map { abs($0 - expected) < 0.011 } ?? false
                        }
                    }
                    guard hasNumber(calculator, 9.96), hasNumber(calculator, 92.96) else {
                        throw AppError.message("Initial calculation values are incorrect")
                    }
                    try await submit("账单改成 125，小费比例保持不变", owner: calculator.id)
                    guard let updated = model.sideTasks.first(where: { $0.id == calculator.id }),
                        hasNumber(updated, 15), hasNumber(updated, 140)
                    else {
                        throw AppError.message("Follow-up did not update the same calculation correctly")
                    }
                }
                if !coreOnly {
                    try await submit("放 Daft Punk 的 Get Lucky")
                    guard let music = model.sideTasks.first(where: { $0.isMediaTask }),
                        let player = model.musicBrowser(music.id)
                    else { throw AppError.message("Music player missing") }
                    func advancing() async throws {
                        let first = try await player.observe()
                        try await Task.sleep(for: .milliseconds(700))
                        let second = try await player.observe()
                        guard second["playing"] as? Bool == true, second["audible"] as? Bool == true,
                            (second["currentTime"] as? Double ?? 0) > (first["currentTime"] as? Double ?? 0)
                        else {
                            throw AppError.message("Music is not audibly advancing")
                        }
                    }
                    try await advancing()
                    let original = model.sideTasks.first(where: { $0.id == music.id })?.musicQueue?.current?.id
                    try await submit("把 Daft Punk 的 One More Time 加到下一首，现在这首别停", owner: music.id)
                    guard let queue = model.sideTasks.first(where: { $0.id == music.id })?.musicQueue,
                        queue.current?.id == original, let next = queue.upcoming.first
                    else {
                        throw AppError.message("Queueing interrupted playback or lost its next track")
                    }
                    try await submit("跳到接下来那首", owner: music.id)
                    guard model.sideTasks.first(where: { $0.id == music.id })?.musicQueue?.current?.id == next.id else {
                        throw AppError.message("Next did not select the queued track")
                    }
                    try await advancing()
                    try await submit("还是回到刚刚那首吧", owner: music.id)
                    guard model.sideTasks.first(where: { $0.id == music.id })?.musicQueue?.current?.id == original
                    else {
                        throw AppError.message("Previous did not restore the original track")
                    }
                    try await advancing()
                    try await submit("换成适合看书的 lofi", owner: music.id)
                    try await advancing()
                    try await submit("先停一下音乐", owner: music.id)
                    guard try await player.observe()["playing"] as? Bool == false else {
                        throw AppError.message("Music did not pause")
                    }
                }
                emit(["unifiedReport": ["ok": true, "results": results]])
                if CommandLine.arguments.contains("--keep-open") { return }
                exit(0)
            } catch {
                model.cancel()
                for task in model.sideTasks where task.isMediaTask {
                    try? await model.performMusicControl(task.id, operation: "pause")
                }
                emit(["unifiedReport": ["ok": false, "error": error.localizedDescription, "results": results]])
                exit(1)
            }
        }
    }
#endif
