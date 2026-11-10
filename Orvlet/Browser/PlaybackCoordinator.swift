import Foundation

/// Audio ownership is independent of semantic task routing. The next owner is
/// released only after every other source has acknowledged its playback hold.
@MainActor
final class PlaybackCoordinator {
    private struct Source { weak var browser: BrowserController? }
    private var sources: [UUID: Source] = [:]
    private var revision = 0
    private(set) var owner: UUID?

    func register(_ browser: BrowserController) {
        sources[browser.id] = Source(browser: browser)
    }

    func remove(_ browser: BrowserController) {
        sources[browser.id] = nil
        if owner == browser.id {
            owner = nil
            revision += 1
        }
    }

    func acquire(_ browser: BrowserController) async throws {
        try Task.checkCancellation()
        guard !browser.disposed else { throw CancellationError() }
        if owner == browser.id && !browser.audioFocusHeld {
            await browser.applyPlaybackGate()
            try Task.checkCancellation()
            guard owner == browser.id else { throw CancellationError() }
            return
        }
        revision += 1
        let ticket = revision
        owner = nil
        sources = sources.filter { $0.value.browser != nil }
        let others = sources.values.compactMap(\.browser).filter { $0 !== browser && !$0.disposed }
        browser.setAudioFocusHeld(true)
        for source in others {
            source.setAudioFocusHeld(true)
        }
        for source in others {
            await source.applyPlaybackGate()
            Diagnostics.record("audio_focus_paused", ["taskID": source.id.uuidString, "revision": ticket])
        }
        try Task.checkCancellation()
        guard ticket == revision, !browser.disposed else { throw CancellationError() }
        owner = browser.id
        browser.setAudioFocusHeld(false)
        await browser.applyPlaybackGate()
        try Task.checkCancellation()
        guard ticket == revision, owner == browser.id else { throw CancellationError() }
        Diagnostics.record("audio_focus_acquired", ["taskID": browser.id.uuidString, "revision": ticket])
    }
}
