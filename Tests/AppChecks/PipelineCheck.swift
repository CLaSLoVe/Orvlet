#if DEBUG
    import Foundation

    @MainActor
    enum PipelineCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                guard value else { throw AppError.message(name) }
                checks.append(name)
            }
            let schema = ToolSchema.function(
                "revise_interface", "Design", CardMarkup.schema["properties"] as! [String: Any])
            var attempts = 0
            let markup: CardMarkup = try await StructuredResponse.generate(
                name: "revise_interface", messages: [], schema: schema,
                complete: { turns, _, _ in
                    attempts += 1
                    if attempts == 1 { return ["content": "I changed it"] }
                    if attempts == 2 {
                        return ["content": "{\"html\":\"<span>10:00</span>\",\"compactHTML\":\"<span>10:00</span>\"}"]
                    }
                    try check(
                        turns.contains { ($0["content"] as? String ?? "").contains("data-bind") },
                        "Binding validation feeds the internal repair loop")
                    return [
                        "content":
                            "{\"html\":\"<span data-bind='clock'></span>\",\"compactHTML\":\"<span data-bind='clock'></span>\"}"
                    ]
                },
                validate: { raw in
                    let markup = try JSONDecoder().decode(CardMarkup.self, from: Data(raw.utf8))
                    try markup.validateBindings(available: ["clock"], requiredLive: ["clock"])
                    return markup
                })
            try check(
                attempts == 3 && markup.bindingKeys == ["clock"],
                "Malformed format and missing live bindings repair before a design can commit")
            attempts = 0
            do {
                let _: CardMarkup = try await StructuredResponse.generate(
                    name: "revise_interface", messages: [], schema: schema,
                    complete: { _, _, _ in
                        attempts += 1
                        return ["content": "bad"]
                    }, validate: { try JSONDecoder().decode(CardMarkup.self, from: Data($0.utf8)) })
                throw AppError.message("Invalid design unexpectedly accepted")
            } catch PipelineFailure.presentation {
                try check(
                    attempts == 3 && !PipelineFailure.presentation.localizedDescription.contains("data-bind"),
                    "Exhausted design repair is bounded and exposes no implementation errors")
            }
            attempts = 0
            do {
                let _: String = try await StructuredResponse.generate(
                    name: "revise_interface", messages: [], schema: schema,
                    complete: { _, _, _ in
                        attempts += 1
                        return ["content": "{}"]
                    }, validate: { _ in throw CancellationError() })
            } catch is CancellationError {}
            try check(attempts == 1, "Cancellation never starts a schema-repair request")
            var invalid = RequestIntent(
                kind: .general, requirements: [OutcomeRequirement(label: "city", anyOf: ["Beijing"])])
            invalid.presentationOnly = true
            var invalidRejected = false
            do { _ = try invalid.validated(for: "Use Beijing time") } catch { invalidRejected = true }
            try check(invalidRejected, "A source correction cannot pass the presentation-only contract")

            let readings = [
                CardReading(key: "place", selector: "#place"), CardReading(key: "clock", selector: "#clock"),
            ]
            let plan = SurfacePlan(components: [], width: 320, height: 140, readings: readings)
            let requirements = [OutcomeRequirement(label: "city", anyOf: ["Beijing", "北京"])]
            let proof: [[String: Any]] = [["requirement": 0, "readingKey": "place", "valueKey": "clock"]]
            func observation(_ place: String, role: String = "primary", scope: String = "main") -> [String: Any] {
                [
                    "readables": [
                        ["selector": "#place", "text": place, "evidenceRole": role, "scopeSelector": scope],
                        ["selector": "#clock", "text": "14:30:05", "evidenceRole": "primary", "scopeSelector": "main"],
                    ]
                ]
            }
            for page in [
                observation("New York"), observation("Beijing", role: "navigation"),
                observation("Beijing", scope: "aside"),
            ] {
                var refused = false
                do { try OutcomeEvidence.verify(requirements, evidence: proof, observation: page, plan: plan) } catch {
                    refused = true
                }
                try check(
                    refused,
                    "Wrong city, related navigation and unrelated result regions cannot certify the requested clock")
            }
            try OutcomeEvidence.verify(
                requirements, evidence: proof, observation: observation("Time in Beijing"), plan: plan)
            checks.append("The requested primary source label and live value verify together")

            let suite = "orvlet-pipeline-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.settings.autoAdapt = false
            let a = SideTask(kind: .workspace, title: "Task A")
            let b = SideTask(kind: .workspace, title: "Task B")
            model.sideTasks = [a, b]
            model.selectedTaskID = a.id
            let message = model.appendMessage("Change A", isUser: true, taskID: a.id)
            model.beginAmbientRequest("Change A", taskID: a.id, messageID: message)
            model.selectedTaskID = b.id
            model.deliverReply("A is ready")
            try check(
                model.activeRequest?.submittedTaskID == a.id && model.messages.last?.taskID == a.id,
                "Changing the selected card cannot retarget the request or its reply")
            let restored = AppModel(defaults: defaults)
            try check(
                restored.messages.count == 2 && restored.messages.allSatisfy { $0.taskID == a.id },
                "Conversation text and task attribution survive a new model instance")
            model.conversationTaskID = b.id
            try check(
                model.visibleConversation.isEmpty, "Task conversation filtering never borrows another card's messages")
            model.busy = true
            model.submitTaskRequest("Change B", taskID: b.id)
            try check(
                model.queuedTaskRequests.first?.taskID == b.id && model.activeRequest?.owner?.id == a.id,
                "A message from another card queues without steering the active task")
            model.busy = false
            model.finishAmbientRequest()
            model.dismissFeedback()
            model.taskClock?.invalidate()
            restored.taskClock?.invalidate()
            checks += try await correction()
            let dormant = AppModel()
            dormant.isLiveTest = true
            dormant.persistHistory = false
            dormant.settings.autoAdapt = false
            var savedPage = SideTask(kind: .web, title: "Saved media")
            savedPage.sourceURL = "http://127.0.0.1:19244/fixture"
            savedPage.listening = true
            let otherTask = SideTask(kind: .workspace, title: "Still selected")
            dormant.sideTasks = [savedPage, otherTask]
            dormant.selectedTaskID = otherTask.id
            try await dormant.prepareTaskSource(savedPage.id)
            let observation = try await dormant.observation()
            try check(
                dormant.browser.id == savedPage.id && dormant.selectedTaskID == otherTask.id
                    && dormant.webURL.contains("/fixture"),
                "A dormant saved page restores for execution without changing its task or selected card")
            try check(
                observation["playing"] as? Bool == false && dormant.browser.userPausedPlayback,
                "Restoring a media task holds playback until an explicit play intent")
            let restoredBrowser = dormant.browser
            try await dormant.prepareTaskSource(savedPage.id)
            try check(
                dormant.browser === restoredBrowser && dormant.parkedBrowsers.isEmpty,
                "Repeated source preparation reuses the same restored browser")
            dormant.closeTask(savedPage.id)
            dormant.browser.dispose()
            try check(
                restoredBrowser.disposed && dormant.taskSourceRestorations[savedPage.id] == nil,
                "Closing a restored task releases its browser and restoration job")
            return checks
        }
        static func correction() async throws -> [String] {
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.busy = true
            model.backgroundRequest = true
            model.collapsed = false
            defer {
                model.busy = false
                model.browser.dispose()
                model.dismissFeedback()
            }
            _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/qualifier"])
            model.upsertWebTask(.webpage)
            let owner = model.browser.id
            let other = SideTask(kind: .workspace, title: "Unrelated card")
            model.sideTasks.append(other)
            model.agent.interpretationOverride = { _ in
                model.selectedTaskID = other.id
                return RequestIntent(
                    kind: .general, needsBrowserContext: true, targetTaskID: owner.uuidString,
                    requirements: [OutcomeRequirement(label: "city", anyOf: ["Beijing"])])
            }
            let markup = CardMarkup(
                html: "<section><span data-bind='place'></span><strong data-bind='clock'></strong></section>",
                compactHTML: "<span data-bind='clock'></span>", css: "")
            let plan = SurfacePlan(
                components: [], width: 320, height: 150, title: "Beijing", markup: markup, actions: [],
                readings: [
                    CardReading(key: "place", selector: "#place"), CardReading(key: "clock", selector: "#clock"),
                ])
            var round = 0
            var refused = false
            func call(_ name: String, _ input: [String: Any]) -> [String: Any] {
                [
                    "id": UUID().uuidString, "type": "function",
                    "function": ["name": name, "arguments": JSONText.encode(input)],
                ]
            }
            let finish: [String: Any] = [
                "outcome": "page_ready", "reply": "Beijing time is ready",
                "outcomeEvidence": [["requirement": 0, "readingKey": "place", "valueKey": "clock"]],
            ]
            model.agent.completionOverride = { turns in
                round += 1
                let calls: [[String: Any]]
                switch round {
                case 1:
                    calls = [
                        call(
                            "compose_ui",
                            (try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any])
                                .filter { ["title", "markup", "actions", "readings"].contains($0.key) }),
                        call("finish", finish),
                    ]
                case 2:
                    refused = turns.contains { ($0["content"] as? String ?? "").contains("source has not verified") }
                    guard refused else { throw AppError.message("Renamed wrong source was not rejected") }
                    calls = [call("navigate", ["url": "http://127.0.0.1:19244/qualifier?city=Beijing"])]
                default:
                    calls = [
                        call(
                            "compose_ui",
                            (try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any])
                                .filter { ["title", "markup", "actions", "readings"].contains($0.key) }),
                        call("finish", finish), call("navigate", ["url": "http://127.0.0.1:19244/qualifier"]),
                    ]
                }
                return ["role": "assistant", "tool_calls": calls]
            }
            let reply = try await model.agent.run("改成北京时间", taskID: owner)
            let page = try await model.observation()
            guard refused, round == 3, reply == "Beijing time is ready", model.webURL.contains("city=Beijing"),
                model.sideTasks.filter({ $0.kind == .web }).count == 1,
                model.sideTasks.contains(where: { $0.id == owner && $0.plan?.readings?.count == 2 }),
                model.selectedTaskID == other.id,
                (page["readables"] as? [[String: Any]])?.contains(where: {
                    $0["selector"] as? String == "#suggestion" && $0["evidenceRole"] as? String == "navigation"
                }) == true
            else {
                throw AppError.message(
                    "Source correction failed: refused=\(refused), round=\(round), url=\(model.webURL), cards=\(model.sideTasks.count), selected=\(model.selectedTaskID == other.id), navigation=\((page["readables"] as? [[String:Any]])?.first(where: { $0["selector"] as? String == "#suggestion" }) ?? [:])"
                )
            }
            return [
                "A renamed New York clock cannot finish as Beijing; real navigation and bound source evidence are required",
                "The source correction keeps one task identity while another card is selected",
                "Finish is terminal: trailing model actions cannot change a verified source",
                "The real DOM distinguishes a related Beijing link from the active clock location",
            ]
        }

    }
#endif
