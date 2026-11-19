import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func sendCommand(forceNewTask: Bool = false) {
        guard isLiveTest || mainServiceState != "checking" else { return }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let editing = forceNewTask ? nil : (editingInterfaceID ?? conversationTaskID)
        command = ""
        backgroundRequest = true
        hasUnreadReply = false
        dismissFeedback()
        if commandPanelVisible && (forceNewTask || conversationTaskID == nil) { selectChat(false) }
        // A completed card supplies conversation context. Start with a provisional
        // destination until placement decides whether this message edits that card.
        let reference = editing.flatMap { id in
            sideTasks.first { $0.id == id && $0.kind != .result && $0.terminalLabel == nil }?.id
        }
        let draftID = reference == nil ? (editing ?? UUID()) : UUID()
        let messageID = appendMessage(text, isUser: true, taskID: draftID)
        if forceNewTask {
            startCommand(text, messageID: messageID, forceNewTask: true)
            return
        }
        if let reference {
            startCommand(text, messageID: messageID, conversationReference: reference)
            return
        }
        if let editing {
            submitTaskRequest(text, taskID: editing, messageID: messageID)
            return
        }
        if ["设置", "settings", "隐藏", "hide", "展开", "expand", "收起", "collapse"].contains(text.lowercased()),
            localCommand(text)
        {
            return
        }
        if busy {
            routeGlobalMessage(text, messageID: messageID, draftID: draftID)
            return
        }
        startCommand(text, messageID: messageID)
    }
    func queueGlobalMessage(_ text: String, messageID: UUID, draftID: UUID, prepared: PreparedRequest? = nil) {
        guard queuedTaskRequests.count < 8 else {
            deliverReply("Several requests are waiting. Please try again shortly.", kind: .information, taskID: draftID)
            return
        }
        var draft = SideTask(id: draftID, kind: .result, title: String(text.prefix(80)))
        draft.status = "Queued"
        draft.intent = text
        sideTasks.append(draft)
        queuedTaskRequests.append(
            TaskUserRequest(taskID: draftID, text: text, messageID: messageID, isNewTask: true, prepared: prepared))
        persistSideTasks()
    }
    func startCommand(
        _ text: String, taskID submittedTaskID: UUID? = nil, receivedAt: Date? = nil, messageID: UUID? = nil,
        prepared: PreparedRequest? = nil, forceNewTask: Bool = false, assignment: CardAssignment? = nil, initialFamilies: Set<String> = [], conversationReference: UUID? = nil
    ) {
        // A queued inferred route is not a user selection. Re-resolve stale
        // packets before adopting/restoring an owner; valid routes execute directly.
        let taskID =
            (prepared.map { !$0.explicitSelection && !$0.usable(text: text, explicit: submittedTaskID, model: self) }
                ?? false)
            ? nil : submittedTaskID
        if !isLiveTest, mainServiceState == "unavailable" {
            checkModelConnections()
            selectChat(true, conversation: taskID)
            command = text
            return
        }
        if let taskID, !restoreHistoryTask(taskID, showCard: false) {
            deliverReply(PipelineFailure.targetUnavailable.localizedDescription, kind: .needsInput, taskID: taskID)
            return
        }
        guard settings.main.isConfigured else {
            deliverReply(
                "Connect a model in Settings to start.", kind: .needsInput,
                taskID: messageID.flatMap { mid in messages.first(where: { $0.id == mid })?.taskID })
            return
        }
        let run = RequestRun(model: self, forceNewTask: forceNewTask)
        run.initialFamilies = initialFamilies
        run.conversationReference = conversationReference
        run.assignment = assignment
        run.receivedAt = receivedAt ?? messageID.flatMap { id in messages.first { $0.id == id }?.date } ?? Date()
        #if DEBUG
            run.agent.interpretationOverride = agent.interpretationOverride
            run.agent.completionOverride = agent.completionOverride
        #endif
        commandRuns.append(run)
        RequestRun.$current.withValue(run) {
            launchCommand(text, taskID: taskID, messageID: messageID, prepared: prepared, run: run)
        }
    }

    private func launchCommand(_ text: String, taskID: UUID?, messageID: UUID?, prepared: PreparedRequest?, run: RequestRun) {
        adaptive.invalidate()
        adaptive.blockedSources.remove(taskID ?? browser.id)
        latestIntent = text
        taskFailed = false
        agent.operatedPage = false
        refreshHover()
        agentStopping = false
        activity = "On it…"
        beginAmbientRequest(text, taskID: taskID, messageID: messageID)
        agentTask = Task {
            defer {
                if taskFailed, let page = requestPageID { adaptive.suspendAutomaticUpdates(page) }
                finishAmbientRequest()
                if browserRun === run { browserRun = nil }
                commandRuns.removeAll { $0 === run }
                if commandRuns.isEmpty { idleRun = run; taskRanking.schedule() }
                refreshHover()
                run.activity = ""
                agentStopping = false
                agentTask = nil
                if !messagesAfterStop.isEmpty {
                    let next = messagesAfterStop.joined(separator: "\n")
                    messagesAfterStop.removeAll()
                    latestIntent = next
                    taskFailed = false
                    startCommand(next)
                } else if let index = queuedTaskRequests.firstIndex(where: { runOwning($0.taskID) == nil }) {
                    let next = queuedTaskRequests.remove(at: index)
                    startCommand(
                        next.text, taskID: next.isNewTask ? nil : next.taskID, receivedAt: next.receivedAt,
                        messageID: next.messageID, prepared: next.prepared)
                } else if agent.operatedPage && !taskFailed {
                    adaptive.changed()
                }
            }
            do {
                if let checking = connectionCheckTask {
                    await checking.value
                    try Task.checkCancellation()
                }
                let reply = try await agent.run(text, receivedAt: requestReceivedAt, taskID: taskID, prepared: prepared)
                if !Task.isCancelled, !reply.isEmpty { deliverReply(reply, kind: agent.replyKind) }
            } catch is CancellationError { taskFailed = true } catch {
                taskFailed = true
                if !Task.isCancelled {
                    if error is ModelAccessError {
                        agent.replyKind = .authorization
                        reportModelAccessIssue(error)
                    } else {
                        let message = friendlyFailure(error)
                        failAmbientRequest(message)
                        deliverReply(message, kind: .failure)
                    }
                }
            }
        }
    }
    func localCommand(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = selectedSideTask, task.taskSurface?.runtime != nil,
            let operation = [
                "暂停": "pause", "pause": "pause", "继续": "resume", "resume": "resume", "停止": "stop", "stop": "stop",
                "重新开始": "restart", "重置": "restart", "reset": "restart",
            ][normalized]
        {
            if busy && ownsRequest(task.id) { stopCommand(for: task.id) }
            taskRuntime.control(task.id, operation: operation)
            if let index = messages.indices.last { messages[index].taskID = task.id }
            return true
        }
        if let seconds = Self.timerSeconds(text) {
            do {
                let id = try startTimer(seconds: seconds, receivedAt: requestReceivedAt)
                if let index = messages.indices.last { messages[index].taskID = id }
                deliverReply("Timer started.", taskID: id)
            } catch { deliverReply(error.localizedDescription, kind: .failure, taskID: messages.last?.taskID) }
            return true
        }
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "收起", "变小", "collapse":
            collapse()
            return true
        case "隐藏", "hide":
            hide()
            return true
        case "展开", "expand":
            reveal()
            return true
        case "设置", "settings":
            onSettings?()
            return true
        case "暂停", "pause": return selectedMediaCommand("pause")
        case "播放", "继续", "play": return selectedMediaCommand("play")
        case "下一首", "切歌", "next": return selectedMediaCommand("next")
        case "上一首", "previous": return selectedMediaCommand("previous")
        default:
            if text.hasPrefix("https://") || text.hasPrefix("http://") {
                openURL(text, background: backgroundRequest)
                if let index = messages.indices.last { messages[index].taskID = browser.id }
                return true
            }
            return false
        }
    }
    func cancel() {
        guard busy else { return }
        agentStopping = true
        messagesAfterStop.removeAll()
        agent.stop()
        agentTask?.cancel()
        activity = "Stopping…"
    }
}
