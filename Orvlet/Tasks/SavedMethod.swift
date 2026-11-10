import CryptoKit
import Foundation

/// Shared method identity and input contracts. Storage, planning and fast routing
/// use the same definition without depending on a model-specific classifier.
@MainActor
enum SavedMethod {
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func signature(_ surface: TaskSurface?) -> String {
        guard var surface else { return "" }
        surface.title = ""
        // Measured content height belongs to the rendered instance, not the method.
        surface.markup.height = 0
        surface.state = [:]
        surface.runID = nil
        if var api = surface.apiData {
            api.inputs = api.inputs?.mapValues { _ in "" }
            surface.apiData = api
        }
        return digest(surface)
    }
    static func matches(_ text: String, pattern: String, group: Int = 0) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }
    static func controls(_ surface: TaskSurface) -> [APIDataControl]? {
        if let api = surface.apiData { return api.inputControls }
        var result: [APIDataControl] = []
        for key in surface.fields {
            let tags = matches(
                surface.markup.html,
                pattern: "<(?:input|select|textarea)\\b[^>]*\\bdata-field\\s*=\\s*[\"']"
                    + NSRegularExpression.escapedPattern(for: key) + "[\"'][^>]*>")
            guard tags.count == 1, let tag = tags.first else { return nil }
            let label = matches(tag, pattern: #"aria-label\s*=\s*["']([^"']+)["']"#, group: 1).first ?? key
            if tag.lowercased().hasPrefix("<select") {
                let body =
                    matches(
                        surface.markup.html, pattern: NSRegularExpression.escapedPattern(for: tag) + "(.*?)</select>",
                        group: 1
                    ).first ?? ""
                let options = matches(body, pattern: #"<option\b[^>]*\bvalue\s*=\s*["']([^"']+)["']"#, group: 1)
                guard !options.isEmpty else { return nil }
                result.append(APIDataControl(key: key, label: label, kind: "select", options: options))
            } else {
                let type = matches(tag, pattern: #"\btype\s*=\s*["']([^"']+)["']"#, group: 1).first?.lowercased()
                guard type == nil || ["text", "number"].contains(type!) else { return nil }
                result.append(APIDataControl(key: key, label: label, kind: type ?? "text"))
            }
        }
        return result
    }
}

/// A selection and fresh arguments, not a second generated implementation.
struct SavedMethodInvocation: Codable {
    var id: String
    var state: [String: String]
    var outcomeEvidence: [SavedMethodEvidence]?
}
struct SavedMethodEvidence: Codable {
    var requirement: Int
    var fieldKey: String
}
