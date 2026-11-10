#if DEBUG
    import Foundation

    @MainActor
    enum RequestTriageCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw AppError.message(label) }
                checks.append(label)
            }
            var media = SideTask(kind: .web, title: "PRIVATE TITLE")
            media.listening = true
            media.sourceURL = "https://private.example/secret"
            let input = JevRequestTriage.request(text: "Pause the music", candidates: [media], explicit: nil)
            let payload = JSONText.encode(input.state)
            try check(
                !payload.contains(media.title) && !payload.contains("private.example")
                    && !payload.contains(media.id.uuidString),
                "Jev routing receives no titles, URLs, persistent IDs or conversation history")
            for text in [
                "my password is hello", "API key: abc", "病历内容", "contact a@b.com", "https://private.example",
                String(repeating: "x", count: 801),
            ] {
                try check(
                    !JevRequestTriage.eligible(text),
                    "Sensitive or oversized request skips optional Jev: \(checks.count)")
            }
            try check(JevRequestTriage.eligible("帮我把这首歌单曲循环"), "Ordinary short requests remain eligible")
            func answer(_ choice: String, _ options: Set<String>, _ confidence: Double = 1) -> [String: Any] {
                [
                    "type": "choice", "choice": choice, "confidence": confidence,
                    "probabilities": Dictionary(uniqueKeysWithValues: options.map { ($0, $0 == choice ? 1.0 : 0.0) }),
                ]
            }
            var answers: [String: Any] = [
                "route": answer("task_0", input.routes),
                "budget": answer("low", Set(JevRequestTriage.budgetOptions.keys)),
                "control": answer("pause", Set(JevRequestTriage.actionOptions.keys)),
            ]
            func decode() throws -> RequestTriage {
                try JevRequestTriage.decode(
                    JSONSerialization.data(withJSONObject: ["answers": answers]), candidates: [media], explicit: nil,
                    routes: input.routes)
            }
            let advice = try decode()
            try check(
                advice.target == media.id && advice.budget == .low && advice.directIntent()?.playbackIntent == "pause",
                "High-confidence advice yields only an existing-media control contract")
            answers["route"] = answer("task_0", input.routes, 0.5)
            try check(try decode().directIntent() == nil, "Uncertain target cannot execute even a confident control")
            try check(
                !RequestTriage(target: media.id, routeKnown: true).resolvesRouting(hasCandidates: true),
                "A confident task guess remains advisory until purpose is checked during interpretation")
            try check(
                advice.resolvesRouting(hasCandidates: true),
                "A validated direct control retains its zero-model execution path")
            try check(
                !RequestTriage(routeKnown: true).resolvesRouting(hasCandidates: true),
                "A new-task prediction cannot hide existing candidate activities from interpretation")
            try check(
                RequestTriage(routeKnown: true).resolvesRouting(hasCandidates: false),
                "A self-contained request without candidates needs no second routing decision")
            answers["route"] = answer("new", input.routes)
            try check(
                try decode().routeKnown && decode().directIntent() == nil,
                "New-task routing never becomes a media control")
            let explicitAdvice = try JevRequestTriage.decode(
                JSONSerialization.data(withJSONObject: ["answers": answers]), candidates: [media], explicit: media.id,
                routes: input.routes)
            try check(
                explicitAdvice.target == media.id && explicitAdvice.routeKnown,
                "User-selected conversations override even a confident Jev suggestion to start another task")
            answers["route"] = answer("task_0", input.routes)
            answers["control"] = answer("none", Set(JevRequestTriage.actionOptions.keys))
            try check(try decode().action == nil, "Complex and multi-part requests retain main-model interpretation")
            let malformed = TriageChoice(
                type: "choice", choice: "low", confidence: 1, probabilities: ["low": 0.4, "normal": 0.6, "high": 0])
            try check(
                malformed.accepted(options: Set(JevRequestTriage.budgetOptions.keys), threshold: 0.8) == nil,
                "Confidence cannot override a contradictory probability distribution")
            try check(
                ThinkingBudget.standard.parameters(for: Endpoint(baseURL: "https://api.x.ai/v1", model: "grok-4.7"))[
                    "reasoning_effort"] as? String == "low",
                "Default budget preserves the provider compatibility setting")
            try check(
                ThinkingBudget.high.parameters(for: Endpoint(baseURL: "https://unknown.example/v1", model: "grok-4.7"))
                    .isEmpty, "Unknown gateways receive no guessed reasoning parameters")
            try check(
                ThinkingBudget.high.parameters(for: Endpoint(baseURL: "https://api.x.ai/v1", model: "grok-4.7"))[
                    "reasoning_effort"] as? String == "high", "Supported Grok receives the selected effort")
            try check(
                ThinkingBudget.low.parameters(
                    for: Endpoint(baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3.2"))[
                        "enable_thinking"] as? Bool == false,
                "Supported hybrid DeepSeek uses non-thinking for low effort")
            let storeName = "orvlet.triage." + UUID().uuidString
            let store = UserDefaults(suiteName: storeName)!
            defer { store.removePersistentDomain(forName: storeName) }
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            model.sideTasks = [media]
            model.sideTasks[0].created = .distantPast
            model.archivedTaskHistory = (0..<20).map { index in
                SideTask(kind: .workspace, title: "Closed activity \(index)")
            }
            let routing = model.routingContext(explicit: nil)
            try check(
                routing.count == 16 && routing.first?["id"] as? String == media.id.uuidString
                    && routing.first?["availability"] as? String == "available"
                    && routing.first?["continuationTargetID"] as? String == media.id.uuidString,
                "An older current activity stays visible ahead of newer closed conversations in bounded routing context"
            )
            try check(
                routing.dropFirst().allSatisfy { $0["availability"] as? String == "archived" },
                "Historical conversations are explicitly marked as history rather than current task candidates")
            let historicalID = model.archivedTaskHistory[0].id
            try check(
                model.routingContext(explicit: historicalID).first?["id"] as? String == historicalID.uuidString,
                "An explicitly referenced historical task remains available for restoration")
            model.archivedTaskHistory = []
            // Exercise the real interpreter and wire contract with an intentionally
            // wrong high-confidence Jev target, not an interpretation override.
            var currency = SideTask(kind: .workspace, title: "Currency converter")
            currency.intent = "100港币兑rmb"
            model.sideTasks = [currency, media]
            model.settings.useFast = true
            model.agent.requestEndpoint = Endpoint(baseURL: "http://127.0.0.1:19244/ownership", model: "fixture")
            for (text, expected, capability) in [
                ("明天香港天气", Optional<String>.none, RequestCapability.data),
                ("放另一首歌", Optional(media.id.uuidString), RequestCapability.music),
            ] {
                model.agent.preparedRequest = PreparedRequest(
                    text: text, triage: RequestTriage(capability: capability, target: currency.id, routeKnown: true),
                    model: model)
                let corrected = try await model.agent.understand(
                    text, clarification: nil, key: "TEST_ONLY", globalRouting: true)
                try check(
                    corrected.targetTaskID == expected,
                    "Interpretation can correct a wrong Jev owner while preserving same-purpose reuse: " + text)
                // The global router transfers the corrected plan without another call.
                model.agent.preparedRequest = PreparedRequest(text: text, intent: corrected, triage: nil, model: model)
                model.agent.requestEndpoint = Endpoint(baseURL: "http://127.0.0.1:1/unreachable", model: "fixture")
                let transferred = try await model.agent.understand(text, clarification: nil, key: "TEST_ONLY")
                try check(
                    transferred.targetTaskID == expected, "Corrected ownership transfers without a second model call")
                model.agent.requestEndpoint = Endpoint(baseURL: "http://127.0.0.1:19244/ownership", model: "fixture")
            }
            model.agent.requestEndpoint = nil
            model.sideTasks = [media]
            var full = RequestIntent(kind: .information)
            full.targetTaskID = media.id.uuidString
            let prepared = PreparedRequest(text: "Explain this", intent: full, triage: nil, model: model)
            try check(
                prepared.usable(text: "Explain this", explicit: media.id, model: model),
                "Fresh interpretation can transfer from global router to its task")
            try check(
                !prepared.usable(text: "Something else", explicit: media.id, model: model),
                "A new message cannot reuse an older interpretation")
            let expired = PreparedRequest(
                text: "Explain this", intent: full, triage: nil, model: model, created: Date().addingTimeInterval(-20))
            try check(
                !expired.usable(text: "Explain this", explicit: media.id, model: model),
                "Long-queued requests are reinterpreted rather than trusting stale routing")
            var interpretations = 0
            model.agent.interpretationOverride = { _ in
                interpretations += 1
                return RequestIntent(kind: .information)
            }
            model.agent.preparedRequest = prepared
            _ = try await model.agent.understand("Explain this", clarification: nil, key: "")
            try check(interpretations == 0, "Executor consumes the global interpretation without another model call")
            model.agent.preparedRequest = PreparedRequest(
                text: "Explain this", intent: full,
                triage: RequestTriage(capability: .control), model: model)
            _ = try await model.agent.understand("Explain this", clarification: nil, key: "")
            try check(
                model.agent.requestCapability == .control && interpretations == 0,
                "Prepared global interpretations preserve their capability scope without expanding the executor catalogue"
            )
            model.sideTasks[0].sourceURL = "https://different.example"
            model.agent.preparedRequest = prepared
            _ = try await model.agent.understand("Explain this", clarification: nil, key: "")
            try check(interpretations == 1, "A changed task source invalidates the transferred interpretation")
            model.settings.useFast = false
            let disabled = await model.prepareFastRequest("Pause music", explicit: nil)
            try check(disabled.triage == nil, "Disabled Jev immediately uses the default path")
            let fixture = try await JevRequestTriage.judge(
                text: "Pause music", candidates: [media], explicit: nil,
                endpoint: Endpoint(baseURL: "http://127.0.0.1:19244/v1", model: "fixture"), key: "TEST_ONLY")
            try check(
                fixture.target == media.id && fixture.action == "pause",
                "Typed Jev choice request and response work against the local fixture")
            model.settings.useFast = true
            model.agent.preparedRequest = PreparedRequest(
                text: "Complex task", triage: RequestTriage(budget: .high), model: model)
            _ = try await model.agent.understand("Complex task", clarification: nil, key: "")
            try check(
                model.agent.thinkingBudget == .high,
                "Jev budget reaches execution without replacing detailed interpretation")
            _ = try await model.agent.understand("Next ordinary task", clarification: nil, key: "")
            try check(model.agent.thinkingBudget == .standard, "Thinking budget does not leak into the next request")
            model.settings.useFast = false
            model.agent.preparedRequest = PreparedRequest(
                text: "Complex task", triage: RequestTriage(budget: .high), model: model)
            _ = try await model.agent.understand("Complex task", clarification: nil, key: "")
            try check(
                model.agent.thinkingBudget == .standard, "Disabling Jev invalidates even already-prepared budget advice"
            )
            let started = Date()
            var timedOut = false
            do {
                _ = try await JevRequestTriage.judge(
                    text: "Pause", candidates: [media], explicit: nil,
                    endpoint: Endpoint(baseURL: "http://127.0.0.1:19244/slow", model: "fixture"), key: "TEST_ONLY",
                    timeout: 0.15)
            } catch { timedOut = true }
            try check(
                timedOut && Date().timeIntervalSince(started) < 1.5,
                "An unresponsive Jev endpoint has a bounded wait and no automatic retry")
            let independent = PreparedRequest(
                text: "New task", intent: RequestIntent(kind: .information), triage: nil, model: model)
            model.sideTasks.append(SideTask(kind: .timer, title: "New context"))
            try check(
                !independent.usable(text: "New task", explicit: nil, model: model),
                "New tasks invalidate a previously independent routing decision")
            let timerID = try model.startTimer(seconds: 120, title: "Synthetic countdown")
            model.settings.useFast = true
            model.agent.interpretationOverride = { _ in
                throw AppError.message("Timer fast path unexpectedly used interpretation")
            }
            model.agent.completionOverride = { _ in
                throw AppError.message("Timer fast path unexpectedly used execution model")
            }
            for operation in ["pause", "resume"] {
                let text = "Synthetic timer " + operation
                let fast = PreparedRequest(
                    text: text,
                    triage: RequestTriage(
                        budget: .low, target: timerID, routeKnown: true, action: operation, localControl: true),
                    model: model)
                _ = try await model.agent.run(text, taskID: timerID, prepared: fast)
                let timer = model.sideTasks.first(where: { $0.id == timerID })!
                try check(
                    (timer.deadline == nil) == (operation == "pause") && timer.remaining > 100,
                    "Natural " + operation + " can use existing timer controls without a model round or reset")
            }
            return checks
        }
        static func live(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            var rows: [[String: Any]] = []
            do {
                let fastKey = try await SecretStore.loadAvailable(model.settings.fastKeyAccount)
                let mainKey = try await SecretStore.loadAvailable(model.settings.mainConnection.keyAccount)
                guard !fastKey.isEmpty, !mainKey.isEmpty else {
                    throw AppError.message("Configured model keys are unavailable")
                }
                var music = SideTask(kind: .web, title: "Synthetic music")
                music.listening = true
                music.playing = true
                model.sideTasks = [music]
                let cases: [(String, String?)] = [
                    ("Pause the current music", "pause"), ("把这首歌单曲循环", "loop"),
                    ("Turn off repeat for this track", "unloop"), ("Explain why prime numbers are infinite", nil),
                    ("Play jazz instead", nil), ("Pause the music and make a countdown for ten minutes", nil),
                    (
                        "Design and prove a lock-free concurrent queue algorithm with memory reclamation, analyze ABA races and provide implementation and adversarial tests",
                        nil
                    ),
                ]
                for (text, expected) in cases {
                    let start = Date()
                    let input = JevRequestTriage.request(text: text, candidates: [music], explicit: nil)
                    let base = model.settings.fast.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let raw = try await ModelClient.request(
                        url: URL(string: base + "/systemone")!, key: fastKey,
                        body: ["model": model.settings.fast.model, "state": input.state, "questions": input.questions],
                        timeout: 1.2)
                    let advice = try JevRequestTriage.decode(
                        JSONSerialization.data(withJSONObject: raw), candidates: [music], explicit: nil,
                        routes: input.routes)
                    let fastTime = Date().timeIntervalSince(start)
                    var row: [String: Any] = [
                        "case": text, "jevSeconds": fastTime, "answers": raw["answers"] ?? [:],
                        "action": advice.action ?? "none", "budget": advice.budget.rawValue,
                        "routeKnown": advice.routeKnown, "expectedControl": expected ?? "none",
                        "controlCorrect": advice.action == expected,
                        "unsafeControl": advice.action != nil && advice.action != expected,
                    ]
                    if !CommandLine.arguments.contains("--triage-probe-only") {
                        let mainStart = Date()
                        do {
                            let baseline = try await model.agent.understand(
                                text, clarification: nil, key: mainKey, globalRouting: true)
                            row["baselineKind"] = baseline.kind.rawValue
                            row["mainInterpretationSeconds"] = Date().timeIntervalSince(mainStart)
                        } catch { row["baselineError"] = error.localizedDescription }
                    }
                    rows.append(row)
                }
                if CommandLine.arguments.contains("--triage-probe-only") {
                    var timer = SideTask(kind: .timer, title: "Synthetic countdown")
                    timer.deadline = Date().addingTimeInterval(120)
                    for operation in ["pause", "resume"] {
                        let text = operation == "pause" ? "Pause the countdown" : "Resume the countdown"
                        let started = Date()
                        let advice = try await JevRequestTriage.judge(
                            text: text, candidates: [timer], explicit: timer.id, endpoint: model.settings.fast,
                            key: fastKey)
                        rows.append([
                            "case": text, "jevSeconds": Date().timeIntervalSince(started),
                            "action": advice.action ?? "none", "localControl": advice.localControl,
                            "unsafeControl": advice.action != nil && advice.action != operation,
                        ])
                    }
                }
                try JSONSerialization.data(
                    withJSONObject: [
                        "ok": rows.allSatisfy { $0["unsafeControl"] as? Bool == false }, "cases": rows,
                        "scope": "Synthetic requests only; classification latency, not end-to-end playback latency",
                    ], options: [.prettyPrinted, .sortedKeys]
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-triage-live.json"))
                exit(rows.allSatisfy { $0["unsafeControl"] as? Bool == false } ? 0 : 1)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "cases": rows, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-triage-live.json"))
                exit(1)
            }
        }
    }
#endif
