import Foundation

/// Bounded scalar state returned by local code, independent of any rendered surface.
nonisolated enum TaskValues {
    static func decode(_ result: [String: Any]) throws -> [String: String] {
        let source = result["state"] as? [String: Any] ?? result
        guard source.count <= 64 else {
            throw AppError.message("The calculation returned too many interface values.")
        }
        var state: [String: String] = [:]
        for (key, value) in source {
            let text: String
            if let value = value as? String {
                text = value
            } else if let value = value as? NSNumber {
                text = value.stringValue
            } else if value is NSNull {
                text = ""
            } else {
                continue
            }
            guard text.utf8.count <= 16000 else {
                throw AppError.message("A calculation value is too long for a task card.")
            }
            state[key] = text
        }
        return state
    }
}
