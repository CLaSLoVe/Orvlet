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
            "compactKey": [
                "type": "string",
                "description":
                    "State key for the compact glance, including a separate computed summary. Choose a short useful result, not long body text.",
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
        let resultsHTML = outputs.map { output in
            "<div class='calm-result'><small class='calm-label'>" + escape(output.label)
                + "</small><strong class='form-value' data-bind='" + output.key + "'></strong></div>"
        }.joined()
        let buttonsHTML = buttons.enumerated().map { index, button in
            "<button class='" + (index == 0 ? "calm-primary" : "calm-secondary") + "' data-action='" + button.action
                + "'>" + escape(button.label) + "</button>"
        }.joined()
        return CardMarkup(
            html: "<section class='calm-surface calm-stack'><div class='calm-fields'>" + fieldsHTML
                + "</div><div class='calm-actions'>" + buttonsHTML + "</div>" + resultsHTML + "</section>",
            compactHTML: "<div class='calm-glance'><strong class='calm-value' data-bind='" + compactKey
                + "'></strong></div>",
            css:
                ".form-wide{grid-column:1/-1}.form-value{font-size:18px;font-weight:600;white-space:pre-wrap;overflow-wrap:anywhere;max-height:110px;overflow:auto;font-variant-numeric:tabular-nums}",
            height: 280)
    }
}
