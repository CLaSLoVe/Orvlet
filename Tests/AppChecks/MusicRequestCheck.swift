#if DEBUG
    import Foundation

    @MainActor
    enum MusicRequestCheck {
        static func routingChecks() async throws -> [String] {
            let suite = "orvlet-music-routing-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            defer { model.browser.dispose() }
            var checks: [String] = []
            var player = SideTask(kind: .web, title: "天下")
            let track = MusicTrack(id: "abcdefghijk", title: player.title, isLive: false)
            player.listening = true
            player.prefersSource = false
            player.musicQueue = MusicQueue(current: track)
            player.hidden = true
            player.sourceURL = track.url
            var video = SideTask(kind: .web, title: "Lecture")
            video.sourceURL = "https://example.org/watch"
            video.listening = true
            video.playing = true
            video.musicQueue = MusicQueue(current: MusicTrack(id: "xyzabcdefgh", title: video.title))
            var separate = SideTask(kind: .web, title: "Other player")
            separate.musicSessionRole = .independent
            model.sideTasks = [video, separate, player]
            model.selectedTaskID = video.id
            try StateMachineCheck.require(!video.isMusicSession && player.isMusicSession,
                "Ordinary video playback cannot claim a request for another song", &checks)
            let agent = AgentController(model: model)
            let text = "播放踏雪"
            agent.preparedRequest = PreparedRequest(text: text,
                triage: RequestTriage(capability: .music, routeKnown: true), model: model)
            let route = try await agent.understand(text, clarification: nil, key: nil, allowFast: false)
            try StateMachineCheck.require(route.targetTaskID == player.id.uuidString && route.placement?.layout == .operate,
                "A new song routes to the hidden paused player even when fast routing suggested a fresh card", &checks)

            agent.currentRequest = text
            let draft = UUID()
            let message = model.appendMessage(text, isUser: true, taskID: draft)
            model.beginAmbientRequest(text, messageID: message)
            try agent.bindMusicRequest()
            try model.enqueueMusic([MusicTrack(id: "bcdefghijkl", title: "踏雪")], id: agent.activeTaskID)
            let continued = model.sideTasks.first { $0.id == player.id }
            try StateMachineCheck.require(model.requestPageID == player.id && continued?.hidden == false
                && continued?.musicQueue?.current == track && continued?.musicQueue?.upcoming.first?.title == "踏雪"
                && model.messages.first(where: { $0.id == message })?.taskID == player.id
                && model.sideTasks.count == 3 && model.sideTasks.first(where: { $0.id == video.id })?.playing == true,
                "The typed music tool reuses one task, moves its provisional message, and queues without interrupting the selected video", &checks)

            model.activeRequest = nil
            agent.currentRequest = "Reproduce esta canción en un reproductor separado."
            model.beginAmbientRequest(agent.currentRequest)
            try agent.bindMusicRequest(newPlayerQuote: "en un reproductor separado")
            try StateMachineCheck.require(model.requestPageID == nil && model.activeRequest?.musicSessionRole == .independent,
                "An explicit independent-player instruction works in the language of the request", &checks)
            model.activeRequest = nil
            agent.currentRequest = "Play ‘New Player’. Don't open another player."
            model.beginAmbientRequest(agent.currentRequest)
            try agent.bindMusicRequest()
            try StateMachineCheck.require(model.requestPageID == player.id && model.activeRequest?.musicSessionRole == .shared,
                "A title or negated instruction mentioning another player preserves the shared session", &checks)
            try StateMachineCheck.require(model.reusableMusicSession(preferred: separate.id)?.id == separate.id
                && model.reusableMusicSession(preferred: nil)?.id == player.id,
                "An independent player can be addressed deliberately and stays outside default music routing", &checks)
            let original = URL(string: track.url)!
            model.didEnterWebAddress(URL(string: track.url + "&t=30")!, replacing: original, taskID: player.id)
            try StateMachineCheck.require(model.reusableMusicSession(preferred: nil)?.id == player.id,
                "Entering another link to the same track preserves the player and queue", &checks)
            model.didEnterWebAddress(URL(string: "https://example.org/article")!, replacing: original, taskID: player.id)
            try StateMachineCheck.require(model.reusableMusicSession(preferred: nil) == nil
                && model.sideTasks.contains(where: { $0.id == player.id && $0.prefersSource == true && $0.musicQueue == nil }),
                "A typed address repurposes the existing page and releases its former music ownership", &checks)
            return checks
        }

        static func run(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.sideTasks = []
            model.archivedTaskHistory = []
            model.messages = []
            Diagnostics.file = URL(fileURLWithPath: MusicCheck.artifact("orvlet-music-request-check.jsonl"))
            FileManager.default.createFile(atPath: Diagnostics.file!.path, contents: nil)
            Diagnostics.started = Date()
            let requests =
                ProcessInfo.processInfo.environment["ORVLET_MUSIC_REQUEST"].map { [$0] }
                ?? ["放点lofi", "放点lofi", "放点lofi", "放点爵士乐", "播放周杰伦的晴天，官方版本"]
            var results: [[String: Any]] = []
            var firstPlayer: UUID?
            for text in requests {
                do {
                    let seconds = try await DeliveryCheck.submit(model, text)
                    guard let task = model.sideTasks.first(where: { $0.isMediaTask && $0.playing }),
                        let controller = model.musicBrowser(task.id)
                    else {
                        throw AppError.message("No playing music task after the request")
                    }
                    guard firstPlayer == nil || firstPlayer == task.id,
                        model.sideTasks.filter(\.isMusicSession).count == 1 else {
                        throw AppError.message("Successive music requests created a second player.")
                    }
                    firstPlayer = task.id
                    let first = try await controller.observe()
                    try await Task.sleep(for: .milliseconds(700))
                    let state = try await controller.observe()
                    guard state["playing"] as? Bool == true, state["audible"] as? Bool == true,
                        state["adPlaying"] as? Bool != true,
                        (state["currentTime"] as? Double ?? 0) > (first["currentTime"] as? Double ?? 0),
                        MusicTrack.videoID(state["url"] as? String ?? "") != nil
                    else {
                        throw AppError.message("YouTube did not confirm audible advancing playback")
                    }
                    results.append([
                        "request": text, "ok": true, "seconds": seconds, "taskID": task.id.uuidString,
                        "title": state["title"] ?? "", "url": state["url"] ?? "", "live": state["live"] ?? false,
                    ])
                    try await model.performMusicControl(task.id, operation: "pause")
                } catch {
                    results.append(["request": text, "ok": false, "error": error.localizedDescription])
                }
                FileHandle.standardOutput.write(
                    Data((JSONText.encode(["musicRequestResult": results.last!]) + "\n").utf8))
            }
            let events = ((try? String(contentsOf: Diagnostics.file!, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { ($0["event"] as? String ?? "").hasPrefix("music_") || $0["event"] as? String == "api" }
            let ok = results.allSatisfy { $0["ok"] as? Bool == true }
            FileHandle.standardOutput.write(
                Data(
                    (JSONText.encode(["musicRequestReport": ["ok": ok, "results": results, "events": events]]) + "\n")
                        .utf8))
            exit(ok ? 0 : 1)
        }
    }
#endif
