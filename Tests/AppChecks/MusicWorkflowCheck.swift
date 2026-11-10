#if DEBUG
    import Foundation

    @MainActor
    enum MusicWorkflowCheck {
        static func run(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.sideTasks = []
            model.archivedTaskHistory = []
            model.messages = []
            Diagnostics.file = URL(fileURLWithPath: MusicCheck.artifact("orvlet-music-workflow.jsonl"))
            FileManager.default.createFile(atPath: Diagnostics.file!.path, contents: nil)
            Diagnostics.started = Date()
            var checks: [String] = []
            var steps: [[String: Any]] = []
            func emit(_ value: [String: Any]) {
                FileHandle.standardOutput.write(Data((JSONText.encode(value) + "\n").utf8))
            }
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message(label) }
                checks.append(label)
            }
            func submit(_ text: String, owner: UUID? = nil) async throws {
                let start = Date()
                if let owner { model.openTaskConversation(owner) } else { model.selectChat(true) }
                model.command = text
                model.taskFailed = false
                model.sendCommand()
                while model.busy && Date().timeIntervalSince(start) < 150 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !model.busy else {
                    model.cancel()
                    throw AppError.message("Request exceeded 150 seconds")
                }
                let step: [String: Any] = [
                    "request": text, "seconds": Date().timeIntervalSince(start),
                    "reply": model.messages.last?.text ?? "", "taskFailed": model.taskFailed,
                ]
                steps.append(step)
                emit(["workflowStep": step])
                guard !model.taskFailed else { throw AppError.message(model.messages.last?.text ?? "Request failed") }
            }
            func playing(_ id: UUID, expectedID: String? = nil, title: String? = nil) async throws -> [String: Any] {
                guard let controller = model.musicBrowser(id) else { throw AppError.message("Owning player missing") }
                var state: [String: Any] = [:]
                for _ in 0..<30 {
                    let first = try await controller.observe()
                    try await Task.sleep(for: .milliseconds(350))
                    state = try await controller.observe()
                    if state["playing"] as? Bool == true, state["audible"] as? Bool == true,
                        state["adPlaying"] as? Bool != true,
                        (state["currentTime"] as? Double ?? 0) > (first["currentTime"] as? Double ?? 0),
                        let video = MusicTrack.videoID(state["url"] as? String ?? ""),
                        expectedID == nil || video == expectedID
                    {
                        if let title {
                            try check(
                                YouTubeDiscovery.normalized(state["title"] as? String ?? "").contains(
                                    YouTubeDiscovery.normalized(title)),
                                "Actual player title matches \(title)")
                        }
                        try check(
                            model.sideTasks.filter { $0.isMediaTask }.map(\.id) == [id],
                            "Playback retains one owning music task")
                        return state
                    }
                }
                throw AppError.message(
                    "Expected audible advancing video \(expectedID ?? "any") but observed \(state["url"] ?? "") / \(state["playing"] ?? false)"
                )
            }
            func report(_ ok: Bool, error: String? = nil) {
                let events = ((try? String(contentsOf: Diagnostics.file!, encoding: .utf8)) ?? "").split(
                    separator: "\n"
                )
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter {
                    ["api", "tool", "intent_validated", "completion_check"].contains($0["event"] as? String ?? "")
                        || ($0["event"] as? String ?? "").hasPrefix("music_")
                }
                var result: [String: Any] = ["ok": ok, "checks": checks, "steps": steps, "events": events]
                if let error { result["error"] = error }
                emit(["musicWorkflowReport": result])
            }
            do {
                try await submit("给我来点适合专心工作的 lofi")
                guard let id = model.sideTasks.first(where: { $0.isMediaTask })?.id else {
                    throw AppError.message("No music task")
                }
                _ = try await playing(id, title: "lofi")
                try await submit("我现在想听周杰伦的晴天，官方版", owner: id)
                let sunny = try await playing(id, title: "晴天")
                let sunnyID = MusicTrack.videoID(sunny["url"] as? String ?? "")!
                try await submit("这首先别切，播完后接着听周杰伦的七里香，官方版", owner: id)
                _ = try await playing(id, expectedID: sunnyID)
                let queue = model.sideTasks.first { $0.id == id }!.musicQueue?.upcoming ?? []
                try check(
                    queue.count == 1
                        && YouTubeDiscovery.normalized(queue[0].title).contains(YouTubeDiscovery.normalized("七里香")),
                    "Paraphrased enqueue adds the requested song without interrupting the current song")
                try await submit("跳到待播列表里的下一首吧", owner: id)
                _ = try await playing(id, expectedID: queue[0].id, title: "七里香")
                try check(
                    model.sideTasks.first { $0.id == id }?.musicQueue?.upcoming.isEmpty == true
                        && model.sideTasks.first { $0.id == id }?.musicQueue?.previous.last?.id == sunnyID,
                    "Conversation next consumes the queued song and preserves playback history")
                try await submit("回到上一首", owner: id)
                _ = try await playing(id, expectedID: sunnyID, title: "晴天")
                try check(
                    model.sideTasks.first { $0.id == id }?.musicQueue?.upcoming.first?.id == queue[0].id,
                    "Conversation previous returns the interrupted song to Up next")
                try await submit("先停一下音乐", owner: id)
                let paused = try await model.musicBrowser(id)!.observe()
                try check(paused["playing"] as? Bool == false, "Paraphrased pause really pauses the owning player")
                try await submit("接着放吧", owner: id)
                _ = try await playing(id, expectedID: sunnyID)

                var peer = SideTask(kind: .workspace, title: "Unrelated task")
                peer.detail = "Retain this unrelated task"
                model.sideTasks.append(peer)
                model.appendMessage("Keep this unrelated conversation", isUser: true, taskID: peer.id)
                let priorMessages = model.messages.filter { $0.taskID == id }.map(\.id)
                let priorQueue = model.sideTasks.first { $0.id == id }!.musicQueue?.upcoming.map(\.id)
                model.closeTask(id)
                try check(
                    !model.sideTasks.contains { $0.id == id } && model.archivedTaskHistory.contains { $0.id == id }
                        && model.messages.filter { $0.taskID == id }.map(\.id) == priorMessages,
                    "Removing the music task clears Tasks but preserves exact conversation and archived state")
                model.selectedTaskID = peer.id
                try await submit("继续刚才的音乐，别换曲子", owner: id)
                _ = try await playing(id, expectedID: sunnyID)
                try check(
                    Set(priorMessages).isSubset(of: Set(model.messages.filter { $0.taskID == id }.map(\.id)))
                        && model.sideTasks.first { $0.id == id }?.musicQueue?.upcoming.map(\.id) == priorQueue,
                    "Continuing from History restores the same task, song, queue and earlier messages")
                try check(
                    model.sideTasks.first { $0.id == peer.id }?.detail == peer.detail
                        && model.messages.filter { $0.taskID == peer.id }.count == 1,
                    "Restoring music leaves the separately selected task and conversation untouched")
                try await submit("Could you put on some jazz for reading?", owner: id)
                _ = try await playing(id, title: "jazz")
                try await submit("Play Daft Punk's Get Lucky, the original version.", owner: id)
                _ = try await playing(id, title: "Get Lucky")
                var emptyQueueRejected = false
                do {
                    _ = try await model.performBrowserAction(["action": "media", "operation": "next"])
                } catch { emptyQueueRejected = true }
                try check(
                    emptyQueueRejected, "An empty queue never falls through to an unrelated YouTube recommendation")
                _ = try await playing(id, title: "Get Lucky")
                model.closeTask(id)
                try await submit("继续", owner: id)
                _ = try await playing(id, title: "Get Lucky")
                try await model.performMusicControl(id, operation: "pause")
                report(true)
                if CommandLine.arguments.contains("--keep-open") {
                    model.pinned = true
                    model.selectChat(false)
                    model.taskShelfVisible = true
                    model.onShow?()
                    return
                }
                exit(0)
            } catch {
                model.cancel()
                for task in model.sideTasks where task.isMediaTask {
                    try? await model.performMusicControl(task.id, operation: "pause")
                }
                report(false, error: error.localizedDescription)
                exit(1)
            }
        }
    }
#endif
