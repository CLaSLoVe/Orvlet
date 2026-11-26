import Foundation

/// A saved acquisition method, not a saved claim that an old value is current.
struct APIDataField: Codable {
    var key: String
    var label: String
    var pointer: String
    var unit: String? = nil
    var itemPointer: String? = nil
}
struct APIDataOutput: Codable {
    var key: String
    var label: String
    var unitKey: String? = nil
    var unit: String? = nil
}
struct APIDataControl: Codable {
    var key: String
    var label: String
    var kind: String = "text"
    var options: [String]? = nil
    var catalog: ChoiceCatalog? = nil
    var optionLabels: [String: String]? = nil
}
struct APIDataSpec: Codable {
    static let maximumSourceFields = 10
    static let maximumValues = 32
    static let maximumInputs = 8
    var url: String
    var fields: [APIDataField]
    var recordPagePointer: String? = nil
    var updatedAtPointer: String?
    var updatedAtFormat: String? = nil
    var updatedAtTimeZone: String? = nil
    var inputs: [String: String]?
    var controls: [APIDataControl]? = nil
    var calculation: String?
    var outputs: [APIDataOutput]?
    var expectations: [String: String]?
    var maxAgeSeconds: Double?
    var refreshSeconds: Double? = nil
    // Captured by the host at generation; a later refresh keeps the card's own language.
    var interfaceLanguage: String? = nil
    var usesEnglishPresetCopy: Bool {
        interfaceLanguage == nil || interfaceLanguage?.caseInsensitiveCompare("English") == .orderedSame
    }
    var refreshLabel: String? = nil
    var visuals: [CardVisual]? = nil
    var card: DataCardPreset? = nil
    // Host-owned opt-out after a deliberate interface edit; not an acquisition parameter.
    var customLayout: Bool? = nil
    // Compiler-verified multi-segment path inputs. Query inputs remain escaped.
    var pathParameters: [String]? = nil
    var primarySourcePointer: String? = nil
    var reminder: CardReminderRule? = nil

    var keys: Set<String> { Set(fields.map(\.key) + (outputs ?? []).map(\.key)) }
    var derivedKeys: Set<String> { Set((outputs ?? []).map(\.key)).subtracting(fields.map(\.key)) }
    /// Bind optional visuals only to declared series or computed outputs. Never guess an axis.
    func bindingVisuals() -> APIDataSpec {
        guard let visuals else { return self }
        let columns = fields.filter { $0.itemPointer != nil }.map { CardVisual.Column(key: $0.key, label: $0.label) }
            + (outputs ?? []).map { CardVisual.Column(key: $0.key, label: $0.label) }
        var copy = self
        copy.visuals = Array(visuals.compactMap { $0.bound(to: columns) }.prefix(3))
        return copy
    }

    /// Presentation and validation share one set of displayed values.
    var displayRows: [APIDataOutput] {
        var rows =
            (outputs ?? []).isEmpty
            ? fields.filter { $0.itemPointer == nil && (!isWttrWeather || !$0.pointer.contains("/nearest_area/") || $0.key == card?.contextKey) }
                .map { APIDataOutput(key: $0.key, label: $0.label, unit: $0.unit) }
            : outputs!
        if let primary = card?.primaryKey, !rows.contains(where: { $0.key == primary }),
            let field = fields.first(where: { $0.key == primary && $0.itemPointer == nil })
        {
            rows.insert(APIDataOutput(key: field.key, label: field.label, unit: field.unit), at: 0)
        }
        return rows
    }
    func validated() throws -> APIDataSpec {
        try reminder?.validate(available: keys.union(inputs?.keys.map { $0 } ?? []))
        _ = try requestURL()
        if let refreshLabel, refreshLabel.count > 80 || refreshLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolArgumentError(path: "$.source.refreshLabel", issue: "provide a short button label")
        }
        let all = fields.map { APIDataOutput(key: $0.key, label: $0.label, unit: $0.unit) } + (outputs ?? [])
        let reserved: Set<String> = [
            "title", "status", "detail", "appearance", "accent", "compact", "resultStatus", "sourceRequest",
            "sourceHost", "sourceDate", "sourceChecked", "recordPageURL",
            "sourceDateDisplay", "currencyFromName", "currencyToName", "currencyPair", "currencyRateEquation", "weatherSampleTime", "weatherAlternateTemperature",
        ]
        func validKey(_ key: String) -> Bool {
            key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,30}$", options: .regularExpression) != nil && !reserved.contains(key)
        }
        guard !fields.isEmpty, fields.count <= Self.maximumSourceFields, keys.count <= Self.maximumValues, (outputs ?? []).count <= Self.maximumValues else {
            throw ToolArgumentError(path: fields.isEmpty || fields.count > Self.maximumSourceFields ? "$.source.fields" : "$.source.outputs", issue: "Provide 1–10 source fields and at most 32 total source/output fields.")
        }
        var seen: Set<String> = []
        for (index, output) in all.enumerated() {
            if index == fields.count { seen.removeAll() }
            let path = index < fields.count ? "$.source.fields[\(index)]" : "$.source.outputs[\(index - fields.count)]"
            guard validKey(output.key), seen.insert(output.key).inserted else {
                throw ToolArgumentError(path: path + ".key", issue: "use a unique, non-reserved source/output identifier")
            }
            guard !output.label.isEmpty, output.label.count <= 80 else {
                throw ToolArgumentError(path: path + ".label", issue: "use a label of 1–80 characters")
            }
            guard (output.unit ?? "").count <= 20 else {
                throw ToolArgumentError(path: path + ".unit", issue: "use a short source-defined unit")
            }
        }
        for (index, field) in fields.enumerated() {
            let path = "$.source.fields[\(index)]"
            guard field.pointer.hasPrefix("/"), field.pointer.count <= 300 else {
                throw ToolArgumentError(path: path + ".pointer", issue: "use an exact JSON pointer beginning with /")
            }
            if let item = field.itemPointer, !item.isEmpty && (!item.hasPrefix("/") || item.count > 300) {
                throw ToolArgumentError(path: path + ".itemPointer", issue: "use a relative JSON pointer or an empty string for a scalar item")
            }
        }
        guard !displayRows.isEmpty else {
            throw ToolArgumentError(path: "$.source.fields", issue: "include a scalar field or computed output for the capsule")
        }
        let inputKeys = Set((inputs ?? [:]).keys)
        let collisions = inputKeys.intersection(derivedKeys)
        guard collisions.isEmpty else {
            throw ToolArgumentError(path: "$.source.outputs", issue:
                "Input keys collide with calculated output keys: " + collisions.sorted().joined(separator: ", ")
                    + ". Use distinct names for editable inputs and calculated results."
            )
        }
        guard inputKeys.count <= Self.maximumInputs, inputKeys.allSatisfy(validKey),
            (inputs ?? [:]).values.allSatisfy({ $0.count <= 1000 })
        else {
            throw ToolArgumentError(path: "$.source.inputs", issue:
                "Provide at most 8 distinct valid input keys with string values up to 1000 characters.")
        }
        guard (controls ?? []).count <= Self.maximumInputs else {
            throw ToolArgumentError(path: "$.source.controls", issue: "provide at most 8 controls")
        }
        var controlKeys = Set<String>()
        for (index, control) in (controls ?? []).enumerated() {
            let path = "$.source.controls[\(index)]"
            guard inputKeys.contains(control.key) else {
                throw ToolArgumentError(path: path + ".key", issue: "this control has no input value. Add its default to source.inputs or select an existing input key: " + inputKeys.sorted().joined(separator: ", "))
            }
            guard controlKeys.insert(control.key).inserted else {
                throw ToolArgumentError(path: path + ".key", issue: "another control already uses this input; keep one control per input")
            }
            guard !control.label.isEmpty, control.label.count <= 60 else {
                throw ToolArgumentError(path: path + ".label", issue: "use a label of 1–60 characters")
            }
            guard ["text", "number", "select"].contains(control.kind) else {
                throw ToolArgumentError(path: path + ".kind", issue: "use text, number or select")
            }
            guard (control.options ?? []).count <= 250,
                (control.options ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
                throw ToolArgumentError(path: path + ".options", issue: "provide at most 250 values, each 1–80 characters")
            }
            guard (control.optionLabels ?? [:]).count <= 250,
                (control.optionLabels ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 80 && !$0.value.isEmpty && $0.value.count <= 80 }) else {
                throw ToolArgumentError(path: path + ".optionLabels", issue: "provide at most 250 value-to-label entries, each key and label 1–80 characters")
            }
        }
        for (index, output) in (outputs ?? []).enumerated() {
            if let key = output.unitKey, !fields.contains(where: { $0.key == key }), !inputKeys.contains(key) {
                throw ToolArgumentError(path: "$.source.outputs[\(index)].unitKey", issue:
                    JSONText.encode(key) + " is not an extracted source field. If it is the intended fixed documented unit, set this output's unit to that label and remove unitKey. Use unitKey only when the response actually reports the measurement's unit; never substitute unrelated response metadata.")
            }
        }
        if let calculation {
            guard !calculation.isEmpty, calculation.utf8.count <= 32768, !(outputs ?? []).isEmpty else {
                throw ToolArgumentError(path: "$.source.calculation", issue: "A calculation needs a nonempty function body up to 32 KB and named outputs.")
            }
        } else if !derivedKeys.isEmpty {
            throw ToolArgumentError(path: "$.source.calculation", issue:
                "These derived fields need a calculation: " + derivedKeys.sorted().joined(separator: ", ") + ". Display existing source fields directly with card.primaryKey and detailKeys.")
        }
        guard Set((expectations ?? [:]).keys).isSubset(of: Set(fields.map(\.key))) else {
            throw ToolArgumentError(path: "$.source.expectations", issue: "Expectations must name actual source fields, not input/output keys.")
        }
        if let pointer = recordPagePointer {
            guard pointer.hasPrefix("/"), pointer.count <= 300 else {
                throw ToolArgumentError(path: "$.source.recordPagePointer", issue: "bind the human-facing page URL from the observed record")
            }
            _ = try expanded(pointer)
        }
        if let pointer = updatedAtPointer {
            guard pointer.hasPrefix("/"), pointer.count <= 300 else {
                throw ToolArgumentError(path: "$.source.updatedAtPointer", issue: "use an exact JSON pointer")
            }
            _ = try expanded(pointer)
        }
        if let format = updatedAtFormat, format.isEmpty || format.count > 80 {
            throw ToolArgumentError(path: "$.source.updatedAtFormat", issue: "use a bounded source timestamp format")
        }
        if updatedAtFormat != nil || updatedAtTimeZone != nil {
            guard updatedAtPointer != nil else {
                throw ToolArgumentError(
                    path: "$.source.updatedAtPointer", issue: "timestamp formatting needs a publication/update pointer")
            }
        }
        if let format = updatedAtFormat, !["unixSeconds", "unixMilliseconds"].contains(format), updatedAtTimeZone == nil
        {
            throw ToolArgumentError(
                path: "$.source.updatedAtTimeZone",
                issue: "a local timestamp format needs the source's documented time zone")
        }
        if let zone = updatedAtTimeZone, TimeZone(identifier: zone) == nil {
            throw ToolArgumentError(path: "$.source.updatedAtTimeZone", issue: "use the source's IANA time zone")
        }
        if let maxAgeSeconds {
            guard updatedAtPointer != nil else {
                throw ToolArgumentError(
                    path: "$.source.maxAgeSeconds",
                    issue:
                        "a freshness bound requires a source publication/update timestamp; applicable dates belong in fields and expectations"
                )
            }
            guard maxAgeSeconds.isFinite, (60...604800).contains(maxAgeSeconds) else {
                throw AppError.message(
                    "maxAgeSeconds must be between 60 and 604800; omit it when a freshness limit is not required.")
            }
        }
        if let refreshSeconds, !refreshSeconds.isFinite || !(15...86400).contains(refreshSeconds) {
            throw ToolArgumentError(path: "$.source.refreshSeconds", issue: "choose a refresh interval from 15 to 86400 seconds")
        }
        var normalized = bindingVisuals()
        normalized.card = try card?.bound(keys: keys.union(inputKeys), rows: displayRows)
        if let rate = normalized.card?.rateKey,
            normalized.card?.kind != .currency || !fields.contains(where: { $0.key == rate && $0.itemPointer == nil }) {
            throw ToolArgumentError(path: "$.source.card.rateKey", issue: "bind the currency preset to a scalar unit rate from the source")
        }
        normalized.controls = normalized.inputControls
        for control in normalized.inputControls where control.kind == "select" {
            guard control.accepts(inputs?[control.key] ?? "") else {
                throw ToolArgumentError(path: "$.source.controls", issue: "The selected value must belong to the field’s catalogue or declared options.")
            }
        }
        if isWttrWeather, let day = inputs?["weatherDay"], !["0", "1", "2"].contains(day) {
            throw AppError.message("Choose an available forecast day.")
        }
        normalized = normalized.withWeatherControls
        if let card = normalized.card, card.kind == .weather {
            let output = normalized.outputs?.first { $0.key == card.primaryKey }
            let unit = output?.unit ?? normalized.fields.first(where: { $0.key == card.primaryKey })?.unit
            guard card.unitKey != nil || output?.unitKey != nil || unit?.isEmpty == false else {
                throw AppError.message(
                    "The weather temperature needs its source-defined unit. Supply unit (°C or °F) or unitKey; never publish a bare number."
                )
            }
        }
        return normalized
    }
    func expanded(_ template: String) throws -> String {
        var result = template
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for (key, value) in inputs ?? [:] {
            result = result.replacingOccurrences(
                of: "{" + key + "}", with: value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        }
        guard !result.contains("{"), !result.contains("}") else {
            throw AppError.message("Provide all source parameters before requesting data.")
        }
        return result
    }
    func expandedPointer(_ template: String) throws -> String {
        var result = template
        for (key,value) in inputs ?? [:] {
            let segment = value.replacingOccurrences(of:"~",with:"~0").replacingOccurrences(of:"/",with:"~1")
            result = result.replacingOccurrences(of:"{" + key + "}",with:segment)
        }
        guard !result.contains("{"), !result.contains("}") else {
            throw AppError.message("Provide all source parameters before reading its fields.")
        }
        return result
    }
    func requestURL() throws -> URL {
        guard let components = URLComponents(string: url), let host = components.host, !host.contains("{"),
            !host.contains("}")
        else { throw AppError.message("Data parameters may change a path or query, never the source host.") }
        var request = url
        let safePath = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~/"))
        for key in pathParameters ?? [] {
            guard let value = inputs?[key] else { continue }
            let prefix = String(request.split(separator:"?",maxSplits:1,omittingEmptySubsequences:false)[0])
            guard prefix.contains("{" + key + "}") else { continue }
            let replacement = prefix.replacingOccurrences(of:"{" + key + "}",with:value.addingPercentEncoding(withAllowedCharacters:safePath) ?? "")
            request = replacement + request.dropFirst(prefix.count)
        }
        return try PublicDataClient.url(expanded(request))
    }
    var inputControls: [APIDataControl] {
        let ordered =
            (controls ?? []).map(\.key)
            + (inputs ?? [:]).keys.filter { key in !(controls ?? []).contains(where: { $0.key == key }) }.sorted()
        return ordered.map { key in
            var control = controls?.first(where: { $0.key == key })
                ?? APIDataControl(
                    key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                    kind: Double(inputs?[key] ?? "") == nil ? "text" : "number")
            if control.options?.isEmpty == false {
                control.kind = "select"
                control.catalog = nil
            } else {
                if control.catalog == nil, url.contains("{" + key + "}"), let value = inputs?[key], value.contains("/"),
                    ChoiceCatalog.timeZone.accepts(value) { control.catalog = .timeZone }
                if control.catalog != nil { control.kind = "select" }
            }
            return control
        }
    }
    static func value(_ pointer: String, in root: Any) -> Any? {
        if pointer.isEmpty { return root }
        guard pointer.hasPrefix("/") else { return nil }
        var value: Any = root
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = String(raw).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = value as? [String: Any], let next = object[key] {
                value = next
            } else if let array = value as? [Any], let index = Int(key), array.indices.contains(index) {
                value = array[index]
            } else {
                return nil
            }
        }
        return value
    }
    /// Object member names are reported identities too (records keyed by region,
    /// category, version, etc.). Count only keys on a complete, existing value path.
    static func reportedKeys(_ pointer: String, in root: Any) -> [String] {
        guard pointer.hasPrefix("/") else { return [] }
        var value = root
        var keys: [String] = []
        for raw in pointer.dropFirst().split(separator:"/", omittingEmptySubsequences:false) {
            let key = String(raw).replacingOccurrences(of:"~1",with:"/").replacingOccurrences(of:"~0",with:"~")
            if let object = value as? [String:Any], let next = object[key] {
                keys.append(key)
                value = next
            } else if let array = value as? [Any], let index = Int(key), array.indices.contains(index) {
                value = array[index]
            } else { return [] }
        }
        return keys
    }

    static func scalar(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty, value.count <= 1000 { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.stringValue }
        return nil
    }
    func sourceTimestamp(_ value: String) -> Date? {
        if updatedAtFormat == nil { return Self.timestamp(value) }
        if updatedAtFormat == "unixSeconds" || updatedAtFormat == "unixMilliseconds" {
            guard let number = Double(value), number.isFinite else { return nil }
            return Date(timeIntervalSince1970: number / (updatedAtFormat == "unixMilliseconds" ? 1000 : 1))
        }
        guard let format = updatedAtFormat, let zone = updatedAtTimeZone.flatMap(TimeZone.init(identifier:)) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter.date(from: value)
    }
    static func timestamp(_ value: String) -> Date? {
        // A selected publication field has already established the semantic role.
        // Standard encodings are decoded here, never assembled by the model.
        if value.range(of: #"^[0-9]{10}(?:\.[0-9]+)?$|^[0-9]{13}$"#, options: .regularExpression) != nil,
            let number = Double(value) {
            return Date(timeIntervalSince1970: number / (value.count == 13 ? 1000 : 1))
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) ?? formatter.date(from: value + "T00:00:00Z") { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return date }
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier:"en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        rfc.isLenient = false
        return rfc.date(from:value)
    }
    static let schema: [String: Any] = [
        "type": "object",
        "description": "Acquisition recipe nested inside source; URL, fields, calculation and card belong here.",
        "properties": [
            "card": DataCardPreset.schema, "visuals": CardVisual.schema, "reminder": CardReminderRule.schema,
            "refreshLabel": ["type": "string", "description": "Refresh button label in the configured interface language; defaults to Refresh."],
            "refreshSeconds": ["type": "number", "minimum": 15, "maximum": 86400,
                "description": "Background refresh interval for a changing reading, even when collapsed. Use 60 for current quotes unless requested otherwise; omit for one-time results."],
            "url": [
                "type": "string",
                "description":
                    "Public HTTPS JSON endpoint; use {inputKey} placeholders in path/query for editable source parameters. Host remains fixed. No credentials, auth headers or cookies.",
            ],
            "fields": [
                "type": "array", "minItems": 1, "maxItems": maximumSourceFields,
                "description": "Fetch only needed scalar values. At most 32 source and calculated values combined.",
                "items": [
                    "type": "object",
                    "properties": [
                        "key": [
                            "type": "string",
                            "description":
                                "Named source value. Do not use host keys: title, status, detail, appearance, accent, compact, resultStatus, sourceRequest, sourceHost, sourceDate, sourceChecked. Applicable dates are ordinary fields; verify requested dates with expectations.",
                        ], "label": ["type": "string"],
                        "unit": [
                            "type": "string",
                            "description":
                                "Unit fixed by the source schema, such as °C, %, mm or km/h. Required for measured weather values when the source supplies no unit field. Never guess.",
                        ],
                        "itemPointer": [
                            "type": "string",
                            "description": "For a chart or table column, pointer selects an array (up to 512 observations); itemPointer selects one scalar inside each record, or an empty string for a scalar array. State holds a JSON-encoded column. Request a suitable source window.",
                        ],
                        "pointer": [
                            "type": "string",
                            "description":
                                "Exact RFC 6901 pointer to one scalar or, with itemPointer, to the observation array.",
                        ],
                    ], "required": ["key", "label", "pointer"],
                ],
            ],
            "recordPagePointer": ["type": "string", "description": "Optional observed JSON pointer to this record’s human-facing HTTPS page, for handoff."],
            "updatedAtPointer": [
                "type": "string",
                "description":
                    "JSON pointer to publication/update time only, never a forecast, scheduled or historical applicability date. Omit when unavailable; bind applicability dates as fields with expectations.",
            ],
            "updatedAtFormat": [
                "type": "string",
                "description":
                    "Omit for ISO 8601. Otherwise use the documented Unicode date format with updatedAtTimeZone, or unixSeconds/unixMilliseconds. Never guess a format.",
            ],
            "updatedAtTimeZone": [
                "type": "string",
                "description":
                    "Source IANA time zone for a formatted local timestamp, never the device zone by assumption.",
            ],
            "controls": [
                "type": "array", "maxItems": maximumInputs,
                "items": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"], "label": ["type": "string"],
                        "kind": ["type": "string", "enum": ["text", "number", "select"]],
                        "options": ["type": "array", "items": ["type": "string"], "description": "Allowed source values for a bounded parameter. Constrain choices to the service’s supported values."],
                        "optionLabels": ["type": "object", "additionalProperties": ["type": "string"], "description": "Human-readable labels keyed by allowed machine value."],
                        "catalog": ["type": "string", "enum": ChoiceCatalog.allCases.map(\.rawValue), "description": "Use a system catalogue when the source accepts the whole standard. Otherwise supply its supported options."],
                    ], "required": ["key", "label", "kind"],
                ],
            ],
            "inputs": [
                "type": "object", "maxProperties": maximumInputs,
                "additionalProperties": ["type": "string", "maxLength": 1000],
                "description":
                    "Editable user parameters, never remote facts. Output/host keys are reserved. An input sharing a source field key must match that field's actual returned value; the source value is preserved.",
            ],
            "calculation": [
                "type": "string",
                "description":
                    "Optional pure JS function body(input,state). input contains supplied strings; state contains fetched scalar strings (use Number for arithmetic). Return {state:{...}} with exactly the declared output keys. Never hardcode a remote value.",
            ],
            "outputs": [
                "type": "array", "maxItems": maximumValues,
                "description": "Optional display rows. Existing field keys show the verified source values directly. Only new keys need a calculation.",
                "items": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"], "label": ["type": "string"],
                        "unit": [
                            "type": "string",
                            "description":
                                "Fixed documented unit for this calculation, e.g. °C or %. Omit when unitKey supplies a dynamic source unit.",
                        ],
                        "unitKey": [
                            "type": "string",
                            "description":
                                "Optional source field supplying a dynamic unit, e.g. the returned quote currency",
                        ],
                    ], "required": ["key", "label"],
                ],
            ],
            "expectations": [
                "type": "object", "additionalProperties": ["type": "string"],
                "description":
                    "Assert returned entity, unit and applicable date match the request. Values may reference {inputKey}, e.g. base={fromCurrency}. Assertions compare actual API fields, not calculated text.",
            ],
            "maxAgeSeconds": [
                "type": "number", "minimum": 60, "maximum": 604800,
                "description":
                    "Maximum source-data age, accounting for publication cadence/weekends. Requires a parseable source update timestamp.",
            ],
        ], "required": ["url", "fields"],
    ]
}


extension APIDataSpec {
    /// Source adapters normalize edits before either agent or UI execution.
    func updatingInputs(_ fields: [String:String]) -> APIDataSpec {
        var spec = self
        if spec.isWttrWeather {
            if let day = fields["weatherDay"], day != spec.inputs?["weatherDay"], let key = spec.weatherDateKey {
                spec.expectations?[key] = nil
            }
            if let place = fields["weatherLocation"], place != spec.inputs?["weatherLocation"] {
                // A deliberate location edit supersedes the original request's geographic constraints.
                // Display the returned nearest city instead of relabelling old readings with the typed name.
                for field in spec.fields where field.pointer.contains("/nearest_area/") {
                    spec.expectations?[field.key] = nil
                }
            }
        }
        spec.inputs = (spec.inputs ?? [:]).merging(fields) { _, new in new }
        return spec
    }
}
