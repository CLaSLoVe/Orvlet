#if DEBUG
    import Foundation

    @MainActor
    enum MusicRequestCheck {
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
            for text in requests {
                do {
                    let seconds = try await DeliveryCheck.submit(model, text)
                    guard let task = model.sideTasks.first(where: { $0.isMediaTask && $0.playing }),
                        let controller = model.musicBrowser(task.id)
                    else {
                        throw AppError.message("No playing music task after the request")
                    }
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
                        "request": text, "ok": true, "seconds": seconds,
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
