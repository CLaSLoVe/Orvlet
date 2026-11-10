import SwiftUI
import WebKit

@MainActor
extension AppModel {
    func sendCommand() {
        guard isLiveTest || mainServiceState != "checking" else { return }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let editing = editingInterfaceID ?? conversationTaskID
        requestReceivedAt = Date()
        command = ""
        backgroundRequest = true
        hasUnreadReply = false
        dismissFeedback()
        if commandPanelVisible && conversationTaskID == nil { selectChat(false) }
        let draftID = editing ?? UUID()
        let messageID = appendMessage(text, isUser: true, taskID: draftID)
        if let editing {
            if restoreHistoryTask(editing, showCard: false), localTaskControl(text, taskID: editing) { return }
            submitTaskRequest(text, taskID: editing, messageID: messageID)
            return
        }
        if ["设置", "settings", "隐藏", "hide", "展开", "expand", "收起", "collapse"].contains(text.lowercased()),
            localCommand(text)
        {
            return
        }
        latestIntent = text
        taskFailed = false
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
        _ text: String, taskID: UUID? = nil, receivedAt: Date? = nil, messageID: UUID? = nil,
        prepared: PreparedRequest? = nil
    ) {
        if let receivedAt { requestReceivedAt = receivedAt }
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
        adaptive.invalidate()
        adaptive.blockedSources.remove(taskID ?? browser.id)
        latestIntent = text
        taskFailed = false
        agent.operatedPage = false
        busy = true
        agentStopping = false
        activity = "On it…"
        beginAmbientRequest(text, taskID: taskID, messageID: messageID)
        agentTask = Task {
            defer {
                if taskFailed, let page = requestPageID { adaptive.suspendAutomaticUpdates(page) }
                finishAmbientRequest()
                busy = false
                activity = ""
                agentStopping = false
                agentTask = nil
                if !messagesAfterStop.isEmpty {
                    let next = messagesAfterStop.joined(separator: "\n")
                    messagesAfterStop.removeAll()
                    latestIntent = next
                    taskFailed = false
                    startCommand(next)
                } else if !queuedTaskRequests.isEmpty {
                    let next = queuedTaskRequests.removeFirst()
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
                if !isLiveTest {
                    let jevKey = try? await SecretStore.loadAvailable(settings.fastKeyAccount)
                    guard settings.fast.isConfigured, jevKey?.isEmpty == false else {
                        fastServiceState = "unconfigured"
                        onSetupModels?()
                        throw AppError.message(
                            userText(
                                "请先在 Models 中配置 Jev。这个请求已保留。",
                                "Configure Jev in Models to continue. Your request is saved."))
                    }
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
                        failAmbientRequest(error.localizedDescription)
                        deliverReply(friendlyFailure(error), kind: .failure)
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
            if busy && ownsRequest(task.id) { cancel() }
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
