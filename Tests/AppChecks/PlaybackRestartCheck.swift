#if DEBUG
    import Foundation
    import WebKit

    @MainActor
    enum PlaybackRestartCheck {
        static func waitForEnd(_ player: BrowserController, timeout: Double) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            var latest: [String: Any] = [:]
            repeat {
                let state = try await player.observe()
                latest = state.filter {
                    ["currentTime", "duration", "ended", "playing", "looping", "adPlaying", "readyState", "mediaError"]
                        .contains($0.key)
                }
                if state["ended"] as? Bool == true { return state }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < deadline
            throw AppError.message("The real media element did not reach ended: " + JSONText.encode(latest))
        }

        static func advancing(_ player: BrowserController) async throws -> [String: Any] {
            let before = try await player.observe()
            var after: [String: Any] = [:]
            // WebKit starts asynchronously; wait for observed progress, not a fixed startup delay.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(200))
                after = try await player.observe()
                if after["playing"] as? Bool == true, after["audible"] as? Bool == true,
                    after["ended"] as? Bool != true, after["adPlaying"] as? Bool != true,
                    after["url"] as? String == before["url"] as? String,
                    (after["currentTime"] as? Double ?? 0) > (before["currentTime"] as? Double ?? 0) + 0.2
                {
                    return after
                }
            }
            throw AppError.message(
                "The source is not audibly advancing: "
                    + JSONText.encode([
                        "before": before.filter {
                            ["currentTime", "playing", "ended", "audible", "readyState"].contains($0.key)
                        },
                        "after": after.filter {
                            ["currentTime", "playing", "ended", "audible", "readyState"].contains($0.key)
                        },
                    ]))
        }

        static func local(_ model: AppModel) async throws -> [String] {
            var checks: [String] = []
            let player = model.browser
            for tag in ["audio", "video"] {
                _ = try await player.action(["action": "navigate", "url": "http://127.0.0.1:19244/playback-end?" + tag])
                _ = try await player.action(["action": "media", "operation": "play"])
                _ = try await waitForEnd(player, timeout: 12)
                _ = try await player.action(["action": "media", "operation": tag == "audio" ? "play" : "toggle"])
                let replay = try await advancing(player)
                guard (replay["currentTime"] as? Double ?? 100) < 2 else {
                    throw AppError.message("Completed media did not restart at zero")
                }
                checks.append("Real WebKit " + tag + " reaches its natural end, then replays from zero and advances")
                try await Task.sleep(for: .seconds(1))
                _ = try await advancing(player)
                _ = try await player.action(["action": "media", "operation": "pause"])
                let position = (try await player.observe())["currentTime"] as? Double ?? 0
                let resumeStart = try await player.action(["action": "media", "operation": "play"])
                let resumed = try await advancing(player)
                guard abs((resumeStart["currentTime"] as? Double ?? -10) - position) < 0.15,
                    (resumed["currentTime"] as? Double ?? 0) >= position - 0.05
                else {
                    throw AppError.message(
                        "Pause/resume reset the playhead: "
                            + JSONText.encode([
                                "tag": tag, "pausedAt": position, "resumedAt": resumed["currentTime"] ?? 0,
                                "resumeStart": resumeStart["currentTime"] ?? "missing",
                                "replayAt": replay["currentTime"] ?? 0,
                            ]))
                }
                checks.append("Real WebKit " + tag + " preserves paused position on resume")
            }
            // A rejected player action must surface once, without a model retry loop.
            model.beginBackgroundListening()
            model.upsertWebTask(model.surface, activate: true)
            model.settings.useFast = true
            var modelCalls = 0
            model.agent.completionOverride = { _ in
                modelCalls += 1
                throw AppError.message("Unexpected retry")
            }
            defer {
                model.agent.completionOverride = nil
                model.endBackgroundListening(clearTaskIntent: true)
                model.sideTasks.removeAll { $0.id == player.id }
            }
            _ = try await player.webView.evaluateJavaScript(
                "document.querySelector('video').play=()=>Promise.reject(new Error('Synthetic playback rejection'));true"
            )
            let text = "Resume the test player"
            let prepared = PreparedRequest(
                text: text,
                triage: RequestTriage(capability: .control, target: player.id, routeKnown: true, action: "resume"),
                model: model)
            var reason = ""
            do { _ = try await model.agent.run(text, taskID: player.id, prepared: prepared) } catch {
                reason = error.localizedDescription
            }
            guard reason.contains("Synthetic playback rejection"), modelCalls == 0 else {
                throw AppError.message("Playback failure was hidden or retried by the model: " + reason)
            }
            checks.append("Playback rejection preserves its concrete error and makes zero model recovery calls")
            return checks
        }

        static func live(_ model: AppModel) async {
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            let trace = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-playback-restart.jsonl")
            Diagnostics.begin(trace.path)
            func emit(_ value: [String: Any]) {
                FileHandle.standardOutput.write(Data((JSONText.encode(value) + "\n").utf8))
            }
            do {
                for query in ["放 dream funk", "放 Daft Punk 的 Get Lucky"] {
                    _ = try await DeliveryCheck.submit(model, query)
                    guard let task = model.sideTasks.first(where: \.isMediaTask),
                        let player = model.musicBrowser(task.id)
                    else {
                        throw AppError.message("No music player")
                    }
                    let fresh = try await advancing(player)
                    guard (fresh["currentTime"] as? Double ?? 100) < 12 else {
                        throw AppError.message("New track did not begin at the start")
                    }
                    guard let length = fresh["duration"] as? Double, length > 5, fresh["live"] as? Bool != true else {
                        throw AppError.message("A finite track is required for the end-of-playback test")
                    }
                    emit([
                        "phase": "new playback", "request": query, "title": fresh["title"] ?? "",
                        "position": fresh["currentTime"] ?? 0, "duration": length,
                    ])
                    // Seek only to shorten the test. Wait for the real ended state,
                    // never fake an ended event or override playback properties.
                    try await model.performMusicControl(task.id, operation: "unloop")
                    try await model.performMusicControl(task.id, operation: "seek", value: length - 1.5)
                    let ended = try await waitForEnd(player, timeout: 20)
                    emit(["phase": "ended", "position": ended["currentTime"] ?? 0, "ended": ended["ended"] ?? false])
                    try await model.performMusicControl(task.id, operation: "play")
                    let native = try await advancing(player)
                    guard (native["currentTime"] as? Double ?? 100) < 6 else {
                        throw AppError.message("Native replay did not start from zero")
                    }
                    emit([
                        "phase": "native replay", "playing": native["playing"] ?? false,
                        "audible": native["audible"] ?? false, "position": native["currentTime"] ?? 0,
                    ])

                    try await model.performMusicControl(task.id, operation: "seek", value: 8)
                    _ = try await advancing(player)
                    try await model.performMusicControl(task.id, operation: "pause")
                    let paused = (try await player.observe())["currentTime"] as? Double ?? 0
                    try await model.performMusicControl(task.id, operation: "play")
                    let resumed = try await advancing(player)
                    guard (resumed["currentTime"] as? Double ?? 0) > paused else {
                        throw AppError.message("Native resume reset playback")
                    }
                    emit(["phase": "resume", "pausedAt": paused, "resumedAt": resumed["currentTime"] ?? 0])

                    try await model.performMusicControl(task.id, operation: "seek", value: length - 1.5)
                    _ = try await waitForEnd(player, timeout: 20)
                    // Real natural-language entry, interpretation, execution and verification.
                    _ = try await DeliveryCheck.submit(model, "播放这首歌", taskID: task.id)
                    let agent = try await advancing(player)
                    guard (agent["currentTime"] as? Double ?? 100) < 10,
                        agent["url"] as? String == fresh["url"] as? String, !model.taskFailed
                    else { throw AppError.message("Conversation replay did not restart the same source") }
                    emit([
                        "phase": "conversation replay", "position": agent["currentTime"] ?? 0,
                        "playing": agent["playing"] ?? false, "audible": agent["audible"] ?? false,
                        "taskFailed": model.taskFailed,
                    ])
                    try await model.performMusicControl(task.id, operation: "pause")
                }
                emit([
                    "ok": true, "sources": 2,
                    "scope":
                        "Actual YouTube playback: native replay, paused resume and natural-language replay after ended",
                ])
                for browser in model.liveBrowsers { browser.dispose() }
                exit(0)
            } catch {
                emit(["ok": false, "error": error.localizedDescription])
                let entries = ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap {
                        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    }.filter { ["tool", "tool_error", "request_plan", "round"].contains($0["event"] as? String ?? "") }
                emit(["recentExecution": Array(entries.suffix(12))])
                model.cancel()
                for browser in model.liveBrowsers { browser.dispose() }
                exit(1)
            }
        }
    }
#endif
