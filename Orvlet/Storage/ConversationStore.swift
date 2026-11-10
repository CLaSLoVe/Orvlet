import Foundation

struct TaskHistoryItem: Identifiable {
    let id: UUID
    let title: String
    let symbol: String
    let preview: String
    let updated: Date
    let state: String
}

extension AppModel {
    var visibleConversation: [ChatMessage] {
        guard let id = conversationTaskID else { return [] }
        return messages.filter { $0.taskID == id }
    }
    var conversationActivity: TaskActivity? {
        guard let id = conversationTaskID else { return nil }
        if busy && ownsRequest(id) { return .working(progressText(activity.isEmpty ? "On it…" : activity)) }
        if queuedTaskRequests.contains(where: { $0.taskID == id }) { return .queued }
        if let task = sideTasks.first(where: { $0.id == id }),
            let state = taskActivity(task), state.isWorking || state == .stopped
        {
            return state
        }
        return nil
    }
    var taskHistoryItems: [TaskHistoryItem] {
        let grouped = Dictionary(grouping: messages.compactMap { $0.taskID == nil ? nil : $0 }, by: { $0.taskID! })
        var tasks = Dictionary(archivedTaskHistory.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for task in sideTasks { tasks[task.id] = task }
        let ids = Set(tasks.keys).union(grouped.keys)
        return ids.map { id in
            let task = tasks[id]
            let conversation = grouped[id] ?? []
            let active = sideTasks.first { $0.id == id }
            return TaskHistoryItem(
                id: id,
                title: task?.title
                    ?? String((conversation.first(where: { $0.isUser })?.text ?? "Earlier conversation").prefix(80)),
                symbol: task?.symbol ?? "bubble.left",
                preview: conversation.last?.text ?? task?.detail ?? "No messages yet",
                updated: conversation.last?.date ?? task?.created ?? .distantPast,
                state: active == nil ? "Closed" : active?.hidden == true ? "Hidden" : "Open")
        }.sorted { $0.updated == $1.updated ? $0.id.uuidString < $1.id.uuidString : $0.updated > $1.updated }
    }
    var conversationTitle: String {
        taskHistoryItems.first(where: { $0.id == conversationTaskID })?.title ?? "Task conversation"
    }
    var historyContentHeight: Double {
        if conversationTaskID == nil { return min(260, max(140, Double(taskHistoryItems.count) * 58 + 16)) }
        let estimated = visibleConversation.reduce(40.0) { $0 + Double(max(1, ($1.text.count + 39) / 40)) * 19 + 28 }
        return min(260, max(180, estimated))
    }
    func openTaskHistory() {
        selectChat(true)
        conversationTaskID = nil
        conversationHistoryVisible = true
        onCommandResize?(commandWindowHeight)
    }
    func openTaskConversation(_ id: UUID) {
        selectChat(true, conversation: id)
        conversationHistoryVisible = true
        onCommandResize?(commandWindowHeight)
    }
    func archiveTaskHistory(_ original: SideTask) {
        var task = original
        task.resumeOnHistoryRestore = false
        if task.runtimeState?.phase == .running || task.runtimeState?.phase == .stale {
            task.resumeOnHistoryRestore = true
            task.runtimeState = TaskRuntimeState(
                phase: .paused, pausedAt: Date(), lastSuccess: task.runtimeState?.lastSuccess)
        }
        if task.kind == .timer, task.deadline != nil {
            task.resumeOnHistoryRestore = true
            task.pausedSeconds = task.remaining
            task.deadline = nil
        }
        task.playing = false
        task.hidden = true
        archivedTaskHistory.removeAll { $0.id == task.id }
        archivedTaskHistory.append(task)
        persistTaskHistory()
    }
    func persistTaskHistory() {
        guard persistHistory, !isLiveTest else { return }
        if let data = try? JSONEncoder().encode(archivedTaskHistory) { preferences.set(data, forKey: "taskHistory.v1") }
    }
    @discardableResult
    func restoreHistoryTask(_ id: UUID, showCard: Bool = true) -> Bool {
        if !sideTasks.contains(where: { $0.id == id }) {
            guard let item = taskHistoryItems.first(where: { $0.id == id }) else { return false }
            var task =
                archivedTaskHistory.first(where: { $0.id == id }) ?? SideTask(id: id, kind: .result, title: item.title)
            task.hidden = false
            task.expires = nil
            if task.runtimeState?.phase == .paused { task.status = "Paused" }
            if task.kind == .result {
                task.detail = messages.last(where: { $0.taskID == id && !$0.isUser })?.text ?? task.detail
                task.status = "Saved conversation"
            }
            sideTasks.append(task)
            archivedTaskHistory.removeAll { $0.id == id }
            persistTaskHistory()
            if task.taskSurface?.runtime != nil { taskRuntime.attach(id) }
            refreshTaskClock()
            persistSideTasks()
        }
        if showCard {
            if let task = sideTasks.first(where: { $0.id == id }), task.resumeOnHistoryRestore == true {
                if task.taskSurface?.runtime != nil {
                    taskRuntime.control(id, operation: "resume")
                } else if task.kind == .timer {
                    timerAction(id, action: "toggle")
                }
            }
            return selectTask(id, expanded: true, preferSource: false)
        }
        return true
    }
    func deleteTaskHistory(_ id: UUID) {
        closeTask(id)
        conversationDrafts[id] = nil
        archivedTaskHistory.removeAll { $0.id == id }
        messages.removeAll { $0.taskID == id }
        persistTaskHistory()
        persistConversation()
        if conversationTaskID == id {
            conversationTaskID = nil
            editingInterfaceID = nil
            command = newTaskDraft
            openTaskHistory()
        }
    }
    /// Older unattributed requests become separate conversations; never guess a
    /// card from whichever one happens to be selected during migration.
    func migrateConversationOwnership() {
        var migrated = messages
        var previous: UUID?
        var requestOwners: [UUID: UUID] = [:]
        for message in messages {
            if let request = message.requestID, let task = message.taskID { requestOwners[request] = task }
        }
        for index in migrated.indices {
            if migrated[index].taskID != nil {
                previous = nil
                continue
            }
            let owner: UUID
            if let request = migrated[index].requestID {
                owner = requestOwners[request] ?? request
                requestOwners[request] = owner
            } else if migrated[index].isUser || previous == nil {
                owner = UUID()
            } else {
                owner = previous!
            }
            migrated[index].taskID = owner
            previous = owner
        }
        if migrated.contains(where: { $0.taskID != nil }) { messages = migrated }
    }
    func persistConversation() {
        guard persistHistory, !isLiveTest else { return }
        if let data = try? JSONEncoder().encode(messages) {
            preferences.set(data, forKey: "conversation.v1")
        }
    }
    @discardableResult
    func appendMessage(_ text: String, isUser: Bool, taskID: UUID? = nil, requestID: UUID? = nil) -> UUID {
        let message = ChatMessage(taskID: taskID ?? UUID(), requestID: requestID, text: text, isUser: isUser)
        let retained = Set(messages.filter { $0.taskID == message.taskID }.suffix(499).map(\.id))
        messages = messages.filter { $0.taskID != message.taskID || retained.contains($0.id) } + [message]
        return message.id
    }
    func associateMessages(requestID: UUID, messageID: UUID?, taskID: UUID) {
        for index in messages.indices where messages[index].requestID == requestID || messages[index].id == messageID {
            messages[index].taskID = taskID
            messages[index].requestID = requestID
        }
    }
    /// A bounded dialogue, including the question being answered, rather than only a task title.
    func taskInterpretationContext(_ id: UUID, excluding latest: String) -> [[String: String]] {
        messages.filter { $0.taskID == id && $0.text != latest }.suffix(6).map {
            [
                "role": $0.isUser ? "user" : "assistant", "text": String($0.text.prefix(500)),
                "sentAt": ISO8601DateFormatter().string(from: $0.date),
            ]
        }
    }
    func taskConversation(_ id: UUID?) -> [[String: Any]] {
        guard let id else { return [] }
        return messages.filter { $0.taskID == id && (activeRequest == nil || $0.requestID != activeRequest?.id) }
            .suffix(12).map {
                ["role": $0.isUser ? "user" : "assistant", "content": $0.text]
            }
    }
    func submitTaskRequest(_ text: String, taskID: UUID, messageID: UUID? = nil, prepared: PreparedRequest? = nil) {
        guard restoreHistoryTask(taskID, showCard: false) else {
            deliverReply(PipelineFailure.targetUnavailable.localizedDescription, kind: .needsInput, taskID: taskID)
            return
        }
        if busy {
            if ownsRequest(taskID), !requestIsStopping, let request = activeRequest {
                associateMessages(requestID: request.id, messageID: messageID, taskID: taskID)
                activeRequest?.submittedTaskID = taskID
                Diagnostics.record(
                    "request_merged",
                    ["requestID": request.id.uuidString, "taskID": taskID.uuidString, "stage": request.stage.rawValue])
                agent.steer(text, prepared: prepared)
                return
            }
            // Explicit card messages queue with their identity; they never steer a
            // different task just because its model happens to be running.
            guard queuedTaskRequests.count < 8 else {
                deliverReply(
                    "Several requests are waiting. Please try again shortly.", kind: .information, taskID: taskID)
                return
            }
            queuedTaskRequests.append(
                TaskUserRequest(taskID: taskID, text: text, messageID: messageID, prepared: prepared))
        } else {
            startCommand(text, taskID: taskID, receivedAt: Date(), messageID: messageID, prepared: prepared)
        }
    }
    /// Exact local controls use the conversation's owner, never the selected card.
    func localTaskControl(_ text: String, taskID: UUID) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let operation = [
                "暂停": "pause", "pause": "pause", "继续": "resume", "resume": "resume", "播放": "resume", "play": "resume",
                "停止": "stop", "stop": "stop", "重新开始": "restart", "重置": "restart", "reset": "restart",
            ][normalized],
            let task = sideTasks.first(where: { $0.id == taskID })
        else { return false }
        if task.taskSurface?.runtime != nil {
            if busy && ownsRequest(taskID) { cancel() }
            taskRuntime.control(taskID, operation: operation)
            return true
        }
        if task.kind == .timer {
            if operation == "pause", task.deadline != nil {
                timerAction(taskID, action: "toggle")
            } else if operation == "resume", task.deadline == nil {
                timerAction(taskID, action: "toggle")
            } else if ["stop", "restart"].contains(operation) {
                timerAction(taskID, action: operation)
            }
            return true
        }
        if task.isMediaTask, ["pause", "resume"].contains(operation),
            task.id == browser.id || parkedBrowsers[task.id] != nil
        {
            controlMedia(taskID, operation: operation == "resume" ? "play" : "pause")
            return true
        }
        return false
    }
}

extension AppModel {
    func userText(_ chinese: String, _ english: String) -> String {
        let text = activeRequest?.input ?? latestIntent
        return text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ? chinese : english
    }
    func routingContext(explicit: UUID?, excluding: UUID? = nil) -> [[String: Any]] {
        let known = Set(sideTasks.map(\.id) + archivedTaskHistory.map(\.id))
        let history = taskHistoryItems.filter {
            $0.id != excluding && known.contains($0.id) && (explicit == nil || $0.id == explicit)
        }
        let preferred = continuationPreference(in: sideTasks.filter { $0.id != excluding && $0.terminalLabel == nil })
        let defaults = JevRequestTriage.continuationDefaults(
            JevRequestTriage.candidates(self, explicit: nil, excluding: excluding), preferred: preferred)
        // Current activities must not disappear behind a longer list of closed conversations.
        let available = Set(sideTasks.filter { $0.terminalLabel == nil }.map(\.id))
        let items =
            (history.filter { available.contains($0.id) }
            + history.filter { !available.contains($0.id) }).prefix(16)
        return items.map { item in
            let task =
                sideTasks.first(where: { $0.id == item.id }) ?? archivedTaskHistory.first(where: { $0.id == item.id })
            let recent =
                (available.contains(item.id) || explicit == item.id ? messages.filter { $0.taskID == item.id } : [])
                .suffix(4).map {
                    ["role": $0.isUser ? "user" : "assistant", "text": String($0.text.prefix(500))]
                }
            return [
                "id": item.id.uuidString, "title": item.title, "kind": task?.kind.rawValue ?? "result",
                "status": task?.status ?? "Archived", "lifecycle": item.state, "terminal": task?.terminalLabel != nil,
                "availability": available.contains(item.id) ? "available" : "archived",
                "media": task?.isMediaTask ?? false, "playing": task?.playing ?? false,
                "preferred": item.id == preferred, "selected": item.id == selectedTaskID,
                "continuationDefault": defaults[item.id] == item.id,
                "continuationTargetID": defaults[item.id]?.uuidString ?? item.id.uuidString,
                "activity": task?.isMediaTask == true
                    ? "media playback" : task?.taskSurface?.apiData?.card?.kind.rawValue ?? "see intent",
                "lastConversationAt": ISO8601DateFormatter().string(from: item.updated), "recent": recent,
                "intent": String((task?.intent ?? "").prefix(240)),
            ]
        }
    }
    func routeGlobalMessage(_ text: String, messageID: UUID, draftID: UUID) {
        // A separate interpreter cannot cancel or corrupt the running executor's model call.
        guard globalRoutingTask == nil else {
            guard pendingRoutingRequests.count < 8 else {
                deliverReply(
                    "Several requests are waiting. Please try again shortly.", kind: .information, taskID: draftID)
                return
            }
            pendingRoutingRequests.append(TaskUserRequest(taskID: draftID, text: text, messageID: messageID))
            return
        }
        routingMessage = "Finding the right task…"
        globalRoutingTask = Task {
            defer {
                globalRoutingTask = nil
                routingMessage = ""
                if !pendingRoutingRequests.isEmpty {
                    let next = pendingRoutingRequests.removeFirst()
                    routeGlobalMessage(next.text, messageID: next.messageID!, draftID: next.taskID)
                }
            }
            do {
                let router = AgentController(model: self)
                #if DEBUG
                    router.interpretationOverride = agent.interpretationOverride
                    router.completionOverride = agent.completionOverride
                #endif
                let fast = await prepareFastRequest(text, explicit: nil)
                router.preparedRequest = fast
                var intent: RequestIntent
                var transfer: PreparedRequest
                if let advice = fast.triage,
                    advice.resolvesRouting(hasCandidates: !JevRequestTriage.candidates(self, explicit: nil).isEmpty)
                {
                    var routing = advice.directIntent() ?? RequestIntent(kind: .general)
                    routing.targetTaskID = advice.target?.uuidString
                    intent = routing
                    transfer = fast
                } else {
                    intent = try await router.understand(text, clarification: nil, key: nil, globalRouting: true)
                    transfer = PreparedRequest(text: text, intent: intent, triage: fast.triage, model: self)
                }
                try Task.checkCancellation()
                if let original = intent.targetTaskID.flatMap(UUID.init(uuidString:)) {
                    let current = resolvedTaskID(original)
                    intent.targetTaskID = current.uuidString
                    if current != original {
                        transfer = PreparedRequest(text: text, intent: intent, triage: nil, model: self)
                    }
                }
                if let question = intent.clarificationQuestion {
                    deliverReply(question, kind: .needsInput, taskID: draftID)
                    return
                }
                if let id = intent.targetTaskID.flatMap(UUID.init(uuidString:)), restoreHistoryTask(id, showCard: false)
                {
                    if intent.taskAction != .perform && !ownsRequest(id) {
                        let reply = try await endTask(id, action: intent.taskAction)
                        deliverReply(reply, taskID: id)
                        return
                    }
                    if intent.playbackIntent == "pause", intent.requirements.isEmpty, intent.initialURL == nil,
                        sideTasks.first(where: { $0.id == id })?.isMediaTask == true,
                        let source = liveBrowsers.first(where: { $0.id == id })
                    {
                        controlMedia(id, operation: "pause")
                        await source.applyPlaybackPolicy()
                        let state = try await source.observe()
                        guard state["playing"] as? Bool != true else {
                            throw AppError.message("Playback hasn't paused yet. Try the pause control.")
                        }
                        deliverReply(userText("已暂停。", "Paused."), taskID: id)
                        return
                    }
                    if busy && ownsRequest(id) {
                        if intent.taskAction != .perform {
                            // Queue the terminal command before stopping; the current writer must finish first.
                            queuedTaskRequests.insert(
                                TaskUserRequest(taskID: id, text: text, messageID: messageID, prepared: transfer), at: 0
                            )
                            cancel()
                        } else {
                            submitTaskRequest(text, taskID: id, messageID: messageID, prepared: transfer)
                        }
                    } else {
                        submitTaskRequest(text, taskID: id, messageID: messageID, prepared: transfer)
                    }
                } else if busy {
                    queueGlobalMessage(text, messageID: messageID, draftID: draftID, prepared: transfer)
                } else {
                    startCommand(text, messageID: messageID, prepared: transfer)
                }
            } catch { deliverReply(friendlyFailure(error), kind: .failure, taskID: draftID) }
        }
    }
    func recordProgress(_ text: String) {
        guard !text.isEmpty, let request = activeRequest else { return }
        let display = progressText(text)
        var entries = requestProgress[request.id] ?? []
        if entries.last != display { entries.append(display) }
        requestProgress[request.id] = Array(entries.suffix(6))
        if requestProgress.count > 40, let old = requestProgress.keys.first(where: { $0 != request.id }) {
            requestProgress[old] = nil
        }
    }
    func progressText(_ text: String) -> String {
        let labels = [
            "Thinking…": "Choosing the next step…", "Opening page…": "Opening the source…",
            "Reading page…": "Checking the latest content…", "Working on page…": "Updating the page…",
            "Building controls…": "Preparing controls…", "Updating your request…": "Got it — adjusting…",
        ]
        return labels[text] ?? text
    }
    var conversationProgress: [String] {
        guard let id = conversationTaskID else { return [] }
        let request =
            ownsRequest(id)
            ? activeRequest?.id : messages.last(where: { $0.taskID == id && $0.requestID != nil })?.requestID
        return request.flatMap { requestProgress[$0] } ?? []
    }
    func friendlyFailure(_ error: Error) -> String {
        if let error = error as? ToolArgumentError {
            return userText(
                "工具参数格式有误（" + error.path + "），未执行这一步。",
                "The tool arguments were invalid at " + error.path + ". This step was not executed.")
        }
        if error.localizedDescription.contains("Looping is unavailable") {
            return userText(
                "当前播放器暂不支持单曲循环，播放保持不变。",
                "This player doesn't currently support repeating this track. Playback is unchanged.")
        }
        if error as? PipelineFailure == .targetUnavailable {
            return userText(
                "没找到之前那个任务。告诉我想继续什么，我会重新接上。", "I couldn't find that task. Tell me what you'd like to pick up.")
        }
        if error as? PipelineFailure == .presentation {
            return "The source is still available. I couldn’t prepare its compact view."
        }
        if error is PipelineFailure { return "I couldn’t verify the result. Your source and work are saved." }
        if error is URLError {
            return userText(
                "连接暂时中断了，你的内容已保留。稍后可以重试。", "The connection dropped. Your work is saved, so you can try again shortly.")
        }
        return error.localizedDescription
    }
    func editTaskList() {
        taskListEditing = true
        taskShelfVisible = true
    }
    func endTask(_ id: UUID, action: RequestIntent.TaskAction) async throws -> String {
        guard let task = sideTasks.first(where: { $0.id == id }) else { throw PipelineFailure.targetUnavailable }
        if task.kind == .calendar && action == .cancel {
            return userText(
                "这个日程已经写入日历。结束这里的任务不会删除它，请在日历中取消。",
                "This event is already in Calendar. Closing this task won't delete it; cancel the event in Calendar.")
        }
        if let controller = liveBrowsers.first(where: { $0.id == id }) {
            controller.setUserPlaybackPaused(true, origin: "task_ended")
            await controller.applyPlaybackPolicy()
            let state = try await controller.observe()
            guard state["playing"] as? Bool != true else {
                throw AppError.message(userText("播放还没停下来，请再试一次。", "Playback hasn't stopped yet. Please try again."))
            }
        }
        stopTaskActions(id)
        taskRuntime.detach(id)
        taskRevisions.invalidate(id)
        adaptive.suspendAutomaticUpdates(id)
        queuedTaskRequests.removeAll { $0.taskID == id }
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        let cancelled = action == .cancel
        let label = cancelled ? "Cancelled" : "Finished"
        sideTasks[i].terminalLabel = task.title + " · " + label
        sideTasks[i].status = label
        sideTasks[i].deadline = nil
        sideTasks[i].playing = false
        sideTasks[i].finished = true
        sideTasks[i].hidden = false
        sideTasks[i].completedAt = Date()
        sideTasks[i].runtimeState?.phase = .stopped
        sideTasks[i].expires = Date().addingTimeInterval(10)
        persistSideTasks()
        refreshTaskClock()
        onResize?(windowSize)
        onShow?()
        return userText(
            "好的，" + task.title + (cancelled ? "已取消。" : "已结束。"), task.title + " is " + label.lowercased() + ".")
    }
}
