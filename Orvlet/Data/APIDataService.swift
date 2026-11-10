import Foundation

/// Public data acquisition and calculation. No UI, task catalogue, model service or credentials.
@MainActor
final class APIDataService {
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
    func acquire(_ proposed: APIDataSpec) async throws -> Reading {
        let spec = try proposed.validated()
        let requestURL = try spec.requestURL().absoluteString
        let json = try await fetch(requestURL)
        var state: [String: String] = [:]
        for (index, field) in spec.fields.enumerated() {
            let value = APIDataSpec.value(try spec.expanded(field.pointer), in: json)
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
                throw AppError.message(
                    "The API returned a different entity or unit. Correct the query before presenting a result.")
            }
        }
        let updated = try spec.updatedAtPointer.flatMap {
            APIDataSpec.scalar(APIDataSpec.value(try spec.expanded($0), in: json))
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
                let raw = APIDataSpec.scalar(APIDataSpec.value(try spec.expanded(prefix + "/time"), in: json)),
                let time = Int(raw), (0...2359).contains(time)
            {
                state["weatherSampleTime"] = String(format: "At %02d:%02d", time / 100, time % 100)
            }
        }
        state = try await calculateValidated(spec, state: state)
        state["sourceRequest"] = requestURL
        state["resultStatus"] = ""
        state["sourceHost"] = URL(string: requestURL)?.host ?? "Data source"
        state["sourceDate"] = updated.map { "Data as of " + $0 } ?? ""
        state["sourceChecked"] = "Checked " + ISO8601DateFormatter().string(from: now())
        return Reading(state: state, response: json)
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
                let output = try TaskValues.decode(result)
                guard Set(output.keys) == Set((spec.outputs ?? []).map(\.key)),
                    output.values.allSatisfy({ !$0.isEmpty && !["NaN", "Infinity", "-Infinity"].contains($0) })
                else { throw AppError.message("The calculation did not produce the declared results.") }
                values.merge(output) { _, new in new }
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
        guard age >= 0, age < min(3600, spec.maxAgeSeconds ?? 3600),
            (try? spec.requestURL().absoluteString) == state["sourceRequest"]
        else { return false }
        if let limit = spec.maxAgeSeconds {
            guard let text = state["sourceDate"],
                let date = spec.sourceTimestamp(text.replacingOccurrences(of: "Data as of ", with: "")),
                current.timeIntervalSince(date) <= limit, date.timeIntervalSince(current) < 86400
            else { return false }
        }
        for key in (spec.inputs ?? [:]).keys
        where spec.fields.contains(where: { $0.key == key || $0.pointer.contains("{" + key + "}") }) {
            if spec.inputs?[key] != state[key] { return false }
        }
        return true
    }
}
