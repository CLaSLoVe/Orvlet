import Foundation

@MainActor
extension AppModel {
    func usesMusicCard(_ task: SideTask) -> Bool {
        task.usesMusicCard && !(externalBrowser && task.id == browser.id)
    }
    func musicCardHeight(_ task: SideTask) -> Double {
        let queue = task.musicQueue?.upcoming ?? []
        return 222 + (musicErrors[task.id] == nil ? 0 : 34)
            + (musicQueueExpanded.contains(task.id) ? (queue.isEmpty ? 38 : Double(min(queue.count, 4)) * 42 + 8) : 0)
    }

    func receiveMusicState(_ id: UUID, data: [String: Any]) {
        guard let index = sideTasks.firstIndex(where: { $0.id == id }), sideTasks[index].isMediaTask,
            MusicTrack.videoID(data["url"] as? String ?? "") != nil
        else { return }
        let state = MusicPlayback(data)
        let old = musicPlayback[id]
        if state != old { musicPlayback[id] = state }
        if !musicLoading.contains(id), state.ready, !state.ad {
            var queue = sideTasks[index].musicQueue ?? MusicQueue()
            if let videoID = state.videoID, queue.current?.id != videoID {
                queue.select(MusicTrack(id: videoID, title: state.title, subtitle: state.subtitle))
            }
            queue.volume = state.volume
            queue.muted = state.muted
            queue.repeatOne = state.looping
            if sideTasks[index].musicQueue != queue { sideTasks[index].musicQueue = queue }
        }
        if state.ended, old?.ended != true, !state.looping, !state.ad, !musicLoading.contains(id),
            let controller = musicBrowser(id), !controller.playbackSuspended,
            sideTasks[index].musicQueue?.upcoming.isEmpty == false
        {
            musicControl(id, operation: "next")
        }
    }

    func musicBrowser(_ id: UUID) -> BrowserController? { id == browser.id ? browser : parkedBrowsers[id] }

    func enqueueMusic(_ tracks: [MusicTrack], id: UUID, next: Bool = false) throws {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), sideTasks[i].isMediaTask else {
            throw AppError.message("Open a music task before adding to its queue.")
        }
        var queue = sideTasks[i].musicQueue ?? MusicQueue()
        queue.append(tracks, next: next)
        sideTasks[i].musicQueue = queue
        persistSideTasks()
        onResize?(windowSize)
    }

    func removeQueuedMusic(_ track: String, id: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        sideTasks[i].musicQueue?.upcoming.removeAll { $0.id == track }
        persistSideTasks()
        onResize?(windowSize)
    }

    func moveQueuedMusic(_ source: String, before target: String, id: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), var queue = sideTasks[i].musicQueue,
            source != target, let from = queue.upcoming.firstIndex(where: { $0.id == source })
        else { return }
        let track = queue.upcoming.remove(at: from)
        guard let to = queue.upcoming.firstIndex(where: { $0.id == target }) else { return }
        queue.upcoming.insert(track, at: to)
        sideTasks[i].musicQueue = queue
        persistSideTasks()
    }

    /// The same operation powers native controls and checks. It always addresses the owning page.
    func performMusicControl(_ id: UUID, operation: String, value: Double? = nil) async throws {
        guard let task = sideTasks.first(where: { $0.id == id }), task.isMediaTask,
            let controller = musicBrowser(id), !controller.disposed
        else { throw CancellationError() }
        if operation == "next" || operation == "previous" {
            var queue = task.musicQueue ?? MusicQueue()
            let track: MusicTrack?
            if operation == "previous" {
                track = queue.back()
                if track != nil, let i = sideTasks.firstIndex(where: { $0.id == id }) {
                    sideTasks[i].musicQueue = queue
                }
            } else {
                track = queue.upcoming.first
            }
            guard let track else { throw AppError.message("No track in this direction yet.") }
            try await playMusicTrack(track, id: id)
            return
        }
        let op = operation == "toggle" ? (task.playing ? "pause" : "play") : operation
        guard ["play", "pause", "seek", "volume", "toggleMute", "loop", "unloop"].contains(op) else {
            throw AppError.message("Unsupported music control.")
        }
        if op == "pause" || op == "play" {
            if op == "pause", busy, requestPageID == id { cancel() }
            controller.setUserPlaybackPaused(op == "pause")
            await controller.applyPlaybackPolicy()
        }
        var input: [String: Any] = ["action": "media", "operation": op]
        if let value { input["value"] = value }
        _ = try await controller.action(input)
        let page = try await controller.observe()
        let actual = MusicPlayback(page)
        if op == "volume", let value, abs(actual.volume - value) > 0.02 {
            throw AppError.message("The player did not accept the volume change.")
        }
        if op == "loop" || op == "unloop", actual.looping != (op == "loop") {
            throw AppError.message("The player did not accept repeat.")
        }
        if op == "pause", actual.playing { throw AppError.message("The player has not paused yet.") }
        receiveMusicState(id, data: page)
        musicErrors[id] = nil
        persistSideTasks()
    }

    func musicControl(_ id: UUID, operation: String, value: Double? = nil) {
        if operation == "pause" || (operation == "toggle" && sideTasks.first(where: { $0.id == id })?.playing == true) {
            musicJobs.removeValue(forKey: id)?.cancel()
            musicRevisions[id] = UUID()
            musicLoading.remove(id)
        } else if musicLoading.contains(id) {
            return
        }
        taskRanking.record(id, .control)
        musicJobs[id] = Task { [weak self] in
            guard let self else { return }
            do { try await performMusicControl(id, operation: operation, value: value) } catch is CancellationError {
            } catch {
                if sideTasks.contains(where: { $0.id == id }) { musicErrors[id] = error.localizedDescription }
            }
            onResize?(windowSize)
        }
    }

    func startQueuedMusic(_ track: MusicTrack, id: UUID) {
        guard !musicLoading.contains(id) else { return }
        musicJobs[id] = Task { [weak self] in
            guard let self else { return }
            do { try await playMusicTrack(track, id: id) } catch is CancellationError {} catch {
                musicErrors[id] = error.localizedDescription
            }
            onResize?(windowSize)
        }
    }

    func playMusicTrack(_ track: MusicTrack, id: UUID) async throws {
        try Task.checkCancellation()
        guard let controller = musicBrowser(id), !controller.disposed,
            let index = sideTasks.firstIndex(where: { $0.id == id })
        else { throw CancellationError() }
        let ticket = UUID()
        musicRevisions[id] = ticket
        musicLoading.insert(id)
        musicErrors[id] = nil
        let start = Date()
        var queue = sideTasks[index].musicQueue ?? MusicQueue()
        queue.select(track)
        sideTasks[index].musicQueue = queue
        sideTasks[index].listening = true
        sideTasks[index].prefersSource = false
        sideTasks[index].sourceURL = track.url
        defer {
            if musicRevisions[id] == ticket { musicLoading.remove(id) }
            persistSideTasks()
            onResize?(windowSize)
        }
        controller.setUserPlaybackPaused(false, origin: "music_selection")
        if (activeRequest?.startPolicy ?? settings.taskStartPolicy) == .interfaceFirst { controller.waitForInterface() }
        await controller.applyPlaybackPolicy()
        var acquiredFocus = !controller.audioFocusHeld
        try Task.checkCancellation()
        _ = try await controller.action(["action": "navigate", "url": track.url])
        var baseline: Double?
        var startedPlayback = false
        var configured = false
        repeat {
            try Task.checkCancellation()
            guard musicRevisions[id] == ticket, !controller.disposed, !controller.userPausedPlayback,
                !(acquiredFocus && controller.audioFocusHeld),
                sideTasks.contains(where: { $0.id == id })
            else { throw CancellationError() }
            let page = try await controller.observe()
            let state = MusicPlayback(page)
            if state.videoID == track.id, state.ready, !state.ad {
                if !configured {
                    _ = try await controller.action(["action": "media", "operation": "volume", "value": queue.volume])
                    _ = try await controller.action(["action": "media", "operation": queue.muted ? "mute" : "unmute"])
                    if state.seekable {
                        _ = try await controller.action([
                            "action": "media", "operation": queue.repeatOne ? "loop" : "unloop",
                        ])
                    }
                    configured = true
                    if let plan = BuiltinCards.music(observation: page),
                        let i = sideTasks.firstIndex(where: { $0.id == id }),
                        sideTasks[i].customCompact != true
                    {
                        sideTasks[i].plan = plan
                        if browser.id == id {
                            surface = plan
                            hasCustomSurface = true
                        }
                    }
                    if controller.waitingForInterface {
                        controller.releaseInterface()
                        await controller.applyPlaybackPolicy()
                        acquiredFocus = !controller.audioFocusHeld
                    }
                }
                if !state.playing, !startedPlayback {
                    // A single attempt; never repeatedly restart a buffering player or an ad.
                    startedPlayback = true
                    _ = try await controller.action(["action": "media", "operation": "play"])
                    if queue.muted { _ = try await controller.action(["action": "media", "operation": "mute"]) }
                }
                if state.playing, let first = baseline, state.position > first + 0.2,
                    page["audible"] as? Bool == true || queue.muted || queue.volume == 0
                {
                    receiveMusicState(id, data: page)
                    Diagnostics.record(
                        "music_playback_ready", ["taskID": id.uuidString, "seconds": Date().timeIntervalSince(start)])
                    return
                }
                if state.playing { baseline = baseline ?? state.position } else { baseline = nil }
            } else {
                baseline = nil
            }
            try await Task.sleep(for: .milliseconds(200))
        } while Date().timeIntervalSince(start) < 30
        throw AppError.message(
            "YouTube has not started this track. Open the source to check loading or sign-in, then try Play.")
    }
}
