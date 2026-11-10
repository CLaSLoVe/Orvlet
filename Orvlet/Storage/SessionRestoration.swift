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
                mediaType: mediaType, listening: backgroundListening, wasPlaying: isPlaying))
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
                let page: [String: Any]
                if browser.webView.url?.absoluteString == entry.url && !webLoading {
                    page = try await browser.observe()
                } else {
                    browser.webView.load(URLRequest(url: URL(string: entry.url)!, cachePolicy: .useProtocolCachePolicy))
                    page = try await browser.settledObservation(navigation: true)
                }
                var latest = page
                if entry.isMedia {
                    let deadline = Date().addingTimeInterval(8)
                    while (latest["hasMedia"] as? Bool != true || (latest["readyState"] as? Int ?? 0) < 1)
                        && Date() < deadline
                    {
                        try await Task.sleep(for: .milliseconds(200))
                        latest = try await browser.observe()
                    }
                }
                try Task.checkCancellation()
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
                if latest["hasMedia"] as? Bool == true {
                    _ = try? await browser.action(["action": "media", "operation": "volume", "value": entry.volume])
                    if entry.position > 0, let length = latest["duration"] as? Double, length > entry.position {
                        _ = try? await browser.action(["action": "media", "operation": "seek", "value": entry.position])
                    }
                }
                try Task.checkCancellation()
                await browser.webView.pauseAllMediaPlayback()
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
