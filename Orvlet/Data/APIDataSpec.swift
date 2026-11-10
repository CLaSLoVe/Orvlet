import Foundation

/// A saved acquisition method, not a saved claim that an old value is current.
struct APIDataField: Codable {
    var key: String
    var label: String
    var pointer: String
    var unit: String? = nil
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
}
struct APIDataSpec: Codable {
    static let maximumSourceFields = 10
    static let maximumValues = 14
    static let maximumInputs = 8
    var url: String
    var fields: [APIDataField]
    var updatedAtPointer: String?
    var updatedAtFormat: String? = nil
    var updatedAtTimeZone: String? = nil
    var inputs: [String: String]?
    var controls: [APIDataControl]? = nil
    var calculation: String?
    var outputs: [APIDataOutput]?
    var expectations: [String: String]?
    var maxAgeSeconds: Double?
    var card: DataCardPreset? = nil
    // Host-owned opt-out after a deliberate interface edit; not an acquisition parameter.
    var customLayout: Bool? = nil

    var keys: Set<String> { Set(fields.map(\.key) + (outputs ?? []).map(\.key)) }
    /// Presentation and validation share one set of displayed values.
    var displayRows: [APIDataOutput] {
        var rows =
            (outputs ?? []).isEmpty
            ? fields.filter { !isWttrWeather || !$0.pointer.contains("/nearest_area/") || $0.key == card?.contextKey }
                .map { APIDataOutput(key: $0.key, label: $0.label, unit: $0.unit) }
            : outputs!
        if let primary = card?.primaryKey, !rows.contains(where: { $0.key == primary }),
            let field = fields.first(where: { $0.key == primary })
        {
            rows.insert(APIDataOutput(key: field.key, label: field.label, unit: field.unit), at: 0)
        }
        return rows
    }
    func validated() throws -> APIDataSpec {
        _ = try requestURL()
        let all = fields.map { APIDataOutput(key: $0.key, label: $0.label, unit: $0.unit) } + (outputs ?? [])
        let reserved: Set<String> = [
            "title", "status", "detail", "appearance", "accent", "compact", "resultStatus", "sourceRequest",
            "sourceHost", "sourceDate", "sourceChecked",
            "currencyFromName", "currencyToName", "currencyPair", "weatherSampleTime",
        ]
        func validKey(_ key: String) -> Bool {
            key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,30}$", options: .regularExpression) != nil && !reserved.contains(key)
        }
        guard !fields.isEmpty, fields.count <= Self.maximumSourceFields, all.count <= Self.maximumValues else {
            throw AppError.message("Provide 1–10 source fields and at most 14 total source/output fields.")
        }
        guard keys.count == all.count else {
            throw AppError.message(
                "Source and output keys must be unique; do not reuse a source key for a calculated output.")
        }
        guard all.allSatisfy({ validKey($0.key) && !$0.label.isEmpty && $0.label.count <= 80 }) else {
            throw AppError.message(
                "Field keys need 1–31 letters/digits/underscores, starting with a letter; avoid reserved host keys. Labels need 1–80 characters."
            )
        }
        guard fields.allSatisfy({ $0.pointer.hasPrefix("/") && $0.pointer.count <= 300 }) else {
            throw AppError.message(
                "Source pointers must be exact JSON pointers beginning with /, at most 300 characters.")
        }
        let inputKeys = Set((inputs ?? [:]).keys)
        let collisions = inputKeys.intersection(Set((outputs ?? []).map(\.key)))
        guard collisions.isEmpty else {
            throw AppError.message(
                "Input keys collide with calculated output keys: " + collisions.sorted().joined(separator: ", ")
                    + ". Use distinct names for editable inputs and calculated results."
            )
        }
        guard inputKeys.count <= Self.maximumInputs, inputKeys.allSatisfy(validKey),
            (inputs ?? [:]).values.allSatisfy({ $0.count <= 1000 })
        else {
            throw AppError.message(
                "Provide at most 8 distinct valid input keys with string values up to 1000 characters.")
        }
        guard (controls ?? []).count <= 8, Set((controls ?? []).map(\.key)).count == (controls ?? []).count,
            (controls ?? []).allSatisfy({
                inputKeys.contains($0.key) && !$0.label.isEmpty && $0.label.count <= 60
                    && ["text", "number", "select"].contains($0.kind) && ($0.options ?? []).count <= 250
                    && ($0.options ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 80 })
            })
        else {
            throw AppError.message(
                "Controls must name distinct existing inputs, use text/number/select and have short labels/options.")
        }
        guard
            (outputs ?? []).allSatisfy({ output in
                output.unitKey == nil || fields.contains(where: { $0.key == output.unitKey })
            })
        else {
            throw AppError.message(
                "output.unitKey must name a source field containing the returned unit, not a literal unit label.")
        }
        if let calculation {
            guard !calculation.isEmpty, calculation.utf8.count <= 32768, !(outputs ?? []).isEmpty else {
                throw AppError.message("A calculation needs a nonempty function body up to 32 KB and named outputs.")
            }
        } else if !(outputs ?? []).isEmpty {
            throw AppError.message(
                "Calculated outputs require a calculation; otherwise display the source fields directly.")
        }
        guard Set((expectations ?? [:]).keys).isSubset(of: Set(fields.map(\.key))) else {
            throw AppError.message("Expectations must name actual source fields, not input/output keys.")
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
        try card?.validate(
            keys: keys.union(inputKeys),
            rows: displayRows)
        var normalized = self
        if var controls = normalized.controls {
            for i in controls.indices
            where controls[i].kind == "select" && !(controls[i].options ?? []).contains(inputs?[controls[i].key] ?? "")
            {
                controls[i].kind = "text"
                controls[i].options = nil
            }
            normalized.controls = controls
        }
        guard all.allSatisfy({ ($0.unit ?? "").count <= 20 }) else {
            throw AppError.message("Use a short source-defined unit.")
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
    func requestURL() throws -> URL {
        guard let components = URLComponents(string: url), let host = components.host, !host.contains("{"),
            !host.contains("}")
        else { throw AppError.message("Data parameters may change a path or query, never the source host.") }
        return try PublicDataClient.url(expanded(url))
    }
    var inputControls: [APIDataControl] {
        let ordered =
            (controls ?? []).map(\.key)
            + (inputs ?? [:]).keys.filter { key in !(controls ?? []).contains(where: { $0.key == key }) }.sorted()
        return ordered.map { key in
            controls?.first(where: { $0.key == key })
                ?? APIDataControl(
                    key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                    kind: Double(inputs?[key] ?? "") == nil ? "text" : "number")
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
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) ?? formatter.date(from: value + "T00:00:00Z") { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    static let schema: [String: Any] = [
        "type": "object",
        "description": "Acquisition recipe nested inside source; URL, fields, calculation and card belong here.",
        "properties": [
            "card": DataCardPreset.schema,
            "url": [
                "type": "string",
                "description":
                    "Public HTTPS JSON endpoint; use {inputKey} placeholders in path/query for editable source parameters. Host remains fixed. No credentials, auth headers or cookies.",
            ],
            "fields": [
                "type": "array", "minItems": 1, "maxItems": maximumSourceFields,
                "description": "Fetch only needed scalar values. At most 14 source and calculated values combined.",
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
                        "pointer": [
                            "type": "string",
                            "description":
                                "Exact RFC 6901 pointer to one scalar, e.g. /items/0/value. Arrays/objects are not scalar fields; select an element.",
                        ],
                    ], "required": ["key", "label", "pointer"],
                ],
            ],
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
                        "options": ["type": "array", "items": ["type": "string"]],
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
                "type": "array", "maxItems": maximumValues - 1,
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
