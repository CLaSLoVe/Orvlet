#if DEBUG
    import Foundation

    @MainActor
    enum FastCardReuseCheck {
        static func answers(
            text: String, cards: [FastCardReuse.Candidate], tasks: [SideTask], values: [String: String],
            route: String = "new"
        ) -> [String: Any] {
            var request = JevRequestTriage.request(text: text, candidates: tasks, explicit: nil)
            FastCardReuse.augment(state: &request.state, questions: &request.questions, candidates: cards, tasks: tasks)
            var selections = [
                "route": route, "instance": "automatic", "budget": "low", "control": "none", "reuse_card": "card_0",
                "card_0_fit": "ready",
            ]
            for (j, slot) in (cards.first?.slots ?? []).enumerated() {
                selections["card_0_field_\(j)"] =
                    slot.values.firstIndex(of: values[slot.key] ?? "").map { "v\($0)" } ?? "unsure"
            }
            return request.questions.mapValues { raw in
                let q = raw as! [String: Any]
                let options = q["criteria"] as! [String: String]
                return options
            }.reduce(into: [String: Any]()) { result, row in
                let selected = selections[row.key] ?? (row.value["fallback"] == nil ? "unsure" : "fallback")
                result[row.key] = [
                    "type": "choice", "choice": selected, "confidence": 1.0,
                    "probabilities": row.value.mapValues { _ in 0.0 }.merging([selected: 1.0]) { _, new in new },
                ]
            }
        }
        static func decode(
            _ answers: [String: Any], cards: [FastCardReuse.Candidate], tasks: [SideTask] = [], explicit: UUID? = nil
        ) throws -> RequestTriage {
            let request = JevRequestTriage.request(text: "Synthetic request", candidates: tasks, explicit: explicit)
            return try JevRequestTriage.decode(
                JSONSerialization.data(withJSONObject: ["answers": answers]), candidates: tasks, explicit: explicit,
                routes: request.routes, cards: cards)
        }
        static func saved(_ surface: TaskSurface, id: UUID = UUID()) -> SideTask {
            var task = SideTask(id: id, kind: .workspace, title: surface.title)
            task.taskSurface = surface
            task.markup = surface.markup
            task.liveValues = surface.state
            return task
        }
        static func live(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            func report(_ object: [String: Any]) {
                guard
                    let data = try? JSONSerialization.data(
                        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                else { return }
                try? data.write(to: URL(fileURLWithPath: "/tmp/orvlet-fast-reuse-live.json"))
                // Inherited stdout also works with the production app sandbox enabled.
                try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
            }
            var rows: [[String: Any]] = []
            do {
                guard URL(string: model.settings.fast.baseURL)?.host == "api.typesafe.ai",
                    URL(string: model.settings.fast.baseURL)?.scheme == "https"
                else { throw AppError.message("The configured Jev endpoint is unavailable") }
                let key = try await SecretStore.loadAvailable(model.settings.fastKeyAccount)
                guard !key.isEmpty else { throw AppError.message("The configured Jev credential is unavailable") }
                let currency = APIDataCheck.currency()
                let currencySurface = try currency.surface(
                    title: "Currency conversion",
                    state: (currency.inputs ?? [:]).merging([
                        "base": "HKD", "quote": "CNY", "rate": "0.9", "converted": "90.00",
                        "resultStatus": "", "sourceDate": "Synthetic", "sourceHost": "api.frankfurter.dev",
                    ]) { _, new in new })
                let runtime = TaskRuntimeSpec(sources: [
                    TaskDataSource(key: "clock", kind: .clock, format: .time, timeZone: "Asia/Hong_Kong")
                ])
                let clockSurface = TaskSurface(
                    title: "Clock", markup: try BuiltinCards.clock(runtime), fields: [],
                    actions: [], state: [:], runtime: runtime, preset: "clock")
                // No personal recipes, tasks, history, or main-model calls enter this live probe.
                let recipes = [
                    InterfaceRecipe(
                        id: UUID(),
                        purpose: "Convert an amount between two currencies using current daily reference rates",
                        kind: .workspace, markup: currencySurface.markup, surface: currencySurface, stateKeys: []),
                    InterfaceRecipe(
                        id: UUID(), purpose: "Show the current local time for one city or time zone",
                        kind: .workspace, markup: clockSurface.markup, surface: clockSurface, stateKeys: []),
                ]
                let cases: [(String, [String: String]?)] = [
                    ("Convert 100 HKD to CNY", ["amount": "100", "fromCurrency": "HKD", "toCurrency": "CNY"]),
                    ("把200美元换算成人民币", ["amount": "200", "fromCurrency": "USD", "toCurrency": "CNY"]),
                    ("Show the current time in London", nil),
                    ("显示东京现在的时间", nil),
                    ("Convert 100 HKD", nil),
                    ("Convert 100 HKD to CNY and subtract a 5 percent fee", nil),
                    ("Do not convert 100 HKD to CNY; explain how exchange rates work", nil),
                    ("Change it to Tokyo time", nil),
                    ("Show Tokyo and London times together", nil),
                    ("Convert 100 HKD to CNY at the rate on January 1, 2020", nil),
                    ("Convert 200 USD to EUR", ["amount": "200", "fromCurrency": "USD", "toCurrency": "EUR"]),
                ]
                for (text, expected) in cases {
                    let tasks = text == "Convert 200 USD to EUR" ? [saved(currencySurface, id: recipes[0].id)] : []
                    let explicit = tasks.first?.id
                    let cards = FastCardReuse.candidates(text: text, recipes: recipes)
                    var input = JevRequestTriage.request(text: text, candidates: tasks, explicit: explicit)
                    FastCardReuse.augment(
                        state: &input.state, questions: &input.questions, candidates: cards, tasks: tasks)
                    let base = model.settings.fast.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let start = Date()
                    do {
                        let raw = try await ModelClient.request(
                            url: URL(string: base + "/systemone")!, key: key,
                            body: [
                                "model": model.settings.fast.model, "state": input.state, "questions": input.questions,
                            ], timeout: 1.2)
                        let advice = try JevRequestTriage.decode(
                            JSONSerialization.data(withJSONObject: raw),
                            candidates: tasks, explicit: explicit, routes: input.routes, cards: cards)
                        let actual = advice.card.map { card in
                            card.inputs
                        }
                        rows.append([
                            "case": text, "seconds": Date().timeIntervalSince(start),
                            "matched": advice.card != nil, "correct": actual == expected,
                            "parameters": actual ?? [:], "answers": raw["answers"] ?? [:],
                        ])
                    } catch {
                        rows.append([
                            "case": text, "seconds": Date().timeIntervalSince(start),
                            "matched": false, "correct": false, "error": error.localizedDescription,
                        ])
                    }
                }
                let ok = rows.allSatisfy { $0["correct"] as? Bool == true }
                report([
                    "ok": ok, "cases": rows,
                    "scope":
                        "Synthetic requests and methods; live Jev classification only, no main model or source fetch",
                ])
                exit(ok ? 0 : 1)
            } catch {
                report(["ok": false, "cases": rows, "error": error.localizedDescription])
                exit(1)
            }
        }
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message(label) }
                checks.append(label)
            }
            let name = "orvlet.fast-reuse." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.useFast = true
            defer {
                model.taskRuntime.stopAll()
                model.taskClock?.invalidate()
                model.browser.dispose()
                model.adaptive.invalidate()
            }
            var spec = APIDataCheck.currency()
            spec.card = DataCardPreset(kind: .currency, primaryKey: "converted", unitKey: "quote")
            var fetches = 0
            var failSource = false
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { url in
                    fetches += 1
                    if failSource { throw AppError.message("Synthetic unavailable source") }
                    let parts = URL(string: url)!.path.split(separator: "/").suffix(2)
                    return ["date": today, "base": String(parts.first!), "quote": String(parts.last!), "rate": 0.9]
                })
            let surface = try spec.surface(title: "Currency conversion", state: try await model.apiData.read(spec))
            let task = saved(surface)
            model.interfaceMemory.remember(
                task, purpose: "Convert an amount between two currencies using current daily reference rates")
            // Exercise the real first-request assembly through a local model fixture.
            // The main model confirms a matching purpose and selects its saved method together.
            model.sideTasks = [task]
            let firstText = "Convert 100 USD to CNY"
            model.agent.requestEndpoint = Endpoint(baseURL: "http://127.0.0.1:19244/planning", model: "fixture")
            model.agent.preparedRequest = PreparedRequest(
                text: firstText, triage: RequestTriage(capability: .control, target: task.id, routeKnown: true),
                model: model)
            let firstPlan = try await model.agent.understand(
                firstText, clarification: nil, key: "", globalRouting: true)
            model.agent.requestEndpoint = nil
            try check(
                firstPlan.targetTaskID == task.id.uuidString && firstPlan.steps.first?.tool == "reuse_saved_ui",
                "A control follow-up confirms matching ownership and retains its method catalogue")
            model.agent.completionOverride = { _ in throw AppError.message("A saved plan must not rebuild") }
            fetches = 0
            let firstReply = try await model.agent.run(
                firstText, taskID: task.id,
                prepared: PreparedRequest(text: firstText, intent: firstPlan, triage: nil, model: model))
            try check(
                fetches == 1 && firstReply.contains("90.00") && model.sideTasks.count == 1,
                "A main-model reuse plan executes one fresh fetch without a second planning or construction call")
            model.agent.completionOverride = nil
            model.sideTasks = []
            model.interfaceMemory.remember(
                task, purpose: "Convert an amount between two currencies using current daily reference rates")
            let text = "Convert 100 HKD to CNY"
            let cards = FastCardReuse.candidates(
                text: text, recipes: model.interfaceMemory.recipes.filter { $0.id == task.id })
            try check(cards.count == 1, "Verified parameterized API recipes become Jev reuse candidates")
            for (literal, expected) in [("1,000.50", "1000.50"), (".5", ".5"), ("1e3", "1e3")] {
                let amount = FastCardReuse.candidates(
                    text: "Convert \(literal) HKD to CNY", recipes: cards.map(\.recipe)
                )
                .first?.slots.first(where: { $0.key == "amount" })?.values
                try check(
                    amount == [expected],
                    "Numeric reuse preserves the complete literal \(literal), never a partial match")
            }
            var request = JevRequestTriage.request(text: text, candidates: [task], explicit: nil)
            FastCardReuse.augment(
                state: &request.state, questions: &request.questions, candidates: cards, tasks: [task])
            let payload = JSONText.encode(["state": request.state, "questions": request.questions])
            try check(
                !payload.contains(task.id.uuidString) && !payload.contains(spec.url)
                    && !payload.contains(spec.calculation!) && !payload.contains("sourceChecked"),
                "Reuse matching shares bounded method descriptions and choices, not IDs, endpoints, handlers or previous results"
            )
            try check(
                request.questions["reuse_card"] != nil && request.questions["route"] != nil
                    && request.questions["card_0_field_2"] != nil,
                "Card matching and independent parameter choices join the existing Jev routing request")
            let selections = answers(
                text: text, cards: cards, tasks: [],
                values: ["amount": "100", "fromCurrency": "HKD", "toCurrency": "CNY"])
            let advice = try decode(selections, cards: cards)
            var duplicate = cards[0].recipe
            duplicate.id = UUID()
            duplicate.purpose = "The same method with different example values"
            let deduplicated = FastCardReuse.candidates(text: text, recipes: [cards[0].recipe, duplicate])
            try check(deduplicated.count == 1, "Equivalent saved methods share one classification choice")
            var duplicateTask = task
            duplicateTask.id = duplicate.id
            let duplicateAnswers = answers(
                text: text, cards: deduplicated, tasks: [duplicateTask],
                values: [
                    "amount": "100", "fromCurrency": "HKD", "toCurrency": "CNY",
                ], route: "task_0")
            try check(
                try decode(duplicateAnswers, cards: deduplicated, tasks: [duplicateTask]).card?.recipeID
                    == duplicate.id,
                "Deduplication retains the exact saved method owned by an existing conversation")
            let methodPayload = JSONText.encode(model.interfaceMemory.planningCatalogue())
            try check(
                methodPayload.contains("fromCurrency") && methodPayload.contains("select")
                    && !methodPayload.contains(spec.calculation!) && !methodPayload.contains(spec.url)
                    && !methodPayload.contains("<"),
                "The first main-model plan sees reusable input contracts without source code or UI markup")
            try check(
                advice.card?.inputs == ["amount": "100", "fromCurrency": "HKD", "toCurrency": "CNY"]
                    && advice.directIntent()?.route == .api,
                "A complete confident choice produces a fresh-data execution contract")
            var modelCalls = 0
            model.agent.interpretationOverride = { _ in
                modelCalls += 1
                return RequestIntent(kind: .information)
            }
            model.agent.completionOverride = { _ in
                modelCalls += 1
                return ["role": "assistant", "content": "Main fallback"]
            }
            fetches = 0
            let started = Date()
            let prepared = PreparedRequest(text: text, triage: advice, model: model)
            let reply = try await model.agent.run(text, prepared: prepared)
            try check(
                modelCalls == 0 && fetches == 1 && reply.contains("90.00")
                    && model.sideTasks.contains(where: { $0.state["converted"] == "90.00" && $0.state["base"] == "HKD" }
                    ),
                "Jev-matched reuse executes and fetches fresh data with zero main-model calls")
            Diagnostics.record(
                "fast_reuse_fixture", ["seconds": Date().timeIntervalSince(started), "mainCalls": modelCalls])

            var uncertain = selections
            var field = uncertain["card_0_field_0"] as! [String: Any]
            field["confidence"] = 0.5
            uncertain["card_0_field_0"] = field
            try check(
                try decode(uncertain, cards: cards).card == nil,
                "An uncertain parameter cannot be rescued by a confident card match")
            var missing = selections
            missing.removeValue(forKey: "card_0_field_1")
            try check(
                try decode(missing, cards: cards).card == nil,
                "Missing input answers fall back without inheriting prior values")
            var extra = selections
            extra["card_0_fit"] = [
                "type": "choice", "choice": "fallback", "confidence": 1.0,
                "probabilities": ["fallback": 1.0, "ready": 0.0],
            ]
            try check(
                try decode(extra, cards: cards).card == nil,
                "Unsupported qualifiers or multiple tasks prevent direct execution")
            var malformed = selections
            malformed["card_0_field_0"] = [
                "type": "choice", "choice": "v999", "confidence": 1.0, "probabilities": ["v999": 1.0],
            ]
            try check(
                try decode(malformed, cards: cards).card == nil,
                "Jev cannot invent parameter values outside the supplied options")
            var unrelated = task
            unrelated.id = UUID()
            let wrong = answers(
                text: text, cards: cards, tasks: [unrelated], values: advice.card!.inputs, route: "task_0")
            try check(
                try decode(wrong, cards: cards, tasks: [unrelated]).card == nil,
                "A matched recipe cannot overwrite an unrelated task of the same category")
            let owned = answers(text: text, cards: cards, tasks: [task], values: advice.card!.inputs, route: "new")
            try check(
                try decode(owned, cards: cards, tasks: [task], explicit: task.id).target == task.id,
                "An explicit owning conversation retains authority over Jev routing")
            var changedMethod = task
            changedMethod.taskSurface?.apiData?.calculation = "return {state:{converted:'incorrect'}};"
            try check(
                !FastCardReuse.owns(changedMethod, recipe: cards[0].recipe),
                "Matching appearance and identity cannot overwrite locally modified calculation logic")
            model.sideTasks = [task]
            let targeted = try decode(owned, cards: cards, tasks: [task], explicit: task.id)
            let pendingTarget = PreparedRequest(text: text, triage: targeted, model: model)
            try check(
                !PreparedRequest(text: text, triage: advice, model: model)
                    .usable(text: text, explicit: task.id, model: model),
                "A global new-card match cannot be transplanted into an explicitly addressed conversation")
            model.sideTasks[0].liveValues?["amount"] = "250"
            try check(
                !pendingTarget.usable(text: text, explicit: task.id, model: model),
                "Editing a target input invalidates its queued Jev decision")
            model.sideTasks = [task]
            model.interfaceMemory.remember(task, purpose: cards[0].recipe.purpose)
            let beforeTarget = modelCalls
            _ = try await model.agent.run(
                text, taskID: task.id,
                prepared: PreparedRequest(text: text, triage: targeted, model: model))
            try check(
                modelCalls == beforeTarget && model.sideTasks.count == 1
                    && model.sideTasks.first?.id == task.id && model.sideTasks.first?.state["converted"] == "90.00",
                "Direct reuse within an owning conversation updates that card without creating or overwriting another task"
            )
            model.sideTasks = []

            let uncertainAdvice = try decode(uncertain, cards: cards)
            let beforeFallback = modelCalls
            let missingReply = try await model.agent.run(
                text, prepared: PreparedRequest(text: text, triage: uncertainAdvice, model: model))
            try check(
                modelCalls == beforeFallback + 2 && missingReply == "Main fallback",
                "Uncertain reuse goes through main interpretation and planning")
            model.sideTasks = []  // This case is a fresh task, without a prior fallback result to route to.
            let beforeFailure = modelCalls
            // The successful request above legitimately refreshed this recipe's purpose.
            // Start this failure case from the exact recipe classified by Jev.
            model.interfaceMemory.remember(task, purpose: cards[0].recipe.purpose)
            failSource = true
            fetches = 0
            model.agent.completionOverride = { _ in
                modelCalls += 1
                return [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": "failure", "type": "function",
                            "function": [
                                "name": "finish",
                                "arguments": JSONText.encode(["outcome": "blocked", "reply": "Source unavailable"]),
                            ],
                        ]
                    ],
                ]
            }
            var sourceFailureReported = false
            do {
                _ = try await model.agent.run(text, prepared: PreparedRequest(text: text, triage: advice, model: model))
            } catch { sourceFailureReported = error.localizedDescription == "Source unavailable" }
            try check(
                sourceFailureReported && modelCalls == beforeFailure + 1 && fetches == 1,
                "Failed execution supplies its receipt to one model decision without repeated routing or stale success")
            model.agent.completionOverride = { _ in
                modelCalls += 1
                return ["role": "assistant", "content": "Main fallback"]
            }
            failSource = false
            let changed = PreparedRequest(text: text, triage: advice, model: model)
            var edited = task
            edited.markup?.css += ".preset-number{font-size:30px}"
            model.interfaceMemory.remember(edited, purpose: "Edited currency conversion")
            try check(
                !changed.usable(text: text, explicit: nil, model: model),
                "Editing a saved recipe invalidates an in-flight or queued reuse decision")
            model.interfaceMemory.remember(task, purpose: cards[0].recipe.purpose)
            let expired = PreparedRequest(
                text: text, triage: advice, model: model, created: Date().addingTimeInterval(-20))
            try check(
                !expired.usable(text: text, explicit: nil, model: model),
                "Expired Jev matches cannot execute after a long queue wait")
            model.settings.useFast = false
            let disabledBefore = modelCalls
            _ = try await model.agent.run(text, prepared: PreparedRequest(text: text, triage: advice, model: model))
            try check(modelCalls == disabledBefore + 2, "Disabling Jev disables already-prepared direct reuse")
            model.settings.useFast = true

            var local = TaskRuntimeCheck.surface()
            local.actions = [local.actions[0]]
            local.markup = try TaskForm(
                inputs: [
                    .init(key: "amount", label: "Amount", kind: "number"),
                    .init(key: "people", label: "People", kind: "number"),
                ], outputs: [.init(key: "share", label: "Per person")],
                buttons: [.init(action: "calculate", label: "Calculate")], compactKey: "share"
            ).markup()
            local.checks = [
                TaskActionCheck(
                    action: "calculate", input: ["amount": "90", "people": "3"], expected: ["share": "30.00"])
            ]
            let localTask = saved(try local.validated())
            model.interfaceMemory.remember(localTask, purpose: "Split an amount equally among people")
            let splitText = "Split 180 between 3 people"
            let splitCards = FastCardReuse.candidates(
                text: splitText, recipes: [try model.interfaceMemory.recipe(localTask.id.uuidString)])
            let splitAdvice = try decode(
                answers(text: splitText, cards: splitCards, tasks: [], values: ["amount": "180", "people": "3"]),
                cards: splitCards)
            model.sideTasks = []  // No existing task competes with this independent reuse fixture.
            let beforeSplit = modelCalls
            _ = try await model.agent.run(
                splitText, prepared: PreparedRequest(text: splitText, triage: splitAdvice, model: model))
            try check(
                modelCalls == beforeSplit && model.sideTasks.contains(where: { $0.state["share"] == "60.00" }),
                "Saved local code is reinitialized and behavior-checked with new inputs without a model call")
            let runtime = TaskRuntimeSpec(sources: [
                TaskDataSource(key: "clock", kind: .clock, format: .time, timeZone: "Asia/Hong_Kong")
            ])
            let clockTask = saved(
                TaskSurface(
                    title: "Hong Kong time", markup: try BuiltinCards.clock(runtime), fields: [], actions: [],
                    state: [:], runtime: runtime, preset: "clock"))
            model.interfaceMemory.remember(clockTask, purpose: "Show the current local time for one city or time zone")
            let clockText = "Show the current time in London"
            let clockCards = FastCardReuse.candidates(
                text: clockText, recipes: [try model.interfaceMemory.recipe(clockTask.id.uuidString)])
            try check(
                clockCards.isEmpty,
                "Time zone inference uses the main model instead of a fixed city shortlist")
            let privateRecipe = InterfaceRecipe(
                id: UUID(), purpose: "Private passport records", kind: .workspace, markup: local.markup, surface: local,
                stateKeys: local.fields)
            try check(
                FastCardReuse.candidates(text: splitText, recipes: [privateRecipe]).isEmpty,
                "Sensitive saved-method descriptions never enter the Jev candidate catalogue")
            var fixed = spec
            fixed.url = "https://example.com/fixed"
            var fixedSurface = surface
            fixedSurface.apiData = fixed
            var unsafeRecipe = cards[0].recipe
            unsafeRecipe.surface = fixedSurface
            try check(
                FastCardReuse.candidates(text: text, recipes: [unsafeRecipe]).isEmpty,
                "A fixed-source API recipe cannot silently reuse the wrong place or currency pair")
            return checks
        }
    }
#endif
