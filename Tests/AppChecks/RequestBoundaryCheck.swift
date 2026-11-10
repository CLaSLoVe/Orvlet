#if DEBUG
    import Foundation

    @MainActor
    enum RequestBoundaryCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            func rejects(_ value: [String: Any], _ tool: String, path: String) throws {
                do {
                    try ToolContract.validate(tool, value)
                    throw AppError.message("Accepted invalid arguments")
                } catch let error as ToolArgumentError {
                    try check(error.path == path, "Argument boundary identifies " + tool + " " + path)
                }
            }
            try rejects(
                ["title": "Snapshot", "source": ["url": "https://example.org/data"], "fields": []], "query_api",
                path: "$.source.fields")
            try rejects(
                [
                    "title": "Snapshot",
                    "source": ["url": "https://example.org/data", "fields": [["key": "value", "pointer": "/value"]]],
                ], "query_api", path: "$.source.fields[0].label")
            try rejects(
                [
                    "title": "Snapshot",
                    "source": [
                        "url": "https://example.org/data",
                        "fields": [["key": "value", "label": "Value", "pointer": "/value"]],
                    ],
                    "calculation": "return {}",
                ], "query_api", path: "$")
            try rejects(
                [
                    "title": "Snapshot",
                    "source": [
                        "url": "https://example.org/data",
                        "fields": [["key": "value", "label": "Value", "pointer": "/value"]], "invented": true,
                    ],
                ],
                "query_api", path: "$.source")
            try rejects(
                [
                    "title": "Snapshot",
                    "source": [
                        "url": "https://example.org/data",
                        "fields": Array(
                            repeating: ["key": "v", "label": "Value", "pointer": "/v"],
                            count: APIDataSpec.maximumSourceFields + 1),
                    ],
                ], "query_api", path: "$.source.fields")
            try rejects(["url": 7], "navigate", path: "$.url")
            try rejects(["seconds": true, "title": "Timer"], "timer_start", path: "$.seconds")
            try rejects(["id": "method", "state": ["private-key-name": 42]], "reuse_saved_ui", path: "$.state.*")
            try ToolContract.validate("reuse_saved_ui", ["id": "method", "state": ["amount": "42"]])
            checks.append("Dynamic saved-method inputs retain their typed contract")
            let optional = try ToolContract.arguments(
                "query_api",
                [
                    "title": "Snapshot", "markup": NSNull(),
                    "source": [
                        "url": "https://example.org/data",
                        "fields": [["key": "value", "label": "Value", "pointer": "/value"]],
                        "updatedAtPointer": NSNull(), "card": NSNull(),
                    ],
                ])
            try check(
                optional["markup"] == nil && (optional["source"] as? [String: Any])?["updatedAtPointer"] == nil,
                "Optional nulls become absent before dispatch, including nested records")
            try rejects(["url": NSNull()], "navigate", path: "$.url")
            try rejects(["id": "method", "state": ["amount": NSNull()]], "reuse_saved_ui", path: "$.state.*")

            for kind in [RequestIntent.Kind.general, .timer, .calendar] {
                var pending = RequestIntent(
                    kind: kind, targetTaskID: UUID().uuidString,
                    requirements: [
                        OutcomeRequirement(label: "Missing parameter", anyOf: []),
                        OutcomeRequirement(label: "Known parameter", anyOf: ["value"]),
                    ],
                    clarificationQuestion: "Which parameter?", route: .api)
                pending.steps = [RequestStep(tool: "timer_start", arguments: "{}")]
                pending.stepsComplete = true
                pending.initialURL = "https://example.org"
                let asking = try pending.validated(for: "An incomplete request")
                try check(
                    asking.targetTaskID == pending.targetTaskID && asking.requirements.count == 1
                        && asking.steps.isEmpty && !asking.stepsComplete && asking.initialURL == nil
                        && asking.reuse == nil,
                    "Clarification preserves conversation and known facts without demanding or executing incomplete parameters"
                )
            }
            var incomplete = RequestIntent(
                kind: .general,
                requirements: [OutcomeRequirement(label: "Missing parameter", anyOf: [])])
            var incompleteRejected = false
            do { _ = try incomplete.validated(for: "Execute now") } catch { incompleteRejected = true }
            try check(incompleteRejected, "Execution still rejects incomplete source identity requirements")
            incomplete.clarificationQuestion = " "
            var emptyQuestionRejected = false
            do { _ = try incomplete.validated(for: "Ask") } catch { emptyQuestionRejected = true }
            try check(emptyQuestionRejected, "Clarification must contain an actual bounded question")
            try check(
                RequestCapability.data.defaultRoute == .api && RequestCapability.workspace.defaultRoute == .local
                    && RequestCapability.browser.defaultRoute == .web
                    && RequestCapability.general.defaultRoute == .auto,
                "Unspecified execution routes inherit the selected capability without a second broad tool catalogue")
            for kind in [SideTaskKind.timer, .workspace] {
                let task = SideTask(kind: kind, title: "Local task")
                var intent = RequestIntent(
                    kind: kind == .timer ? .timer : .general, playbackIntent: "pause", targetTaskID: task.id.uuidString,
                    route: .local)
                intent.steps = [RequestStep(tool: "control_task", arguments: "{\"operation\":\"pause\"}")]
                let control = try intent.resolvingControlDomain(task).validated(for: "Pause this task")
                try check(
                    control.playbackIntent == nil && control.route == .local && control.kind == .general,
                    "Resolved local control cannot accidentally request media playback")
                let other = SideTask(kind: .workspace, title: "Another task")
                try check(
                    intent.resolvingControlDomain(other).playbackIntent == "pause",
                    "Domain normalization cannot borrow an unrelated owner")
            }
            try check(
                !BundledMethods.recipes.isEmpty,
                "Bundled executable methods load and validate without fabricated source values")
            var measured = BundledMethods.recipes[0].surface!
            let beforeMeasurement = SavedMethod.signature(measured)
            measured.markup.height += 80
            try check(
                SavedMethod.signature(measured) == beforeMeasurement,
                "Rendered content measurement does not change executable method identity")
            let targetSchema = ToolSchema.function(
                "interpret_request", "Interpret",
                [
                    "kind": ["type": "string"],
                    "targetTaskID": ["type": ["string", "null"], "enum": [NSNull()]],
                ], required: ["kind"])
            var targetAttempts = 0
            let repairedTarget = try await RequestIntent.interpret(
                "Use the saved method", messages: [], schema: targetSchema
            ) { _, _, _ in
                targetAttempts += 1
                return [
                    "content": targetAttempts == 1
                        ? "{\"kind\":\"general\",\"targetTaskID\":\"method-id\"}"
                        : "{\"kind\":\"general\",\"targetTaskID\":null}"
                ]
            }
            try check(
                targetAttempts == 2 && repairedTarget.targetTaskID == nil,
                "Method IDs cannot become task destinations and invalid routing is repaired before execution")
            let suite = "orvlet.boundary." + UUID().uuidString
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            let webRecipe = InterfaceRecipe(
                id: UUID(), purpose: "Reusable transport", kind: .web,
                markup: CardMarkup(html: "<div data-bind='title'></div>", css: ""), plan: .webpage, stateKeys: [])
            store.set(try JSONEncoder().encode([webRecipe]), forKey: "interfaceRecipes.v1")
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            defer {
                model.agent.stop()
                model.agentTask?.cancel()
                model.globalRoutingTask?.cancel()
                model.taskClock?.invalidate()
                model.browser.dispose()
            }
            let dialogueID = UUID()
            let unrelatedID = UUID()
            model.messages = [
                ChatMessage(
                    taskID: dialogueID, text: "Compare the delivery estimates for the day after tomorrow", isUser: true),
                ChatMessage(taskID: dialogueID, text: "Which destination?", isUser: false),
                ChatMessage(taskID: unrelatedID, text: "Private unrelated task", isUser: true),
                ChatMessage(taskID: dialogueID, text: "Hong Kong", isUser: true),
            ]
            let dialogue = model.taskInterpretationContext(dialogueID, excluding: "Hong Kong")
            try check(
                dialogue.count == 2 && dialogue[0]["text"]?.contains("day after tomorrow") == true
                    && dialogue[1]["text"] == "Which destination?" && dialogue.allSatisfy { $0["sentAt"] != nil },
                "Clarification retains the original period and assistant question with dates, excluding other tasks")
            model.messages = []
            model.agent.nativeRequestActive = true
            var refusedUnownedDesign = false
            do {
                _ = try await model.agent.execute("reuse_saved_ui", ["id": webRecipe.id.uuidString])
            } catch { refusedUnownedDesign = error.localizedDescription.contains("before reusing a webpage design") }
            try check(
                refusedUnownedDesign && model.requestPageID == nil,
                "Reusing a webpage design cannot adopt an unrelated task's source")
            model.agent.nativeRequestActive = false
            let sourceIntent = RequestIntent(kind: .general, route: .web)
            func offeredNames() -> Set<String> {
                Set(
                    model.agent.offeredTools(for: sourceIntent).compactMap {
                        ($0["function"] as? [String: Any])?["name"] as? String
                    })
            }
            try check(
                offeredNames().contains("find_music") && !offeredNames().contains("observe")
                    && !offeredNames().contains("compose_ui") && !offeredNames().contains("reuse_saved_ui"),
                "Source discovery omits page operations and construction schemas until a page is owned")
            model.beginAmbientRequest("Inspect an existing source")
            model.adoptRequestTask(.web(UUID()))
            try check(
                offeredNames().contains("observe") && offeredNames().contains("compose_ui"),
                "Owned sources expose their page operations at execution time")
            model.activeRequest = nil
            model.sideTasks = []
            model.beginAmbientRequest("Prepare a project estimate")
            let placeholder = model.requestCardID!
            try check(
                JevRequestTriage.candidates(model, explicit: nil).contains { $0.id == placeholder },
                "Preparing tasks are routable before a card or source exists")
            try check(
                JevRequestTriage.candidates(model, explicit: nil, excluding: placeholder).isEmpty,
                "A new request does not route to its own preparation placeholder")
            let context = JevRequestTriage.request(
                text: "Change the estimate", candidates: model.sideTasks, explicit: nil)
            try check(
                JSONText.encode(context.state).contains("Prepare a project estimate"),
                "Router receives bounded task purpose while work is running")
            let prepared = PreparedRequest(
                text: "Independent request", triage: RequestTriage(routeKnown: true), model: model)
            var queued = SideTask(kind: .result, title: "Queued report")
            queued.intent = "Prepare a second report"
            model.sideTasks.append(queued)
            try check(
                !prepared.usable(text: "Independent request", explicit: nil, model: model),
                "A newly registered task invalidates an earlier new-task decision")
            let owner = UUID()
            model.queuedTaskRequests = [TaskUserRequest(taskID: placeholder, text: "Add a section")]
            model.adoptRequestTask(.workspace(owner))
            try check(
                model.resolvedTaskID(placeholder) == owner && model.queuedTaskRequests[0].taskID == owner,
                "Queued follow-ups retain ownership when a preparation card acquires its resource")
            model.queuedTaskRequests = []
            model.sideTasks = []
            model.activeRequest = nil

            // Two global follow-ups arrive before the first routing call finishes.
            // All three requests go through the ordinary command/route entry points.
            var firstStarted = false
            var routingOwner: UUID?
            model.agent.interpretationOverride = { text in
                if text == "Prepare a project estimate" {
                    firstStarted = true
                    try await Task.sleep(for: .seconds(2))
                } else {
                    try await Task.sleep(for: .milliseconds(40))
                }
                var intent = RequestIntent(kind: .information)
                intent.targetTaskID = text == "Prepare a project estimate" ? nil : routingOwner?.uuidString
                intent.answer = "Estimate prepared"
                return intent
            }
            model.selectChat(true)
            model.command = "Prepare a project estimate"
            model.sendCommand()
            for _ in 0..<100 where !firstStarted { try await Task.sleep(for: .milliseconds(5)) }
            let initial = model.requestCardID!
            routingOwner = initial
            model.command = "Include materials"
            model.sendCommand()
            model.command = "Also include delivery"
            model.sendCommand()
            for _ in 0..<200 where model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            try check(
                model.pendingRoutingRequests.isEmpty && model.queuedTaskRequests.isEmpty,
                "Overlapping routing requests are resolved in order instead of prematurely creating new tasks")
            try check(
                model.messages.filter { $0.isUser }.suffix(3).allSatisfy { $0.taskID == initial },
                "Running-task follow-ups share one conversation owner")
            for _ in 0..<500 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
            try check(!model.busy && !model.taskFailed, "Superseded interpretation resumes with the latest task input")

            // Cancellation reaches the in-flight source operation, before commit.
            model.beginAmbientRequest("Fetch a public measurement")
            model.agent.nativeRequestActive = true
            model.agent.activeTaskID = model.requestCardID!
            var started = false
            var cancelled = false
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { _ in
                    started = true
                    do { try await Task.sleep(for: .seconds(5)) } catch {
                        cancelled = true
                        throw error
                    }
                    return ["value": 3]
                })
            let operation = Task {
                try await model.agent.execute(
                    "query_api",
                    [
                        "title": "Measurement",
                        "source": [
                            "url": "https://example.org/data",
                            "fields": [["key": "value", "label": "Value", "pointer": "/value"]],
                        ],
                    ])
            }
            for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(5)) }
            model.agent.steer("Use the new measurement")
            _ = try? await operation.value
            try check(
                started && cancelled && !model.sideTasks.contains { $0.taskSurface?.apiData != nil },
                "A superseded source operation is cancelled and cannot publish its old result")

            model.activeRequest = nil
            model.sideTasks = []
            model.agent.pendingMessages = []
            let good: [String: Any] = [
                "title": "Measurement",
                "source": [
                    "url": "https://example.org/data",
                    "fields": [["key": "value", "label": "Value", "pointer": "/value"]],
                ],
            ]
            var fetches = 0
            model.apiData = APIDataService(
                code: model.taskCode,
                fetch: { _ in
                    fetches += 1
                    if fetches == 1 { throw AppError.message("The source did not verify the requested identity") }
                    return ["value": 42]
                })
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.route = .api
                intent.steps = [RequestStep(tool: "query_api", arguments: JSONText.encode(good))]
                intent.stepsComplete = true
                return intent
            }
            var repairs = 0
            model.agent.completionOverride = { turns in
                repairs += 1
                let arguments: [String: Any] =
                    repairs == 1
                    ? ["title": "Measurement", "source": ["url": "https://example.org/data"], "fields": []] : good
                if repairs == 2 {
                    try check(
                        JSONText.encode(turns).contains("$.source.fields"),
                        "The model receives the missing field path rather than a generic decoder message")
                }
                return ["tool_calls": [RequestStep(tool: "query_api", arguments: JSONText.encode(arguments)).call]]
            }
            _ = try await model.agent.run("Read a fresh measurement")
            try check(
                fetches == 2 && repairs == 2 && model.sideTasks.contains { $0.state["value"] == "42" },
                "Source failure then malformed repair still permits a valid bounded repair without opening a page")
            return checks
        }
    }
#endif
