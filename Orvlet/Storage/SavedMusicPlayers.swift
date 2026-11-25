import Foundation

extension AppModel {
    /// Restore multiple confirmed music requests into one shelf player without
    /// losing their queues, custom views or original results in history.
    func consolidateSavedMusicPlayers() -> [UUID] {
        let candidates = sideTasks.indices.filter { index in
            let task = sideTasks[index]
            guard task.isMusicSession, task.musicSessionRole != .independent, task.customCompact != true,
                  task.prefersSource != true, task.savedQueueTrack != nil else { return false }
            guard let view = work.view(task.id) else { return true }
            return view.closed != true && view.layout == .single && view.markup == nil
                && work.artifact(view.selected)?.native?.id == task.id
                && !work.snapshot.views.values.contains {
                    $0.id != task.id && $0.closed != true && $0.artifacts.contains(view.selected)
                }
        }
        guard candidates.count > 1 else { return [] }

        func preferred(_ a: Int, _ b: Int) -> Bool {
            let left = sideTasks[a], right = sideTasks[b]
            if left.playing != right.playing { return left.playing }
            let leftHidden = work.view(left.id)?.hidden ?? left.hidden
            let rightHidden = work.view(right.id)?.hidden ?? right.hidden
            if leftHidden != rightHidden { return !leftHidden }
            if left.created != right.created { return left.created > right.created }
            return left.id.uuidString < right.id.uuidString
        }
        let ordered = candidates.sorted(by: preferred)
        let owner = ordered[0]
        var queue = sideTasks[owner].musicQueue ?? MusicQueue()
        queue.current = sideTasks[owner].savedQueueTrack
        var retired: [UUID] = []
        for index in ordered.dropFirst() {
            let task = sideTasks[index]
            guard let track = task.savedQueueTrack else { continue }
            let other = task.musicQueue ?? MusicQueue()
            var pending = Set(queue.upcoming.map(\.id))
            if let current = queue.current { pending.insert(current.id) }
            let additions = ([track] + other.upcoming).filter { pending.insert($0.id).inserted }
            var history = Set(queue.previous.map(\.id))
            let older = other.previous.filter { history.insert($0.id).inserted }
            // Keep a separate view if the complete queue would not fit.
            guard queue.upcoming.count + additions.count <= MusicQueue.upcomingLimit,
                  queue.previous.count + older.count <= MusicQueue.historyLimit else { continue }
            queue.upcoming += additions
            queue.previous = older + queue.previous
            retired.append(task.id)
        }
        guard !retired.isEmpty else { return [] }
        var updated = sideTasks
        updated[owner].musicQueue = queue
        guard let encoded = try? shelfArchive.encoded(updated) else { return [] }
        // Persist the combined queue first. An interrupted migration can safely
        // repeat the union before closing the remaining duplicate views.
        preferences.set(encoded, forKey: "sideTasks.v1")
        sideTasks = updated
        return retired
    }
}

private extension SideTask {
    var savedQueueTrack: MusicTrack? {
        guard let id = MusicTrack.videoID(sourceURL ?? "") else { return nil }
        if let current = musicQueue?.current { return current.id == id ? current : nil }
        return MusicTrack(id: id, title: title)
    }
}
