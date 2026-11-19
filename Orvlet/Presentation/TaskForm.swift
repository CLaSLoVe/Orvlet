import Foundation

/// A small composition vocabulary, not a catalogue of task-specific templates.
/// Custom markup remains available when these controls do not fit the purpose.
struct TaskForm: Decodable {
    struct Field: Decodable {
        let key: String
        let label: String
        var kind: String?
        var options: [String]?
    }
    struct Output: Decodable {
        let key: String
        let label: String
    }
    struct Button: Decodable {
        let action: String
        let label: String
    }
    var inputs: [Field]
    var outputs: [Output]
    var buttons: [Button]
    var visuals: [CardVisual]? = nil
    var compactUnit: String? = nil
    var compactSubject: String? = nil
    var compactKey: String
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "inputs": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"], "label": ["type": "string"],
                        "kind": ["type": "string", "enum": ["text", "number", "textarea", "select"]],
                        "options": ["type": "array", "items": ["type": "string"]],
                    ], "required": ["key", "label", "kind"],
                ],
            ],
            "outputs": [
                "type": "array",
                "items": [
                    "type": "object", "properties": ["key": ["type": "string"], "label": ["type": "string"]],
                    "required": ["key", "label"],
                ],
            ],
            "buttons": [
                "type": "array",
                "items": [
                    "type": "object", "properties": ["action": ["type": "string"], "label": ["type": "string"]],
                    "required": ["action", "label"],
                ],
            ],
            "visuals": CardVisual.schema,
            "compactUnit": ["type": "string", "maxLength": 12, "description": "Unit for a raw numerical compact value, unless the state value already includes it."],
            "compactSubject": ["type": "string", "maxLength": 40, "description": "Short object or activity name in the configured UI language for the capsule, e.g. Studio. Use a name a person recognizes."],
            "compactKey": [
                "type": "string",
                "description":
                    "Use the primary output key with a formatted short value and unit. The capsule has only 82 px: one amount or status, no explanatory sentence. For a long output provide a separate concise summary.",
            ],
        ], "required": ["inputs", "outputs", "buttons", "compactKey"],
    ]

    func markup() throws -> CardMarkup {
        func id(_ value: String) -> Bool {
            value.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,31}$", options: .regularExpression) != nil
        }
        func label(_ value: String) -> Bool { !value.isEmpty && value.count <= 80 }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        guard inputs.count <= 12, (1...6).contains(outputs.count), buttons.count <= 3 else {
            throw AppError.message(
                "A form supports up to 12 inputs, 1–6 outputs and 3 buttons. Use custom markup for a different composition."
            )
        }
        guard Set(inputs.map(\.key)).count == inputs.count, Set(outputs.map(\.key)).count == outputs.count else {
            throw AppError.message("Form input keys and output keys must each be unique.")
        }
        guard id(compactKey) else {
            throw AppError.message(
                "compactKey must be a named state key; its value may be a separate concise summary.")
        }
        guard
            inputs.allSatisfy({
                id($0.key) && label($0.label) && ["text", "number", "textarea", "select"].contains($0.kind ?? "text")
            })
        else {
            throw AppError.message(
                "Form inputs need valid field keys, short labels and text/number/textarea/select kinds.")
        }
        guard
            inputs.allSatisfy({
                ($0.options ?? []).count <= 250 && ($0.options ?? []).allSatisfy(label)
                    && ($0.kind != "select" || !($0.options ?? []).isEmpty)
            })
        else { throw AppError.message("Select inputs need nonempty string options, at most 250 short choices.") }
        guard outputs.allSatisfy({ id($0.key) && label($0.label) }),
            buttons.allSatisfy({ id($0.action) && label($0.label) })
        else {
            throw AppError.message("Output keys and button action IDs must be valid identifiers with short labels.")
        }
        let fieldsHTML = inputs.map { field in
            let binding = " data-field='" + field.key + "' aria-label=\"" + escape(field.label) + "\""
            let control: String
            switch field.kind ?? "text" {
            case "textarea": control = "<textarea rows='3'" + binding + "></textarea>"
            case "select":
                control =
                    "<select" + binding + ">"
                    + (field.options ?? []).map { "<option value=\"" + escape($0) + "\">" + escape($0) + "</option>" }
                    .joined() + "</select>"
            case "number": control = "<input type='number' step='any'" + binding + ">"
            default: control = "<input type='text'" + binding + ">"
            }
            return "<label class='calm-field" + (field.kind == "textarea" ? " form-wide" : "") + "'>"
                + escape(field.label) + control + "</label>"
        }.joined()
        let ordered = outputs.filter { $0.key == compactKey } + outputs.filter { $0.key != compactKey }
        let resultsHTML = ordered.map { output in
            "<div class='calm-result'><small class='calm-label'>" + escape(output.label)
                + "</small><div><strong class='form-value' data-bind='" + output.key + "'></strong>"
                + (output.key == compactKey ? CardMarkup.unitSuffix(compactUnit) : "") + "</div></div>"
        }
        let buttonsHTML = buttons.enumerated().map { index, button in
            "<button class='" + (index == 0 ? "calm-primary" : "calm-secondary") + "' data-action='" + button.action
                + "'>" + escape(button.label) + "</button>"
        }.joined()
        let visualHTML = try CardVisual.markup(visuals ?? [])
        let name = compactSubject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = name.flatMap { $0.isEmpty ? nil : $0 }.map { "<small class='calm-label'>" + escape($0) + "</small>" } ?? "<small class='calm-label' data-bind='title'></small>"
        return CardMarkup(
            html: "<section class='calm-surface calm-stack calm-form'>" + (resultsHTML.first ?? "") + visualHTML
                + "<div class='calm-fields'>" + fieldsHTML + "</div><div class='calm-actions'>" + buttonsHTML
                + "</div><div class='form-details'>" + resultsHTML.dropFirst().joined() + "</div></section>",
            compactHTML: "<div class='calm-glance'>" + subject + "<span><strong class='calm-value' data-bind='" + compactKey
                + "'></strong>" + CardMarkup.unitSuffix(compactUnit) + "</span></div>",
            css:
                ".calm-form .form-details{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.calm-form .form-details:empty,.calm-form .calm-fields:empty,.calm-form figure:not(:has(svg)){display:none}.calm-form>.calm-result .form-value{font-size:26px}.form-details .form-value{font-size:14px}.calm-form .preset-unit-suffix{font-size:12px;margin-left:3px;color:var(--muted)}.form-wide{grid-column:1/-1}.form-value{font-size:18px;font-weight:600;white-space:pre-wrap;overflow-wrap:anywhere;max-height:110px;overflow:auto;font-variant-numeric:tabular-nums}",
            height: 280)
    }
}
