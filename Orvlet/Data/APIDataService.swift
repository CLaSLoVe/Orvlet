import Foundation

/// Public data acquisition and calculation. No UI, task catalogue, model service or credentials.
@MainActor
final class APIDataService {
    struct Sample {
        let url: String
        let checked: Date
        let response: Any

        /// inspect_api presents the response in its own `data` envelope. Accept
        /// either coordinate system, retaining a real source `/data` member.
        /// Never search by leaf name or silently bind a different record.
        func sourcePointer(_ pointer: String) -> String {
            if APIDataSpec.value(pointer, in: response) != nil { return pointer }
            if pointer.hasPrefix("/data/") {
                let relative = String(pointer.dropFirst(5))
                if APIDataSpec.value(relative, in: response) != nil { return relative }
            }
            return pointer
        }

        /// Keep small responses intact. For large payloads show real paths and representative
        /// values without copying whole time series into every subsequent decision.
        var preview: Any {
            if let data = try? JSONSerialization.data(withJSONObject: response), data.count <= 6000 { return response }
            var rows: [[String: String]] = []
            var bytes = 0
            func visit(_ value: Any, _ path: String, _ depth: Int) {
                guard depth <= 12, bytes < 6000, rows.count < 80, path.utf8.count <= 400 else { return }
                if let object = value as? [String: Any] {
                    for key in object.keys.sorted() where bytes < 6000 && rows.count < 80 {
                        let segment = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                        visit(object[key]!, path + "/" + segment, depth + 1)
                    }
                } else if let array = value as? [Any] {
                    for (index, item) in array.prefix(2).enumerated() { visit(item, path + "/" + String(index), depth + 1) }
                } else if let scalar = APIDataSpec.scalar(value) {
                    let example = String(scalar.prefix(100))
                    rows.append(["pointer": path, "example": example])
                    bytes += path.utf8.count + example.utf8.count + 30
                }
            }
            visit(response, "", 0)
            return ["sampledPointers": rows, "partial": true] as [String: Any]
        }
    }
    struct Reading {
        let state: [String: String]
        let response: Any

        func bindingError(label: String, excluding: [String] = [], matching accepts: (String) -> Bool)
            -> ToolArgumentError?
        {
            let candidates = candidatePointers(matching: accepts).filter { !excluding.contains($0) }
            guard !candidates.isEmpty else { return nil }
            return ToolArgumentError(
                path: "$.source.fields",
                issue: "Selected fields do not prove " + label
                    + ". This same response contains possible matching values at " + JSONText.encode(candidates)
                    + "; verify their meaning and bind the appropriate scalar field as evidence")
        }
        /// Bounded repair hints from the same response; candidates are never accepted as proof automatically.
        func candidatePointers(matching accepts: (String) -> Bool) -> [String] {
            var result: [String] = []
            var visited = 0
            func visit(_ value: Any, path: String, depth: Int) {
                guard visited < 2048, depth <= 12, result.count < 8, path.count <= 300 else { return }
                visited += 1
                if let text = APIDataSpec.scalar(value), text.count <= 160, accepts(text), !path.isEmpty {
                    result.append(path)
                } else if let object = value as? [String: Any] {
                    for key in object.keys.sorted() {
                        let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
                            of: "/", with: "~1")
                        visit(object[key]!, path: path + "/" + escaped, depth: depth + 1)
                        if visited >= 2048 || result.count >= 8 { break }
                    }
                } else if let array = value as? [Any] {
                    for (index, element) in array.enumerated() {
                        visit(element, path: path + "/" + String(index), depth: depth + 1)
                        if visited >= 2048 || result.count >= 8 { break }
                    }
                }
            }
            visit(response, path: "", depth: 0)
            return result
        }
    }
    private let fetch: (String) async throws -> Any
    private let code: any TaskCodeExecuting
    private let now: () -> Date
    init(
        code: any TaskCodeExecuting,
        fetch: @escaping (String) async throws -> Any = { try await PublicDataClient().fetch($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.code = code
        self.fetch = fetch
        self.now = now
    }
    func read(_ proposed: APIDataSpec) async throws -> [String: String] {
        try await acquire(proposed).state
    }
    func sample(url: String, previous: Sample?, maxAge: TimeInterval = 60) async throws -> Sample {
        let address = try PublicDataClient.url(url).absoluteString
        if let previous, previous.url == address, (0..<maxAge).contains(now().timeIntervalSince(previous.checked)) { return previous }
        do {
            let response = try await fetch(address)
            return Sample(url: address, checked: now(), response: response)
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let hostUnavailable = (error as? URLError).map {
                [URLError.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
                    .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot].contains($0.code)
            } ?? false
            throw SourceReadFailure(url: address, reason: error.localizedDescription,
                allowsCorrection: error is PublicDataRequestIssue, hostUnavailable: hostUnavailable)
        }
    }
    func acquire(_ proposed: APIDataSpec, previous: Sample? = nil, observed: ((Sample) -> Void)? = nil) async throws -> Reading {
        let spec = try proposed.validated()
        let requestURL = try spec.requestURL().absoluteString
        let sample = try await sample(url: requestURL, previous: previous, maxAge: min(60, spec.refreshSeconds ?? 60))
        observed?(sample)
        let json = sample.response
        var state: [String: String] = [:]
        for (index, field) in spec.fields.enumerated() {
            let value = APIDataSpec.value(try spec.expandedPointer(field.pointer), in: json)
            if let pointer = field.itemPointer {
                state[field.key] = try Self.column(value, pointer: pointer, index: index)
                continue
            }
            guard let text = APIDataSpec.scalar(value) else {
                let structured = value is [Any] || value is [String: Any]
                Diagnostics.record(
                    "api_validation",
                    [
                        "stage": "source_field", "reasonCode": structured ? "non_scalar" : "field_missing",
                        "fieldPath": "$.source.fields[\(index)].pointer",
                    ])
                throw ToolArgumentError(
                    path: "$.source.fields[\(index)].pointer",
                    issue: structured
                        ? "pointer selects an array/object; select a scalar leaf with an exact key or array index"
                        : "pointer has no nonempty scalar value in this response; inspect the schema and correct the pointer"
                )
            }
            state[field.key] = text
        }
        for (key, expected) in spec.expectations ?? [:] {
            let target = try spec.expanded(expected).removingPercentEncoding ?? expected
            guard state[key]?.caseInsensitiveCompare(target) == .orderedSame else {
                if let repair = Reading(state: state, response: json).bindingError(
                    label: key,
                    matching: {
                        $0.caseInsensitiveCompare(target) == .orderedSame
                    })
                {
                    throw repair
                }
                let observed = String((state[key] ?? "").prefix(120))
                throw ToolArgumentError(path: "$.source.expectations." + key,
                    issue: "Expected " + String(target.prefix(120)) + " but the source returned " + observed
                        + ". Verify the requested identity against the same record or look it up at another source. Never just accept a different entity.")
            }
        }
        let updated = try spec.updatedAtPointer.flatMap {
            APIDataSpec.scalar(APIDataSpec.value(try spec.expandedPointer($0), in: json))
        }
        func timeFailure(_ code: String, _ issue: String, argument: Bool) throws -> Never {
            Diagnostics.record("api_validation", ["stage": "source_time", "reasonCode": code])
            if argument { throw ToolArgumentError(path: "$.source.updatedAtPointer", issue: issue) }
            throw AppError.message(issue)
        }
        if spec.updatedAtPointer != nil && updated == nil {
            try timeFailure(
                "timestamp_missing",
                "The source update timestamp is missing. Inspect the response and correct its pointer", argument: true)
        }
        if let limit = spec.maxAgeSeconds {
            guard let updated, let date = spec.sourceTimestamp(updated) else {
                try timeFailure(
                    "timestamp_unparseable",
                    "The source timestamp cannot be parsed. Supply its documented format and time zone, or choose a documented publication timestamp",
                    argument: true)
            }
            let age = now().timeIntervalSince(date)
            guard age > -86400 else {
                try timeFailure(
                    "timestamp_future",
                    "The selected timestamp is in the future. Publication/update time must describe when data was produced; bind forecast or scheduled dates as fields and verify them with expectations",
                    argument: true)
            }
            guard age <= limit else {
                try timeFailure(
                    "timestamp_stale",
                    "The source publication/update timestamp exceeds the requested freshness limit. Fetch a current source; do not relabel its timestamp",
                    argument: false)
            }
        }
        if spec.isWttrWeather {
            let periods = Set(
                spec.fields.compactMap { field -> String? in
                    let parts = field.pointer.split(separator: "/").map(String.init)
                    return parts.count > 4 && parts[2] == "hourly" ? "/" + parts.prefix(4).joined(separator: "/") : nil
                })
            if periods.count == 1, let prefix = periods.first,
                let raw = APIDataSpec.scalar(APIDataSpec.value(try spec.expandedPointer(prefix + "/time"), in: json)),
                let time = Int(raw), (0...2359).contains(time)
            {
                state["weatherSampleTime"] = String(format: "At %02d:%02d", time / 100, time % 100)
            }
        }
        state = try await calculateValidated(spec, state: state)
        if let pointer = spec.recordPagePointer,
            let raw = APIDataSpec.value(try spec.expandedPointer(pointer), in: json) as? String,
            let url = try? PublicDataClient.url(raw) {
            state["recordPageURL"] = url.absoluteString
        }
        state["sourceRequest"] = requestURL
        state["resultStatus"] = ""
        state["sourceHost"] = URL(string: requestURL)?.host ?? "Data source"
        state["sourceDate"] = updated.map { "Data as of " + $0 } ?? ""
        state["sourceChecked"] = "Checked " + ISO8601DateFormatter().string(from: sample.checked)
        return Reading(state: state, response: json)
    }

    private static func column(_ value: Any?, pointer: String, index: Int) throws -> String {
        let path = "$.source.fields[\(index)]"
        guard let array = value as? [Any], array.count <= 512 else {
            throw ToolArgumentError(path: path + ".pointer", issue: "select an array with at most 512 observations")
        }
        var found = false
        let cells: [Any] = try array.map { item in
            guard let cell = APIDataSpec.value(pointer, in: item) else { return NSNull() }
            found = true
            if cell is NSNull { return cell }
            guard APIDataSpec.scalar(cell) != nil else {
                throw ToolArgumentError(path: path + ".itemPointer", issue: "select a scalar value inside each observation")
            }
            return cell
        }
        guard cells.isEmpty || found else {
            throw ToolArgumentError(path: path + ".itemPointer", issue: "no observations contain a reading at this pointer")
        }
        let data = try JSONSerialization.data(withJSONObject: cells)
        guard data.count <= 16000 else {
            throw ToolArgumentError(path: path, issue: "narrow the source window so this column fits in the card")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Initial acquisition and cached edits use the same handler and output contract.
    func calculate(_ proposed: APIDataSpec, state: [String: String]) async throws -> [String: String] {
        try await calculateValidated(proposed.validated(), state: state)
    }
    private func calculateValidated(_ spec: APIDataSpec, state: [String: String]) async throws -> [String: String] {
        let sourceKeys = Set(spec.fields.map(\.key))
        var values = state
        for (key, input) in spec.inputs ?? [:] {
            if sourceKeys.contains(key) {
                guard state[key]?.caseInsensitiveCompare(input) == .orderedSame else {
                    Diagnostics.record(
                        "api_validation", ["stage": "source_identity", "reasonCode": "input_echo_mismatch"])
                    throw AppError.message(
                        "The source did not echo the requested input. Correct the query or use distinct keys for unrelated source values and inputs."
                    )
                }
            } else {
                values[key] = input
            }
        }
        if let calculation = spec.calculation {
            do {
                let result = try await code.run(code: calculation, input: spec.inputs ?? [:], state: values)
                let raw = result["state"] as? [String: Any] ?? result
                let declared = Set((spec.outputs ?? []).map(\.key))
                let output = try TaskValues.decode(["state": raw.filter { declared.contains($0.key) }])
                for row in spec.outputs ?? [] {
                    let key = row.key
                    if sourceKeys.contains(key) {
                        // Source values remain authoritative, including when code echoes the full state.
                        if let echo = output[key], echo != values[key] {
                            throw AppError.message("The calculation changes fetched field '" + key
                                + "'. Use a distinct output key for a transformed value or display the fetched field directly.")
                        }
                        continue
                    }
                    guard let value = output[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        !["NaN", "Infinity", "-Infinity"].contains(value) else {
                        throw AppError.message("Missing or invalid result '" + key + "'. Required derived keys: "
                            + spec.derivedKeys.sorted().joined(separator: ", ") + ". Returned keys: "
                            + raw.keys.sorted().prefix(16).map { String($0.prefix(40)) }.joined(separator: ", ")
                            + ". Read fetched values from state and return {state:{...}} with the named results. For a direct reading use the fetched field as card.primaryKey.")
                    }
                    values[key] = value
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                throw ToolArgumentError(path: "$.source.calculation", issue: error.localizedDescription)
            }
        }
        return values
    }
    func canReuse(_ spec: APIDataSpec, state: [String: String], fetchedAt: Date?) -> Bool {
        let current = now()
        let age = current.timeIntervalSince(fetchedAt ?? .distantPast)
        guard age >= 0, age < min(3600, spec.maxAgeSeconds ?? 3600, spec.refreshSeconds ?? 3600),
            let url = try? spec.requestURL().absoluteString, url == state["sourceRequest"]
        else { return false }
        if let limit = spec.maxAgeSeconds {
            guard let text = state["sourceDate"],
                let date = spec.sourceTimestamp(text.replacingOccurrences(of: "Data as of ", with: "")),
                current.timeIntervalSince(date) <= limit, date.timeIntervalSince(current) < 86400
            else { return false }
        }
        for (key, pattern) in spec.expectations ?? [:] {
            guard let expanded = try? spec.expanded(pattern),
                state[key]?.caseInsensitiveCompare(expanded.removingPercentEncoding ?? expanded) == .orderedSame else { return false }
        }
        for key in (spec.inputs ?? [:]).keys
        where spec.fields.contains(where: { $0.key == key || $0.pointer.contains("{" + key + "}") })
            || spec.updatedAtPointer?.contains("{" + key + "}") == true
            || spec.recordPagePointer?.contains("{" + key + "}") == true {
            if spec.inputs?[key] != state[key] { return false }
        }
        return true
    }
}
