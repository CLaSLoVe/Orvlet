import Foundation

struct SavedSession: Codable, Identifiable {
    var url: String
    var title: String
    var plan: SurfacePlan?
    var position: Double = 0
    var volume: Double = 1
    var mediaType: String = ""
    var listening = false
    var wasPlaying = false
    var updated = Date()
    var id: String { url }
    var isMedia: Bool { listening || plan?.hasMediaControls == true }
}

@MainActor
final class SessionStore {
    private(set) var entries: [SavedSession] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "sessions.v1"),
            let saved = try? JSONDecoder().decode([SavedSession].self, from: data)
        {
            entries = saved.filter {
                Self.validURL($0.url) && $0.position.isFinite && $0.position >= 0 && $0.volume.isFinite
                    && (0...1).contains($0.volume)
            }.prefix(24).map { $0 }
        }
    }
    static func validURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""),
            url.host != nil, url.user == nil, url.password == nil
        else { return false }
        return true
    }
    func get(_ url: String) -> SavedSession? { entries.first { $0.url == url } }
    var storedBytes: Int { defaults.data(forKey: "sessions.v1")?.count ?? 0 }
    func put(_ entry: SavedSession) {
        guard Self.validURL(entry.url), entry.position.isFinite, entry.position >= 0, entry.volume.isFinite,
            (0...1).contains(entry.volume)
        else { return }
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(24))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "sessions.v1") }
    }
    func clear() {
        entries = []
        defaults.removeObject(forKey: "sessions.v1")
    }
}
