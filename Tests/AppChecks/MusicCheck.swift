#if DEBUG
    import AppKit
    import SwiftUI
    import WebKit

    @MainActor
    enum MusicCheck {
        static func artifact(_ name: String) -> String {
            (NSHomeDirectory().contains("/Containers/") ? NSTemporaryDirectory() : "/tmp/") + name
        }
        static func run(_ model: AppModel, delegate: AppDelegate, live: Bool, sourceOnly: Bool = false) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.settings.reduceMotion = true
            model.settings.appearance = .light
            model.sideTasks = []
            model.messages = []
            model.pinned = true
            let path = artifact(
                sourceOnly
                    ? "orvlet-music-source-check.json"
                    : live ? "orvlet-music-live-check.json" : "orvlet-music-check.json")
            Diagnostics.file = URL(
                fileURLWithPath: artifact(
                    sourceOnly ? "orvlet-music-source.jsonl" : live ? "orvlet-music-live.jsonl" : "orvlet-music.jsonl"))
            FileManager.default.createFile(atPath: Diagnostics.file!.path, contents: nil)
            Diagnostics.started = Date()
            var checks: [String] = []
            var timings: [String: Double] = [:]
            func check(_ condition: Bool, _ label: String) throws {
                guard condition else { throw AppError.message(label) }
                checks.append(label)
            }
            func write(_ ok: Bool, error: String? = nil) {
                var report: [String: Any] = ["ok": ok, "checks": checks, "timings": timings]
                if let data = try? String(contentsOf: Diagnostics.file!, encoding: .utf8) {
                    report["events"] = data.split(separator: "\n").compactMap { line -> [String: Any]? in
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                            let name = event["event"] as? String,
                            [
                                "api", "music_search", "music_selection", "music_playback_ready", "music_exact_match",
                                "music_search_cache", "music_request_ready", "music_interpret",
                            ].contains(name)
                        else { return nil }
                        return event
                    }
                }
                if let error { report["error"] = error }
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
                print(JSONText.encode(["musicReport": report]))
                for name in ["orvlet-music-light.png", "orvlet-music-queue.png", "orvlet-music-dark.png"] {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: artifact(name))) {
                        print(JSONText.encode(["musicArtifact": name, "base64": data.base64EncodedString()]))
                    }
                }
            }
            func sourceSong(_ query: String, term: String) async throws -> MusicTrack {
                let candidates = try await YouTubeDiscovery.search(query, model: model)
                try JSONEncoder().encode(candidates).write(
                    to: URL(fileURLWithPath: artifact("orvlet-music-source-candidates.json")))
                guard
                    let track = candidates.first(where: {
                        $0.title.contains(term)
                            && ($0.title.contains("官方") || $0.title.contains("Official")
                                || $0.subtitle.contains("Jay Chou"))
                    })
                else {
                    throw AppError.message("Expected official song was not found in observed search results")
                }
                return track
            }
            do {
                let a = MusicTrack(id: "abcdefghijk", title: "A")
                let b = MusicTrack(id: "bcdefghijkl", title: "B")
                let c = MusicTrack(id: "cdefghijklm", title: "C")
                var queue = MusicQueue(current: a)
                queue.append([a, b, b, c])
                try check(queue.upcoming == [b, c], "Queue deduplicates tracks and excludes the current song")
                queue.select(b)
                try check(
                    queue.previous == [a] && queue.upcoming == [c],
                    "Selecting next records history and removes the pending item")
                try check(
                    queue.back() == a && queue.upcoming == [b, c],
                    "Previous restores the interrupted track to the front of the queue")
                try check(
                    MusicTrack.videoID("https://youtube.com.evil.test/watch?v=abcdefghijk") == nil,
                    "Non-YouTube lookalike URLs are rejected")
                let request = MusicRequest(query: "A", selection: .song, placement: .replace)
                var rejected = false
                do {
                    _ = try YouTubeDiscovery.validateSelection([a.id, b.id], candidates: [a, b], request: request)
                } catch { rejected = true }
                try check(rejected, "Named-song selection cannot queue multiple alternate versions")
                var saved = SideTask(kind: .web, title: "Music")
                let style = MusicRequest(query: "lofi", selection: .style, placement: .replace)
                let station = MusicTrack(id: a.id, title: "lofi hip hop radio", isLive: true)
                try check(
                    try YouTubeDiscovery.validateSelection([station.id], candidates: [station], request: style) == [
                        station
                    ],
                    "A matching live music station is a valid style selection")
                var recoverable = false
                do {
                    _ = try YouTubeDiscovery.validateSelection([], candidates: [station], request: style)
                } catch is MusicSelectionUnavailable { recoverable = true }
                try check(
                    recoverable,
                    "Empty music selection is a recoverable discovery failure, not a missing-artist request")
                saved.musicQueue = queue
                let restored = try JSONDecoder().decode(SideTask.self, from: JSONEncoder().encode(saved))
                try check(restored.musicQueue == queue, "Music queue survives task persistence")
                let id: UUID
                var namedVideoID: String?
                if live {
                    let query =
                        ProcessInfo.processInfo.environment["ORVLET_MUSIC_TEST_REQUEST"] ?? "用 YouTube 播放周杰伦的晴天，官方版本"
                    if sourceOnly {
                        let start = Date()
                        let track = try await sourceSong("周杰倫 晴天 官方 MV", term: "晴天")
                        var task = SideTask(id: model.browser.id, kind: .web, title: track.title)
                        task.sourceURL = track.url
                        task.listening = true
                        model.sideTasks.append(task)
                        try await model.playMusicTrack(track, id: task.id)
                        timings["sourceSong"] = Date().timeIntervalSince(start)
                    } else {
                        timings["namedSong"] = try await DeliveryCheck.submit(model, query)
                    }
                    guard let task = model.sideTasks.first(where: { $0.isMediaTask }), task.musicQueue?.current != nil
                    else {
                        throw AppError.message("Named-song request did not use the YouTube music path")
                    }
                    id = task.id
                    try check(
                        task.playing && MusicTrack.videoID(task.sourceURL ?? "") != nil,
                        sourceOnly
                            ? "Direct source search finds and plays the observed official YouTube song (no model)"
                            : "Real named-song request selects and starts YouTube playback")
                    let initial = task.musicQueue!.current!.id
                    namedVideoID = initial
                    if sourceOnly {
                        let start = Date()
                        let track = try await sourceSong("周杰倫 七里香 官方 MV", term: "七里香")
                        try model.enqueueMusic([track], id: id, next: true)
                        timings["sourceEnqueue"] = Date().timeIntervalSince(start)
                    } else {
                        timings["enqueue"] = try await DeliveryCheck.submit(
                            model, "下一首放周杰伦的七里香，官方版本，不要中断当前播放", taskID: id)
                    }
                    let added = model.sideTasks.first(where: { $0.id == id })!
                    try check(
                        added.playing && added.musicQueue?.current?.id == initial
                            && added.musicQueue?.upcoming.count == 1,
                        "Enqueuing a second named song preserves current playback and task identity")
                    let next = added.musicQueue!.upcoming[0].id
                    try await model.performMusicControl(id, operation: "volume", value: 0.31)
                    let t = Date()
                    try await model.performMusicControl(id, operation: "next")
                    timings["next"] = Date().timeIntervalSince(t)
                    try await Task.sleep(for: .seconds(2))
                    let afterNext = try await model.musicBrowser(id)!.observe()
                    try check(
                        abs((afterNext["volume"] as? Double ?? 1) - 0.31) < 0.02,
                        "Volume survives YouTube initialization and track changes")
                    try check(
                        model.musicPlayback[id]?.videoID == next && model.musicPlayback[id]?.playing == true,
                        "Next plays the queued YouTube video without model inference")
                    let previousPolicy = model.settings.taskStartPolicy
                    model.settings.taskStartPolicy = .interfaceFirst
                    try await model.performMusicControl(id, operation: "previous")
                    model.settings.taskStartPolicy = previousPolicy
                    try check(
                        model.musicPlayback[id]?.videoID == initial && model.musicPlayback[id]?.playing == true,
                        "Previous returns to the actual previous song under interface-first playback")
                } else {
                    _ = try await model.browser.action([
                        "action": "navigate", "url": "http://127.0.0.1:19244/fixture?music",
                    ])
                    _ = try await model.browser.action(["action": "media", "operation": "play"])
                    let page = try await model.browser.observe()
                    let plan = BuiltinCards.music(observation: page)!
                    model.install(plan)
                    model.beginBackgroundListening()
                    model.upsertWebTask(plan, activate: true)
                    id = model.browser.id
                }
                try await model.performMusicControl(id, operation: "volume", value: 0.23)
                var state = try await model.musicBrowser(id)!.observe()
                try check(abs((state["volume"] as? Double ?? 1) - 0.23) < 0.02, "Volume reaches the actual player")
                try await model.performMusicControl(id, operation: "toggleMute")
                state = try await model.musicBrowser(id)!.observe()
                try check(state["muted"] as? Bool == true, "Mute reaches the actual player")
                try await model.performMusicControl(id, operation: "toggleMute")
                try await model.performMusicControl(id, operation: "seek", value: 8)
                state = try await model.musicBrowser(id)!.observe()
                try check(abs((state["currentTime"] as? Double ?? 0) - 8) < 2, "Seek changes the actual playhead")
                try await model.performMusicControl(id, operation: "loop")
                state = try await model.musicBrowser(id)!.observe()
                try check(state["looping"] as? Bool == true, "Repeat is confirmed by the player")
                try await model.performMusicControl(id, operation: "unloop")
                try await model.performMusicControl(id, operation: "pause")
                state = try await model.musicBrowser(id)!.observe()
                try check(state["playing"] as? Bool == false, "Pause stops playback")
                try await model.performMusicControl(id, operation: "play")
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(150))
                    state = try await model.musicBrowser(id)!.observe()
                    if state["playing"] as? Bool == true && (state["currentTime"] as? Double ?? 0) > 8.1 { break }
                }
                try check(
                    state["playing"] as? Bool == true && (state["currentTime"] as? Double ?? 0) > 8,
                    "Resume advances the player again")
                if !live {
                    let peer = BrowserController(model: model)
                    var peerTask = SideTask(id: peer.id, kind: .web, title: "Other music task")
                    peerTask.sourceURL = "http://127.0.0.1:19244/fixture?other-music"
                    peerTask.listening = true
                    model.sideTasks.append(peerTask)
                    model.parkedBrowsers[peer.id] = peer
                    _ = try await peer.action(["action": "navigate", "url": peerTask.sourceURL!])
                    _ = try await peer.action(["action": "media", "operation": "play"])
                    try model.activateTaskSource(peer.id)
                    try await model.performMusicControl(id, operation: "volume", value: 0.17)
                    try await model.performMusicControl(id, operation: "pause")
                    let ownerState = try await model.musicBrowser(id)!.observe()
                    let peerState = try await peer.observe()
                    try check(
                        ownerState["playing"] as? Bool == false && peerState["playing"] as? Bool == true
                            && abs((ownerState["volume"] as? Double ?? 1) - 0.17) < 0.02
                            && (peerState["volume"] as? Double ?? 0) > 0.9,
                        "Music controls address a parked owning task without altering the active player's volume or playback"
                    )
                }
                if live {
                    if sourceOnly {
                        let candidates = try await YouTubeDiscovery.search(
                            "lofi hip hop study relaxing beats", model: model)
                        try model.enqueueMusic(Array(candidates.prefix(3)), id: id)
                    } else {
                        timings["style"] = try await DeliveryCheck.submit(model, "换成 lofi 学习音乐，准备几首接着听", taskID: id)
                    }
                    try check(
                        model.sideTasks.first(where: { $0.id == id })?.musicQueue?.upcoming.isEmpty == false,
                        "Style request produces a real pending queue in the same music task")
                    if !sourceOnly {
                        try check(
                            model.musicPlayback[id]?.videoID != namedVideoID
                                && model.musicPlayback[id]?.playing == true,
                            "Switching to a style replaces current playback rather than only appending to the queue")

                    }
                    let tracks = model.sideTasks.first(where: { $0.id == id })!.musicQueue!.upcoming
                    if tracks.count > 1 {
                        model.moveQueuedMusic(tracks[1].id, before: tracks[0].id, id: id)
                        try check(
                            model.sideTasks.first(where: { $0.id == id })?.musicQueue?.upcoming.first?.id
                                == tracks[1].id,
                            "Pending queue reorder is retained")
                        model.removeQueuedMusic(tracks[0].id, id: id)
                        try check(
                            model.sideTasks.first(where: { $0.id == id })?.musicQueue?.upcoming.contains(where: {
                                $0.id == tracks[0].id
                            }) == false,
                            "Removing a pending song leaves current playback intact")
                        try model.enqueueMusic([tracks[0]], id: id)
                    }
                    model.selectChat(false)
                    model.selectTask(id, expanded: true, preferSource: false)
                    model.onShow?()
                    try await Task.sleep(for: .milliseconds(600))
                    try await SideScreenCheck.snapshot(delegate.panel, path: artifact("orvlet-music-light.png"))
                    model.musicQueueExpanded.insert(id)
                    model.onResize?(model.windowSize)
                    try await Task.sleep(for: .milliseconds(500))
                    try await SideScreenCheck.snapshot(delegate.panel, path: artifact("orvlet-music-queue.png"))
                    model.settings.appearance = .dark
                    try await Task.sleep(for: .milliseconds(500))
                    try await SideScreenCheck.snapshot(delegate.panel, path: artifact("orvlet-music-dark.png"))
                    model.settings.appearance = .light
                }
                write(true)
                if CommandLine.arguments.contains("--keep-open") {
                    while true {
                        if let current = model.musicBrowser(id), !current.disposed {
                            let page = try await current.observe()
                            var report = page.filter {
                                [
                                    "title", "url", "playing", "audible", "muted", "volume", "looping", "currentTime",
                                    "duration",
                                ].contains($0.key)
                            }
                            report["queue"] =
                                model.sideTasks.first(where: { $0.id == id })?.musicQueue?.upcoming.map(\.title) ?? []
                            try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(
                                to: URL(fileURLWithPath: artifact("orvlet-music-ui-state.json")))
                            if NSHomeDirectory().contains("/Containers/") {
                                print(JSONText.encode(["musicUIState": report]))
                            }
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                model.browser.dispose()
                exit(0)
            } catch {
                write(false, error: error.localizedDescription)
                if CommandLine.arguments.contains("--keep-open") { return }
                exit(1)
            }
        }
    }
#endif
