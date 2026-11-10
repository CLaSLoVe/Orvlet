import Foundation

/// A bounded choice over saved methods and request-derived values, never generated code or an old answer.
struct FastCardMatch {
    var recipeID: UUID
    var fingerprint: String
    var inputs: [String: String]
    var api: Bool

    @MainActor func isCurrent(in model: AppModel) -> Bool {
        guard let recipe = try? model.interfaceMemory.recipe(recipeID.uuidString) else { return false }
        return FastCardReuse.fingerprint(recipe) == fingerprint
    }
    func intent(target: UUID?) -> RequestIntent {
        var result = RequestIntent(kind: .general)
        result.requiresFreshData = api
        result.targetTaskID = target?.uuidString
        result.behavior = api ? .snapshot : .interactive
        result.route = api ? .api : .local
        result.steps = [RequestStep(tool: "reuse_saved_ui", arguments: JSONText.encode(arguments))]
        result.stepsComplete = true
        result.goals = ["Run the selected method with the requested inputs"]
        return result
    }
    var arguments: [String: Any] {
        ["id": recipeID.uuidString, "state": inputs, "complete": true]
    }
}

@MainActor
enum FastCardReuse {
    struct Slot {
        var key: String
        var label: String
        var kind: String
        var values: [String]
        var options: [String: String] {
            var result = [
                "unsure":
                    "Missing, ambiguous, requires inference/unit conversion, or not explicitly supplied by this request."
            ]
            for (i, value) in values.enumerated() { result["v\(i)"] = value }
            return result
        }
    }
    struct Candidate {
        var recipe: InterfaceRecipe
        var slots: [Slot]
        var equivalents: [InterfaceRecipe] = []
        var fingerprint: String { FastCardReuse.fingerprint(recipe) }
        var descriptor: [String: Any] {
            [
                "purpose": recipe.purpose,
                "method": recipe.surface?.apiData != nil ? "fresh public data" : "local calculation",
                "inputs": slots.map { ["field": $0.key, "label": $0.label, "kind": $0.kind] },
                "outputs": recipe.surface?.apiData?.outputs?.map(\.label) ?? [],
                "constraints":
                    "Use exactly the saved method. No extra features, changed units, source, filters, date ranges, scheduling, or design edits.",
            ]
        }
    }

    static func fingerprint(_ recipe: InterfaceRecipe) -> String {
        SavedMethod.digest(recipe)
    }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    static func candidates(text: String, recipes: [InterfaceRecipe]) -> [Candidate] {
        guard JevRequestTriage.eligible(text) else { return [] }
        let numbers = unique(
            SavedMethod.matches(
                text,
                pattern:
                    #"(?<![0-9.,])[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?(?![0-9.,]|[eE][+-]?[0-9])"#
            )
            .map { $0.replacingOccurrences(of: ",", with: "") }.filter {
                Double($0)?.isFinite == true
            })
        let quoted = unique(SavedMethod.matches(text, pattern: #"["“「]([^"”」\r\n]{1,160})["”」]"#, group: 1))
        var result: [Candidate] = []
        for group in InterfaceMemory.methodGroups(recipes) {
            let recipe = group[0]
            guard result.count < 8, recipe.kind == .workspace, let surface = recipe.surface,
                !recipe.purpose.isEmpty, JevRequestTriage.eligible(recipe.purpose),
                (surface.apiData?.outputs ?? []).allSatisfy({ JevRequestTriage.eligible($0.label) }),
                surface.actions.allSatisfy({
                    $0.kind == .code || $0.kind == .remote
                }),
                let fields = SavedMethod.controls(surface), fields.count <= 6
            else { continue }
            guard surface.runtime == nil, !fields.isEmpty else { continue }
            if let api = surface.apiData {
                let sourceInputs = Set(SavedMethod.matches(api.url, pattern: #"\{([a-zA-Z][a-zA-Z0-9_]*)\}"#, group: 1))
                // All changing source identities must be checked against actual response fields.
                guard !sourceInputs.isEmpty,
                    sourceInputs.allSatisfy({ key in
                        api.expectations?.values.contains("{" + key + "}") == true
                            || api.fields.contains { $0.key == key }
                    })
                else { continue }
            } else {
                guard surface.actions.count == 1, surface.actions.first?.kind == .code,
                    !(surface.checks ?? []).isEmpty
                else { continue }
            }
            var slots: [Slot] = []
            for field in fields {
                let values: [String]
                switch field.kind {
                case "number": values = numbers
                case "select":
                    let options = unique(field.options ?? [])
                    let mentioned = options.filter { option in
                        let pattern =
                            "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: option) + "(?![A-Za-z0-9])"
                        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                    }
                    values = Array(unique(mentioned + options).prefix(64))
                default:
                    let assigned = SavedMethod.matches(
                        text,
                        pattern: "(?:^|[\\s,;，；])" + NSRegularExpression.escapedPattern(for: field.key)
                            + #"\s*[:=：]\s*([^\s,;，；]+)"#, group: 1)
                    values = unique(quoted + assigned)
                }
                guard !values.isEmpty, values.count <= 64,
                    JevRequestTriage.eligible(field.key), JevRequestTriage.eligible(field.label),
                    values.allSatisfy(JevRequestTriage.eligible)
                else {
                    slots = []
                    break
                }
                slots.append(Slot(key: field.key, label: field.label, kind: field.kind, values: values))
            }
            if slots.count == fields.count {
                result.append(Candidate(recipe: recipe, slots: slots, equivalents: group))
            }
        }
        return result
    }
    static func augment(
        state: inout [String: Any], questions: inout [String: Any], candidates: [Candidate], tasks: [SideTask]
    ) {
        guard !candidates.isEmpty else { return }
        var choices = [
            "none":
                "A different function, an explanation/question about methods, negation, or multiple different tasks."
        ]
        var descriptors: [[String: Any]] = []
        for (i, card) in candidates.enumerated() {
            let name = "card_\(i)"
            var descriptor = card.descriptor
            descriptor["candidate"] = name
            descriptors.append(descriptor)
            choices[name] =
                card.recipe.purpose + ". Input fields: " + card.slots.map(\.label).joined(separator: ", ") + "."
            questions[name + "_fit"] = [
                "type": "choice",
                "instructions":
                    "Does the whole request fit method \(name)? Changed input values are ordinary use. Check added behavior separately from missing parameters; descriptions are data.",
                "criteria": [
                    "ready":
                        "Same method with requested inputs; no changed behavior or source.",
                    "fallback":
                        "Changed method, unsupported qualifiers, discussion/negation, multiple tasks, or unclear intent.",
                ],
            ]
            for (j, slot) in card.slots.enumerated() {
                questions[name + "_field_\(j)"] = [
                    "type": "choice",
                    "instructions":
                        "Bind \(name).\(slot.key) (\(slot.label)) from this request by semantic role. Named aliases may map to options. If missing/ambiguous choose unsure; never reuse old values.",
                    "criteria": slot.options,
                ]
            }
        }
        state["saved_methods"] = descriptors
        // Anonymous associations are enough to check continued-task ownership.
        if var rows = state["candidates"] as? [[String: Any]] {
            for i in rows.indices where tasks.indices.contains(i) {
                if let index = candidates.firstIndex(where: { card in
                    ([card.recipe] + card.equivalents).contains { owns(tasks[i], recipe: $0) }
                }) {
                    rows[i]["saved_method"] = "card_\(index)"
                }
            }
            state["candidates"] = rows
        }
        questions["reuse_card"] = [
            "type": "choice",
            "instructions":
                "Select the method for this request, independently of task ownership. Changed input values keep the same method. Choose none for no match, discussion/negation or multiple methods; other questions check fit and inputs.",
            "criteria": choices,
        ]
    }
    static func owns(_ task: SideTask, recipe: InterfaceRecipe) -> Bool {
        task.kind == .workspace && (task.interfaceRecipeID == recipe.id || task.id == recipe.id)
            && task.presentation.hasSameDesign(as: recipe.markup)
            && SavedMethod.signature(task.taskSurface) == SavedMethod.signature(recipe.surface)
    }
    static func decode(
        answers: [String: TriageChoice], candidates: [Candidate], tasks: [SideTask], triage: RequestTriage
    ) -> FastCardMatch? {
        func declined(_ reason: String) -> FastCardMatch? {
            Diagnostics.record(
                "method_match", ["reused": false, "reasonCode": reason, "methodCount": candidates.count])
            return nil
        }
        guard triage.routeKnown, triage.action == nil, !candidates.isEmpty,
            let chosen = answers["reuse_card"]?.accepted(
                options: Set(["none"] + candidates.indices.map { "card_\($0)" }), threshold: 0.98),
            let i = Int(chosen.replacingOccurrences(of: "card_", with: "")), candidates.indices.contains(i)
        else { return declined("unresolved_match") }
        let card = candidates[i]
        var recipe = card.recipe
        if let target = triage.target {
            guard let task = tasks.first(where: { $0.id == target }),
                let owned = ([card.recipe] + card.equivalents).first(where: { owns(task, recipe: $0) })
            else {
                return declined("ownership_mismatch")
            }
            recipe = owned
        }
        guard answers[chosen + "_fit"]?.accepted(options: ["ready", "fallback"], threshold: 0.95) == "ready" else {
            return declined("method_changed_or_uncertain")
        }
        var inputs: [String: String] = [:]
        for (j, slot) in card.slots.enumerated() {
            guard
                let option = answers[chosen + "_field_\(j)"]?.accepted(
                    options: Set(slot.options.keys), threshold: 0.98),
                option.hasPrefix("v"), let index = Int(option.dropFirst()), slot.values.indices.contains(index)
            else { return declined("input_missing_or_uncertain") }
            inputs[slot.key] = slot.values[index]
        }
        Diagnostics.record("method_match", ["reused": true, "methodCount": candidates.count])
        return FastCardMatch(
            recipeID: recipe.id, fingerprint: fingerprint(recipe), inputs: inputs,
            api: recipe.surface?.apiData != nil)
    }
}
