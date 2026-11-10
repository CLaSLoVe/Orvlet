import Foundation

/// A model-produced interpretation, not a keyword classifier. The host checks
/// its schema and execution receipts; language understanding belongs to the model.
struct RequestIntent: Codable {
    enum TaskAction: String, Codable { case perform, cancel, complete }
    var taskAction: TaskAction = .perform
    var summary: String? = nil
    var requiresFreshData = false
    var mediaSetting: String? = nil
    enum Route: String, Codable { case auto, local, web, api }
    enum Kind: String, Codable { case general, information, calendar, timer }
    var kind: Kind
    var missingFields: [String] = []
    var continuesClarification = false
    var needsBrowserContext = false
    var playbackIntent: String? = nil
    var reuse: SavedMethodInvocation? = nil
    var steps: [RequestStep] = []
    var stepsComplete = false
    var goals: [String] = []
    var contextDetail = "state"
    var answer: String? = nil
    var timerSeconds: Double? = nil
    var timerEvidence: String? = nil
    var targetTaskID: String? = nil
    var restoreTaskID: String? = nil
    var requirements: [OutcomeRequirement] = []
    var initialURL: String? = nil
    var presentationOnly = false
    var clarificationQuestion: String? = nil
    var behavior: TaskBehavior = .snapshot
    var timeZones: [String] = []
    var route: Route = .auto
    var updateIntervalSeconds: Double? = nil
    var isCalendar: Bool { kind == .calendar }
    var isTimer: Bool { kind == .timer }
    var isNative: Bool { isCalendar || isTimer }
    var needsEventTitle: Bool { isCalendar && missingFields.contains("title") }

    func resolvingControlDomain(_ task: SideTask?) -> RequestIntent {
        guard let task, task.id.uuidString == targetTaskID, task.kind != .web,
            !steps.isEmpty, steps.allSatisfy({ $0.tool == "control_task" })
        else { return self }
        var result = self
        result.playbackIntent = nil
        result.mediaSetting = nil
        result.needsBrowserContext = false
        result.route = .local
        return result
    }

    func validated(for request: String) throws -> RequestIntent {
        // Waiting for human input is a non-executable state, not an incomplete execution plan.
        if let question = clarificationQuestion {
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 400 else {
                throw AppError.message("Return a short clarification question.")
            }
            var asking = RequestIntent(
                kind: kind, targetTaskID: targetTaskID,
                requirements: Array(requirements.filter { $0.validated() }.prefix(6)),
                clarificationQuestion: question, route: route)
            asking.continuesClarification = continuesClarification
            return asking
        }
        // Category describes creation; existing-task controls carry their own
        // capability and target. Normalize once, before steps are consumed.
        if kind == .timer, targetTaskID != nil, !steps.isEmpty,
            steps.allSatisfy({ $0.tool == "control_task" }), timerSeconds == nil
        {
            var control = self
            control.kind = .general
            return try control.validated(for: request)
        }
        guard goals.count <= 6, goals.allSatisfy({ !$0.isEmpty && $0.count <= 240 }),
            steps.allSatisfy({ $0.goal == nil || goals.indices.contains($0.goal!) })
        else {
            throw AppError.message("Assign each action to a declared request goal.")
        }
        if stepsComplete, !steps.isEmpty, !goals.isEmpty {
            let covered = Set(steps.compactMap { $0.goal ?? (goals.count == 1 ? 0 : nil) })
            guard covered == Set(goals.indices) else {
                throw ToolArgumentError(
                    path: "$.goals",
                    issue: "a complete plan must cover every declared goal; keep only outcomes actually requested by the user, never field names or internal verification steps, and assign actions to each remaining goal")
            }
        }
        guard steps.count <= 4 else {
            throw AppError.message("Use at most four known actions before observing their results.")
        }
        for step in steps {
            guard AgentToolName(rawValue: step.tool) != nil, allows(step.tool), step.arguments.utf8.count <= 60000
            else {
                throw AppError.message("The planned action does not match the request contract.")
            }
            _ = try step.input()
        }
        guard ["state", "page", "definition"].contains(contextDetail) else {
            throw AppError.message("Unknown context detail.")
        }
        guard mediaSetting == nil || ["none", "loop", "unloop"].contains(mediaSetting!) else {
            throw AppError.message("Unknown media setting.")
        }
        if let interval = updateIntervalSeconds {
            guard interval.isFinite, (1...3600).contains(interval) else {
                throw AppError.message("Use a bounded explicit update interval.")
            }
        }
        guard timeZones.count <= 6, timeZones.allSatisfy({ TimeZone(identifier: $0) != nil }) else {
            throw AppError.message("Use valid IANA time zones for the requested locations.")
        }
        guard playbackIntent == nil || ["none", "play", "pause"].contains(playbackIntent!) else {
            throw AppError.message("Invalid playback intent.")
        }
        guard requirements.count <= 6, requirements.allSatisfy({ $0.validated() }) else {
            throw AppError.message("Return explicit, bounded outcome requirements from the human request.")
        }
        guard
            !presentationOnly
                || (!isNative && requirements.isEmpty && initialURL == nil
                    && (playbackIntent == nil || playbackIntent == "none"))
        else { throw AppError.message("A source, value, playback or native task change cannot be presentationOnly.") }
        if ["play", "pause"].contains(playbackIntent ?? ""), [.local, .api].contains(route) {
            throw AppError.message("Playback requires the web/media execution route, not a local form or data recipe.")
        }
        if requiresFreshData && route == .local {
            throw AppError.message(
                "Current external facts require an API or web source, not a local cached calculation.")
        }
        if route == .local && (initialURL != nil || needsBrowserContext) {
            throw AppError.message("Local data tasks cannot require browser navigation.")
        }
        if route == .api && [.live, .advancing].contains(behavior) {
            throw AppError.message(
                "The API route produces a fresh snapshot or an editable result. Use snapshot for current/latest facts. Ongoing monitoring requires an explicitly scheduled task, not repeated snapshot tool calls."
            )
        }
        if route == .api && (initialURL != nil || needsBrowserContext) {
            throw AppError.message(
                "An API request cannot navigate a webpage. Keep its source and execution route consistent.")
        }
        if let initialURL {
            guard !isNative, let url = URL(string: initialURL), ["https", "http"].contains(url.scheme ?? ""),
                url.host != nil
            else { throw AppError.message("Initial navigation needs a valid web URL and a non-native request.") }
        }
        if isTimer && taskAction == .perform {
            guard let seconds = timerSeconds, seconds.isFinite, seconds > 0, seconds <= 7 * 86400,
                let evidence = timerEvidence?.trimmingCharacters(in: .whitespacesAndNewlines), !evidence.isEmpty,
                request.contains(evidence)
            else {
                throw AppError.message(
                    "A countdown needs an explicitly requested duration and an exact supporting quote from the human request. Asking for current/exact time, opening a clock website, or reusing a clock interface is general, not timer. Reinterpret the request; do not invent a duration."
                )
            }
        }
        return self
    }

    @MainActor
    static func decode(_ response: [String: Any], allowJSON: Bool = false) throws -> RequestIntent {
        let arguments = try StructuredResponse.arguments(response, named: "interpret_request", allowJSON: allowJSON)
        let value = try JSONDecoder().decode(RequestIntent.self, from: Data(arguments.utf8))
        let fields: Set<String> = ["title", "date", "start", "end", "timeZone", "calendar", "dateConflict"]
        guard value.missingFields.allSatisfy(fields.contains) else {
            throw AppError.message("The model returned invalid clarification fields.")
        }
        return value
    }

    /// Recover from providers that omit tool calls without bypassing semantic
    /// validation or granting a default capability to an unclassified request.
    @MainActor
    static func interpret(
        _ request: String, messages: [[String: Any]], schema: [String: Any],
        contextualize: (RequestIntent) throws -> RequestIntent = { $0 },
        complete: ([[String: Any]], [[String: Any]], String?) async throws -> [String: Any]
    ) async throws -> RequestIntent {
        var turns = messages
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var response: [String: Any] = [:]
            var received = false
            do {
                response = try await complete(
                    turns, attempt == 0 ? [schema] : [], attempt == 0 ? "interpret_request" : nil)
                received = true
                try Task.checkCancellation()
                let arguments = try StructuredResponse.arguments(response, named: "interpret_request", allowJSON: true)
                let raw = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
                if let parameters = (schema["function"] as? [String: Any])?["parameters"] as? [String: Any] {
                    try ToolContract.validate(raw, schema: parameters)
                }
                let intent = try contextualize(decode(response, allowJSON: true)).validated(for: request)
                Diagnostics.record(
                    "intent_validated",
                    [
                        "attempt": attempt + 1,
                        "format": (response["tool_calls"] as? [Any])?.isEmpty == false ? "tool" : "json",
                        "kind": intent.kind.rawValue,
                    ])
                return intent
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let transport =
                    (error as? URLError).map {
                        [URLError.timedOut, .networkConnectionLost].contains($0.code)
                    } ?? false
                // Interpretation has no side effects. One transient transport recovery shares
                // the existing two-attempt budget; auth/rate-limit errors and tool writes never retry here.
                if !received && !transport { throw error }
                // Diagnostics contain validation categories, never model content or user text.
                var failure = String(describing: type(of: error))
                if case DecodingError.keyNotFound(let key, _) = error { failure = "missing_field:" + key.stringValue }
                if case DecodingError.typeMismatch(_, let context) = error {
                    failure = "wrong_type:" + context.codingPath.map(\.stringValue).joined(separator: ".")
                }
                if case AppError.message(let message) = error { failure = message }

                Diagnostics.record(
                    transport ? "interpretation_transport_failure" : "intent_invalid",
                    [
                        "reason": failure,
                        "reasonCode": transport
                            ? "transient_transport" : error is DecodingError ? "invalid_arguments" : "invalid_intent",
                        "fieldPath": (error as? ToolArgumentError ?? ToolArgumentError.decoding(error))?.path ?? "",
                        "attempt": attempt + 1,
                        "toolCalls": (response["tool_calls"] as? [Any])?.count ?? 0,
                        "hasContent": !(response["content"] as? String ?? "").isEmpty,
                    ])
                guard attempt == 0 else {
                    if transport { throw error }
                    throw PipelineFailure.interpretation
                }
                let parameters = (schema["function"] as? [String: Any])?["parameters"] ?? [:]
                turns.append([
                    "role": "system",
                    "content":
                        "No valid interpretation was received. For this single recovery attempt, return ONLY one JSON object matching this schema, without calling tools or adding prose: "
                        + JSONText.encode(parameters)
                        + ". Reinterpret the latest human request. Validation feedback: "
                        + (ToolArgumentError.decoding(error)?.localizedDescription ?? error.localizedDescription),
                ])
            }
        }
        throw CancellationError()
    }

    func allows(_ tool: String) -> Bool {
        if tool == "calendar_create" || tool == "calendar_clarify" { return isCalendar }
        if tool == "timer_start" { return isTimer }
        // Native tasks do not need to visit a notice's tracking links or change music.
        if isNative { return tool == "finish" }
        if route == .local {
            return ["run_code", "present_ui", "control_task", "reuse_saved_ui", "finish", "visibility"].contains(tool)
        }
        if route == .api {
            return ["query_api", "inspect_api", "reuse_saved_ui", "finish"].contains(tool)
        }
        return true
    }
}

extension RequestIntent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        taskAction = try c.decodeIfPresent(TaskAction.self, forKey: .taskAction) ?? .perform
        mediaSetting = try c.decodeIfPresent(String.self, forKey: .mediaSetting)
        requiresFreshData = try c.decodeIfPresent(Bool.self, forKey: .requiresFreshData) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary).map { String($0.prefix(180)) }
        missingFields = try c.decodeIfPresent([String].self, forKey: .missingFields) ?? []
        continuesClarification = try c.decodeIfPresent(Bool.self, forKey: .continuesClarification) ?? false
        needsBrowserContext = try c.decodeIfPresent(Bool.self, forKey: .needsBrowserContext) ?? false
        playbackIntent = try c.decodeIfPresent(String.self, forKey: .playbackIntent)
        reuse = try c.decodeIfPresent(SavedMethodInvocation.self, forKey: .reuse)
        steps = try c.decodeIfPresent([RequestStep].self, forKey: .steps) ?? []
        stepsComplete = try c.decodeIfPresent(Bool.self, forKey: .stepsComplete) ?? false
        goals = try c.decodeIfPresent([String].self, forKey: .goals) ?? []
        contextDetail = try c.decodeIfPresent(String.self, forKey: .contextDetail) ?? "state"
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        timerSeconds = try c.decodeIfPresent(Double.self, forKey: .timerSeconds)
        timerEvidence = try c.decodeIfPresent(String.self, forKey: .timerEvidence)
        targetTaskID = try c.decodeIfPresent(String.self, forKey: .targetTaskID)
        restoreTaskID = try c.decodeIfPresent(String.self, forKey: .restoreTaskID)
        requirements = try c.decodeIfPresent([OutcomeRequirement].self, forKey: .requirements) ?? []
        initialURL = try c.decodeIfPresent(String.self, forKey: .initialURL)
        presentationOnly = try c.decodeIfPresent(Bool.self, forKey: .presentationOnly) ?? false
        clarificationQuestion = try c.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        behavior = try c.decodeIfPresent(TaskBehavior.self, forKey: .behavior) ?? .snapshot
        timeZones = try c.decodeIfPresent([String].self, forKey: .timeZones) ?? []
        route = try c.decodeIfPresent(Route.self, forKey: .route) ?? .auto
        updateIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .updateIntervalSeconds)
    }
}
