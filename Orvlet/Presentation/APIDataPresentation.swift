import Foundation

extension APIDataSpec {
    static let genericDataCSS =
        ".data-result{display:grid;gap:10px}.data-inputs{display:flex;flex-wrap:wrap;gap:10px}.data-input{display:grid;gap:5px;flex:1 1 85px;min-width:0}.data-input input,.data-input select{width:100%;min-width:0}.data-input span,.data-row>span,footer{font-size:11px;color:var(--muted)}.data-row{display:flex;align-items:baseline;justify-content:space-between;gap:14px}.data-row strong{font-size:24px;font-variant-numeric:tabular-nums}footer{display:grid;gap:4px;margin-top:4px}footer button{justify-self:end}"
    @MainActor
    func surface(title: String, state: [String: String], proposed: CardMarkup? = nil) throws -> TaskSurface {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var source = withWeatherControls
        source.card = source.resolvedCard
        source.controls = source.cardControls
        let roles = source.currencyFields
        let usesPreset =
            source.card != nil && customLayout != true
            && (card != nil || proposed == nil || proposed?.html.contains("class='data-result'") == true
                || proposed?.html.contains("data-preset") == true)
        let rows = source.displayRows
        let primary = rows.first(where: { $0.key == source.card?.primaryKey }) ?? rows.last!
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
        let content = rows.map { row in
            "<div class='data-row'><span>" + escape(row.label) + "</span><strong><span data-bind='" + row.key
                + "'></span>"
                + (row.unitKey.map { "&nbsp;<span data-bind='" + $0 + "'></span>" } ?? row.unit.map { " " + escape($0) }
                    ?? "")
                + "</strong></div>"
        }.joined()
        let footer =
            "<small data-bind='resultStatus'></small><footer><span data-bind='sourceHost'></span><span data-bind='sourceDate'></span><button class='calm-secondary' data-action='refreshData' aria-label='Refresh data'>Refresh</button></footer>"
        let compact =
            "<strong data-bind='" + primary.key + "'></strong>&nbsp;"
            + (primary.unitKey.map { "<span data-bind='" + $0 + "'></span>" } ?? "<span>" + escape(primary.label)
                + "</span>")
        let fallback =
            source.card.map {
                BuiltinCards.data(
                    $0, rows: rows, inputs: inputHTML, footer: footer, swap: source.supportsCurrencySwap,
                    dateKey: source.weatherDateKey, conditionKey: source.weatherConditionKey,
                    lowKey: source.weatherLowKey)
            }
            ?? CardMarkup(
                html: "<section class='data-result'><div class='data-inputs'>" + inputHTML.joined() + "</div>" + content
                    + footer
                    + "</section>", compactHTML: compact,
                css: Self.genericDataCSS
            )
        var surface = TaskSurface(
            title: usesPreset
                ? (source.card?.kind == .currency ? "Currency converter" : "Weather") : String(title.prefix(120)),
            markup: fallback, fields: source.inputControls.map(\.key),
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
            if !markup.bindingKeys.isSuperset(of: ["sourceHost", "sourceDate", "resultStatus"]) {
                markup.html += footer
            }
            surface.markup = markup
            if let validated = try? surface.validated(), !primary.key.isEmpty,
                markup.bindingKeys.contains(primary.key),
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
            surface.markup = fallback
        }
        return try surface.validated()
    }
}
