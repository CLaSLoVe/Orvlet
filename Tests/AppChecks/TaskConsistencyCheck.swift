#if DEBUG
    import AppKit

    @MainActor
    enum TaskConsistencyCheck {
        static func start() async {
            var checks: [String] = []
            var stage = ""
            func part(_ name: String, _ run: () async throws -> [String]) async throws {
                stage = name
                checks += try await run()
            }
            do {
                try await part("service boundaries") { try await ServiceBoundaryCheck.run() }
                try await part("conversation lifecycle") { try await conversationLifecycle() }
                try await part("runtime lifecycle") { try await RuntimeLifecycleCheck.run() }
                try await part("execution receipts") { try await ExecutionLedgerCheck.run() }
                try await part("pipeline") { try await PipelineCheck.run() }
                try await part("consistency") { try run() }
                try await part("task lifecycle") { try TaskLifecycleCheck.run() }
                try await part("required interpretation") { try await requiredInterpretation() }
                try await part("agent routing") { try await agentRouting() }
                try await part("foreground isolation") { try await TaskLifecycleCheck.foregroundIsolation() }
                try await part("direct action wins") { try await TaskLifecycleCheck.directActionWins() }
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-consistency-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: [
                    "ok": false, "stage": stage, "checks": checks, "error": error.localizedDescription,
                ]).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-consistency-checks.json"))
                exit(1)
            }
        }
        static func requiredInterpretation() async throws -> [String] {
            let tool = ToolSchema.function(
                "interpret_request", "Interpret the human request", ["kind": ["type": "string"]], required: ["kind"])
            let response = try await ModelClient.complete(
                endpoint: Endpoint(baseURL: "http://127.0.0.1:19244/required-tool", model: "fixture"), key: "",
                messages: [["role": "user", "content": "播放 DREAM FUNK"]], tools: [tool], reasoning: false,
                requiredTool: "interpret_request")
            let intent = try RequestIntent.decode(response).validated(for: "播放 DREAM FUNK")
            guard intent.playbackIntent == "play" else {
                throw AppError.message("Required interpretation did not use the structured response")
            }
            return [
                "Single-step interpretation requires its named tool and disallows parallel responses at the API boundary"
            ]
        }
        static func agentRouting() async throws -> [String] {
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
            var bridgeRefused = false
            do {
                _ = try await model.bridge.route(
                    "/rpc", ["tool": "reuse_saved_ui", "arguments": ["id": UUID().uuidString]])
            } catch { bridgeRefused = true }
            guard bridgeRefused else {
                throw AppError.message("Saved interfaces must not bypass human-request ownership through the bridge")
            }
            model.busy = true
            model.beginAmbientRequest("Show a live webpage reading")
            defer { model.browser.dispose() }
            var round = 0
            var refusals = 0
            var prematureFinishRefused = false
            var preciseRepair = false
            let markup = CardMarkup(
                html: "<strong data-bind='value'></strong>", compactHTML: "<span data-bind='value'></span>", css: "",
                height: 120)
            model.agent.completionOverride = { turns in
                round += 1
                let errors = turns.filter {
                    $0["role"] as? String == "tool"
                        && ($0["content"] as? String ?? "").contains("already owns a live webpage")
                }
                refusals = errors.count
                preciseRepair = turns.contains {
                    ($0["content"] as? String ?? "").contains("Invalid tool arguments at $.actions[0].id")
                }
                prematureFinishRefused = turns.contains {
                    $0["role"] as? String == "tool"
                        && ($0["content"] as? String ?? "").contains("has not passed validation")
                }
                let name: String
                let arguments: [String: Any]
                switch round {
                case 1:
                    name = "navigate"
                    arguments = ["url": "http://127.0.0.1:19244/fixture"]
                case 2, 4:
                    name = "present_ui"
                    arguments = [
                        "title": "Static duplicate",
                        "markup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(markup)), "fields": [],
                        "actions": [], "state": ["value": "stale"],
                    ]
                case 3:
                    name = "run_code"
                    arguments = ["code": "return {state:{value:'stale'}};"]
                case 5, 7:
                    name = "compose_ui"
                    guard
                        let selector = (model.lastObservation["readables"] as? [[String: Any]])?.first?["selector"]
                            as? String
                    else { throw AppError.message("The fixture has no observed reading") }
                    let plan = SurfacePlan(
                        components: [], width: 320, height: 150, markup: markup, actions: [],
                        readings: [CardReading(key: "value", selector: round == 5 ? "#invented" : selector)])
                    var specification =
                        (try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]).filter {
                            ["title", "markup", "actions", "readings"].contains($0.key)
                        }
                    if round == 5 {
                        specification["actions"] = [["binding": ["action": "media", "operation": "toggle"]]]
                    }
                    arguments = specification
                default:
                    name = "finish"
                    arguments = ["outcome": "page_ready", "reply": "Live page ready"]
                }
                return [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": UUID().uuidString, "type": "function",
                            "function": ["name": name, "arguments": JSONText.encode(arguments)],
                        ]
                    ],
                ]
            }
            _ = try await model.agent.run("Show a live webpage reading")
            model.finishAmbientRequest()
            model.busy = false
            guard refusals == 2, prematureFinishRefused, preciseRepair, model.sideTasks.count == 1,
                model.sideTasks[0].kind == .web,
                !model.sideTasks[0].isMediaTask, model.sideTasks[0].plan?.readings?.count == 1
            else {
                throw AppError.message(
                    "Page ownership check: refused=\(refusals), rounds=\(round), tasks=\(model.sideTasks.count), kinds=\(model.sideTasks.map { $0.kind.rawValue }), media=\(model.sideTasks.map { $0.isMediaTask }), readings=\(model.sideTasks.map { $0.plan?.readings?.count ?? -1 })"
                )
            }
            return [
                "A live page cannot be replaced by present_ui, even after a code call",
                "Correcting the model route leaves exactly one bound webpage task and no incidental media player",
                "Invalid interface bindings cannot be hidden by a premature finish claim",
                "Agent generation receives the same precise missing-field repair feedback as automatic generation",
            ]
        }
        static func run() throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                if !value { throw AppError.message(name) }
                checks.append(name)
            }
            var invalidTimer = false
            do { _ = try RequestIntent(kind: .timer).validated(for: "请再次打开 time.is 看准确时间") } catch {
                invalidTimer = true
            }
            try check(
                invalidTimer, "An AI timer classification without a human duration cannot start an invented countdown")
            let countdown = RequestIntent(kind: .timer, timerSeconds: 600, timerEvidence: "十分钟")
            try check(
                try countdown.validated(for: "帮我倒计时十分钟").timerSeconds == 600,
                "AI-extracted non-numeric durations are supported without keyword routing")
            invalidTimer = false
            do { _ = try countdown.validated(for: "看看现在的准确时间") } catch { invalidTimer = true }
            try check(invalidTimer, "A duration quote must come from this request, not a prior task")
            try check(AppSettings().taskStartPolicy == .taskFirst, "New installations default to task-first execution")
            try check(
                try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).taskStartPolicy == .taskFirst,
                "Existing settings migrate to task-first without a reset")
            let suite = "orvlet-consistency-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            try check(
                SurfaceCache.pageKey("https://example.com") == SurfaceCache.pageKey("https://example.com:443/"),
                "Equivalent root URLs share task identity without dropping content query parameters")
            var clock = SideTask(kind: .web, title: "Clock")
            clock.sourceURL = "https://example.com/clock"
            clock.hasMedia = true
            clock.mediaPrimary = true
            clock.playing = true
            try check(
                !clock.isMediaTask,
                "Unclassified incidental media never creates a player, including restored tasks without a plan")
            clock.plan = .webpage
            try check(
                !clock.isMediaTask,
                "Incidental playing media on a webpage cannot turn an information task into a player")
            var music = clock
            music.id = UUID()
            music.listening = true
            try check(
                music.isMediaTask, "Explicit listening retains immediate media controls before UI generation finishes")
            model.webURL = clock.sourceURL!
            let owner = model.browser.id
            model.hasCustomSurface = true
            try model.prepareBrowserForNewTask(destination: clock.sourceURL)
            try check(
                model.browser.id == owner && model.parkedBrowsers.isEmpty,
                "Opening the same URL keeps one browser task instead of parking a duplicate")
            try check(
                !SavedSession(url: clock.sourceURL!, title: "Clock", plan: .webpage, mediaType: "video").isMedia,
                "Restored page ads are not treated as resumable user media")
            clock.intent = "Show the live clock"
            music.intent = "Play music"
            model.sideTasks = [clock, music]
            model.latestIntent = "Another unrelated request"
            try check(
                model.interfaceIntent(for: clock.id) == "Show the live clock"
                    && model.interfaceIntent(for: music.id) == "Play music",
                "Automatic UI generation uses each task's own intent, never the last unrelated request")
            model.busy = true
            model.beginAmbientRequest("Live reading")
            model.adoptRequestTask(.web(clock.id))
            model.activity = "Reading page…"
            try check(
                model.taskActivity(clock) == .working("Reading page…") && model.taskActivity(music) == nil,
                "Work indicators belong to their task and do not mark unrelated playing music as busy")
            model.busy = false
            model.activeRequest = nil
            model.recordTaskOutcome(clock.id, .succeeded)
            try check(
                model.taskActivity(clock) == .succeeded,
                "Verified completion leaves a visible receipt on the owning card")
            let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
            model.interfaceJobs[clock.id] = pending
            try check(
                model.taskActivity(clock) == .working("Updating view…") && model.hasTaskWork,
                "A new interface edit supersedes an old completion indicator without replacing controls")
            model.recordInterfaceFailure(clock.id, AppError.message("Synthetic view failure"))
            model.interfaceJobs[clock.id] = nil
            pending.cancel()
            try check(
                model.taskActivity(clock) == .interfaceFailed
                    && model.sideTasks.first(where: { $0.id == clock.id })?.interfaceIssue
                        == PipelineFailure.presentation.localizedDescription,
                "An unsuccessful edit reports a recoverable view problem without exposing validation internals or failing the underlying task"
            )
            model.stopTaskActions(clock.id)
            try check(
                model.taskActivityReceipts[clock.id] == nil,
                "Closing or cancelling a task removes its operation receipts")
            model.sideTasks.removeAll { $0.id == clock.id }
            model.recordTaskOutcome(clock.id, .succeeded)
            try check(model.taskActivityReceipts[clock.id] == nil, "Late completion cannot resurrect a closed task")

            let markup = CardMarkup(
                html: "<section class='calm-surface'><strong data-bind='clock'></strong></section>",
                compactHTML: "<span data-bind='clock'></span>", css: "", height: 120)
            clock.plan = SurfacePlan(
                components: [], width: 320, height: 150, markup: markup, actions: [],
                readings: [CardReading(key: "clock", selector: "#clock")])
            try check(
                !clock.opensSourceByDefault,
                "A generated information card opens its interface by default, not a second webpage view")
            clock.markup = markup
            clock.liveValues = ["clock": "12:34:56"]
            clock.customCompact = true
            let modern = try JSONDecoder().decode(
                SurfacePlan.self,
                from: JSONSerialization.data(withJSONObject: [
                    "markup": try JSONSerialization.jsonObject(with: JSONEncoder().encode(markup)), "actions": [],
                    "readings": [["key": "clock", "selector": "#clock"]],
                ]))
            try check(
                modern.components.isEmpty && modern.width == 320 && modern.markup == markup,
                "Generated HTML no longer depends on obsolete native-template fields")
            let page: [String: Any] = [
                "url": "https://example.com/clock", "hasMedia": true, "mediaPrimary": true,
                "readables": [["selector": "#clock", "text": "12:34:57"]],
            ]
            try check(
                try clock.plan!.validated(observation: page).markup == markup,
                "A live clock card remains valid even when the page contains media")
            var decorativeReadings = clock.plan!
            decorativeReadings.markup = CardMarkup(
                html: "<strong>12:34:56</strong>", compactHTML: "<span>12:34:56</span>", css: "")
            var staticMarkupRejected = false
            do { _ = try decorativeReadings.validated(observation: page) } catch { staticMarkupRejected = true }
            try check(
                staticMarkupRejected, "Declaring readings without binding the displayed values cannot pass validation")
            var missingGlance = clock.plan!
            missingGlance.markup?.compactHTML = ""
            var missingGlanceRejected = false
            do { _ = try missingGlance.validated(observation: page) } catch { missingGlanceRejected = true }
            try check(missingGlanceRejected, "A live webpage card cannot silently omit its compact live view")
            var snapshot = clock.plan!
            snapshot.readings = []
            snapshot.markup = CardMarkup(
                html: "<strong data-bind='detail'>12:34:56</strong>", compactHTML: "<span>12:34:56</span>", css: "")
            var invalidSnapshot = false
            do { _ = try snapshot.validated(observation: page) } catch { invalidSnapshot = true }
            try check(invalidSnapshot, "A nonexistent detail binding cannot masquerade as a live webpage clock")
            snapshot.markup = CardMarkup(
                html: "<strong>12:34:56</strong>", compactHTML: "<span>12:34:56</span>", css: "")
            invalidSnapshot = false
            do { _ = try snapshot.validated(observation: page) } catch { invalidSnapshot = true }
            try check(invalidSnapshot, "Read-only webpage cards reject frozen values without declared live readings")
            try check(
                BrowserController.contentReady(["documentReady": "interactive", "text": "Useful page content"])
                    && !BrowserController.contentReady(["documentReady": "loading", "text": ""]),
                "A usable document need not wait for peripheral resources, while an empty loading page is not ready")
            model.interfaceMemory.remember(clock, purpose: "A calm live clock with seconds")
            let reloaded = InterfaceMemory(defaults: defaults)
            let reused = try reloaded.webPlan(clock.id.uuidString, observation: page)
            try check(
                reused.markup == markup && reused.interfaceRecipeID == clock.id,
                "Edited web design survives relaunch and reuses its exact markup")
            try check(
                !JSONText.encode(reloaded.catalogue).contains("12:34:56")
                    && !JSONText.encode(reloaded.catalogue).contains("example.com"),
                "Semantic selection catalogue excludes old values and page URLs")
            var rejected = false
            do { _ = try reloaded.webPlan(clock.id.uuidString, observation: ["readables": []]) } catch {
                rejected = true
            }
            try check(rejected, "Saved design cannot silently attach to missing live selectors")
            let rebound = try reloaded.webPlan(
                clock.id.uuidString,
                observation: ["url": "https://example.com/clock", "readables": [["selector": "#new-clock"]]],
                readings: [CardReading(key: "clock", selector: "#new-clock")])
            try check(
                rebound.markup == markup && rebound.readings?.first?.selector == "#new-clock",
                "Changed pages can rebind fresh readings without reconstructing the edited design")
            var workspace = SideTask(kind: .workspace, title: "Bill")
            workspace.taskSurface = TaskRuntimeCheck.surface()
            workspace.markup = workspace.taskSurface?.markup
            workspace.liveValues = workspace.taskSurface?.state
            model.interfaceMemory.remember(workspace, purpose: "Adjustable equal bill splitting")
            rejected = false
            do {
                _ = try model.interfaceMemory.taskSurface(workspace.id.uuidString, title: "New bill", state: [:])
            } catch { rejected = true }
            try check(rejected, "Independent task reuse requires fresh state instead of replaying old results")
            let fresh = try model.interfaceMemory.taskSurface(
                workspace.id.uuidString, title: "New bill", state: ["amount": "90", "people": "2", "share": "45.00"])
            try check(
                fresh.state["share"] == "45.00" && fresh.markup == workspace.markup,
                "Task designs and generated actions can be reused with new verified values")
            return checks
        }
    }
#endif
#if DEBUG
    extension TaskConsistencyCheck {
        static func conversationLifecycle() async throws -> [String] {
            let defaults = UserDefaults(suiteName: "orvlet-lifecycle-" + UUID().uuidString)!
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            var checks: [String] = []
            func check(_ ok: Bool, _ text: String) throws {
                guard ok else { throw AppError.message(text) }
                checks.append(text)
            }
            var draft = SideTask(kind: .result, title: "Calendar draft")
            draft.status = "Waiting for reply"
            model.sideTasks = [draft]
            model.appendMessage("Add a calendar event", isUser: true, taskID: draft.id)
            model.appendMessage("When should it start?", isUser: false, taskID: draft.id)
            let context = model.routingContext(explicit: nil)
            try check(
                context.contains(where: { $0["id"] as? String == draft.id.uuidString })
                    && JSONText.encode(context).contains("When should it start?"),
                "Global routing sees pending drafts and the assistant's clarification question")
            var playback = SideTask(kind: .web, title: "Listening")
            playback.listening = true
            playback.playing = true
            model.sideTasks.append(playback)
            let playbackContext = model.routingContext(explicit: nil).first {
                $0["id"] as? String == playback.id.uuidString
            }!
            try check(
                playbackContext["media"] as? Bool == true && playbackContext["playing"] as? Bool == true
                    && playbackContext["lifecycle"] as? String == "Open"
                    && playbackContext["lastConversationAt"] as? String != nil,
                "Routing exposes purpose, actual playback and lifecycle for content replacements")
            model.sideTasks.removeAll { $0.id == playback.id }
            model.archiveTaskHistory(playback)
            let closedContext = model.routingContext(explicit: nil).first {
                $0["id"] as? String == playback.id.uuidString
            }!
            try check(
                closedContext["lifecycle"] as? String == "Closed" && closedContext["playing"] as? Bool == false,
                "Closed playback history is distinguishable from an active replacement target")
            model.archivedTaskHistory.removeAll { $0.id == playback.id }
            model.beginAmbientRequest("A brand new request")
            let placeholder = model.requestCardID!
            try check(
                !model.routingContext(explicit: nil, excluding: placeholder).contains(where: {
                    $0["id"] as? String == placeholder.uuidString
                }), "A new request's temporary card cannot route back to itself as an existing task")
            model.finishAmbientRequest()
            model.openTaskConversation(draft.id)
            model.selectChat(true)
            try check(model.conversationTaskID == nil, "Global summon clears an explicitly bound conversation")
            var calls = 0
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .calendar)
                intent.taskAction = .cancel
                intent.targetTaskID = draft.id.uuidString
                intent.missingFields = ["title", "date", "start"]
                return intent
            }
            model.agent.completionOverride = { _ in
                calls += 1
                throw AppError.message("Cancellation must not enter execution")
            }
            let reply = try await model.agent.run("oh, it's cancelled")
            try check(
                calls == 0 && reply.contains("cancelled")
                    && model.sideTasks.first?.terminalLabel?.contains("Calendar draft") == true,
                "Natural cancellation exits without asking missing fields or executing a calendar write")
            try check(
                model.sideTasks.first?.expires != nil && !model.sideTasks[0].hidden,
                "Cancellation creates a named receipt with an automatic hide deadline")
            model.pointerInside = false
            model.menuTracking = false
            model.sideTasks[0].expires = Date().addingTimeInterval(-1)
            model.tickTasks()
            try check(
                model.sideTasks[0].hidden && model.sideTasks[0].terminalLabel != nil,
                "Automatic expiry hides the receipt without closing its task")
            model.closeTask(draft.id)
            try check(
                !model.sideTasks.contains(where: { $0.id == draft.id })
                    && model.archivedTaskHistory.contains(where: { $0.id == draft.id }),
                "A hidden receipt can be closed and retains its history")
            _ = model.restoreHistoryTask(draft.id, showCard: false)
            let timer = try model.startTimer(seconds: 60, title: "Tea")
            _ = try await model.endTask(timer, action: .complete)
            try check(
                model.sideTasks.first(where: { $0.id == timer })?.deadline == nil
                    && model.sideTasks.first(where: { $0.id == timer })?.terminalLabel != nil,
                "Completion stops the actual timer before displaying its acknowledgement")
            model.editTaskList()
            try check(model.taskListEditing && model.taskShelfVisible, "Edit opens the task list in editing mode")
            var native = RequestIntent(kind: .timer)
            native.taskAction = .cancel
            _ = try native.validated(for: "never mind")
            try check(true, "Cancelling a timer does not require an invented new duration")
            let task = SideTask(kind: .calendar, title: "Already added")
            model.sideTasks.append(task)
            let external = try await model.endTask(task.id, action: .cancel)
            try check(
                external.contains("won't delete") && model.sideTasks.last?.terminalLabel == nil,
                "Ending a conversation never claims to delete an existing Calendar event")
            var externalIntent = RequestIntent(kind: .general)
            externalIntent.route = .local
            externalIntent.requiresFreshData = true
            var staleRejected = false
            do { _ = try externalIntent.validated(for: "current rate") } catch { staleRejected = true }
            try check(staleRejected, "Current external data cannot be routed to a cached local calculation")
            _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fresh-data"])
            model.upsertWebTask(activate: true)
            let previousTitle = model.webTitle
            model.agent.interpretationOverride = { _ in
                var intent = RequestIntent(kind: .general)
                intent.targetTaskID = model.browser.id.uuidString
                intent.needsBrowserContext = true
                intent.requiresFreshData = true
                intent.route = .web
                return intent
            }
            model.agent.completionOverride = { _ in
                [
                    "role": "assistant",
                    "tool_calls": [
                        [
                            "id": "fresh", "type": "function",
                            "function": [
                                "name": "finish", "arguments": "{\"outcome\":\"page_ready\",\"reply\":\"Refreshed\"}",
                            ],
                        ]
                    ],
                ]
            }
            _ = try await model.agent.run("Refresh the current reading", taskID: model.browser.id)
            try check(
                model.webTitle != previousTitle,
                "A new request for current external data refreshes the source instead of reusing the old observation")
            model.taskRuntime.stopAll()
            model.browser.dispose()
            return checks
        }
    }
#endif
