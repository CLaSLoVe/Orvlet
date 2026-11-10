#if DEBUG
    import AppKit

    @MainActor
    enum TaskHistoryCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.appearance = .light
            model.settings.reduceMotion = true
            model.archivedTaskHistory = []
            model.sideTasks = []
            model.messages = []
            var checks: [String] = []
            func check(_ condition: Bool, _ text: String) throws {
                guard condition else { throw AppError.message(text) }
                checks.append(text)
            }
            func settle() async throws {
                delegate.resizeCommandPanel()
                delegate.commandPanel?.resignKey()
                try await Task.sleep(for: .milliseconds(400))
            }
            let suite = "orvlet-history-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            do {
                let clock = SideTask(kind: .workspace, title: "Beijing clock")
                let music = SideTask(kind: .workspace, title: "Dream Funk")
                model.sideTasks = [clock, music]
                model.appendMessage("给个北京时间时钟", isUser: true, taskID: clock.id)
                model.appendMessage("北京时间正在持续更新。", isUser: false, taskID: clock.id)
                model.appendMessage("播放 dream funk", isUser: true, taskID: music.id)
                model.appendMessage("音乐已开始播放。", isUser: false, taskID: music.id)
                model.openTaskHistory()
                try await settle()
                try check(
                    model.visibleConversation.isEmpty && model.taskHistoryItems.count == 2,
                    "History opens a task index without interleaving messages")
                guard let panel = delegate.commandPanel else { throw AppError.message("History window missing") }
                try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-task-history-index.png")
                model.openTaskConversation(clock.id)
                model.command = "保留秒数"
                try await settle()
                try check(
                    model.visibleConversation.count == 2
                        && model.visibleConversation.allSatisfy { $0.taskID == clock.id },
                    "Opening a card shows only its own conversation")
                model.selectTask(music.id, expanded: false)
                try check(
                    model.conversationTaskID == clock.id,
                    "Selecting another card does not retarget the open conversation")
                model.openTaskConversation(music.id)
                model.command = "换一首"
                model.openTaskConversation(clock.id)
                try await settle()
                try check(model.command == "保留秒数", "Drafts remain with their own tasks")
                model.command = ""
                try await settle()
                try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-task-history-conversation.png")
                model.settings.appearance = .dark
                try await settle()
                try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-task-history-dark.png")
                model.settings.appearance = .light
                model.openTaskConversation(music.id)
                model.beginAmbientRequest("改成24小时制", taskID: clock.id)
                model.deliverReply("时钟已改成24小时制。")
                try check(
                    model.messages.last?.taskID == clock.id
                        && model.visibleConversation.allSatisfy { $0.taskID == music.id }
                        && model.feedback?.taskID == clock.id,
                    "A background reply keeps its owner while another conversation is open")
                model.finishAmbientRequest()
                model.dismissFeedback()
                model.dismissTask(clock.id)
                model.openTaskHistory()
                try check(
                    model.taskHistoryItems.first(where: { $0.id == clock.id })?.state == "Hidden",
                    "Hidden cards remain in task history")
                model.closeTask(clock.id)
                try check(
                    model.taskHistoryItems.first(where: { $0.id == clock.id })?.state == "Closed"
                        && model.messages.contains { $0.taskID == clock.id },
                    "Closing a card keeps its conversation and restorable state")
                defaults.set(try JSONEncoder().encode(model.archivedTaskHistory), forKey: "taskHistory.v1")
                defaults.set(try JSONEncoder().encode(model.messages), forKey: "conversation.v1")
                let restored = AppModel(defaults: defaults)
                restored.settings.autoAdapt = false
                restored.openTaskConversation(clock.id)
                try check(
                    restored.visibleConversation.count == 3 && restored.restoreHistoryTask(clock.id, showCard: false),
                    "A new model instance restores a closed task and its own conversation")
                restored.command = "Discard this task's draft"
                restored.deleteTaskHistory(clock.id)
                try check(
                    restored.conversationDrafts[clock.id] == nil, "Deleting the open task also discards its draft")
                let reread = AppModel(defaults: defaults)
                try check(
                    !reread.taskHistoryItems.contains { $0.id == clock.id }
                        && reread.messages.contains { $0.taskID == music.id },
                    "Deleting one task's history persists and leaves other conversations intact")
                let legacy = [
                    ChatMessage(text: "Old request A", isUser: true), ChatMessage(text: "Answer A", isUser: false),
                    ChatMessage(text: "Old request B", isUser: true), ChatMessage(text: "Answer B", isUser: false),
                ]
                defaults.set(try JSONEncoder().encode(legacy), forKey: "conversation.v1")
                let migrated = AppModel(defaults: defaults)
                try check(
                    Set(migrated.messages.compactMap(\.taskID)).count == 2
                        && migrated.messages[0].taskID == migrated.messages[1].taskID,
                    "Unattributed old requests migrate into separate conversations")
                model.busy = true
                model.beginAmbientRequest("Background music", taskID: music.id)
                model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
                model.selectChat(true)
                model.command = "Create an independent calculator"
                model.sendCommand()
                for _ in 0..<20 {
                    if model.globalRoutingTask == nil { break }
                    try await settle()
                }
                model.agent.interpretationOverride = nil
                try check(
                    model.queuedTaskRequests.last?.isNewTask == true
                        && model.queuedTaskRequests.last?.taskID != music.id
                        && model.activeRequest?.owner?.id == music.id,
                    "New tasks queue independently instead of steering another conversation")
                model.busy = false
                model.queuedTaskRequests = []
                model.finishAmbientRequest()
                let requestID = UUID()
                let failedID = UUID()
                let failedMessage = model.appendMessage("A request that fails", isUser: true, taskID: failedID)
                model.beginAmbientRequest("A request that fails", messageID: failedMessage)
                model.failAmbientRequest("Source unavailable")
                model.deliverReply("Source unavailable", kind: .failure)
                try check(
                    model.messages.last?.taskID == failedID && model.feedback?.taskID == failedID,
                    "A failed preparation keeps the request, error and card in one conversation")
                model.finishAmbientRequest()
                model.dismissFeedback()
                model.openTaskConversation(failedID)
                model.beginAmbientRequest("Retry the same task", taskID: failedID)
                model.adoptRequestTask(.workspace(requestID))
                try check(
                    model.conversationTaskID == requestID && model.messages.filter { $0.taskID == requestID }.count == 2
                        && !model.taskHistoryItems.contains { $0.id == failedID },
                    "Resolving a retried task transfers its entire conversation without leaving an orphan history entry"
                )
                model.finishAmbientRequest()
                let retainedID = UUID()
                let noisyID = UUID()
                model.messages =
                    [ChatMessage(taskID: retainedID, text: "Keep this other task", isUser: true)]
                    + (0..<510).map { ChatMessage(taskID: noisyID, text: "Message \($0)", isUser: true) }
                model.appendMessage("Newest", isUser: false, taskID: noisyID)
                try check(
                    model.messages.contains { $0.taskID == retainedID }
                        && model.messages.filter { $0.taskID == noisyID }.count == 500,
                    "One busy conversation cannot evict another task's history")
                model.messages = [
                    ChatMessage(taskID: music.id, text: "播放 dream funk", isUser: true),
                    ChatMessage(taskID: music.id, text: "音乐已开始播放。", isUser: false),
                    ChatMessage(taskID: clock.id, text: "给个北京时间时钟", isUser: true),
                ]
                model.openTaskHistory()
                try await settle()
                try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-task-history-closed.png")
                let runtimeID = UUID()
                let surface = TaskSurface(
                    title: "Elapsed",
                    markup: CardMarkup(
                        html: "<span data-bind='elapsed'></span>", compactHTML: "<span data-bind='elapsed'></span>",
                        css: ""), fields: [], actions: [], state: [:],
                    runtime: TaskRuntimeSpec(sources: [TaskDataSource(key: "elapsed", kind: .elapsed, format: .seconds)]
                    ))
                model.publishTaskSurface(try surface.validated(), id: runtimeID)
                try await model.taskRuntime.verify(runtimeID)
                model.closeTask(runtimeID)
                try check(model.restoreHistoryTask(runtimeID), "A closed running tool can be restored from History")
                try await model.taskRuntime.verify(runtimeID)
                try check(
                    model.sideTasks.first(where: { $0.id == runtimeID })?.runtimeState?.phase == .running,
                    "Restoring a running local tool resumes its data engine")
                model.openTaskConversation(runtimeID)
                model.selectedTaskID = music.id
                model.command = "暂停"
                model.sendCommand()
                try check(
                    model.sideTasks.first(where: { $0.id == runtimeID })?.runtimeState?.phase == .paused
                        && model.messages.last?.taskID == runtimeID,
                    "A local control in a task conversation targets that task even when another card is selected")
                model.closeTask(runtimeID)
                _ = model.restoreHistoryTask(runtimeID)
                try check(
                    model.sideTasks.first(where: { $0.id == runtimeID })?.runtimeState?.phase == .paused,
                    "A tool paused before closing stays paused when restored")
                model.closeTask(runtimeID)
                model.openTaskConversation(runtimeID)
                model.command = "继续"
                model.sendCommand()
                try check(
                    model.sideTasks.first(where: { $0.id == runtimeID })?.runtimeState?.phase == .running
                        && model.visibleConversation.contains { $0.text == "暂停" }
                        && model.visibleConversation.last?.text == "继续",
                    "Continuing a removed task restores it from history with its messages and local controls intact")
                let result: [String: Any] = ["ok": true, "checks": checks]
                try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-task-history-checks.json"))
                model.taskRuntime.stopAll()
                if CommandLine.arguments.contains("--keep-open") {
                    model.selectChat(false)
                    model.pinned = true
                    model.taskShelfVisible = true
                    model.onShow?()
                    return
                }
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-task-history-checks.json"))
                exit(1)
            }
        }
    }
#endif
