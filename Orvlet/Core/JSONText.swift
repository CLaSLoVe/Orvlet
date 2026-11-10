import Foundation

/// Stable JSON text for prompts, bridge messages and diagnostic metadata.
nonisolated enum JSONText {
    static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
