import Foundation

extension APIDataSpec {
    func readingSummary(title: String, state: [String: String]) -> String {
        guard let primary = displayRows.first(where: { $0.key == card?.primaryKey }) ?? displayRows.first else { return title }
        let value = state[primary.key] ?? "—"
        let unit = (card?.unitKey ?? primary.unitKey).flatMap { state[$0] } ?? primary.unit ?? ""
        let suffix = unit.isEmpty || value.hasSuffix(unit) ? "" : " " + unit
        let date = state["sourceDateDisplay"] ?? state["sourceDate"] ?? ""
        return title + " · " + value + suffix + (date.isEmpty ? "" : " · " + date)
    }

    static let genericDataCSS =
        ".data-result{display:grid;gap:10px}.data-inputs{display:flex;flex-wrap:wrap;gap:10px}.data-input{display:grid;gap:5px;flex:1 1 85px;min-width:0}.data-input input,.data-input select{width:100%;min-width:0}.data-input span,.data-row>span,footer{font-size:11px;color:var(--muted)}.data-row{display:flex;align-items:baseline;justify-content:space-between;gap:14px}.data-row strong{font-size:24px;font-variant-numeric:tabular-nums}footer{display:grid;gap:4px;margin-top:4px}footer button{justify-self:end}"
    @MainActor
    func surface(title: String, state: [String: String], proposed: CardMarkup? = nil, request: String = "") throws -> TaskSurface {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var source = withWeatherControls.bindingVisuals()
        source.card = source.resolvedCard
        source.controls = source.cardControls
        let roles = source.currencyFields
        let usesPreset =
            source.card != nil && customLayout != true
            && (proposed == nil || proposed?.html.contains("class='data-result'") == true
                || proposed?.html.contains("data-preset") == true)
        let rows = source.displayRows
        guard let primary = rows.first(where: { $0.key == source.card?.primaryKey }) ?? rows.first else {
            throw ToolArgumentError(path: "$.source.fields", issue: "provide a scalar reading or calculated output for the capsule")
        }
        if var layout = source.card, layout.kind == .reading {
            layout.resolveReadingSubject(title: title, request: request, state: state, source: source)
            source.card = layout
        }
        if source.card?.detailKeys == nil, source.card?.kind == .reading {
            let hidden = Set((source.expectations ?? [:]).keys)
                .union(source.fields.filter { $0.pointer == source.updatedAtPointer }.map(\.key))
            source.card?.detailKeys = Array(rows.filter { !hidden.contains($0.key) && $0.key != primary.key }.prefix(4).map(\.key))
        }
        let primaryUnit = source.card?.unitKey ?? primary.unitKey
        let inputHTML = source.inputControls.map { control -> String in
            let event =
                control.kind == "select" || source.url.contains("{" + control.key + "}") ? "data-change" : "data-input"
            let attributes =
                " data-field='" + control.key + "' " + event + "='updateData' aria-label=\"" + escape(control.label)
                + "\""
            let element: String
            if control.kind == "select", let options = control.options, !options.isEmpty {
                element =
                    "<select" + attributes + ">"
                    + options.map {
                        "<option value=\"" + escape($0) + "\">" + escape(source.optionLabel($0, for: control.key))
                            + "</option>"
                    }.joined()
                    + "</select>"
            } else {
                element =
                    "<input" + attributes + " type='" + (control.kind == "number" ? "number' step='any" : "text") + "'>"
            }
            let name =
                control.key == roles?.from ? "currencyFromName" : control.key == roles?.to ? "currencyToName" : nil
            let caption = name.map { "<small class='currency-name' data-bind='" + $0 + "'></small>" } ?? ""
            return "<label class='data-input'><span>" + escape(control.label) + "</span>" + element + caption
                + "</label>"
        }
        let refreshLabel = escape(source.refreshLabel ?? (source.usesEnglishPresetCopy ? "Refresh" : "↻"))
        let footer =
            "<small data-bind='resultStatus'></small><footer><span data-bind='sourceHost'></span><span data-bind='sourceDateDisplay'></span><button class='calm-secondary' data-action='refreshData' aria-label='\(refreshLabel)'>\(refreshLabel)</button></footer>"
        let layout = source.card ?? DataCardPreset(kind: .reading, primaryKey: primary.key, subject: title)
        let fallback = BuiltinCards.data(
            layout, rows: rows, inputs: inputHTML, footer: footer, swap: source.supportsCurrencySwap,
            visuals: try CardVisual.markup(source.visuals ?? [], path: "$.source.visuals"), englishPresetCopy: source.usesEnglishPresetCopy, dateKey: source.weatherDateKey, conditionKey: source.weatherConditionKey, lowKey: source.weatherLowKey)
        var standardMarkup = fallback
        standardMarkup.interfaceLanguage = source.interfaceLanguage
        var surface = TaskSurface(
            title: source.usesEnglishPresetCopy && usesPreset && source.card?.kind == .weather ? "Weather"
                : source.usesEnglishPresetCopy && usesPreset && source.card?.kind == .currency ? "Currency converter" : String(title.prefix(120)),
            markup: standardMarkup, fields: source.inputControls.map(\.key),
            actions: [
                TaskSurfaceAction(id: "refreshData", kind: .remote, operation: "refresh"),
                TaskSurfaceAction(id: "updateData", kind: .remote, operation: "update"),
            ], state: source.presentationState(state.merging(source.inputs ?? [:]) { current, _ in current }),
            apiData: source)
        if source.supportsCurrencySwap {
            surface.actions.append(TaskSurfaceAction(id: "swapCurrencies", kind: .remote, operation: "swap"))
        }
        if usesPreset {
            surface.preset = source.card?.kind.rawValue
            return try surface.validated()
        }
        if var markup = proposed {
            if markup.compactHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { markup.compactHTML = fallback.compactHTML }
            // Input behavior belongs to the host even when layout is generated.
            for control in source.inputControls {
                let pattern =
                    "<(?:input|select|textarea)\\b[^>]*\\bdata-field\\s*=\\s*[\"']" + control.key + "[\"'][^>]*>"
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                let mutable = NSMutableString(string: markup.html)
                for match in regex.matches(in: markup.html, range: NSRange(markup.html.startIndex..., in: markup.html))
                    .reversed()
                {
                    let old = mutable.substring(with: match.range)
                    let event =
                        control.kind == "select" || source.url.contains("{" + control.key + "}")
                        ? "data-change" : "data-input"
                    let events = try NSRegularExpression(
                        pattern: #"\s+data-(input|change)\s*=\s*["'][^"']*["']"#, options: .caseInsensitive)
                    if events.numberOfMatches(in: old, range: NSRange(old.startIndex..., in: old)) == 1,
                        old.range(of: "\\s+" + event + #"\s*=\s*["']updateData["']"#, options: .regularExpression)
                            != nil
                    {
                        continue
                    }
                    let stripped = old.replacingOccurrences(
                        of: "\\s+data-(input|change)\\s*=\\s*[\"'][^\"']*[\"']", with: "",
                        options: [.regularExpression, .caseInsensitive])
                    let close = stripped.hasSuffix("/>") ? "/>" : ">"
                    mutable.replaceCharacters(
                        in: match.range,
                        with: String(stripped.dropLast(close.count)) + " " + event + "='updateData'" + close)
                }
                markup.html = mutable as String
            }
            if !markup.bindingKeys.isSuperset(of: ["sourceHost", "resultStatus"])
                || markup.bindingKeys.isDisjoint(with: ["sourceDate", "sourceDateDisplay"]) {
                markup.html += footer
            }
            if layout.kind == .reading { markup.compactHTML = fallback.compactHTML }
            surface.markup = markup
            if let validated = try? surface.validated(), !primary.key.isEmpty,
                CardMarkup.bindingKeys(in: markup.html).contains(primary.key),
                CardMarkup.bindingKeys(in: markup.compactHTML).contains(primary.key),
                primaryUnit == nil
                    || (markup.bindingKeys.contains(primaryUnit!)
                        && CardMarkup.bindingKeys(in: markup.compactHTML).contains(primaryUnit!)),
                source.inputControls.allSatisfy({ control in
                    markup.html.range(
                        of: "data-field\\s*=\\s*[\"']" + control.key + "[\"']", options: .regularExpression) != nil
                })
            {
                var custom = validated
                custom.apiData?.customLayout = true
                return custom
            }
            surface.apiData?.customLayout = nil
            surface.preset = source.card?.kind.rawValue
            surface.markup = standardMarkup
        }
        return try surface.validated()
    }
}
