import Foundation

struct CurrencyCardFields {
    var amount: String
    var from: String
    var to: String
}

extension APIDataSpec {
    /// Bind roles through the source's declared unit and identity checks, never task-title keywords.
    var currencyFields: CurrencyCardFields? {
        guard calculation != nil, let output = outputs?.first(where: { $0.key == card?.primaryKey }) ?? outputs?.last,
            let unit = card?.unitKey ?? output.unitKey,
            let target = expectations?[unit], target.hasPrefix("{"), target.hasSuffix("}")
        else { return nil }
        let to = String(target.dropFirst().dropLast())
        let codes = Set(Locale.commonISOCurrencyCodes)
        guard codes.contains(inputs?[to] ?? "") else { return nil }
        let sources = (expectations ?? [:]).filter { $0.key != unit }.values.compactMap { value -> String? in
            guard value.hasPrefix("{"), value.hasSuffix("}") else { return nil }
            let key = String(value.dropFirst().dropLast())
            return key != to && codes.contains(inputs?[key] ?? "") ? key : nil
        }
        let amounts = inputControls.filter { $0.kind == "number" && !url.contains("{" + $0.key + "}") }
        guard sources.count == 1, amounts.count == 1, inputs?.count == 3 else { return nil }
        return CurrencyCardFields(amount: amounts[0].key, from: sources[0], to: to)
    }
    var resolvedCard: DataCardPreset? {
        if let card { return card }
        guard currencyFields != nil, let output = outputs?.last else { return nil }
        return DataCardPreset(kind: .currency, primaryKey: output.key, unitKey: output.unitKey)
    }
    var cardControls: [APIDataControl] {
        guard customLayout != true, resolvedCard?.kind == .currency, let roles = currencyFields else {
            return inputControls
        }
        return [roles.amount, roles.from, roles.to].compactMap { key in
            guard var control = inputControls.first(where: { $0.key == key }) else { return nil }
            control.label = key == roles.amount ? "Amount" : key == roles.from ? "From" : "To"
            if key != roles.amount {
                control.kind = "select"
                if control.options?.isEmpty != false {
                    control.options = Locale.commonISOCurrencyCodes.sorted()
                }
            }
            return control
        }
    }
    var supportsCurrencySwap: Bool {
        guard let roles = currencyFields,
            let from = cardControls.first(where: { $0.key == roles.from })?.options,
            let to = cardControls.first(where: { $0.key == roles.to })?.options
        else { return false }
        return Set(from) == Set(to)
    }
    func presentationState(_ state: [String: String]) -> [String: String] {
        var result = state
        if card?.kind == .weather {
            result["weatherSampleTime"] = state["weatherSampleTime"] ?? ""
            if let key = card?.contextKey, result[key] == nil { result[key] = "" }
        }
        if result["sourceDate"] == "Source update time unavailable" { result["sourceDate"] = "" }
        if resolvedCard?.kind == .currency { result["currencyPair"] = "" }
        guard resolvedCard?.kind == .currency, let roles = currencyFields else { return result }
        result["currencyPair"] = (state[roles.from] ?? "") + " → " + (state[roles.to] ?? "")
        let locale = Locale(identifier: "en_US")
        result["currencyFromName"] = locale.localizedString(forCurrencyCode: state[roles.from] ?? "") ?? ""
        result["currencyToName"] = locale.localizedString(forCurrencyCode: state[roles.to] ?? "") ?? ""
        return result
    }
}
