import Combine
import SwiftUI
import WebKit

extension AppModel {
    func beginAmbientRequest(_ text: String, taskID: UUID? = nil, messageID: UUID? = nil) {
        adaptive.blockedSources.remove(taskID ?? browser.id)
        var request = TaskRequestContext(
            input: text, receivedAt: requestReceivedAt, startPolicy: settings.taskStartPolicy)
        request.submittedTaskID = taskID
        request.sourceCandidateID = taskID ?? (messageID == nil ? selectedSideTask?.id : nil)
        request.messageID = messageID
        if let messageID, let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].requestID = request.id
        }
        if let taskID, let i = sideTasks.firstIndex(where: { $0.id == taskID }) {
            sideTasks[i].terminalLabel = nil
            sideTasks[i].expires = nil
            taskActivityReceipts[taskID] = nil
            request.owner = .init(id: taskID, kind: sideTasks[i].kind)
            activeRequest = request
            ambientRequestID = taskID
            if sideTasks[i].kind == .workspace { sideTasks[i].status = "Working…" }
            sideTasks[i].hidden = false
            onShow?()
            return
        }
        var task = SideTask(
            id: messageID.flatMap { mid in messages.first(where: { $0.id == mid })?.taskID } ?? UUID(), kind: .result,
            title: String(text.prefix(80)))
        task.status = "Preparing…"
        task.intent = text
        request.placeholderID = task.id
        activeRequest = request
        ambientRequestID = task.id
        sideTasks.removeAll { $0.id == task.id }
        sideTasks.append(task)
        associateMessages(requestID: request.id, messageID: messageID, taskID: task.id)
        onResize?(windowSize)
        onShow?()
    }
    func finishAmbientRequest() {
        if let request = activeRequest {
            Diagnostics.record(
                "request_finished",
                [
                    "requestID": request.id.uuidString, "stage": request.stage.rawValue,
                    "seconds": Date().timeIntervalSince(request.receivedAt), "failed": taskFailed,
                    "cancelled": Task.isCancelled,
                ])
        }
        if let owner = activeRequest?.owner, taskActionJobs[owner.id] == nil {
            let outcome: TaskActivity =
                Task.isCancelled
                ? .stopped
                : agent.replyKind == .needsInput
                    ? .needsInput : taskFailed || agent.replyKind == .failure ? .failed : .succeeded
            if agent.replyKind != .authorization && activeRequest?.presentationFailure == nil {
                recordTaskOutcome(owner.id, outcome)
            }
            if owner.kind == .workspace, let i = sideTasks.firstIndex(where: { $0.id == owner.id }),
                sideTasks[i].status == "Working…"
            {
                sideTasks[i].status =
                    agent.replyKind == .authorization
                    ? "Waiting for model" : outcome == .succeeded ? "Ready" : outcome.label
            }
        }
        if let id = requestCardID, let i = sideTasks.firstIndex(where: { $0.id == id }) {
            sideTasks[i].status =
                agent.replyKind == .needsInput ? "Waiting for reply" : taskFailed ? "Needs attention" : "Done"
            if !taskFailed && agent.replyKind == .success && sideTasks[i].terminalLabel == nil {
                sideTasks[i].terminalLabel = sideTasks[i].title + " · Done"
                sideTasks[i].expires = Date().addingTimeInterval(10)
            }
            if ambientRequestID == id { ambientRequestID = nil }
        }
        if !taskFailed, agent.replyKind == .success, let id = activeRequest?.owner?.id,
            let task = sideTasks.first(where: { $0.id == id }), task.terminalLabel == nil,
            task.kind == .web || task.kind == .workspace
        {
            interfaceMemory.remember(task, purpose: task.intent ?? activeRequest?.input ?? task.title)
        }
        refreshTaskClock()
        activeRequest = nil
        persistSideTasks()
        reconcileTasks()
    }
    func failAmbientRequest(_ message: String) {
        guard activeRequest?.presentationFailure == nil else { return }
        let id = activeRequest?.owner?.id ?? requestCardID
        if let i = sideTasks.firstIndex(where: { $0.id == id }) {
            if sideTasks[i].kind == .result {
                sideTasks[i].status = "Task failed"
                sideTasks[i].detail = message
            }
            recordTaskOutcome(sideTasks[i].id, .failed)
            if sideTasks[i].kind == .result {
                activeRequest?.owner = .init(id: sideTasks[i].id, kind: .result)
                activeRequest?.placeholderID = nil
            }
        }
    }
    func isPreparingTask(_ task: SideTask) -> Bool {
        task.id == requestCardID || (busy && task.id == requestTaskID)
            || (busy && task.id == requestPageID && !task.isMediaTask)
    }
    var preparationLabel: String {
        switch activity {
        case "Reading page…": return "Reading…"
        case "Opening page…": return "Opening…"
        case "Building controls…": return "Preparing view…"
        case "Stopping…": return "Stopping…"
        default: return "Preparing…"
        }
    }
    var visibleTasks: [SideTask] { sideTasks.filter { !$0.hidden } }
    var selectedSideTask: SideTask? { visibleTasks.first { $0.id == selectedTaskID } ?? visibleTasks.first }
    func loadSideTasks() {
        taskOrder = (preferences.stringArray(forKey: "taskOrder.v1") ?? []).compactMap(UUID.init(uuidString:))
        if let data = preferences.data(forKey: "sideTasks.v1"),
            let saved = try? JSONDecoder().decode([SideTask].self, from: data)
        {
            sideTasks = saved.map { original in
                var task = original
                if task.kind == .web {
                    task.hidden = true
                    task.playing = false
                    task.status = "Resume page"
                }
                if [.workspace, .result].contains(task.kind),
                    ["Preparing…", "Working…", "Queued", "Calculating…"].contains(task.status)
                {
                    task.status = "Interrupted · retry"
                }
                return task
            }
        }
        for task in sideTasks where task.taskSurface?.runtime != nil { taskRuntime.attach(task.id) }
        reconcileTasks()
        refreshTaskClock()
    }
    func persistSideTasks() {
        guard persistHistory, !isLiveTest else { return }
        preferences.set(
            taskOrder.filter { id in sideTasks.contains { $0.id == id && $0.id != requestCardID } }.map(\.uuidString),
            forKey: "taskOrder.v1")
        if let data = try? JSONEncoder().encode(sideTasks.filter { $0.id != requestCardID }) {
            preferences.set(data, forKey: "sideTasks.v1")
        }
    }
    func reconcileTasks() {
        if !visibleTasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = visibleTasks.first?.id }
        if visibleTasks.isEmpty && !taskShelfVisible && !commandPanelVisible && !hasUnreadReply && !busy
            && feedback == nil
        {
            onHide?()
        }
        onResize?(windowSize)
    }
    func toggleTaskPresentation(_ id: UUID) {
        taskRanking.record(id, .open)
        if !collapsed && !taskShelfVisible && !commandPanelVisible && selectedTaskID == id {
            collapse()
        } else {
            selectTask(id, expanded: true)
        }
    }
    @discardableResult
    func selectTask(_ id: UUID, expanded: Bool = false, preferSource: Bool? = nil) -> Bool {
        if id == requestCardID {
            openTaskConversation(id)
            return true
        }
        upgradeStandardCard(id)
        guard let task = sideTasks.first(where: { $0.id == id }) else { return false }
        lastActionError = nil
        if task.taskSurface?.apiData != nil, taskActionJobs[id] == nil,
            Date().timeIntervalSince(task.dataUpdatedAt ?? .distantPast) >= 60
        {
            refreshAPIData(id)
        }
        if feedback?.kind == .success { dismissFeedback() }
        if task.kind == .web, id != browser.id, parkedBrowsers[id] == nil {
            do { _ = try beginTaskSourceRestore(task) } catch {
                lastActionError = error.localizedDescription
                return false
            }
        }
        if task.hidden, let i = sideTasks.firstIndex(where: { $0.id == id }) {
            sideTasks[i].hidden = false
            sideTasks[i].expires = nil
        }
        if commandPanelVisible { selectChat(false, restoreFocus: false) }
        taskShelfVisible = false
        selectedTaskID = id
        if task.kind == .web && !busy {
            activateSelectedSource()
            if !hasCustomSurface { adaptive.changed() }
        }
        webExpanded = expanded && (preferSource ?? task.opensSourceByDefault) && task.kind == .web
        collapsed = !expanded
        clickExpanded = expanded
        onResize?(windowSize)
        onShow?()
        refreshHover()
        if expanded && task.kind != .web && !task.generated { decorateTask(id) }
        return true
    }

    func dismissTask(_ id: UUID) {
        taskRanking.record(id, .hide)
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        // Hiding a card does not stop its underlying task.
        sideTasks[i].hidden = true
        if selectedTaskID == id && !taskShelfVisible { collapse() }
        persistSideTasks()
        reconcileTasks()
    }
    func upsertWebTask(_ plan: SurfacePlan? = nil, activate: Bool = false) {
        guard !webURL.isEmpty else { return }
        let id = browser.id
        guard !sideTasks.contains(where: { $0.id == id && $0.terminalLabel != nil }) else { return }
        if let old = sideTasks.firstIndex(where: {
            $0.kind == .web && $0.sourceURL == webURL && $0.id != id && parkedBrowsers[$0.id] == nil
        }) {
            archiveTaskHistory(sideTasks[old])
            sideTasks.remove(at: old)
        }
        let index = sideTasks.firstIndex { $0.id == id }
        var card = index.map { sideTasks[$0] } ?? SideTask(id: id, kind: .web, title: trackTitle)
        if let previous = card.sourceURL, URL(string: previous)?.host != URL(string: webURL)?.host {
            endBackgroundListening(clearTaskIntent: true)
        }
        card.updateMediaRole(primary: browser.lastState["mediaPrimary"] as? Bool, url: webURL)
        if backgroundListening {
            card.listening = true
            card.prefersSource = false
        }
        if card.sourceURL != webURL {
            card.plan = nil
            card.liveValues = nil
            card.markup = nil
            card.customCompact = nil
            card.interfaceRecipeID = nil
        }
        card.title = trackTitle
        card.sourceURL = webURL
        if requestPageID == id { card.intent = activeRequest?.input }
        card.hasMedia = hasMedia
        card.playing = isPlaying
        card.muted = browser.lastState["muted"] as? Bool
        card.plan = plan ?? card.plan ?? surface
        card.markup = nil
        card.generated = card.plan?.markup != nil
        if plan?.markup != nil { card.interfaceIssue = nil }
        if let recipeID = card.plan?.interfaceRecipeID {
            card.interfaceRecipeID = recipeID
            card.customCompact = true
        }
        card.status =
            card.isMediaTask
            ? (hasMedia ? (isPlaying ? "Playing" : "Paused") : "Loading…") : (URL(string: webURL)?.host ?? "Ready")
        if activate { card.hidden = false }
        if let index { sideTasks[index] = card } else { sideTasks.append(card) }
        if selectedTaskID == nil || (activate && !backgroundRequest) { selectedTaskID = id }
        persistSideTasks()
        onResize?(windowSize)
        if activate { onShow?() }
    }
    func interfaceIntent(for id: UUID) -> String {
        let task = sideTasks.first { $0.id == id }
        return task?.intent
            ?? (task?.listening == true
                ? "Listening to this page's media" : "Show useful live information and controls for this webpage")
    }
    func updateBackgroundTask(_ id: UUID, data: [String: Any]) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), sideTasks[i].terminalLabel == nil else { return }
        sideTasks[i].updateMediaRole(primary: data["mediaPrimary"] as? Bool, url: data["url"] as? String)
        if let title = data["title"] as? String { sideTasks[i].title = title }
        if let url = data["url"] as? String {
            if sideTasks[i].sourceURL != url {
                sideTasks[i].plan = nil
                sideTasks[i].generated = false
                sideTasks[i].liveValues = nil
                sideTasks[i].markup = nil
                sideTasks[i].customCompact = nil
                sideTasks[i].interfaceRecipeID = nil
            }
            sideTasks[i].sourceURL = url
            if sideTasks[i].plan == nil, let plan = parkedBrowsers[id]?.reusableMediaSurface(data) {
                sideTasks[i].plan = plan
                sideTasks[i].generated = plan.markup != nil
            }
        }
        if let media = data["hasMedia"] as? Bool { sideTasks[i].hasMedia = media }
        if let muted = data["muted"] as? Bool { sideTasks[i].muted = muted }
        updateLiveReadings(id, data: data)
        receiveMusicState(id, data: data)
        if let playing = data["playing"] as? Bool {
            sideTasks[i].playing = playing
            if sideTasks[i].isMediaTask {
                sideTasks[i].status = sideTasks[i].hasMedia ? (playing ? "Playing" : "Paused") : "Loading…"
            }
        }
    }
    func updateLiveReadings(_ id: UUID, data: [String: Any]) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), sideTasks[i].terminalLabel == nil,
            let readings = sideTasks[i].plan?.readings, !readings.isEmpty,
            let values = data["readings"] as? [String: String]
        else { return }
        let bound = Dictionary(uniqueKeysWithValues: readings.map { ($0.key, values[$0.key] ?? "—") })
        let missing = bound.values.contains { $0 == "—" || $0.isEmpty }
        sideTasks[i].dataIssue = missing ? "The source is unavailable. Open the page to reconnect." : nil
        if !missing { sideTasks[i].dataUpdatedAt = Date() }
        if sideTasks[i].liveValues != bound { sideTasks[i].liveValues = bound }
    }
    func closeTask(_ id: UUID) {
        adaptive.blockedSources.remove(id)
        stopTaskActions(id)
        if ownsRequest(id) && busy { cancel() }
        if id == requestCardID {
            activeRequest?.placeholderID = nil
            if ambientRequestID == id { ambientRequestID = nil }
        }
        guard let task = sideTasks.first(where: { $0.id == id }) else { return }
        archiveTaskHistory(task)
        if task.kind == .web {
            closeWebTask(id)
            return
        }
        sideTasks.removeAll { $0.id == id }
        if selectedTaskID == id && !taskShelfVisible { collapse() }
        refreshTaskClock()
        persistSideTasks()
        reconcileTasks()
    }
    func prepareBrowserForNewTask(destination: String? = nil) throws {
        if let destination, let target = SurfaceCache.pageKey(destination) {
            if target == SurfaceCache.pageKey(webURL) { return }
            if let existing = sideTasks.first(where: {
                $0.kind == .web && SurfaceCache.pageKey($0.sourceURL ?? "") == target && parkedBrowsers[$0.id] != nil
            }) {
                activateSource(existing)
                return
            }
        }
        guard !externalBrowser, !webURL.isEmpty, hasCustomSurface || hasMedia else { return }
        upsertWebTask(surface, activate: true)
        guard parkedBrowsers.count < 2 else {
            throw AppError.message(
                "Three web tasks are already open. Close a page from its card before opening another.")
        }
        adaptive.invalidate()
        cancelRestoration()
        parkedBrowsers[browser.id] = browser
        endBackgroundListening()
        browser = BrowserController(model: self)
        webURL = ""
        webTitle = ""
        hasMedia = false
        isPlaying = false
        mediaType = ""
        hasCustomSurface = false
        surface = .empty
        webExpanded = false
        browserRevision += 1
    }
    var liveBrowsers: [BrowserController] {
        Array(parkedBrowsers.values).sorted { $0.id.uuidString < $1.id.uuidString } + [browser]
    }
    /// UI opening and execution share the same restoration job and task identity.
    private func beginTaskSourceRestore(_ task: SideTask) throws -> Task<Void, Error> {
        if let job = taskSourceRestorations[task.id] { return job }
        guard parkedBrowsers.count < 2 else {
            throw AppError.message("Three pages are already open. Close one from the task list, then try again.")
        }
        guard let raw = task.sourceURL, let url = URL(string: raw),
            ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw AppError.message("This task no longer has a usable page address.")
        }
        let id = task.id
        let restored = BrowserController(model: self, id: task.id)
        parkedBrowsers[id] = restored
        browserRevision += 1
        let job = Task { @MainActor in
            defer { taskSourceRestorations[id] = nil }
            do {
                try Task.checkCancellation()
                guard !restored.disposed else { throw CancellationError() }
                if task.isMediaTask {
                    restored.setUserPlaybackPaused(true, origin: "restore_saved_task")
                    await restored.applyPlaybackPolicy()
                }
                let page = try await restored.action(["action": "navigate", "url": raw])
                try Task.checkCancellation()
                guard !restored.disposed, let i = sideTasks.firstIndex(where: { $0.id == id }) else {
                    throw CancellationError()
                }
                if let plan = task.plan, let checked = try? plan.validated(observation: page) {
                    sideTasks[i].plan = checked
                    restored.rememberMediaSurface(checked, url: raw)
                    try await restored.bindReadings(checked.readings ?? [])
                } else {
                    sideTasks[i].plan = nil
                    sideTasks[i].status = "Page restored"
                }
                if browser.id == id {
                    surface = sideTasks[i].plan ?? .webpage
                    hasCustomSurface = sideTasks[i].plan != nil
                }
            } catch {
                if let i = sideTasks.firstIndex(where: { $0.id == id }) {
                    sideTasks[i].status = "Open page to continue"
                }
                throw error
            }
        }
        taskSourceRestorations[id] = job
        return job
    }
    func prepareTaskSource(_ id: UUID) async throws {
        guard let task = sideTasks.first(where: { $0.id == id }), task.kind == .web else { throw CancellationError() }
        if let job = taskSourceRestorations[id] {
            try await job.value
        } else if browser.id != id && parkedBrowsers[id] == nil {
            try await beginTaskSourceRestore(task).value
        }
        try Task.checkCancellation()
        try activateTaskSource(id)
    }
    func activateTaskSource(_ id: UUID) throws {
        guard sideTasks.contains(where: { $0.id == id }) else { throw CancellationError() }
        if browser.id == id { return }
        guard let task = sideTasks.first(where: { $0.id == id }), parkedBrowsers[id] != nil else {
            throw AppError.message("This task's page is no longer open. Reopen that task before continuing.")
        }
        activateSource(task)
    }
    func activateSelectedSource() {
        guard let task = selectedSideTask else { return }
        activateSource(task)
    }
    private func activateSource(_ task: SideTask) {
        guard task.kind == .web, task.id != browser.id,
            let selected = parkedBrowsers.removeValue(forKey: task.id)
        else { return }
        adaptive.invalidate()
        cancelRestoration()
        if !webURL.isEmpty { parkedBrowsers[browser.id] = browser }
        browser = selected
        backgroundListening = task.listening == true
        webURL = task.sourceURL ?? ""
        webTitle = task.title
        surface = task.plan ?? .webpage
        hasMedia = task.hasMedia
        isPlaying = task.playing
        hasCustomSurface = task.plan != nil
        webLoading = selected.loading
        webError = nil
        if !selected.lastState.isEmpty { selected.updateState(selected.lastState) }
        browserRevision += 1
    }
    func controlMedia(_ id: UUID, operation: String) {
        if !(externalBrowser && id == browser.id),
            let task = sideTasks.first(where: { $0.id == id }), task.isMediaTask,
            MusicTrack.videoID(task.sourceURL ?? "") != nil
        {
            musicControl(id, operation: operation)
            return
        }
        guard ["play", "pause", "toggle", "next"].contains(operation),
            let task = sideTasks.first(where: { $0.id == id }), task.isMediaTask
        else { return }
        let operation = operation == "toggle" ? (task.playing ? "pause" : "play") : operation
        let controller = id == browser.id ? browser : parkedBrowsers[id]
        // User intent wins over pending restoration, model work and page autoplay.
        if operation == "pause" {
            if busy && requestPageID == id { cancel() }
        }
        if (operation == "pause" || operation == "play") && id == browser.id { cancelRestoration() }
        if operation == "pause" || operation == "play" { controller?.setUserPlaybackPaused(operation == "pause") }
        let generation = controller?.playbackGeneration
        Task {
            await controller?.applyPlaybackPolicy()
            guard generation == controller?.playbackGeneration else { return }
            do {
                if externalBrowser && id == browser.id {
                    _ = try await performBrowserAction(["action": "media", "operation": operation])
                } else if let controller {
                    _ = try await controller.action(["action": "media", "operation": operation])
                }
            } catch {
                guard sideTasks.contains(where: { $0.id == id }) else { return }
                if let i = sideTasks.firstIndex(where: { $0.id == id }) {
                    sideTasks[i].status = "Open page to continue"
                }
                deliverReply("Could not change playback. " + error.localizedDescription, kind: .failure, taskID: id)
            }
        }
    }
    func selectedMediaCommand(_ operation: String) -> Bool {
        let target =
            selectedSideTask.flatMap { $0.kind == .web && $0.isMediaTask ? $0 : nil }
            ?? quickMediaTasks.first(where: { $0.playing }) ?? quickMediaTasks.first
        guard let target else { return false }
        if let index = messages.indices.last { messages[index].taskID = target.id }
        controlMedia(target.id, operation: operation)
        return true
    }
    func closeWebTask(_ id: UUID) {
        musicJobs.removeValue(forKey: id)?.cancel()
        musicRevisions.removeValue(forKey: id)
        musicLoading.remove(id)
        musicPlayback.removeValue(forKey: id)
        musicQueueExpanded.remove(id)
        musicErrors.removeValue(forKey: id)
        if let task = sideTasks.first(where: { $0.id == id }) { archiveTaskHistory(task) }
        taskSourceRestorations.removeValue(forKey: id)?.cancel()
        stopTaskActions(id)
        if preferredMediaTaskID == id { preferredMediaTaskID = nil }
        if id == browser.id {
            if busy && agent.operatedPage { cancel() }
            adaptive.invalidate()
            cancelRestoration()
            endBackgroundListening(clearTaskIntent: true)
            browser.dispose()
            browser = BrowserController(model: self)
            webURL = ""
            webTitle = ""
            hasMedia = false
            isPlaying = false
            hasCustomSurface = false
            surface = .empty
        } else if let old = parkedBrowsers.removeValue(forKey: id) {
            old.dispose()
        }
        let closingSelected = selectedTaskID == id
        sideTasks.removeAll { $0.id == id }
        browserRevision += 1
        if closingSelected && !taskShelfVisible { collapse() }
        persistSideTasks()
        reconcileTasks()
    }
    func cardAction(_ id: UUID, action: String, value: String?) {
        taskRanking.record(id, .control)
        guard let task = sideTasks.first(where: { $0.id == id }), task.allowedActions.contains(action) else { return }
        switch action {
        case "expand": selectTask(id, expanded: true)
        case "dismiss": dismissTask(id)
        case "source":
            selectedTaskID = id
            clickExpanded = true
            collapsed = false
            webExpanded = true
            onResize?(windowSize)
            onShow?()
        case "calendar":
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: configuration
            ) { [weak self] application, error in
                Task { @MainActor [weak self] in
                    #if DEBUG
                        self?.calendarOpenCheck?(application?.bundleIdentifier == "com.apple.iCal" && error == nil)
                    #endif
                    if error != nil {
                        self?.deliverReply(
                            "Calendar couldn’t be opened. Try opening it from Applications.", kind: .failure, taskID: id
                        )
                    }
                }
            }
        default:
            if task.kind == .timer {
                timerAction(id, action: action)
                return
            }
            if task.kind == .workspace {
                performTaskAction(id, action: action, value: value)
                return
            }
            guard task.kind == .web else { return }
            let controller = id == browser.id ? browser : parkedBrowsers[id]
            let bound = task.plan?.actions?.first { $0.id == action }
            let binding =
                bound?.binding
                ?? (action == "toggle" && task.hasMedia ? PageBinding(action: "media", operation: "toggle") : nil)
            guard let binding else { return }
            if binding.action == "media", let operation = binding.operation,
                ["play", "pause", "toggle", "next"].contains(operation)
            {
                controlMedia(id, operation: operation)
                return
            }
            Task {
                do {
                    var arguments = binding.dictionary
                    if let value { arguments["text"] = value }
                    if externalBrowser && id == browser.id {
                        _ = try await performBrowserAction(arguments)
                    } else if let controller {
                        // Validate against the owning page just before execution, not another task's page.
                        let observation = try await controller.observe()
                        guard sideTasks.contains(where: { $0.id == id }) else { return }
                        // A missing secondary button must not disable the requested control.
                        let checked: BoundCardAction?
                        if let plan = task.plan, let bound {
                            checked = try plan.validatedAction(bound, observation: observation)
                        } else {
                            checked = nil
                        }
                        arguments = try (checked?.binding ?? binding).validated(observation: observation).dictionary
                        if let value { arguments["text"] = value }
                        _ = try await controller.action(arguments)
                        if let submit = checked?.submit { _ = try await controller.action(submit.dictionary) }
                    }
                    guard sideTasks.contains(where: { $0.id == id }) else { return }
                    if bound?.revealSource == true && binding.action != "media",
                        selectedTaskID == id, !collapsed, !taskShelfVisible
                    {
                        selectedTaskID = id
                        clickExpanded = true
                        collapsed = false
                        webExpanded = true
                        onResize?(windowSize)
                        onShow?()
                    }
                } catch {
                    guard sideTasks.contains(where: { $0.id == id }) else { return }
                    if let i = sideTasks.firstIndex(where: { $0.id == id }) {
                        sideTasks[i].status = "Control changed · open page"
                    }
                    deliverReply(
                        "This page control is no longer available. Open its source page to continue.", kind: .failure,
                        taskID: id)
                }
            }
        }
    }
    @discardableResult func startTimer(seconds: Double, title: String = "Timer", receivedAt: Date = Date()) throws
        -> UUID
    {
        guard seconds.isFinite, seconds >= 1, seconds <= 86400 * 7 else {
            throw AppError.message("Choose a timer between one second and seven days.")
        }
        ToolExecutionScope.current?.effectStarted = true
        var task = SideTask(kind: .timer, title: title.isEmpty ? "Timer" : String(title.prefix(80)))
        task.created = receivedAt
        task.duration = seconds
        task.deadline = receivedAt.addingTimeInterval(seconds)
        task.status = "Counting down"
        sideTasks.append(task)
        selectedTaskID = task.id
        ambientRequestID = task.id
        collapsed = true
        clickExpanded = false
        webExpanded = false
        persistSideTasks()
        refreshTaskClock()
        onResize?(windowSize)
        onShow?()
        if task.deadline! <= Date() { tickTasks() }
        return task.id
    }
    func timerAction(_ id: UUID, action: String) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = sideTasks[i]
        task.resumeOnHistoryRestore = nil
        if action == "addMinute", !task.finished {
            if task.remaining + 60 > 86400 * 7 { return }
            if let deadline = task.deadline {
                task.deadline = deadline.addingTimeInterval(60)
            } else {
                task.pausedSeconds = (task.pausedSeconds ?? 0) + 60
            }
            task.duration = min(86400 * 7, (task.duration ?? 0) + 60)
        } else if action == "stop" {
            task.deadline = nil
            task.pausedSeconds = 0
            task.finished = true
            task.hidden = false
            task.status = "Stopped"
            task.terminalLabel = task.title + " · Stopped"
            task.expires = Date().addingTimeInterval(10)
        } else if action == "restart" || task.finished {
            task.terminalLabel = nil
            task.expires = nil
            task.deadline = Date().addingTimeInterval(task.duration ?? 60)
            task.pausedSeconds = nil
            task.finished = false
            task.completedAt = nil
            task.status = "Counting down"
        } else if task.deadline != nil {
            task.pausedSeconds = task.remaining
            task.deadline = nil
            task.status = "Paused"
        } else {
            task.deadline = Date().addingTimeInterval(task.pausedSeconds ?? 60)
            task.pausedSeconds = nil
            task.status = "Counting down"
        }
        sideTasks[i] = task
        persistSideTasks()
        refreshTaskClock()
        reconcileTasks()
    }
    func refreshTaskClock() {
        taskClock?.invalidate()
        taskClock = nil
        guard sideTasks.contains(where: { $0.deadline != nil || ($0.expires != nil && !$0.hidden) }) else { return }
        taskClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTasks() }
        }
    }
    func tickTasks() {
        var changed = false
        for i in sideTasks.indices {
            if sideTasks[i].terminalLabel != nil, !sideTasks[i].hidden, pointerInside || menuTracking,
                let expiry = sideTasks[i].expires
            {
                sideTasks[i].expires = expiry.addingTimeInterval(1)
            }
            if let end = sideTasks[i].deadline, end <= Date() {
                sideTasks[i].deadline = nil
                sideTasks[i].finished = true
                sideTasks[i].completedAt = Date()
                sideTasks[i].status = "Time is up"
                sideTasks[i].hidden = false
                sideTasks[i].pausedSeconds = 0
                sideTasks[i].terminalLabel = sideTasks[i].title + " · Done"
                sideTasks[i].expires = Date().addingTimeInterval(10)
                ambientRequestID = sideTasks[i].id
                if selectedTaskID == nil { selectedTaskID = sideTasks[i].id }
                if !isLiveTest { NSSound.beep() }
                deliverReply(sideTasks[i].title + " · Time is up.", kind: .attention, taskID: sideTasks[i].id)
                onShow?()
                changed = true
            }
            if let end = sideTasks[i].expires, end <= Date(), !sideTasks[i].hidden {
                if pointerInside || menuTracking {
                    sideTasks[i].expires = Date().addingTimeInterval(1)
                    continue
                }
                sideTasks[i].hidden = true
                changed = true
            }
        }
        objectWillChange.send()
        if changed {
            persistSideTasks()
            reconcileTasks()
            refreshTaskClock()
        }
    }
    @discardableResult func addCalendarCard(_ result: [String: Any]) -> UUID? {
        guard result["verified"] as? Bool == true else { return nil }
        let event = result
        var task = SideTask(kind: .calendar, title: event["title"] as? String ?? "Calendar event")
        task.status = result["status"] as? String == "exists" ? "Already in Calendar" : "Added to Calendar"
        task.liveValues = CalendarService.cardState(event)
        task.detail = [event["start"] as? String, event["end"] as? String, event["location"] as? String].compactMap {
            $0
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        task.terminalLabel = task.title + " · " + task.status
        task.expires = Date().addingTimeInterval(10)
        sideTasks.append(task)
        selectedTaskID = task.id
        collapsed = true
        clickExpanded = false
        webExpanded = false
        persistSideTasks()
        refreshTaskClock()
        onResize?(windowSize)
        onShow?()
        return task.id
    }
    func decorateTask(_ id: UUID) {
        guard !isLiveTest, settings.main.isConfigured, interfaceJobs[id] == nil,
            let task = sideTasks.first(where: { $0.id == id }), task.terminalLabel == nil,
            ![.result, .timer, .calendar].contains(task.kind),
            !["Task failed", "Needs attention"].contains(task.status), !task.generated
        else { return }
        generateTaskInterface(
            id,
            instruction:
                "Create a calm interface for this already running task. Bind every changing value, including remaining time, in both the expanded and compact views. Preserve its actions and verified state.",
            userEdit: false)
    }
    /// Restricted local grammar: recognize explicit timer requests, never examples or explanations.
    static func timerSeconds(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
            in: CharacterSet(charactersIn: "。！!.")
        ).lowercased()
        let patterns = [
            #"^(?:请|麻烦)?(?:帮我|给我)?(?:设置|设|开始|开)?(?:一?个)?(?:倒计时|计时器|计时|定时器|定时)\s*(.+?)(?:吧|谢谢)?$"#,
            #"^(?:请|麻烦)?(?:帮我|给我)?(?:设置|设|开始|开)(?:一?个)?\s*(.+?)(?:的)?(?:倒计时|计时器|计时|定时器|定时)(?:吧|谢谢)?$"#,
            #"^(?:please\s+)?(?:(?:set|start)\s+(?:a\s+)?(?:timer|countdown)(?:\s+for)?|timer|countdown)\s+(.+?)(?:\s+please)?$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text)
            else { continue }
            if let seconds = localDuration(String(text[range])) { return seconds }
        }
        return nil
    }
    static func localDuration(_ raw: String) -> Double? {
        let source = raw.replacingOccurrences(of: " ", with: "")
        let pattern =
            #"(\d+(?:\.\d+)?|[零〇一二两三四五六七八九十百千]+|半)(小时|钟头|分钟|秒钟|分|秒|hours?|hrs?|minutes?|mins?|seconds?|secs?)(半)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty, matches.reduce(0, { $0 + $1.range.length }) == (source as NSString).length else {
            return nil
        }
        var total: Double = 0
        for match in matches {
            guard let nr = Range(match.range(at: 1), in: source), let ur = Range(match.range(at: 2), in: source),
                let amount = localNumber(String(source[nr]))
            else { return nil }
            let unit = String(source[ur])
            let multiplier: Double =
                unit.contains("小时") || unit.contains("钟头") || unit.hasPrefix("h")
                ? 3600 : unit.hasPrefix("分") || unit.hasPrefix("m") ? 60 : 1
            total += (amount + (match.range(at: 3).location == NSNotFound ? 0 : 0.5)) * multiplier
        }
        return total.isFinite && total > 0 ? total : nil
    }
    static func localNumber(_ text: String) -> Double? {
        if let number = Double(text) { return number }
        if text == "半" { return 0.5 }
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        var total = 0
        var digit = 0
        for c in text {
            if let n = digits[c] {
                digit = n
            } else if let n = units[c] {
                total += max(1, digit) * n
                digit = 0
            } else {
                return nil
            }
        }
        return Double(total + digit)
    }
}
