import Foundation

/// Immutable observations for one revision. A later fetch never changes the
/// meaning of an earlier handle, even when the two URLs are identical.
struct RequestObservations {
    private var samples: [(id: String, sample: APIDataService.Sample)] = []
    private let namespace = String(UUID().uuidString.prefix(8))
    private var sequence = 0

    mutating func retain(_ sample: APIDataService.Sample) -> String {
        if let last = samples.last, last.sample.url == sample.url, last.sample.checked == sample.checked { return last.id }
        sequence += 1
        let id = namespace + "-" + String(sequence)
        if samples.count >= 12 { samples.removeFirst() }
        samples.append((id, sample))
        return id
    }

    func sourceNotes(for bindings: [[String: String]]) -> String {
        let references = Set(bindings.compactMap { $0["observation"] })
        let notes = samples.compactMap { entry -> String? in
            guard references.contains(entry.id) || references.contains(entry.sample.url),
                let host = URL(string: entry.sample.url)?.host else { return nil }
            return host + ", " + entry.sample.checked.formatted(date: .abbreviated, time: .shortened)
        }
        return Set(notes).sorted().joined(separator: " / ")
    }

    var hasSamples: Bool { !samples.isEmpty }
    func sample(_ reference: String) -> APIDataService.Sample? {
        samples.last(where: { $0.id == reference || $0.sample.url == reference })?.sample
    }
    var hasSeveralSources: Bool { Set(samples.map { $0.sample.url }).count > 1 }

    static let bindingSchema: [String: Any] = [
        "type": "array", "maxItems": 24,
        "description": "Bind actual values obtained by inspect_api into named worker inputs. Use the observation handle (or its observed URL for the latest sample) and a JSON pointer relative to the source JSON. Code reads input[name].",
        "items": ["type": "object", "properties": [
            "name": ["type": "string"], "observation": ["type": "string"], "pointer": ["type": "string"]
        ], "required": ["name", "observation", "pointer"]]
    ]

    func inputs(_ arguments: [String: Any]) throws -> [String: Any] {
        var values = arguments["input"] as? [String: Any] ?? [:]
        guard let bindings = arguments["bindings"] as? [[String: String]], !bindings.isEmpty else { return values }
        for (i, binding) in bindings.enumerated() {
            let path = "$.bindings[\(i)]"
            guard let name = binding["name"], !name.isEmpty, name.utf8.count <= 64, values[name] == nil else {
                throw ToolArgumentError(path: path + ".name", issue: "give each binding a unique input name distinct from literal inputs")
            }
            let reference = binding["observation"]
            guard let sample = samples.last(where: { $0.id == reference || $0.sample.url == reference })?.sample else {
                throw ToolArgumentError(path: path + ".observation", issue: "use an observation handle returned in this request, or inspect the source again")
            }
            guard let pointer = binding["pointer"], pointer.utf8.count <= 512 else {
                throw ToolArgumentError(path: path + ".pointer", issue: "use a JSON pointer relative to the source response")
            }
            var resolved = APIDataSpec.value(pointer, in: sample.response)
            if resolved == nil, pointer.hasPrefix("/data/") {
                resolved = APIDataSpec.value(String(pointer.dropFirst(5)), in: sample.response)
            }
            if resolved == nil { resolved = (sample.response as? [String: Any])?[pointer] }
            guard let value = resolved, !(value is NSNull) else {
                let keys = (sample.response as? [String: Any]).map { $0.keys.sorted().prefix(100).joined(separator: ", ") } ?? "[array]"
                throw ToolArgumentError(path: path + ".pointer", issue: "no value at that path in this source. Root fields: " + String(keys.prefix(1800)))
            }
            values[name] = value
        }
        guard try JSONSerialization.data(withJSONObject: values).count <= 128 * 1024 else {
            throw ToolArgumentError(path: "$.input", issue: "select smaller fields or narrow the source window before calculating")
        }
        return values
    }
}
