import Foundation

/// A sibling can reuse a proven access pattern while resolving its own identity.
@MainActor
final class SharedReadingMethods {
    private(set) var examples: [[String: String]] = []

    func remember(_ spec: APIDataSpec) {
        guard let url = try? spec.requestURL(), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host, let card = spec.card, let primary = spec.fields.first(where: { $0.key == card.primaryKey }) else { return }
        for (key, identity) in spec.expectations ?? [:] {
            guard !identity.isEmpty, let field = spec.fields.first(where: { $0.key == key }) else { continue }
            let segments = url.pathComponents.map { $0.caseInsensitiveCompare(identity) == .orderedSame ? "{identity}" : $0 }
            let queryIdentity = components.queryItems?.first { $0.value?.caseInsensitiveCompare(identity) == .orderedSame }?.name
            guard segments.contains("{identity}") || queryIdentity != nil else { continue }
            let path = "/" + segments.filter { $0 != "/" }.joined(separator: "/")
            var example = ["host": host, "path": path, "identityPointer": field.pointer, "valuePointer": primary.pointer]
            example["identityQueryParameter"] = queryIdentity
            example["unitPointer"] = spec.fields.first { $0.key == card.unitKey }?.pointer
            example["displayNamePointer"] = spec.fields.first { $0.key == card.displayNameKey }?.pointer
            example["unit"] = primary.unit
            if !examples.contains(example), examples.count < 4 { examples.append(example) }
        }
    }
}

/// Keep the human's full instruction intact. An assignment selects one outcome
/// from that instruction, including when its conditions occur elsewhere in it.
struct CardAssignment {
    let methods: SharedReadingMethods
    let original: String
    let focus: String
    var clauses: [String] = []
    var siblingFocuses: [String] = []

    var messages: [[String: Any]] {
        // In a list of names the surrounding words carry the shared activity.
        // Hide sibling names from this instruction, while keeping the untouched
        // original locally for authorization and complex cross-clause qualifiers.
        var scoped = original
        if !siblingFocuses.isEmpty, clauses.isEmpty, original.count <= 100,
            original.rangeOfCharacter(from: CharacterSet(charactersIn: "。;；!?！？\n")) == nil,
            ([focus] + siblingFocuses).allSatisfy({ $0.count <= 40 && !$0.contains(where: { ",，。;；".contains($0) }) }),
            !siblingFocuses.contains(where: { focus.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(focus) }) {
            for sibling in siblingFocuses { scoped = scoped.replacingOccurrences(of: sibling, with: "…") }
        }
        return [
            ["role": "system", "content": "Carry out the shared activity for the assigned focus only. Apply relevant qualifiers and corrections. Ellipses stand for other independently handled items. Verify this subject, name its card recognizably and finish this one result."],
            ["role": "user", "content": JSONText.encode(["sourceRequest": scoped, "assignedFocus": focus, "applicableClauses": clauses])]
        ]
    }

    func permitsActionEvidence(_ quote: String) -> Bool {
        original.contains(quote) && (quote.contains(focus) || focus.contains(quote))
    }

}

struct IndependentCards {
    static let schema = ToolSchema.function("separate_cards",
        "Allocate independent outcomes before acting. Supply one verbatim identifying excerpt per card: a name exactly as typed (including misspellings), clause or independently usable deliverable. For a short noisy input, @offset:length selects original characters without retyping them. Excerpts may appear anywhere in the request. When the request contains shared conditions or exceptions, include their verbatim clauses for each affected subject. Each executor receives its assigned subject and the shared request context. Keep dependent steps, comparisons and explicitly combined results together.",
        ["subjects": ["type": "array", "minItems": 2, "maxItems": 8,
                      "items": ["type": "string", "maxLength": 640]],
         "conditions": ["type": "array", "maxItems": 8, "items": ["type": "object",
             "properties": ["subject": ["type": "string"], "quotes": ["type": "array", "maxItems": 12, "items": ["type": "string"]]],
             "required": ["subject", "quotes"]]]], required: ["subjects"])

    let assignments: [CardAssignment]

    @MainActor init(_ input: [String: Any], request: String) throws {
        let shortWords = request.count <= 120 ? request.split(whereSeparator: { $0.isWhitespace }).prefix(16) : ArraySlice<Substring>()
        let spans = shortWords.map { word in
            let offset = request.distance(from: request.startIndex, to: word.startIndex)
            return "@\(offset):\(word.count)"
        }
        let choices = spans.count > 1 ? " Whitespace-delimited spans in input order: " + spans.joined(separator: ", ") : ""
        let invalid = ToolArgumentError(path: "$.subjects", issue: "copy the subject as typed, keeping its typos, script and spacing. For a short request you can instead select spans with subjects such as @0:2 (zero-based character offset:length). Use the original human message." + choices)
        guard let subjects = input["subjects"] as? [String], (2...8).contains(subjects.count) else { throw invalid }
        let quotes = try subjects.map { subject -> String in
            let raw = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = request.range(of: raw, options: [.caseInsensitive, .widthInsensitive]) { return String(request[match]) }
            if raw.hasPrefix("@"), raw.count < 16 {
                let parts = raw.dropFirst().split(separator: ":")
                if parts.count == 2, let start = Int(parts[0]), let length = Int(parts[1]),
                    start >= 0, start < request.count, length > 0, length <= request.count - start {
                    return String(request.dropFirst(start).prefix(length))
                }
            }
            throw invalid
        }
        guard Set(quotes.map { $0.lowercased() }).count == quotes.count else { throw invalid }

        // Match the longest excerpts first so embedded names need their own mention.
        var used: [Range<String.Index>] = []
        for quote in quotes.sorted(by: { $0.count > $1.count }) {
            guard !quote.isEmpty, quote.count <= 640 else { throw invalid }
            let previousCount = used.count
            var start = request.startIndex
            while let range = request.range(of: quote, range: start..<request.endIndex) {
                start = range.upperBound
                if !used.contains(where: { $0.overlaps(range) }) { used.append(range); break }
            }
            guard used.count > previousCount else { throw invalid }
        }
        var conditions: [String: [String]] = [:]
        for item in input["conditions"] as? [[String: Any]] ?? [] {
            guard let subject = item["subject"] as? String, let index = subjects.firstIndex(of: subject) ?? quotes.firstIndex(of: subject),
                let clauses = item["quotes"] as? [String] else { continue }
            // Preserve the original instruction when a child has shared qualifiers.
            conditions[quotes[index], default: []].append(contentsOf: clauses.filter { !$0.isEmpty && request.contains($0) })
        }
        let methods = SharedReadingMethods()
        assignments = quotes.map { focus in
            CardAssignment(methods: methods, original: request, focus: focus, clauses: conditions[focus] ?? [], siblingFocuses: quotes.filter { $0 != focus })
        }
    }
}

extension AgentController {
    /// For a number calculated from the user's own scoped instructions, a quick
    /// independent review can catch a missed condition before the card is visible.
    func reviewAssignedReading(_ surface: TaskSurface) async throws {
        guard let run = RequestRun.current, let assignment = run.assignment, !observations.hasSamples,
            !operatedPage, model.settings.useFast, Date() >= model.fastTriageRetryAfter,
            !model.isLiveTest || CommandLine.arguments.contains("--allow-live-services"),
            JevRequestTriage.eligible(assignment.original),
            let url = URL(string: model.settings.fast.baseURL), url.scheme == "https", url.host == "api.typesafe.ai",
            let primary = CardMarkup.bindingKeys(in: surface.markup.compactHTML).subtracting(["title", "status"]).first,
            let reading = surface.state[primary],
            let range = reading.range(of: #"[+−-]?[0-9]+(?:[.,][0-9]+)*"#, options: .regularExpression)
        else { return }
        // Only the numeric part travels alongside the already eligible human instruction.
        let number = String(reading[range])
        guard run.reviewedReadings.insert(assignment.focus + "|" + number).inserted,
            let key = try? await SecretStore.loadAvailable(model.settings.fastKeyAccount), !key.isEmpty else { return }
        let scores = try? await JevClient.judge(endpoint: model.settings.fast, key: key,
            state: ["request": assignment.original, "focus": assignment.focus, "visibleNumber": number],
            questions: ["contradiction": "Independently derive the requested primary result for the assigned focus using the human's numbers, shared conditions and exceptions. Is the displayed number demonstrably wrong? An unknown value or a reasonable interpretation is not a contradiction."],
            timeout: 1.5)
        guard let score = scores?["contradiction"], score.isFinite, (0.90...1).contains(score) else { return }
        throw ToolArgumentError(path: "$.state", issue: "independently recompute the primary result from the original supplied inputs. Recheck shared rules and corrections for this assigned subject before publishing.")
    }

    func startIndependentCards(_ assignments: [CardAssignment]) {
        let first = assignments[0]
        RequestRun.current?.assignment = first
        unavailableTools.remove("read_value")
        for assignment in assignments.dropFirst() {
            model.startCommand(assignment.focus, receivedAt: requestStartedAt,
                               forceNewTask: true, assignment: assignment, initialFamilies: loadedToolFamilies)
        }
        currentRequest = first.focus
        model.activeRequest?.input = currentRequest
        model.latestIntent = currentRequest
        if let id = model.requestCardID, let index = model.sideTasks.firstIndex(where: { $0.id == id && $0.kind == .result }) {
            model.sideTasks[index].intent = currentRequest
            model.sideTasks[index].title = String(currentRequest.prefix(80))
        }
        Diagnostics.record("cards_partitioned", ["candidateCount": assignments.count, "requestID": model.activeRequest?.id.uuidString ?? ""])
    }
}
