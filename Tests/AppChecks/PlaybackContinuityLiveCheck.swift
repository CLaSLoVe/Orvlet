#if DEBUG
    import Foundation

    /// Full sendCommand path with the saved provider; no preset plans, responses or source URLs.
    @MainActor
    enum PlaybackContinuityLiveCheck {
        static func run(_ model: AppModel) async {
            let trace = FileManager.default.temporaryDirectory.appendingPathComponent(
                "orvlet-playback-continuity.jsonl")
            Diagnostics.begin(trace.path)
            func emit(_ value: [String: Any]) {
                FileHandle.standardOutput.write(Data((JSONText.encode(value) + "\n").utf8))
            }
            func events() -> [[String: Any]] {
                ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
            }
            func waiting() -> Bool {
                model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty
            }
            func send(_ text: String) {
                model.selectChat(true)
                model.command = text
                model.sendCommand()
            }
            do {
                guard let profile = model.settings.profiles.first(where: { $0.name.lowercased() == "siliconflow" })
                else {
                    throw AppError.message("Saved siliconflow profile is unavailable")
                }
                model.settings.main = profile.endpoint
                model.settings.activeProfileID = profile.id
                model.settings.autoAdapt = true
                if CommandLine.arguments.contains("--with-task-history") {
                    model.archivedTaskHistory =
                        UserDefaults.standard.data(forKey: "taskHistory.v1").flatMap {
                            try? JSONDecoder().decode([SideTask].self, from: $0)
                        } ?? []
                }
                if CommandLine.arguments.contains("--force-main") { model.fastTriageRetryAfter = .distantFuture }
                // Automatic UI updates remain enabled; all writes are to the harness's isolated task store.
                emit([
                    "configuration": [
                        "host": profile.endpoint.completionURL?.host ?? "", "model": profile.endpoint.model,
                        "reasoning": profile.endpoint.options.reasoning.rawValue, "autoAdapt": model.settings.autoAdapt,
                    ]
                ])
                let prime = Date()
                send("放 lofi")
                while waiting() && Date().timeIntervalSince(prime) < 100 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !waiting(), !model.taskFailed, let owner = model.sideTasks.first(where: \.isMediaTask)?.id,
                    let player = model.musicBrowser(owner)
                else { throw AppError.message("Initial lofi request did not complete") }
                let before = try await player.observe()
                guard before["audible"] as? Bool == true, before["playing"] as? Bool == true,
                    let oldVideo = MusicTrack.videoID(before["url"] as? String ?? "")
                else {
                    throw AppError.message("Initial lofi was not audible")
                }
                emit([
                    "lofi": [
                        "seconds": Date().timeIntervalSince(prime), "title": before["title"] ?? "", "video": oldVideo,
                    ]
                ])
                let commands =
                    CommandLine.arguments.contains("--sequential-switches")
                    ? ["放 EDM", "放爵士乐", "放古典音乐", "放 lofi"] : ["放 EDM"]
                var allPassed = true
                var previousVideo = oldVideo
                for command in commands {
                    let index = events().count
                    let start = Date()
                    send(command)
                    var firstSound: Date?
                    var finish: Double?
                    var firstVideo: String?
                    var generation: Int?
                    var lastPosition: Double?
                    var interruptions: [[String: Any]] = []
                    var samples = 0
                    var lastTitle = ""
                    while Date().timeIntervalSince(start) < 100 {
                        if !waiting(), finish == nil { finish = Date().timeIntervalSince(start) }
                        if let state = try? await player.observe(),
                            let video = MusicTrack.videoID(state["url"] as? String ?? "")
                        {
                            let audible =
                                state["playing"] as? Bool == true && state["audible"] as? Bool == true
                                && state["adPlaying"] as? Bool != true
                            let position = state["currentTime"] as? Double ?? 0
                            if firstSound == nil, video != previousVideo, audible {
                                firstSound = Date()
                                firstVideo = video
                                generation = player.navigationGeneration
                                lastTitle = state["title"] as? String ?? ""
                                emit([
                                    "firstSound": [
                                        "seconds": Date().timeIntervalSince(start), "video": video, "title": lastTitle,
                                    ]
                                ])
                            }
                            if let firstSound {
                                samples += 1
                                if !audible || video != firstVideo || player.navigationGeneration != generation
                                    || (lastPosition.map { position + 0.4 < $0 } ?? false)
                                {
                                    interruptions.append([
                                        "seconds": Date().timeIntervalSince(firstSound), "audible": audible,
                                        "position": position, "video": video, "navigation": player.navigationGeneration,
                                    ])
                                }
                                lastPosition = position
                            }
                        } else if let firstSound {
                            interruptions.append(["seconds": Date().timeIntervalSince(firstSound), "unavailable": true])
                        }
                        if let firstSound, Date().timeIntervalSince(firstSound) >= 30 { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    let evidence = Array(events().dropFirst(index))
                    let executedTools = evidence.filter { $0["event"] as? String == "tool" }
                        .compactMap { $0["name"] as? String }
                    let cleanSwitch = executedTools.filter { $0 == "find_music" }.count == 1
                        && !executedTools.contains { ["control_media", "navigate", "act"].contains($0) }
                    let seconds = firstSound.map { $0.timeIntervalSince(start) }
                    let observed = firstSound.map { Date().timeIntervalSince($0) } ?? 0
                    let result: [String: Any] = [
                        "command": command,
                        "taskCount": model.sideTasks.count, "browserCount": model.liveBrowsers.count,
                        "owner": owner.uuidString,
                        "playerIDs": model.sideTasks.filter(\.isMediaTask).map { $0.id.uuidString },
                        "firstSoundSeconds": seconds as Any? ?? NSNull(),
                        "finishedSeconds": finish as Any? ?? NSNull(), "observedSeconds": observed, "samples": samples,
                        "interruptions": interruptions, "title": lastTitle, "taskFailed": model.taskFailed,
                        "onePlayer": model.sideTasks.filter(\.isMediaTask).count == 1,
                        "metLatencyTarget": seconds.map { $0 <= 10 } ?? false,
                        "continuous": observed >= 30 && interruptions.isEmpty,
                        "cleanSwitch": cleanSwitch, "executedTools": executedTools,
                        "events": evidence,
                    ]
                    emit(["result": result])
                    let passed =
                        seconds != nil && observed >= 30 && interruptions.isEmpty && !model.taskFailed && cleanSwitch
                        && model.sideTasks.filter(\.isMediaTask).count == 1
                        && model.sideTasks.contains { $0.id == owner }
                    allPassed = allPassed && passed
                    previousVideo = firstVideo ?? previousVideo
                    if !passed { break }
                }
                for browser in model.liveBrowsers {
                    browser.setUserPlaybackPaused(true)
                    await browser.applyPlaybackPolicy()
                }
                model.cancel()
                if let suite = DebugHarness.pipelineSuite { model.preferences.removePersistentDomain(forName: suite) }
                exit(allPassed ? 0 : 1)
            } catch {
                emit(["error": error.localizedDescription, "events": events()])
                model.cancel()
                for browser in model.liveBrowsers { browser.dispose() }
                exit(1)
            }
        }
    }
#endif
