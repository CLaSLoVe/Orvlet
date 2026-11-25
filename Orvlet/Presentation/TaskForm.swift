import Foundation

/// A small composition vocabulary, not a catalogue of task-specific templates.
/// Custom markup remains available when these controls do not fit the purpose.
struct TaskForm: Decodable {
    struct Field: Decodable {
        let key: String
        let label: String
        var kind: String?
        var catalog: ChoiceCatalog? = nil
        var optionLabels: [String: String]? = nil
        var options: [String]?
    }
    struct Output: Decodable {
        let key: String
        let label: String
        var sourceAction: String? = nil
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
                        "optionLabels": ["type": "object", "additionalProperties": ["type": "string"], "description": "Labels keyed by canonical option value."],
                        "catalog": ["type": "string", "enum": ChoiceCatalog.allCases.map(\.rawValue)],
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
            "compactSubject": ["type": "string", "maxLength": 40, "description": "Short recognizable object or activity, at most 82px wide. Choose the name that distinguishes this result on the shelf."],
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
        guard id(compactKey), !["title", "status", "detail"].contains(compactKey) else {
            throw ToolArgumentError(path: "$.form.compactKey", issue: "Use a short task-owned output key, not its displayed value or a host key (title, status, detail). Bind that key in outputs and initialize it in state.")
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
                    && ($0.optionLabels ?? [:]).count <= 250 && ($0.optionLabels ?? [:]).allSatisfy({ label($0.key) && label($0.value) })
                    && ($0.kind != "select" || $0.catalog != nil || !($0.options ?? []).isEmpty)
            })
        else { throw AppError.message("Select inputs need nonempty string options, at most 250 short choices.") }
        guard outputs.allSatisfy({ id($0.key) && (label($0.label) || outputs.count == 1 && $0.label.isEmpty && $0.sourceAction == nil) }),
            buttons.allSatisfy({ id($0.action) && label($0.label) })
        else {
            throw AppError.message("Output keys and button action IDs must be valid identifiers with short labels.")
        }
        guard Set(buttons.map(\.action)).count == buttons.count else {
            throw ToolArgumentError(path: "$.form.buttons", issue: "Give distinct choices distinct action IDs and handlers. Clicking sends the action ID and the current fields; the button label is not an input.")
        }
        let fieldsHTML = inputs.map { field in
            let binding = " data-field='" + field.key + "' aria-label=\"" + escape(field.label) + "\""
            let control: String
            switch field.catalog != nil || field.options?.isEmpty == false ? "select" : field.kind ?? "text" {
            case "textarea": control = "<textarea rows='3'" + binding + "></textarea>"
            case "select":
                control =
                    "<select" + binding + (field.options?.isEmpty != false ? field.catalog.map { " data-catalog='" + $0.rawValue + "'" } ?? "" : "") + ">"
                    + (field.options ?? []).map { "<option value=\"" + escape($0) + "\">" + escape(field.optionLabels?[$0] ?? $0) + "</option>" }
                    .joined() + "</select>"
            case "number": control = "<input type='number' step='any'" + binding + ">"
            default: control = "<input type='text'" + binding + ">"
            }
            return "<label class='calm-field" + (field.kind == "textarea" ? " form-wide" : "") + "'>"
                + escape(field.label) + control + "</label>"
        }.joined()
        let ordered = outputs.filter { $0.key == compactKey } + outputs.filter { $0.key != compactKey }
        let resultsHTML = ordered.map { output in
            let heading: String
            if let action = output.sourceAction, id(action) {
                heading = "<button class='calm-secondary' data-action='" + action + "'>" + escape(output.label) + " ↗</button>"
            } else { heading = escape(output.label) }
            let caption = heading.isEmpty ? "" : "<small class='calm-label'>" + heading + "</small>"
            return "<div class='calm-result'>" + caption + "<div><strong class='form-value' data-bind='" + output.key + "'></strong>"
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


// Finite choices use the same rendered controls, persistence and checked action runner as forms.
extension TaskForm {
    static let stateViewSchema: [String: Any] = [
        "type": "object", "description": "A local card with known visible states. Only the current value is displayed. Supply this instead of form, code and checks. First value is initially visible. Each button selects a value or moves through the values.",
        "properties": [
            "subject": ["type": "string", "description": "Name the specific object or activity the human supplied, distinguishing it from another card of the same kind."],
            "compactValues": ["type": "array", "items": ["type": "string"], "description": "Very short visible state for each value. Lead with what changes. Omit the subject already displayed above it, numbering, and commentary."],
            "values": ["type": "array", "description": "When the human supplies content, preserve it verbatim in its original order. Keep short states short. Localize the buttons around it.", "minItems": 2, "maxItems": 32, "items": ["type": "string"]],
            "buttons": ["type": "array", "minItems": 1, "maxItems": 3, "items": [
                "type": "object", "properties": ["label": ["type": "string"],
                    "to": ["type": "string", "description": "Select this exact visible value."],
                    "move": ["type": "string", "enum": ["next", "previous", "cycle", "first"]],
                    "targets": ["type": "array", "items": ["type": "integer"], "description": "Only for other transitions: one zero-based destination per state."]],
                "required": ["label"]]],
        ], "required": ["subject", "values", "buttons"],
    ]

    static func expandingStateView(_ input: [String: Any]) throws -> [String: Any] {
        guard let proposal = input["stateView"] as? [String: Any] else { return input }
        struct View: Decodable {
            struct Button: Decodable {
                let label: String
                let to: String?
                let move: String?
                let targets: [Int]?
            }
            let subject: String
            let values: [String]
            let compactValues: [String]?
            let buttons: [Button]
        }
        let view = try JSONDecoder().decode(View.self, from: JSONSerialization.data(withJSONObject: proposal))
        guard (2...32).contains(view.values.count), (1...3).contains(view.buttons.count),
            view.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 512 })
        else { throw ToolArgumentError(path: "$.stateView", issue: "Supply 2–32 short, nonempty values and 1–3 controls.") }
        let controls = try view.buttons.map { button -> (label: String, targets: [Int]) in
            let indices = view.values.indices
            if let value = button.to {
                let candidates = indices.filter { index in
                    let short = view.compactValues.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    return [view.values[index], short].compactMap { $0 }.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
                }
                if candidates.count == 1, let index = candidates.first {
                    return (button.label, Array(repeating: index, count: indices.count))
                }
            }
            if let targets = button.targets, targets.count == 1, let index = targets.first, indices.contains(index) {
                return (button.label, Array(repeating: index, count: indices.count))
            }
            switch button.move {
            case "next": return (button.label, indices.map { min($0 + 1, indices.count - 1) })
            case "previous": return (button.label, indices.map { max(0, $0 - 1) })
            case "cycle": return (button.label, indices.map { ($0 + 1) % indices.count })
            case "first": return (button.label, Array(repeating: 0, count: indices.count))
            default:
                guard let targets = button.targets, targets.count == indices.count, targets.allSatisfy(indices.contains) else {
                    throw ToolArgumentError(path: "$.stateView.buttons", issue: "For button " + button.label + ", set its to field to one of " + JSONText.encode(view.values) + ", or use move: next, previous, cycle or first.")
                }
                return (button.label, targets)
            }
        }
        var reached: Set<Int> = [0]
        var pending = [0]
        while let index = pending.popLast() {
            for button in controls where reached.insert(button.targets[index]).inserted {
                pending.append(button.targets[index])
            }
        }
        guard reached.count == view.values.count, controls.allSatisfy({ button in
            button.targets.enumerated().contains { view.values[$0.offset] != view.values[$0.element] }
        }) else { throw ToolArgumentError(path: "$.stateView.buttons", issue: "Each control needs a visible effect and all declared states must be reachable from the first value.") }
        guard input["runtime"] == nil, input["initialize"] == nil, (input["actions"] as? [[String: Any]] ?? []).isEmpty else {
            throw ToolArgumentError(path: "$.stateView", issue: "For a local state view use its own transitions. For external effects, scheduling or custom code use a form instead.")
        }
        let compactValues = view.compactValues ?? view.values
        guard compactValues.count == view.values.count, compactValues.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ToolArgumentError(path: "$.stateView.compactValues", issue: "Supply one nonempty short state per value, or omit compactValues.")
        }
        func shortened(_ text: String) -> String {
            let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
            if CardMarkup.fitsGlance(line,width:72) { return line }
            var prefix = ""
            for character in line {
                guard CardMarkup.fitsGlance(prefix + String(character) + "…",width:72) else { break }
                prefix.append(character)
            }
            return prefix + "…"
        }
        // Preserve distinguishable original identities when they fit as short
        // prefixes. A generated short value must not discard the selected object.
        let originalSummaries = view.values.map(shortened)
        let summaries = Set(originalSummaries).count == Set(view.values).count ? originalSummaries : zip(view.values, compactValues).map { full, short in
            if !full.contains(where: { $0.isNewline }), CardMarkup.fitsGlance(full, width: 72) { return full }
            let value = short
            let line = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if CardMarkup.fitsGlance(line, width: 72) { return line }
            var prefix = ""
            for character in line {
                let candidate = prefix + String(character)
                guard CardMarkup.fitsGlance(candidate + "…", width: 72) else { break }
                prefix = candidate
            }
            return prefix + "…"
        }
        guard Set(summaries).count == Set(view.values).count else {
            throw ToolArgumentError(path: "$.stateView.compactValues", issue: "Supply distinct short state labels that remain distinguishable in the capsule.")
        }
        var state = ["items": JSONText.encode(view.values), "summaries": JSONText.encode(summaries),
                     "activeIndex": "0", "currentValue": view.values[0], "summary": summaries[0]]
        var buttons: [[String: String]] = []
        var actions: [[String: String]] = []
        var checks: [[String: Any]] = []
        for (index, button) in controls.enumerated() {
            let id = "select" + String(index + 1)
            let mapKey = id + "Targets"
            state[mapKey] = JSONText.encode(button.targets)
            let code = """
                const items = JSON.parse(state.items);
                const i = JSON.parse(state.\(mapKey))[Number(state.activeIndex)];
                return {state:{activeIndex:String(i), currentValue:items[i], summary:JSON.parse(state.summaries)[i]}};
                """
            buttons.append(["action": id, "label": button.label])
            actions.append(["id": id, "kind": "code", "code": code])
            checks.append(["action": id, "input": [String: String](), "expected": ["currentValue": view.values[button.targets[0]], "summary": summaries[button.targets[0]]]])
        }
        var result = input
        result.removeValue(forKey: "stateView")
        result.removeValue(forKey: "markup")
        result["state"] = state
        result["actions"] = actions
        result["checks"] = checks
        result["form"] = ["inputs": [], "outputs": [["key": "currentValue", "label": ""]],
                          "buttons": buttons, "compactSubject": CardMarkup.shortGlanceSubject(view.subject), "compactKey": summaries == view.values ? "currentValue" : "summary"] as [String: Any]
        return result
    }
}
