import Foundation
import CryptoKit

enum MusicSessionRole: String, Codable { case shared, independent }

struct MusicTrack: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var subtitle: String = ""
    var durationLabel: String = ""
    var verifiedArtist: Bool? = nil
    var isLive: Bool? = nil
    var searchQuery: String?
    var styleSelection: Bool?
    var url: String { "https://www.youtube.com/watch?v=" + id }

    static func videoID(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased(),
            ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host)
        else { return nil }
        let value =
            host == "youtu.be"
            ? String(url.path.dropFirst())
            : (["embed", "live", "shorts"].contains(url.pathComponents.dropFirst().first ?? "") ? url.lastPathComponent :
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value)
        guard let value, value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

/// A source becomes eligible again when its media timeline advances.
@MainActor
final class PlaybackSourceMemory {
    private struct State: Codable {
        var failed = Set<String>()
        var tracks: [String: MusicTrack] = [:]
        var media: [String: String] = [:]
    }

    private let defaults: UserDefaults
    private let key = "playbackSources.v2"
    private var state: State

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
            let legacy = "mediaSourceCooldowns.v1"
            if let old = defaults.dictionary(forKey: legacy) {
                state.failed = Set(old.keys)
                save()
                defaults.removeObject(forKey: legacy)
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identity(_ raw: String) -> String? {
        guard SessionStore.validURL(raw), var url = URLComponents(string: raw) else { return nil }
        url.host = url.host?.lowercased()
        let identity = MusicTrack.videoID(raw).map { "youtube:" + $0 } ?? url.string ?? raw
        return digest(identity)
    }
    func recordPlayerFailure(_ observation: [String: Any]) {
        guard observation["playbackFailed"] as? Bool == true, let page = observation["url"] as? String else { return }
        if MusicTrack.videoID(page) == nil, let file = observation["activeMediaSource"] as? String, SessionStore.validURL(file) {
            record(file)
        } else {
            record(page)
        }
    }

    func avoids(_ url: String) -> Bool {
        guard !state.failed.isEmpty, let id = Self.identity(url) else { return false }
        return state.failed.contains(id)
    }
    func avoidsLink(_ href: String?, on page: String) -> Bool {
        guard !state.failed.isEmpty, let href, !href.isEmpty, let base = URL(string: page),
            let resolved = URL(string: href, relativeTo: base)?.absoluteURL else { return false }
        return avoids(resolved.absoluteString)
    }
    @discardableResult func record(_ url: String) -> Bool {
        guard let id = Self.identity(url), state.failed.insert(id).inserted else { return false }
        save()
        return true
    }

    private func queryKey(_ query: String) -> String {
        let normalized = query.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return Self.digest(normalized)
    }
    private func trackKey(_ track: MusicTrack) -> String {
        if track.styleSelection == true {
            return "style." + queryKey(track.searchQuery ?? track.title) + "." + track.id
        }
        return "video." + track.id
    }
    func preferredSong(_ query: String) -> MusicTrack? {
        guard var saved = state.tracks["song." + queryKey(query)], !avoids(saved.url) else { return nil }
        saved.searchQuery = query
        saved.styleSelection = false
        return saved
    }
    func preferredReplacement(for requested: MusicTrack) -> MusicTrack? {
        var next = requested
        var seen = Set([requested.id])
        while var saved = state.tracks[trackKey(next)], seen.insert(saved.id).inserted {
            saved.searchQuery = requested.searchQuery
            saved.styleSelection = requested.styleSelection
            if !avoids(saved.url) { return saved }
            next = saved
        }
        if requested.styleSelection == false, let query = requested.searchQuery { return preferredSong(query) }
        return nil
    }
    func verified(_ candidate: MusicTrack, for requested: MusicTrack) {
        var saved = candidate
        saved.searchQuery = nil
        saved.styleSelection = nil
        var keys: [String] = []
        if candidate.id != requested.id { keys.append(trackKey(requested)) }
        if requested.styleSelection == false, let query = requested.searchQuery { keys.append("song." + queryKey(query)) }
        let changes = keys.filter { state.tracks[$0] != saved }
        for key in changes { state.tracks[key] = saved }
        if !changes.isEmpty { save() }
    }
    func preferredMedia(for failed: String, among candidates: [String]) -> String? {
        guard var id = Self.identity(failed) else { return nil }
        var seen = Set([id])
        while let next = state.media[id], seen.insert(next).inserted {
            if !state.failed.contains(next) { return candidates.first { Self.identity($0) == next } }
            id = next
        }
        return nil
    }
    func verifiedMedia(_ url: String, replacing failed: String) {
        guard let id = Self.identity(failed), let target = Self.identity(url), id != target,
            state.media[id] != target else { return }
        state.media[id] = target
        save()
    }

    func play(_ requested: MusicTrack, replacement: (MusicTrack) async throws -> MusicTrack,
              attempt: (MusicTrack) async throws -> Void) async throws {
        var candidate = requested
        var tried = Set<String>()
        for _ in 0..<3 {
            try Task.checkCancellation()
            if avoids(candidate.url) {
                if let known = preferredReplacement(for: requested) { candidate = known }
                else { candidate = try await replacement(requested) }
            }
            try Task.checkCancellation()
            guard !avoids(candidate.url), tried.insert(candidate.id).inserted else { throw PlaybackSourceUnavailable() }
            do {
                try await attempt(candidate)
                try Task.checkCancellation()
                verified(candidate, for: requested)
                return
            } catch is PlaybackSourceUnavailable {
                try Task.checkCancellation()
                record(candidate.url)
            }
        }
        throw PlaybackSourceUnavailable()
    }
    func recovered(_ url: String) {
        guard !state.failed.isEmpty, let id = Self.identity(url), state.failed.remove(id) != nil else { return }
        save()
    }
}

struct PlaybackSourceUnavailable: LocalizedError {
    var errorDescription: String? { "This playback source reported an error. Choose another source for the same request." }
}

/// Queue entries are chosen tracks, never alternate search results for the same song.
struct MusicQueue: Codable, Equatable {
    static let upcomingLimit = 50
    static let historyLimit = 30
    var current: MusicTrack?
    var upcoming: [MusicTrack] = []
    var previous: [MusicTrack] = []
    var repeatOne = false
    var volume: Double = 1
    var muted = false

    func matchingReplacement(for track: MusicTrack, available: (MusicTrack) -> Bool) -> MusicTrack? {
        guard track.styleSelection == true, let query = track.searchQuery else { return nil }
        return upcoming.first { $0.id != track.id && $0.styleSelection == true && $0.searchQuery == query && available($0) }
    }
    mutating func append(_ tracks: [MusicTrack], next: Bool = false) {
        var seen = Set(upcoming.map(\.id))
        if let current { seen.insert(current.id) }
        let additions = tracks.filter { seen.insert($0.id).inserted }
        upcoming = Array((next ? additions + upcoming : upcoming + additions).prefix(Self.upcomingLimit))
    }
    mutating func select(_ track: MusicTrack) {
        if let current, current.id != track.id { previous = Array((previous + [current]).suffix(Self.historyLimit)) }
        upcoming.removeAll { $0.id == track.id }
        current = track
    }
    mutating func back() -> MusicTrack? {
        guard let track = previous.popLast() else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = track
        return track
    }
}

struct MusicPlayback: Equatable {
    var title = ""
    var subtitle = ""
    var position: Double = 0
    var duration: Double = 0
    var volume: Double = 1
    var muted = false
    var looping = false
    var playing = false
    var ready = false
    var seekable = false
    var ad = false
    var ended = false
    var live = false
    var videoID: String?
    var sourceURL: String?

    init(_ data: [String: Any] = [:]) {
        title = data["title"] as? String ?? ""
        subtitle = data["artist"] as? String ?? data["channel"] as? String ?? ""
        position = max(0, data["currentTime"] as? Double ?? 0)
        duration = max(0, data["duration"] as? Double ?? 0)
        if !position.isFinite { position = 0 }
        if !duration.isFinite { duration = 0 }
        volume = min(1, max(0, data["volume"] as? Double ?? 1))
        muted = data["muted"] as? Bool == true
        looping = data["looping"] as? Bool == true
        playing = data["playing"] as? Bool == true
        ready = data["hasMedia"] as? Bool == true
        ad = data["adPlaying"] as? Bool == true
        ended = data["ended"] as? Bool == true
        live = data["live"] as? Bool == true
        seekable = data["seekable"] as? Bool == true && duration > 0 && !ad
        sourceURL = data["url"] as? String
        videoID = MusicTrack.videoID(sourceURL ?? "")
    }
    func endTimeLabel(showRemaining: Bool, position: Double) -> String {
        if !showRemaining { return Self.time(duration) }
        return "−" + Self.time(ceil(max(0, duration - position)))
    }

    static func time(_ seconds: Double) -> String {
        let n = Int(max(0, seconds.isFinite ? seconds : 0))
        return n >= 3600
            ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
}

extension SideTask {
    var isMusicSession: Bool {
        guard kind == .web, prefersSource != true else { return false }
        if musicSessionRole != nil { return true }
        guard listening == true else { return false }
        if let queue = musicQueue {
            // Discovery supplies these fields even when false. Passive page observations do not.
            let tracks = [queue.current].compactMap { $0 } + queue.upcoming + queue.previous
            if tracks.contains(where: { $0.verifiedArtist != nil || $0.isLive != nil }) { return true }
        }
        return false
    }

    var usesMusicCard: Bool {
        isMediaTask && customCompact != true
    }
}

extension AppModel {
    func reusableMusicSession(preferred: UUID?, eligible: Set<UUID>? = nil) -> SideTask? {
        let candidates = sideTasks.filter { task in
            guard task.isMusicSession, task.terminalLabel == nil, eligible?.contains(task.id) != false else { return false }
            if let view = work.view(task.id) {
                if view.closed == true { return false }
                if let native = work.artifact(view.selected)?.native, native.id != task.id { return false }
            }
            return true
        }
        if let preferred, let choice = candidates.first(where: { $0.id == preferred }) { return choice }
        let shared = candidates.filter { $0.musicSessionRole != .independent }
        return shared.first(where: { $0.playing }) ?? shared.first(where: { $0.id == preferredMediaTaskID })
            ?? shared.first(where: { $0.id == browser.id })
            ?? shared.first(where: { !$0.hidden }) ?? shared.first
    }
}
