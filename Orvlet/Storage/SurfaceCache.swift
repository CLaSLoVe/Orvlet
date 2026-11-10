import Foundation

struct CachedSurface: Codable {
    var version = 7
    var key: String
    var plan: SurfacePlan
    var updated = Date()
}
@MainActor
final class SurfaceCache {
    var entries: [CachedSurface] = []
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "surfaces.v1"),
            let saved = try? JSONDecoder().decode([CachedSurface].self, from: data)
        {
            entries = saved.filter { $0.version == 7 }
        }
    }
    static func pageKey(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.host != nil, ["https", "http"].contains(url.scheme ?? "") else {
            return nil
        }
        // Content IDs (for example YouTube v=) are part of task identity.
        // A valid action binding does not make another page's factual HTML reusable.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        return components.string
    }
    func get(_ key: String) -> SurfacePlan? { entries.first { $0.key == key }?.plan }
    func put(_ plan: SurfacePlan, key: String) {
        entries.removeAll { $0.key == key }
        entries.insert(CachedSurface(key: key, plan: plan), at: 0)
        entries = Array(entries.prefix(40))
        persist()
    }
    func remove(_ key: String) {
        entries.removeAll { $0.key == key }
        persist()
    }
    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: "surfaces.v1")
    }
    func persist() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "surfaces.v1") } }
}
