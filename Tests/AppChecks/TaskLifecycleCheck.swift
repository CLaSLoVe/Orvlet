#if DEBUG
    import AppKit

    @MainActor
    enum TaskLifecycleCheck {
        static func run() throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                guard value else { throw AppError.message(name) }
                checks.append(name)
            }
            let suite = "orvlet-lifecycle-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            defer {
                model.dismissFeedback()
                model.taskClock?.invalidate()
                model.browser.dispose()
            }
            let received = Date().addingTimeInterval(-30)
            model.requestReceivedAt = received
            model.settings.taskStartPolicy = .taskFirst
            model.beginAmbientRequest("A new lightweight tool")
            let pending = model.requestCardID!
            model.settings.taskStartPolicy = .interfaceFirst
            try check(
                model.activeRequest?.receivedAt == received && model.activeRequest?.startPolicy == .taskFirst,
                "Request timing and start policy remain fixed while settings change")
            let owner = UUID()
            model.adoptRequestTask(.workspace(owner))
            try check(
                model.sideTasks.count == 1 && model.sideTasks[0].id == owner && model.requestCardID == nil
                    && model.requestTaskID == owner, "Resolving a new task replaces its preparation card in place")
            model.finishAmbientRequest()
            model.beginAmbientRequest("Continue that tool")
            model.adoptRequestTask(.workspace(owner))
            try check(
                model.sideTasks.count == 1 && !model.sideTasks.contains(where: { $0.id == pending }),
                "Resolving an existing task removes the placeholder without duplicating the task")
            model.finishAmbientRequest()
            let initial = TaskRuntimeCheck.surface()
            model.publishTaskSurface(try initial.validated(), id: owner)
            let oldInterface = model.taskRevisions.begin(owner, .interface)
            let execution = model.taskRevisions.begin(owner, .execution)
            let userInterface = model.taskRevisions.begin(owner, .interface)
            model.taskRevisions.finish(oldInterface)
            try check(
                !model.accepts(oldInterface) && model.accepts(userInterface) && model.accepts(execution),
                "A stale generation cannot finish a newer edit or invalidate independent execution")
            let original = model.sideTasks[0]
            model.fitCardSurface(owner, height: 240)
            var edited = initial.markup
            edited.html = edited.html.replacingOccurrences(of: "Per person", with: "Each person")
            try model.applyInterfaceRevision(owner, markup: edited, original: original)
            var result = initial
            result.state["share"] = "45.00"
            try model.commitTaskSurface(result, id: owner, ticket: oldInterface)
            try check(
                model.sideTasks[0].presentation.hasSameDesign(as: edited)
                    && model.sideTasks[0].state["share"] == "45.00",
                "Measured height changes allow editing; late execution supplies fresh values without replacing the newer design"
            )
            model.taskRevisions.finish(userInterface)
            let late = model.taskRevisions.begin(owner, .interface)
            model.closeTask(owner)
            var refused = false
            do { try model.commitTaskSurface(result, id: owner, ticket: late) } catch { refused = true }
            try check(
                refused && model.sideTasks.isEmpty && !model.accepts(late),
                "A late result cannot recreate a closed task")
            let timer = try model.startTimer(seconds: 600, receivedAt: received)
            try check(
                abs(model.sideTasks[0].deadline!.timeIntervalSince(received) - 600) < 0.01,
                "Timer deadlines use request time, never model or interface completion time")
            var music = SideTask(kind: .web, title: "Music")
            music.listening = true
            music.playing = true
            model.sideTasks.append(music)
            let messageCount = model.messages.count
            model.recordInterfaceFailure(timer, ModelAccessError.authorizationRequired)
            model.recordInterfaceFailure(music.id, ModelAccessError.authorizationRequired)
            try check(
                model.messages.count == messageCount + 1 && model.feedback?.kind == .authorization
                    && model.taskActivity(model.sideTasks[0]) == nil && model.taskActivity(music) == nil,
                "A shared model authorization problem produces one notice without marking healthy tasks as failed")
            model.recordInterfaceFailure(music.id, AppError.message("Unavailable view"))
            try check(
                model.sideTasks.last?.playing == true && model.taskActivity(model.sideTasks.last!) == .interfaceFailed,
                "A presentation failure preserves execution and has its own recoverable status")
            model.beginAmbientRequest("Prepare music controls")
            model.adoptRequestTask(.web(music.id))
            model.activeRequest?.presentationFailure = "Unavailable view"
            model.taskFailed = true
            model.failAmbientRequest("Unavailable view")
            model.finishAmbientRequest()
            try check(
                model.sideTasks.last?.playing == true && model.sideTasks.last?.status != "Task failed"
                    && model.taskActivity(model.sideTasks.last!) == .interfaceFailed,
                "Finishing a request cannot turn its presentation failure into an execution failure")
            return checks
        }

        static func directActionWins() async throws -> [String] {
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
            model.settings.autoAdapt = false
            let id = UUID()
            model.publishTaskSurface(try TaskRuntimeCheck.surface().validated(), id: id)
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
            var deciding = false
            model.agent.completionOverride = { _ in
                deciding = true
                try await Task.sleep(for: .seconds(20))
                return ["role": "assistant", "content": "Obsolete response"]
            }
            model.startCommand("Update this tool", taskID: id, receivedAt: Date())
            for _ in 0..<50 {
                if deciding { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard deciding else { throw AppError.message("Request never entered the model decision") }
            model.performTaskAction(id, action: "calculate", value: "{\"amount\":\"150\",\"people\":\"5\"}")
            for _ in 0..<100 {
                if !model.busy && model.taskActionJobs[id] == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !model.busy, model.sideTasks.first?.state["share"] == "30.00",
                model.sideTasks.first?.status == "Ready",
                model.taskActivity(model.sideTasks[0]) == .succeeded
            else { throw AppError.message("A stale request overwrote a newer direct task action") }
            model.closeTask(id)
            model.browser.dispose()
            model.dismissFeedback()
            return [
                "A direct form action cancels obsolete agent work for that task and retains its verified result and completion state"
            ]
        }
        static func foregroundIsolation() async throws -> [String] {
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            defer {
                for browser in model.liveBrowsers { browser.dispose() }
                model.dismissFeedback()
            }
            _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
            model.upsertWebTask(.webpage, activate: true)
            let first = model.browser
            try model.prepareBrowserForNewTask()
            _ = try await model.browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/live-reading"])
            model.upsertWebTask(.webpage, activate: true)
            let second = model.browser
            model.busy = true
            model.beginAmbientRequest("Read the second task")
            model.adoptRequestTask(.web(second.id))
            model.selectTask(first.id, expanded: true)
            guard model.selectedTaskID == first.id, model.browser === second, model.requestPageID == second.id else {
                throw AppError.message("Foreground selection redirected a running request")
            }
            try model.activateTaskSource(second.id)
            let observation = try await model.observation()
            guard (observation["url"] as? String)?.contains("live-reading") == true else {
                throw AppError.message("Observation escaped its request owner")
            }
            model.busy = false
            model.finishAmbientRequest()
            model.selectTask(first.id, expanded: true)
            guard model.browser === first else {
                throw AppError.message("Idle foreground source did not switch normally")
            }
            return [
                "Switching foreground cards preserves the running request's source and observations; normal switching resumes when idle"
            ]
        }
    }
#endif
