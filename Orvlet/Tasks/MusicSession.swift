import Foundation

struct MusicTrack: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var subtitle: String = ""
    var durationLabel: String = ""
    var verifiedArtist: Bool? = nil
    var isLive: Bool? = nil
    var url: String { "https://www.youtube.com/watch?v=" + id }

    static func videoID(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased(),
            ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host)
        else { return nil }
        let value =
            host == "youtu.be"
            ? String(url.path.dropFirst())
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        guard let value, value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

/// Queue entries are chosen tracks, never alternate search results for the same song.
struct MusicQueue: Codable, Equatable {
    var current: MusicTrack?
    var upcoming: [MusicTrack] = []
    var previous: [MusicTrack] = []
    var repeatOne = false
    var volume: Double = 1
    var muted = false

    mutating func append(_ tracks: [MusicTrack], next: Bool = false) {
        var seen = Set(upcoming.map(\.id))
        if let current { seen.insert(current.id) }
        let additions = tracks.filter { seen.insert($0.id).inserted }
        upcoming = Array((next ? additions + upcoming : upcoming + additions).prefix(50))
    }
    mutating func select(_ track: MusicTrack) {
        if let current, current.id != track.id { previous = Array((previous + [current]).suffix(30)) }
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
        videoID = MusicTrack.videoID(data["url"] as? String ?? "")
    }
    static func time(_ seconds: Double) -> String {
        let n = Int(max(0, seconds.isFinite ? seconds : 0))
        return n >= 3600
            ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
}

extension SideTask {
    var usesMusicCard: Bool {
        isMediaTask && customCompact != true && MusicTrack.videoID(sourceURL ?? "") != nil
    }
}
