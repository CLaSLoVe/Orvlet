#if DEBUG
import Foundation

@MainActor
enum SavedMusicPlayerCheck {
    static func run() throws -> [String] {
        var checks: [String] = []
        let suite = "orvlet-player-restoration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func track(_ number: Int) -> MusicTrack {
            MusicTrack(id: String(format: "%011d", number), title: UUID().uuidString, verifiedArtist: false)
        }
        func player(_ track: MusicTrack) -> SideTask {
            var task = SideTask(kind: .web, title: track.title)
            task.sourceURL = track.url
            task.musicQueue = MusicQueue(current: track)
            task.listening = true
            return task
        }
        let songs = (1...8).map(track)
        var owner = player(songs[0])
        owner.playing = true
        owner.musicQueue?.volume = 0.43
        owner.musicQueue?.upcoming = [songs[1]]
        var old = player(songs[2])
        old.hidden = true
        old.musicQueue?.previous = [songs[3]]
        old.musicQueue?.upcoming = [songs[1], songs[4]]
        var separate = player(songs[5])
        separate.musicSessionRole = .independent
        var video = player(songs[6])
        video.musicQueue?.current?.verifiedArtist = nil
        video.prefersSource = true
        var custom = player(songs[7])
        custom.customCompact = true
        let source = [old, custom, separate, owner, video]
        defaults.set(try SavedTaskList().encoded(source), forKey: "sideTasks.v1")

        let first = AppModel(defaults: defaults)
        first.isLiveTest = true
        first.loadSideTasks()
        let queue = first.listedTasks.first { $0.id == owner.id }?.musicQueue
        try StateMachineCheck.require(queue?.current == songs[0] && queue?.volume == 0.43
            && queue?.upcoming == [songs[1], songs[2], songs[4]] && queue?.previous == [songs[3]],
            "Restoration keeps the playing track, settings, pending order and history across duplicate music views", &checks)
        try StateMachineCheck.require(Set(first.listedTasks.map(\.id)) == Set([custom, separate, owner, video].map(\.id))
            && first.work.view(old.id)?.closed == true && !first.listedTasks.contains(where: { $0.playing }),
            "Restoration preserves independent players, video pages and custom views without starting playback", &checks)
        let next = AppModel(defaults: defaults)
        next.isLiveTest = true
        next.loadSideTasks()
        try StateMachineCheck.require(next.listedTasks.count == first.listedTasks.count
            && next.listedTasks.first { $0.id == owner.id }?.musicQueue == queue,
            "A second launch keeps the same player identity and does not append the tracks twice", &checks)

        // Cancel synchronously, before restoration can issue a navigation.
        next.restoreSessionOnLaunch(SavedSession(url: old.sourceURL!, title: old.title))
        try StateMachineCheck.require(!next.restoringSession, "Startup leaves retired page sessions closed", &checks)
        next.restoreSessionOnLaunch(SavedSession(url: owner.sourceURL! + "&t=3", title: owner.title))
        try StateMachineCheck.require(next.browser.id == owner.id && next.restoringSession,
            "A legacy session reattaches to its original shelf player before navigation", &checks)
        next.cancelRestoration()
        next.browser.dispose()
        var full = owner
        full.musicQueue?.upcoming = (100..<100 + MusicQueue.upcomingLimit).map(track)
        defaults.set(try SavedTaskList().encoded([old, full]), forKey: "sideTasks.v1")
        defaults.removeObject(forKey: "work.v1")
        let overflow = AppModel(defaults: defaults)
        overflow.isLiveTest = true
        overflow.loadSideTasks()
        try StateMachineCheck.require(overflow.listedTasks.count == 2
            && overflow.listedTasks.first { $0.id == full.id }?.musicQueue == full.musicQueue,
            "A full queue leaves the other player available instead of dropping pending tracks", &checks)
        return checks
    }
}
#endif
