import Combine
import SwiftUI
import WebKit

extension AppModel {
    func beginAmbientRequest(_ text: String, taskID: UUID? = nil, messageID: UUID? = nil) {
        adaptive.blockedSources.remove(taskID ?? browser.id)
        var request = TaskRequestContext(
            input: text, receivedAt: requestReceivedAt, startPolicy: settings.taskStartPolicy)
        request.submittedTaskID = taskID
        request.sourceCandidateID = taskID ?? (messageID == nil && RequestRun.current?.forceNewTask != true ? selectedSideTask?.id : nil)
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
        if !taskFailed, agent.replyKind == .information, let id = activeRequest?.owner?.id ?? requestCardID {
            // The conversation and its receipt already carry this answer.
            sideTasks.removeAll { $0.id == id && $0.kind == .result }
            if ambientRequestID == id { ambientRequestID = nil }
        }
        if let id = requestCardID, let i = sideTasks.firstIndex(where: { $0.id == id }) {
            sideTasks[i].status =
                agent.replyKind == .needsInput ? "Waiting for reply" : taskFailed ? "Needs attention" : "Done"
            if !taskFailed && (agent.replyKind == .success || agent.replyKind == .information) && sideTasks[i].terminalLabel == nil {
                sideTasks[i].terminalLabel = sideTasks[i].title + ", done"
                sideTasks[i].expires = Date().addingTimeInterval(10)
            }
            if ambientRequestID == id { ambientRequestID = nil }
        }
        if !taskFailed, agent.replyKind == .success, let id = activeRequest?.owner?.id,
            let task = sideTasks.first(where: { $0.id == id }), task.terminalLabel == nil,
            task.kind == .web || task.kind == .workspace
        {
            if task.workFile == nil && task.taskSurface?.actions.contains(where: { $0.kind == .openRecord }) != true {
                interfaceMemory.remember(task, purpose: task.intent ?? activeRequest?.input ?? task.title)
            }
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
    var listedTasks: [SideTask] { sideTasks.filter { work.view($0.id)?.closed != true } }
    var visibleTasks: [SideTask] { listedTasks.filter { !$0.hidden } }
    /// Individual countdowns own their alarms; the shelf and strip share a single tool.
    var timerEntries: [SideTask] {
        let ownerIDs = Set(listedTasks.filter { $0.kind == .timer }.map { task in
            work.view(task.id).flatMap { work.artifact($0.selected)?.native?.id } ?? task.id
        })
        return sideTasks.filter { ownerIDs.contains($0.id) && $0.kind == .timer && $0.timerToolLauncher != true }
    }
    var primaryTimerEntry: SideTask? {
        let entries = timerEntries
        return entries.filter { $0.pendingTimerReminderID != nil }.max { ($0.completedAt ?? $0.created) < ($1.completedAt ?? $1.created) }
            ?? entries.filter { $0.deadline != nil }.min { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
            ?? entries.first(where: { !$0.finished })
            ?? entries.max { ($0.completedAt ?? $0.created) < ($1.completedAt ?? $1.created) }
    }
    var timerTool: SideTask? {
        let views = listedTasks.filter { $0.kind == .timer }
        guard let anchor = views.first(where: { $0.timerToolLauncher == true }) ?? views.min(by: { a, b in
            a.created == b.created ? a.id.uuidString < b.id.uuidString : a.created < b.created
        }) else { return nil }
        var tool = primaryTimerEntry ?? anchor
        tool.id = anchor.id
        tool.title = "Timer"
        tool.terminalLabel = nil
        tool.hidden = views.allSatisfy(\.hidden)
        return tool
    }
    var listedToolCount: Int {
        let tasks = listedTasks
        let timers = tasks.filter { $0.kind == .timer }.count
        return tasks.count - max(0, timers - 1)
    }
    var selectedSideTask: SideTask? { visibleTasks.first { $0.id == selectedTaskID } ?? visibleTasks.first }
    func loadSideTasks() {
        taskOrder = (preferences.stringArray(forKey: "taskOrder.v1") ?? []).compactMap(UUID.init(uuidString:))
        if let data = preferences.data(forKey: "sideTasks.v1") {
            sideTasks = shelfArchive.read(data)
        }
        for artifact in work.snapshot.artifacts.values {
            guard var task = artifact.native, !sideTasks.contains(where: { $0.id == task.id }) else { continue }
            task.hidden = true
            sideTasks.append(task)
        }
        let retiredPlayers = consolidateSavedMusicPlayers()
        for i in sideTasks.indices {
            if sideTasks[i].kind == .web {
                sideTasks[i].hidden = true
                sideTasks[i].playing = false
                sideTasks[i].status = "Resume page"
            }
            if [.workspace, .result].contains(sideTasks[i].kind),
                ["Preparing…", "Working…", "Queued", "Calculating…"].contains(sideTasks[i].status) {
                sideTasks[i].status = "Interrupted. Retry"
            }
        }
        for task in sideTasks where task.taskSurface != nil { migrateWorkSurface(task) }
        // Restore executors independently of visible views. Never autoplay a page
        // solely because its last persisted resource snapshot was playing.
        for task in sideTasks where [.timer,.calendar,.web].contains(task.kind) {
            if let view = work.view(task.id), let native = work.artifact(view.selected)?.native, native.id != task.id { continue }
            _ = work.syncNative(task,goalID:nil)
        }
        for id in retiredPlayers { work.closeView(id) }
        for view in work.snapshot.views.values { try? projectWorkView(view.id) }
        work.save()
        scheduleDataRefresh()
        for artifact in work.snapshot.artifacts.values where artifact.definition.runtime != nil { taskRuntime.attach(artifact.id) }
        for task in sideTasks {
            guard let alarm = task.pendingTimerReminderID, timerAlarmView(for: task.id) != nil else { continue }
            presentTimerAlarm(for: task, eventID: alarm, restoring: true)
        }
        restoreMessageReminders()
        reconcileTasks()
        refreshTaskClock()
    }
    func persistSideTasks() {
        // Native adapters publish resource state; secondary views never write it back.
        for task in sideTasks where [.timer,.calendar,.web].contains(task.kind) {
            if let view = work.view(task.id), let resource = work.artifact(view.selected)?.native, resource.id != task.id { continue }
            let relevant = work.view(task.id) == nil || RequestRun.current?.owns(task.id) == true
            let id = work.syncNative(task,goalID:relevant ? RequestRun.current?.goalID : nil)
            if relevant { RequestRun.current?.retainResult(id,needsView:false) }
            projectWorkResult(id)
        }
        work.save()
        scheduleDataRefresh()
        guard persistHistory, !isLiveTest else { return }
        let preparing = Set(commandRuns.compactMap { $0.context?.placeholderID } + [requestCardID].compactMap { $0 })
        preferences.set(
            taskOrder.filter { id in !preparing.contains(id) && sideTasks.contains { $0.id == id } }.map(\.uuidString),
            forKey: "taskOrder.v1")
        if let data = try? shelfArchive.encoded(sideTasks.filter { !preparing.contains($0.id) }) {
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
        if taskClickWillCollapse(id) {
            collapse()
        } else {
            selectTask(id, expanded: true)
        }
    }
    func taskClickWillCollapse(_ id: UUID) -> Bool {
        guard !collapsed, !taskShelfVisible, !commandPanelVisible else { return false }
        return selectedTaskID == id || (selectedSideTask?.kind == .timer && timerTool?.id == id)
    }
    func openHandoff(_ url: URL, taskID: UUID) {
        if selectedTaskID == taskID, let source = handoffSource, source.taskID == taskID, source.destination == url {
            taskShelfVisible = false
            showPage()
            return
        }
        guard selectTask(taskID, expanded: true, preferSource: false) else { return }
        do {
            handoffSource = try HandoffSource(taskID: taskID, destination: url, model: self)
            webExpanded = true
            onResize?(windowSize)
        } catch {
            deliverReply(userText("无法读取这份原件。", "Could not read this source."), kind: .failure, taskID: taskID)
        }
    }
    func openTaskFromDoubleClick(_ id: UUID) {
        guard let task = sideTasks.first(where: { $0.id == id }) else { return }
        taskRanking.record(id, .open)
        if let file = task.workFile {
            guard let url = try? file.existingURL() else {
                deliverReply(userText("找不到或无法打开这份文件。", "This file is missing or could not be opened."), kind: .failure, taskID: id)
                return
            }
            openHandoff(url, taskID: id)
            return
        }
        if task.kind == .workspace, task.taskSurface?.apiData?.recordPagePointer != nil,
            let raw = task.liveValues?["recordPageURL"], let url = try? PublicDataClient.url(raw) {
            openHandoff(url, taskID: id)
            return
        }
        if task.kind == .web { stopCommand(for: id) }
        selectTask(id, expanded: true, preferSource: task.kind == .web)
    }
    @discardableResult
    func selectTask(_ id: UUID, expanded: Bool = false, preferSource: Bool? = nil) -> Bool {
        if id == requestCardID {
            openTaskConversation(id)
            return true
        }
        if handoffSource?.taskID != id || !collapsed { handoffSource = nil }
        upgradeStandardCard(id)
        guard let task = sideTasks.first(where: { $0.id == id }) else { return false }
        let openingSource = expanded && (preferSource ?? task.opensSourceByDefault) && task.kind == .web
        lastActionError = nil
        if task.taskSurface?.apiData != nil, taskActionJobs[id] == nil,
            Date().timeIntervalSince(task.dataUpdatedAt ?? .distantPast) >= 60
        {
            refreshAPIData(id)
        }
        if feedback?.kind == .success { dismissFeedback() }
        if task.kind == .web, dormantLaunchSession?.taskID == id || (id != browser.id && parkedBrowsers[id] == nil) {
            do { _ = try beginTaskSourceRestore(task) } catch {
                lastActionError = error.localizedDescription
                return false
            }
        }
        if task.hidden, let i = sideTasks.firstIndex(where: { $0.id == id }) {
            work.showView(id)
            sideTasks[i].hidden = false
            sideTasks[i].expires = nil
            persistSideTasks()
        }
        if commandPanelVisible { selectChat(false, restoreFocus: false) }
        taskShelfVisible = false
        selectedTaskID = id
        if task.kind == .web && !busy {
            activateSelectedSource()
            if !hasCustomSurface { adaptive.changed() }
        }
        webExpanded = openingSource
        collapsed = !expanded
        clickExpanded = expanded
        onResize?(windowSize)
        onShow?()
        refreshHover()
        if expanded && task.kind != .web && task.kind != .timer && !task.generated { decorateTask(id) }
        return true
    }

    func dismissTask(_ id: UUID) {
        if work.view(id) != nil { work.hideView(id) }
        taskRanking.record(id, .hide)
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        // Hiding a card does not stop its underlying task.
        sideTasks[i].hidden = true
        if selectedTaskID == id && !taskShelfVisible { collapse() }
        persistSideTasks()
        reconcileTasks()
    }
    func showTask(_ id: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        work.showView(id)
        sideTasks[i].hidden = false
        sideTasks[i].expires = nil
        persistSideTasks()
        reconcileTasks()
    }
    func setToolHidden(_ id: UUID, hidden: Bool) {
        guard sideTasks.first(where: { $0.id == id })?.kind == .timer else {
            if hidden { dismissTask(id) } else { showTask(id) }
            return
        }
        let ids = Set(listedTasks.filter { $0.kind == .timer }.map(\.id))
        for index in sideTasks.indices where ids.contains(sideTasks[index].id) {
            let entryID = sideTasks[index].id
            if hidden { work.hideView(entryID) } else { work.showView(entryID) }
            sideTasks[index].hidden = hidden
            sideTasks[index].expires = nil
        }
        if hidden {
            taskRanking.record(id, .hide)
            if let selectedTaskID, ids.contains(selectedTaskID), !taskShelfVisible { collapse() }
        }
        persistSideTasks()
        reconcileTasks()
    }
    func closeTaskTool(_ id: UUID) {
        guard sideTasks.first(where: { $0.id == id })?.kind == .timer else {
            closeTask(id)
            return
        }
        for entry in listedTasks where entry.kind == .timer { closeTask(entry.id) }
        refreshTaskClock()
    }
    func upsertWebTask(_ plan: SurfacePlan? = nil, activate: Bool = false) {
        guard !webURL.isEmpty else { return }
        let id = browser.id
        guard !sideTasks.contains(where: { $0.id == id && $0.terminalLabel != nil }) else { return }
        let index = sideTasks.firstIndex { $0.id == id }
        var card = index.map { sideTasks[$0] } ?? SideTask(id: id, kind: .web, title: trackTitle)
        if let previous = card.sourceURL, URL(string: previous)?.host != URL(string: webURL)?.host {
            endBackgroundListening(clearTaskIntent: true)
        }
        card.updateMediaRole(primary: browser.lastState["mediaPrimary"] as? Bool, url: webURL)
        if requestPageID == id, activeRequest?.expectsPlayback == true {
            card.listening = true
            card.prefersSource = false
            if let role = activeRequest?.musicSessionRole {
                card.musicSessionRole = card.musicSessionRole ?? role
            }
        }
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
        if browser.sourceAccessIssue == nil { card.title = trackTitle }
        else if index == nil { card.title = activeRequest?.input ?? "Media source" }
        card.sourceURL = webURL
        if requestPageID == id { card.intent = activeRequest?.input }
        card.hasMedia = hasMedia
        card.playing = isPlaying
        card.muted = browser.lastState["muted"] as? Bool
        card.plan = plan ?? card.plan ?? surface
        card.markup = nil
        card.generated = card.plan?.markup != nil
        if plan?.markup != nil {
            card.interfaceIssue = nil
            resolveTaskIssue(id, source: .interface)
        }
        if let recipeID = card.plan?.interfaceRecipeID {
            card.interfaceRecipeID = recipeID
            card.customCompact = true
        }
        card.status =
            card.isMediaTask
            ? (browser.sourceAccessIssue != nil ? "Access needed" : hasMedia ? (isPlaying ? "Playing" : "Paused") : "Loading…") : (URL(string: webURL)?.host ?? "Ready")
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
        if let title = data["title"] as? String, parkedBrowsers[id]?.sourceAccessIssue == nil { sideTasks[i].title = title }
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
    static let missingPageReadingsIssue = "The source is unavailable. Open the page to reconnect."

    func updateLiveReadings(_ id: UUID, data: [String: Any]) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), sideTasks[i].terminalLabel == nil,
            let url = data["url"] as? String, url == sideTasks[i].sourceURL
        else { return }
        // A new surface can drop the old DOM bindings (for example, the native
        // music player). Their persisted error must not outlive those bindings.
        guard let readings = sideTasks[i].plan?.readings, !readings.isEmpty else {
            if sideTasks[i].dataIssue == Self.missingPageReadingsIssue {
                sideTasks[i].dataIssue = nil
                resolveTaskIssue(id, source: .readings)
            }
            return
        }
        guard let values = data["readings"] as? [String: String] else { return }
        let bound = Dictionary(readings.map { ($0.key, values[$0.key] ?? "—") }, uniquingKeysWith: { first, _ in first })
        let missing = bound.values.contains { $0 == "—" || $0.isEmpty }
        if missing, sideTasks[i].dataIssue == nil || sideTasks[i].dataIssue == Self.missingPageReadingsIssue {
            sideTasks[i].dataIssue = Self.missingPageReadingsIssue
            let unavailable = readings.filter { bound[$0.key] == "—" || bound[$0.key]?.isEmpty == true }.map(\.key)
            reportTaskIssue(id, source: .readings,
                detail: "The page no longer provides these readings: " + unavailable.joined(separator: ", ") + ". Reopen the source or update this view.")
        } else if !missing, sideTasks[i].dataIssue == Self.missingPageReadingsIssue {
            sideTasks[i].dataIssue = nil
            resolveTaskIssue(id, source: .readings)
        }
        if !missing { sideTasks[i].dataUpdatedAt = Date() }
        if sideTasks[i].liveValues != bound { sideTasks[i].liveValues = bound }
    }
    func closeTask(_ id: UUID) {
        if let view = work.view(id) {
            work.closeView(id)
            let retainedAlarm = timerAlarmView(for: id) == nil ? nil : sideTasks.first { $0.id == id }?.pendingTimerReminderID
            if retainedAlarm == nil { clearPendingTimerAlarm(for: id) }
            removeReminders { $0.owner == id && $0.id != retainedAlarm }
            if let task = sideTasks.first(where: { $0.id == id }) { archiveTaskHistory(task) }
            try? projectWorkView(id)
            for artifactID in view.artifacts {
                guard !work.hasOpenView(for: artifactID), let resource = work.artifact(artifactID)?.native else { continue }
                if resource.kind == .web {
                    closeWebTask(resource.id)
                } else if resource.kind == .timer {
                    clearPendingTimerAlarm(for: resource.id)
                    guard let i = sideTasks.firstIndex(where: { $0.id == resource.id }), sideTasks[i].deadline != nil else { continue }
                    sideTasks[i].pausedSeconds = sideTasks[i].remaining
                    sideTasks[i].deadline = nil
                    sideTasks[i].resumeOnHistoryRestore = true
                    sideTasks[i].status = "Paused"
                    refreshTaskClock()
                }
            }
            if selectedTaskID == id && !taskShelfVisible { collapse() }
            persistSideTasks()
            reconcileTasks()
            return
        }
        clearPendingTimerAlarm(for: id)
        removeReminders { $0.owner == id }
        adaptive.blockedSources.remove(id)
        stopTaskActions(id)
        if ownsRequest(id) && busy { stopCommand(for: id) }
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
        // An unresolved new owner is an independent activity, even at the same URL.
        // Existing-task navigation is prepared by the dispatcher before reaching here.
        let independent = activeRequest != nil && activeRequest?.owner == nil
        let engineChanged = (browser.systemPage != nil) != (settings.browserEngine == .systemBrowser)
        if engineChanged && webURL.isEmpty {
            browser.dispose()
            browser = BrowserController(model: self)
            browserRevision += 1
        }
        if !independent, !engineChanged, let destination, let target = SurfaceCache.pageKey(destination) {
            if target == SurfaceCache.pageKey(webURL) { return }
            if let existing = sideTasks.first(where: {
                $0.kind == .web && SurfaceCache.pageKey($0.sourceURL ?? "") == target && parkedBrowsers[$0.id] != nil
            }) {
                activateSource(existing)
                return
            }
        }
        guard !externalBrowser, !webURL.isEmpty, independent || hasCustomSurface || hasMedia || engineChanged else { return }
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
    private func beginTaskSourceRestore(_ task: SideTask, replacingMedia: Bool = false) throws -> Task<Void, Error> {
        if let job = taskSourceRestorations[task.id] { return job }
        guard let raw = task.sourceURL, let url = URL(string: raw),
            ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw AppError.message("This task no longer has a usable page address.")
        }
        let id = task.id
        let saved = dormantLaunchSession.flatMap { $0.taskID == task.id && $0.url == raw ? $0 : nil }
        let restored: BrowserController
        if let existing = id == browser.id ? browser : parkedBrowsers[id] {
            restored = existing
        } else {
            guard parkedBrowsers.count < 2 else {
                throw AppError.message("Three pages are already open. Close one from the task list, then try again.")
            }
            restored = BrowserController(model: self, id: id)
            parkedBrowsers[id] = restored
            browserRevision += 1
        }
        let job = Task { @MainActor in
            defer {
                if browser === restored || parkedBrowsers[id] === restored { taskSourceRestorations[id] = nil }
            }
            do {
                try Task.checkCancellation()
                guard !restored.disposed else { throw CancellationError() }
                if task.isMediaTask {
                    restored.setUserPlaybackPaused(true, origin: "restore_saved_task")
                    await restored.applyPlaybackPolicy()
                }
                if replacingMedia && task.isMediaTask && playbackSources.avoids(raw) {
                    if dormantLaunchSession?.taskID == id { dormantLaunchSession = nil }
                    return
                }
                let replacement = task.isMediaTask ? try await savedPlaybackReplacement(raw, title: task.title, task: task) : nil
                let source = replacement?.selected.url ?? raw
                try Task.checkCancellation()
                guard !restored.disposed else { throw CancellationError() }
                var page = try await restored.action(["action": "navigate", "url": source])
                try Task.checkCancellation()
                restored.restoredPlaybackReplacement = replacement
                if var saved {
                    if source != raw { saved.url = source; saved.position = 0 }
                    page = try await restoredObservation(page, entry: saved, browser: restored)
                    await restoreMediaSettings(saved, page: page, browser: restored)
                }
                try Task.checkCancellation()
                guard !restored.disposed, let i = sideTasks.firstIndex(where: { $0.id == id }) else {
                    throw CancellationError()
                }
                if let plan = saved?.plan ?? task.plan, let checked = try? plan.validated(observation: page) {
                    sideTasks[i].plan = checked
                    restored.rememberMediaSurface(checked, url: source)
                    try await restored.bindReadings(checked.readings ?? [])
                    try Task.checkCancellation()
                } else {
                    sideTasks[i].plan = nil
                    sideTasks[i].status = "Page restored"
                }
                guard !restored.disposed, let current = sideTasks.first(where: { $0.id == id }) else {
                    throw CancellationError()
                }
                if dormantLaunchSession?.taskID == id { dormantLaunchSession = nil }
                if browser === restored {
                    surface = current.plan ?? .webpage
                    hasCustomSurface = current.plan != nil
                }
            } catch {
                if !Task.isCancelled, !restored.disposed,
                    browser === restored || parkedBrowsers[id] === restored,
                    let i = sideTasks.firstIndex(where: { $0.id == id }) {
                    sideTasks[i].status = "Open page to continue"
                }
                throw error
            }
        }
        taskSourceRestorations[id] = job
        return job
    }
    func wakeDormantSource(_ id: UUID, replacingMedia: Bool = false) async throws {
        guard dormantLaunchSession?.taskID == id else { return }
        guard let task = sideTasks.first(where: { $0.id == id }) else { throw CancellationError() }
        try await beginTaskSourceRestore(task, replacingMedia: replacingMedia).value
        try Task.checkCancellation()
        // A direct Play from the restored capsule becomes the active session
        // when the shell has no other page open, so its progress is saved.
        if webURL.isEmpty { try activateTaskSource(id) }
    }

    func prepareTaskSource(_ id: UUID, replacingMedia: Bool = false) async throws {
        guard let task = sideTasks.first(where: { $0.id == id }), task.kind == .web else { throw CancellationError() }
        if let job = taskSourceRestorations[id] {
            try await job.value
        } else if dormantLaunchSession?.taskID == id || (browser.id != id && parkedBrowsers[id] == nil) {
            try await beginTaskSourceRestore(task, replacingMedia: replacingMedia).value
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
        if !webURL.isEmpty { parkedBrowsers[browser.id] = browser } else { browser.dispose() }
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
        if dormantLaunchSession?.taskID == id {
            Task {
                do {
                    try await wakeDormantSource(id)
                    try Task.checkCancellation()
                    controlMedia(id, operation: operation)
                } catch is CancellationError {} catch {
                    reportTaskIssue(id, source: .playback, detail: error.localizedDescription)
                }
            }
            return
        }
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
        stopCommand(for: id)
        if dormantLaunchSession?.taskID == id { dormantLaunchSession = nil }
        musicJobs.removeValue(forKey: id)?.cancel()
        musicRevisions.removeValue(forKey: id)
        musicLoading.remove(id)
        musicPlayback.removeValue(forKey: id)
        musicQueueExpanded.remove(id)
        musicErrors.removeValue(forKey: id)
        if var task = sideTasks.first(where: { $0.id == id }) {
            archiveTaskHistory(task)
            if work.view(id)?.closed == true {
                if task.isMediaTask { task.status = "Paused" }
                task.playing = false
                task.listening = false
                _ = work.syncNative(task, goalID: nil)
            }
        }
        taskSourceRestorations.removeValue(forKey: id)?.cancel()
        stopTaskActions(id)
        if preferredMediaTaskID == id { preferredMediaTaskID = nil }
        if id == browser.id {
            if busy && agent.operatedPage && requestPageID == id { cancel() }
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
    func cardAction(_ id: UUID, action: String, value: String?, fromCapsule: Bool = false) {
        if !["expand","dismiss","source","calendar"].contains(action), let view = work.view(id),
            let native = work.artifact(view.selected)?.native, native.id != id {
            cardAction(native.id,action:action,value:value,fromCapsule:fromCapsule)
            return
        }
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
                        guard !fromCapsule else { return }
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
                        if fromCapsule {
                            guard let expected = bound?.compactPageURL, expected == observation["url"] as? String,
                                  bound?.compactLabel != nil, checked?.binding.action == "click" else {
                                throw AppError.message("The source page has changed.")
                            }
                            arguments["expectedPage"] = expected
                        }
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
                        sideTasks[i].status = "Control changed. Open page"
                    }
                    deliverReply(
                        "This page control is no longer available. Open its source page to continue.", kind: .failure,
                        taskID: id)
                }
            }
        }
    }
    @discardableResult func startTimer(seconds: Double, title: String = "Timer", receivedAt: Date = Date(), keepExpanded: Bool = false) throws
        -> UUID
    {
        guard seconds.isFinite, seconds >= 1, seconds <= 86400 * 7 else {
            throw AppError.message("Choose a timer between one second and seven days.")
        }
        ToolExecutionScope.current?.effectStarted = true
        let stayOpen = keepExpanded || (!collapsed && !commandPanelVisible && !taskShelfVisible && selectedSideTask?.kind == .timer)
        var task = SideTask(kind: .timer, title: title.isEmpty ? "Timer" : String(title.prefix(80)))
        task.created = receivedAt
        task.duration = seconds
        task.deadline = receivedAt.addingTimeInterval(seconds)
        task.status = "Counting down"
        sideTasks.append(task)
        selectedTaskID = task.id
        ambientRequestID = task.id
        collapsed = !stayOpen
        clickExpanded = stayOpen
        webExpanded = false
        persistSideTasks()
        refreshTaskClock()
        onResize?(windowSize)
        onShow?()
        if task.deadline! <= Date() { tickTasks() }
        return task.id
    }
    func openTimerTool() {
        if let tool = timerTool {
            selectTask(tool.id, expanded: true)
            return
        }
        var launcher = SideTask(kind: .timer, title: "Timer")
        launcher.timerToolLauncher = true
        launcher.finished = true
        launcher.status = "Ready"
        sideTasks.append(launcher)
        persistSideTasks()
        selectTask(launcher.id, expanded: true)
    }
    @discardableResult
    func startTimerFromTool(seconds: Double, title: String) throws -> UUID {
        try startTimer(seconds: seconds, title: title, keepExpanded: true)
    }
    func acknowledgeTimerFromTool(_ id: UUID) {
        guard let event = sideTasks.first(where: { $0.id == id })?.pendingTimerReminderID else { return }
        dismissReminder(event)
    }
    func timerAction(_ id: UUID, action: String) {
        guard ["toggle", "stop", "restart", "addMinute"].contains(action),
            let i = sideTasks.firstIndex(where: { $0.id == id && $0.kind == .timer && $0.timerToolLauncher != true }) else { return }
        guard action != "addMinute" || !sideTasks[i].finished else { return }
        clearPendingTimerAlarm(for: id)
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
            task.terminalLabel = task.title + ", stopped"
            task.expires = nil
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
            if let view = work.view(sideTasks[i].id), let native = work.artifact(view.selected)?.native,
                native.id != sideTasks[i].id { continue }
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
                sideTasks[i].pausedSeconds = 0
                sideTasks[i].terminalLabel = sideTasks[i].title + ", done"
                sideTasks[i].expires = nil
                if timerAlarmView(for: sideTasks[i].id) != nil {
                    if !sideTasks[i].hidden {
                        ambientRequestID = sideTasks[i].id
                        if selectedTaskID == nil { selectedTaskID = sideTasks[i].id }
                    }
                    let task = sideTasks[i]
                    let event = appendMessage(task.timerAlarmText, isUser: false, taskID: task.id)
                    sideTasks[i].pendingTimerReminderID = event
                    presentTimerAlarm(for: task, eventID: event)
                }
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
        // The countdown is derived from its deadline, so ordinary seconds do not mutate sideTasks.
        if !cardReminderValues.isEmpty { observeCardReminders() }
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
        task.terminalLabel = task.title + ", " + task.status
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
