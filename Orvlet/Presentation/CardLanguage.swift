import Foundation
import NaturalLanguage

extension CardMarkup {
    nonisolated static func localeIdentifier(for preference: String) -> String? {
        let name = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = Locale(identifier: "en")
        switch name.lowercased() {
        case "english": return "en"
        case "简体中文", "简体", "中文（简体）", "simplified chinese", "chinese (simplified)": return "zh-Hans"
        case "繁體中文", "繁體", "中文（繁體）", "traditional chinese", "chinese (traditional)": return "zh-Hant"
        default: break
        }
        if name.range(of: #"^[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})+$"#, options: .regularExpression) != nil {
            return name.replacingOccurrences(of: "_", with: "-")
        }
        return Locale.LanguageCode.isoLanguageCodes.first { code in
            [code.identifier, english.localizedString(forLanguageCode: code.identifier),
             Locale.current.localizedString(forLanguageCode: code.identifier),
             Locale(identifier: code.identifier).localizedString(forLanguageCode: code.identifier)]
                .compactMap { $0 }.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }?.identifier
    }

    /// Names and quoted values can use a different language from the interface labels.
    func validateLanguage(_ preference: String, path: String = "$.markup") throws {
        let name = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = Locale(identifier: "en")
        guard let id = Self.localeIdentifier(for: name), let language = Locale(identifier: id).language.languageCode?.identifier else { return }
        let pattern = #"<(?:label|button|th|caption|figcaption|small)\b[^>]*>\s*(?:<span\b[^>]*>\s*)?([^<>]+)"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let labels = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
        let copy = labels.joined(separator: ". ")
        guard Set(labels).count >= 2, copy.filter(\.isLetter).count >= 10 else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(copy)
        let candidates = recognizer.languageHypotheses(withMaximum: 3)
        guard let detected = candidates.max(by: { $0.value < $1.value }), detected.value >= 0.85,
            let base = Locale(identifier: detected.key.rawValue).language.languageCode?.identifier, base != language else { return }
        throw ToolArgumentError(path: path, issue: "The interface labels read as " + (english.localizedString(forLanguageCode: base) ?? base) + ". Use " + name + " for the title, capsule subject, controls, column headings and generated display strings. Preserve proper names, data and bindings.")
    }
}
