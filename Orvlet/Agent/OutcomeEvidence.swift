import Foundation

/// Criteria are interpreted from the human request before execution. Completion
/// checks read the source again; generated titles and model prose are not evidence.
struct OutcomeRequirement: Codable {
    var label: String
    var anyOf: [String]
    var inputKey: String? = nil
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": [
                "type": "string",
                "description": "Requested source property, such as location, entity, currency, date or filter",
            ],
            "inputKey": [
                "type": "string",
                "description":
                    "Only for a supplied parameter: its declared method input key. Omit for facts to verify from the source.",
            ],
            "anyOf": [
                "type": "array", "items": ["type": "string"],
                "description":
                    "Equivalent source values for this identity. Include canonical identifiers/codes from the declared method options, not only display names or translations. Never include a different value or a generic term.",
            ],
        ], "required": ["label", "anyOf"],
    ]
    func validated() -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !anyOf.isEmpty && anyOf.count <= 8
            && anyOf.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 }
    }
}

enum OutcomeEvidence {
    static func matches(_ text: String, expected: String) -> Bool {
        let value = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let target = expected.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard !target.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: target)
        return value.range(of: "(?<![a-z0-9])" + escaped + "(?![a-z0-9])", options: .regularExpression) != nil
    }
    static func verify(
        _ requirements: [OutcomeRequirement], evidence: [[String: Any]], observation: [String: Any], plan: SurfacePlan?
    ) throws {
        guard !requirements.isEmpty else { return }
        let readables = observation["readables"] as? [[String: Any]] ?? []
        for (index, requirement) in requirements.enumerated() {
            guard let proof = evidence.first(where: { ($0["requirement"] as? Int) == index }),
                let key = proof["readingKey"] as? String,
                let reading = plan?.readings?.first(where: { $0.key == key }),
                let source = readables.first(where: { $0["selector"] as? String == reading.selector }),
                let text = source["text"] as? String,
                ["primary", "selected"].contains(source["evidenceRole"] as? String ?? ""),
                let valueKey = proof["valueKey"] as? String, valueKey != key,
                let valueReading = plan?.readings?.first(where: { $0.key == valueKey }),
                let value = readables.first(where: { $0["selector"] as? String == valueReading.selector }),
                let scope = source["scopeSelector"] as? String,
                scope == value["scopeSelector"] as? String,
                value["evidenceRole"] as? String != "navigation",
                !(value["text"] as? String ?? "").isEmpty,
                requirement.anyOf.contains(where: { matches(text, expected: $0) })
            else {
                throw AppError.message(
                    "The source has not verified the requested \(requirement.label). Change the actual source/filter first, observe it, bind its primary/selected identifying label as readingKey and actual result as valueKey within the same source region, and provide outcomeEvidence. Navigation links and related suggestions do not identify the active result. Editing a card title or inserting the requested text is not evidence."
                )
            }
        }
    }
}
