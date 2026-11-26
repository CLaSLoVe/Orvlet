import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func remember(title: String, url: String, kind: String) {
        guard ["https", "http"].contains(URL(string: url)?.scheme ?? "") else { return }
        if let latest = history.first, latest.url == url && latest.title == title,
            Date().timeIntervalSince(latest.date) < 60
        {
            return
        }
        history.insert(HistoryEntry(date: Date(), title: title, url: url, kind: kind), at: 0)
        history = Array(history.prefix(500))
        if persistHistory, let data = try? JSONEncoder().encode(history) { preferences.set(data, forKey: "history") }
    }
    func restore(_ entry: HistoryEntry) {
        restoreSession(
            sessions.get(entry.url)
                ?? SavedSession(url: entry.url, title: entry.title, mediaType: entry.kind == "web" ? "" : entry.kind),
            play: false)
    }
    func saveSession(force: Bool = false) {
        guard persistHistory, !isLiveTest, !restoringSession, !webLoading, !externalBrowser,
            SessionStore.validURL(webURL), force || Date().timeIntervalSince(lastSessionSave) > 4
        else { return }
        lastSessionSave = Date()
        let old = sessions.get(webURL)
        let plan = hasCustomSurface ? surface : old?.plan
        sessions.put(
            SavedSession(
                url: webURL, title: trackTitle, plan: plan, position: max(0, progress), volume: volume,
                mediaType: mediaType, listening: backgroundListening, wasPlaying: isPlaying, taskID: browser.id))
        recentSessions = sessions.entries
    }
    func cancelRestoration() {
        restoreRevision += 1
        restoreTask?.cancel()
        restoreTask = nil
        restoringSession = false
        queuedRestoreAction = nil
        browser.setRestorationHeld(false)
        let revision = restoreRevision
        let owner = browser
        Task { [weak self] in
            guard let self, !owner.disposed,
                self.browser !== owner || (self.restoreRevision == revision && !self.restoringSession)
            else { return }
            await owner.applyPlaybackPolicy()
        }
    }
    func restoreSessionOnLaunch(_ entry: SavedSession) {
        guard SessionStore.validURL(entry.url) else { return }
        func matchesPage(_ task: SideTask) -> Bool {
            if task.sourceURL == entry.url { return true }
            guard task.isMusicSession, let track = MusicTrack.videoID(entry.url) else { return false }
            return track == MusicTrack.videoID(task.sourceURL ?? "")
        }
        let matches: [SideTask]
        if let id = entry.taskID {
            matches = sideTasks.filter { $0.id == id && $0.kind == .web }
            guard !matches.isEmpty else { return }
        } else {
            // Older session records only identified a page by its address.
            matches = sideTasks.filter { $0.kind == .web && matchesPage($0) }
            if matches.isEmpty && work.snapshot.artifacts.values.contains(where: {
                $0.native.map(matchesPage) == true && !work.hasOpenView(for: $0.id)
            }) { return }
        }
        let open = matches.filter { task in
            guard let view = work.view(task.id) else { return true }
            return work.artifact(view.selected)?.native?.id == task.id && work.hasOpenView(for: view.selected)
        }
        if let owner = open.first {
            guard open.count == 1, matchesPage(owner) else { return }
        } else if !matches.isEmpty {
            return
        }
        let play = settings.resumePlaybackOnLaunch && entry.wasPlaying && entry.isMedia
        if !play && (usesNativeBrowser || (entry.isMedia && playbackSources.avoids(entry.url))) {
            // The saved card is enough until the user opens or operates its source.
            var task = open.first ?? SideTask(id: entry.taskID ?? UUID(), kind: .web, title: entry.title)
            task.sourceURL = entry.url
            task.hidden = false
            task.playing = false
            task.listening = task.listening == true || entry.listening
            task.hasMedia = task.hasMedia || entry.isMedia
            if task.plan == nil, let plan = entry.plan, plan.hasMediaControls {
                task.plan = SurfacePlan(components: [SurfaceComponent(kind: .media)], width: plan.width, height: plan.height)
            }
            task.status = task.isMediaTask ? "Paused" : "Resume page"
            if let index = sideTasks.firstIndex(where: { $0.id == task.id }) { sideTasks[index] = task }
            else { sideTasks.append(task) }
            var saved = entry
            saved.taskID = task.id
            dormantLaunchSession = saved
            selectedTaskID = task.id
            persistSideTasks()
            reconcileTasks()
            return
        }
        if let id = open.first?.id, browser.id != id {
            browser.dispose()
            browser = BrowserController(model: self, id: id)
            browserRevision += 1
        }
        restoreSession(entry, play: play)
    }

    func savedPlaybackReplacement(_ url: String, title: String, task: SideTask?) async throws -> (original: MusicTrack, selected: MusicTrack)? {
        guard playbackSources.avoids(url) else { return nil }
        guard let videoID = MusicTrack.videoID(url) else { throw PlaybackSourceUnavailable() }
        let original = task.flatMap { recoveryTrack($0, url: url) } ?? MusicTrack(id: videoID, title: title)
        if let known = playbackSources.preferredReplacement(for: original) { return (original, known) }
        let selected = try await YouTubeDiscovery.replacement(for: original, model: self)
        return (original, selected)
    }

    func restoredObservation(_ page: [String: Any], entry: SavedSession, browser: BrowserController) async throws -> [String: Any] {
        var latest = page
        if entry.isMedia {
            let deadline = Date().addingTimeInterval(8)
            while (latest["hasMedia"] as? Bool != true || (latest["readyState"] as? Int ?? 0) < 1)
                && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                latest = try await browser.observe()
            }
        }
        try Task.checkCancellation()
        return latest
    }

    func restoreMediaSettings(_ entry: SavedSession, page: [String: Any], browser: BrowserController) async {
        guard page["hasMedia"] as? Bool == true else { return }
        _ = try? await browser.action(["action": "media", "operation": "volume", "value": entry.volume])
        if !Task.isCancelled, entry.position > 0, let length = page["duration"] as? Double, length > entry.position {
            _ = try? await browser.action(["action": "media", "operation": "seek", "value": entry.position])
        }
    }

    func restoreSession(_ entry: SavedSession, play: Bool = false) {
        guard SessionStore.validURL(entry.url) else { return }
        saveSession(force: true)
        cancelRestoration()
        adaptive.invalidate()
        let revision = restoreRevision
        restoringSession = true
        webError = nil
        taskFailed = false
        externalBrowser = false
        webURL = entry.url
        webTitle = entry.title
        surface = .webpage
        hasCustomSurface = false  // Saved HTML is installed only after live validation.
        backgroundListening = entry.listening
        progress = entry.position
        volume = entry.volume
        mediaType = entry.mediaType
        isPlaying = false
        hasMedia = entry.isMedia
        collapsed = true
        pinned = false
        webExpanded = false
        onResize?(windowSize)
        let browser = browser  // Restoration never follows a later active-browser switch.
        browser.setRestorationHeld(true)
        restoreTask = Task {
            do {
                try Task.checkCancellation()
                await browser.applyPlaybackPolicy()
                try Task.checkCancellation()
                var entry = entry
                let replacement = entry.isMedia ? try await savedPlaybackReplacement(entry.url, title: entry.title, task: sideTasks.first { $0.id == browser.id }) : nil
                if let replacement {
                    entry.url = replacement.selected.url
                    entry.position = 0
                    try Task.checkCancellation()
                    guard revision == restoreRevision, !browser.disposed else { return }
                }
                let page: [String: Any]
                if browser.currentURL?.absoluteString == entry.url && !webLoading {
                    page = try await browser.observe()
                } else {
                    page = try await browser.action(["action": "navigate", "url": entry.url])
                }
                try Task.checkCancellation()
                browser.restoredPlaybackReplacement = replacement
                let latest = try await restoredObservation(page, entry: entry, browser: browser)
                guard revision == restoreRevision else { return }
                if let plan = entry.plan, let checked = try? plan.validated(observation: latest) {
                    surface = checked
                    hasCustomSurface = checked.markup != nil
                    surfaceOrigin = "Restored"
                    browser.rememberMediaSurface(checked, url: entry.url)
                    try? await browser.bindReadings(checked.readings ?? [])
                    if !isLiveTest, let key = SurfaceCache.pageKey(entry.url) { adaptive.cache.put(checked, key: key) }
                } else {
                    surface = .webpage
                    hasCustomSurface = false
                }
                try Task.checkCancellation()
                await restoreMediaSettings(entry, page: latest, browser: browser)
                try Task.checkCancellation()
                await browser.pauseMedia()
                try Task.checkCancellation()
                guard revision == restoreRevision else { return }
                browser.setRestorationHeld(false)
                await browser.applyPlaybackPolicy()
                try Task.checkCancellation()
                guard revision == restoreRevision else { return }
                restoringSession = false
                upsertWebTask(surface, activate: true)
                onResize?(windowSize)
                if play && entry.isMedia && !browser.userPausedPlayback {
                    _ = try await browser.action(["action": "media", "operation": "play"])
                }
                if let queued = queuedRestoreAction {
                    queuedRestoreAction = nil
                    queued()
                }
                saveSession(force: true)
                if !hasCustomSurface { adaptive.changed() }
                Diagnostics.record("session_restored", ["reusedUI": hasCustomSurface, "playing": isPlaying])
            } catch {
                guard revision == restoreRevision else { return }
                browser.setRestorationHeld(false)
                await browser.applyPlaybackPolicy()
                guard revision == restoreRevision, self.browser === browser else { return }
                restoringSession = false
                queuedRestoreAction = nil
                if !Task.isCancelled { webError = "Could not restore this page. Open it to retry." }
            }
        }
    }
    func clearRecentSessions() {
        cancelRestoration()
        sessions.clear()
        recentSessions = []
        history = []
        preferences.removeObject(forKey: "history")
    }
}
