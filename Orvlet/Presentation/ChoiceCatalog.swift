import Foundation

/// Only a declared standard (or an unambiguous IANA identifier) supplies a catalogue.
/// Explicit service-specific options always take precedence.
enum ChoiceCatalog: String, Codable, CaseIterable {
    case timeZone, region, currency

    private static let countriesByZone: [String: String] = {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return [:] }
        var countries: [String: String] = [:]
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            if columns.count >= 3 { countries[String(columns[2])] = String(columns[0]) }
        }
        return countries
    }()

    var values: [String] {
        switch self {
        case .timeZone: return TimeZone.knownTimeZoneIdentifiers + ["UTC"]
        case .region: return Locale.Region.isoRegions.map(\.identifier)
        case .currency: return Locale.commonISOCurrencyCodes
        }
    }

    func accepts(_ value: String) -> Bool {
        self == .timeZone ? TimeZone(identifier: value) != nil : values.contains(value)
    }

    func choices(locale: Locale) -> [[String]] {
        Set(values).sorted().map { value in
            switch self {
            case .timeZone:
                let city = (value.split(separator: "/").last.map(String.init) ?? value).replacingOccurrences(of: "_", with: " ")
                let country = Self.countriesByZone[value] ?? ""
                let region = locale.localizedString(forRegionCode: country) ?? ""
                return [value, city, [country, region, value].joined(separator: " ")]
            case .region: return [value, locale.localizedString(forRegionCode: value) ?? value, value]
            case .currency: return [value, value, locale.localizedString(forCurrencyCode: value) ?? value]
            }
        }
    }
}

extension APIDataControl {
    func accepts(_ value: String) -> Bool { catalog?.accepts(value) ?? options?.contains(value) ?? false }
}

extension CardMarkup {
    /// A declared catalogue constrains the control even when a custom layout spells it as an input.
    mutating func resolveCatalogInputs(state: [String: String]) throws {
        guard html.contains("data-catalog") else { return }
        let inputs = try NSRegularExpression(pattern: #"<input\b[^>]*\bdata-field\s*=\s*["']([^"']+)["'][^>]*>"#, options: .caseInsensitive)
        let catalogAttribute = try NSRegularExpression(pattern: #"\bdata-catalog\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        for match in inputs.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range, in: html), let key = Range(match.range(at: 1), in: html) else { continue }
            let element = String(html[range])
            guard let attr = catalogAttribute.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
                let name = Range(attr.range(at: 1), in: element), let catalog = ChoiceCatalog(rawValue: String(element[name])) else { continue }
            guard let value = state[String(html[key])], catalog.accepts(value) else {
                throw ToolArgumentError(path: "$.state", issue: "Choose an initial value from the field's catalogue.")
            }
            let attrs = element.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).dropFirst("<input".count)
            html.replaceSubrange(range, with: "<select" + attrs + "><option value='" + value + "'>" + value + "</option></select>")
        }
    }

    /// Preserve host-owned choice values and action wiring across generated visual edits.
    mutating func preserveChoices(from original: CardMarkup) throws {
        let select = try NSRegularExpression(pattern: #"<select\b[^>]*\bdata-field\s*=\s*["']([^"']+)["'][^>]*>[\s\S]*?</select\s*>"#, options: .caseInsensitive)
        for match in select.matches(in: original.html, range: NSRange(original.html.startIndex..., in: original.html)) {
            guard let keyRange = Range(match.range(at: 1), in: original.html), let range = Range(match.range, in: original.html) else { continue }
            let key = NSRegularExpression.escapedPattern(for: String(original.html[keyRange]))
            let attr = #"\bdata-field\s*=\s*["']"# + key + #"["']"#
            let field = try NSRegularExpression(pattern: #"<(?:select\b[^>]*"# + attr + #"[^>]*>[\s\S]*?</select\s*>|input\b[^>]*"# + attr + #"[^>]*>|textarea\b[^>]*"# + attr + #"[^>]*>[\s\S]*?</textarea\s*>)"#, options: .caseInsensitive)
            let matches = field.matches(in: html, range: NSRange(html.startIndex..., in: html))
            guard matches.count == 1, let replacement = Range(matches[0].range, in: html) else {
                throw ToolArgumentError(path: "$.markup.html", issue: "Keep exactly one bound choice control for " + String(original.html[keyRange]))
            }
            html.replaceSubrange(replacement, with: original.html[range])
        }
    }
}

extension APIDataSpec {
    /// Turn a fixed query value into a bound choice only when the response itself
    /// confirms that parameter's identity. Preserve the host, path and other filters.
    func exposingVerifiedChoices(state: [String: String]) -> Self {
        guard !url.contains("{"), var parts = URLComponents(string: url),
            var query = parts.queryItems, !query.isEmpty else { return self }
        var result = self
        var tokens: [(String,String)] = []
        for index in query.indices {
            let item = query[index]
            guard let value = item.value,
                let proof = expectations?.first(where: { $0.value == value && state[$0.key] == value }),
                query.filter({ $0.name == item.name }).count == 1,
                (result.inputs ?? [:]).count < Self.maximumInputs else { continue }
            let role = item.name.lowercased().filter(\.isLetter)
            let catalog: ChoiceCatalog
            if value.contains("/"), ChoiceCatalog.timeZone.accepts(value) { catalog = .timeZone }
            else if ["currency","currencycode"].contains(role), ChoiceCatalog.currency.accepts(value) { catalog = .currency }
            else if ["region","regioncode","country","countrycode"].contains(role), ChoiceCatalog.region.accepts(value) { catalog = .region }
            else { continue }
            var key = "choice" + String(index)
            while keys.contains(key) || result.inputs?[key] != nil { key += "_" }
            let token = "orvlet" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            query[index].value = token
            tokens.append((token, key))
            var values = result.inputs ?? [:]
            values[key] = value
            result.inputs = values
            var controls = result.controls ?? []
            let label = item.name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
            controls.append(.init(key: key, label: label, kind: "select", catalog: catalog))
            result.controls = controls
            result.expectations?[proof.key] = "{" + key + "}"
            if result.card?.kind == .reading, result.card?.displayNameKey == nil {
                result.card?.displayNameKey = proof.key
            }
        }
        guard !tokens.isEmpty else { return self }
        parts.queryItems = query
        guard var template = parts.string else { return self }
        for (token, key) in tokens { template = template.replacingOccurrences(of: token, with: "{" + key + "}") }
        result.url = template
        return (try? result.validated()) ?? self
    }
}

extension APIDataSpec {
    /// Keep the source identifier intact for verification and give its visible label a separate binding.
    func choiceSubject(_ state: [String: String]) -> String? {
        guard card?.kind == .reading, let identity = card?.displayNameKey, !keys.contains("orvletChoiceSubject"),
            let value = state[identity], let control = inputControls.first(where: {
                expectations?[identity] == "{" + $0.key + "}" && $0.kind == "select"
            }) else { return nil }
        if let label = control.optionLabels?[value] { return label }
        let locale = Locale(identifier: interfaceLanguage.flatMap(CardMarkup.localeIdentifier(for:)) ?? Locale.current.identifier)
        switch control.catalog {
        case .timeZone: return (value.split(separator: "/").last.map(String.init) ?? value).replacingOccurrences(of: "_", with: " ")
        case .region: return locale.localizedString(forRegionCode: value) ?? value
        case .currency: return locale.localizedString(forCurrencyCode: value) ?? value
        case nil: return value
        }
    }
}
