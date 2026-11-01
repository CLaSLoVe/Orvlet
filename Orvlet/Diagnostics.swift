import Foundation

@MainActor
enum Diagnostics {
    static var file: URL?
    static var started = Date()
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard let file else { return }
        var entry = fields
        entry["event"] = event
        entry["elapsed"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data("\n".utf8))
    }
    static func begin(_ path: String) {
        file = URL(fileURLWithPath: path); started = Date()
        try? Data().write(to: file!, options: .atomic)
    }
}
