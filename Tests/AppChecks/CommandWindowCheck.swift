#if DEBUG
    import AppKit

    @MainActor
    enum CommandWindowCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.appearance = .light
            model.settings.reduceMotion = true
            var checks: [String] = []
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw AppError.message(name) }
                checks.append(name)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(350)) }
            do {
                let timer = try model.startTimer(seconds: 600, title: "Tea")
                model.collapse()
                try await pause()
                let compact = delegate.panel.frame
                model.command = "A draft to keep"
                model.selectChat(true)
                try await pause()
                guard let input = delegate.commandPanel else { throw AppError.message("Input window missing") }
                let keyboardFocusVerified = input.isKeyWindow
                if NSApp.isActive {
                    try check(
                        keyboardFocusVerified,
                        "The independent input becomes the keyboard window when the app is active")
                }
                try check(
                    input !== delegate.panel && input.isVisible && delegate.panel.frame == compact
                        && !model.shellExpanded,
                    "Summoning uses a separate window and leaves the compact shell unchanged")
                let moved = NSPoint(x: input.frame.minX - 40, y: input.frame.minY - 20)
                input.setFrameOrigin(moved)
                model.selectChat(false, restoreFocus: false)
                try check(
                    !input.isVisible && delegate.panel.frame == compact, "Dismissing input hides only the input window")
                model.selectChat(true)
                try await pause()
                try check(
                    input.frame.origin == moved && model.command == "A draft to keep",
                    "Input keeps its own dragged position and draft when reopened")
                let oldTop = input.frame.maxY
                model.messages.append(
                    ChatMessage(text: String(repeating: "A longer reply. ", count: 25), isUser: false))
                delegate.resizeCommandPanel()
                try await pause()
                try check(
                    input.frame.maxY == oldTop && delegate.panel.frame == compact,
                    "Reply resizing holds the input top edge without moving the compact shell")
                model.selectChat(false, restoreFocus: false)
                model.selectTask(timer, expanded: true)
                try await pause()
                let detail = delegate.panel.frame
                model.selectChat(true)
                try await pause()
                try check(
                    !model.collapsed && delegate.panel.frame == detail && input.isVisible,
                    "Summoning input preserves already expanded task details")
                delegate.dismissDetails(at: NSPoint(x: input.frame.midX, y: input.frame.midY))
                try check(
                    input.isVisible && delegate.panel.frame == detail, "Clicking inside input leaves task details alone"
                )
                delegate.dismissDetails(at: NSPoint(x: delegate.panel.frame.midX, y: delegate.panel.frame.midY))
                try check(
                    !model.commandPanelVisible && !input.isVisible && !model.collapsed,
                    "Clicking the task window dismisses input while preserving details")
                model.collapse()
                model.selectChat(true)
                model.settings.main = Endpoint(baseURL: "http://127.0.0.1:19244", model: "fixture")
                model.agent.completionOverride = { _ in
                    try await Task.sleep(for: .milliseconds(700))
                    return ["role": "assistant", "content": "Background reply"]
                }
                model.command = "Help me think"
                model.sendCommand()
                try check(
                    !input.isVisible && model.busy && model.requestCardID != nil,
                    "Submission dismisses the independent input and continues in the compact preparing card")
                for _ in 0..<30 {
                    if !model.busy { break }
                    try await pause()
                }
                try check(
                    !input.isVisible && !model.commandPanelVisible && !model.shellExpanded && model.hasUnreadReply,
                    "Completion stays in the background without reopening either window")
                model.agent.completionOverride = nil
                model.selectChat(true)
                try await pause()
                try await SideScreenCheck.snapshot(input, path: "/tmp/orvlet-independent-command.png")
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-independent-compact.png")
                model.busy = true
                model.conversationHistoryVisible = true
                delegate.resizeCommandPanel()
                try await pause()
                try check(
                    model.commandWindowHeight >= 240 && input.frame.height >= 240,
                    "History remains readable while a request is running")
                try await SideScreenCheck.snapshot(input, path: "/tmp/orvlet-conversation-history.png")
                model.beginAmbientRequest("Play music", taskID: timer)
                model.openTaskConversation(timer)
                model.activity = "Finding your music…"
                model.command = "想听 dream funk"
                model.sendCommand()
                try await pause()
                try check(
                    input.isVisible && model.commandPanelVisible
                        && model.conversationActivity == .working(model.progressText("Updating your request…")),
                    "A follow-up keeps the conversation visible and immediately acknowledges steering")
                try await SideScreenCheck.snapshot(input, path: "/tmp/orvlet-conversation-working.png")
                model.activity = "Building controls…"
                try await pause()
                try check(
                    model.conversationActivity == .working(model.progressText("Building controls…")),
                    "Conversation reflects the live execution stage")
                let other = try model.startTimer(seconds: 300, title: "Other task")
                model.openTaskConversation(other)
                try check(
                    model.conversationActivity == nil, "Another conversation never borrows the active request status")
                model.openTaskConversation(timer)
                model.deliverReply("Playing Dream Funk.", taskID: timer)
                model.finishAmbientRequest()
                model.busy = false
                try await pause()
                try check(
                    model.conversationActivity == nil && model.visibleConversation.last?.text == "Playing Dream Funk.",
                    "Completion replaces the working indicator with the assistant reply")
                try await SideScreenCheck.snapshot(input, path: "/tmp/orvlet-conversation-complete.png")
                model.busy = false
                model.conversationHistoryVisible = false
                model.selectChat(false, restoreFocus: false)
                model.sideTasks.removeAll()
                let receipt = try model.startTimer(seconds: 60, title: "日历创建")
                model.latestIntent = "取消日历创建"
                _ = try await model.endTask(receipt, action: .cancel)
                try check(
                    model.sideTasks.first(where: { $0.id == receipt })?.status == "Cancelled"
                        && model.dragAppearance(receipt).closeLabel == "Release to close"
                        && model.progressText("Thinking…") == "Choosing the next step…",
                    "Chinese requests retain English receipt, drag and progress UI labels")
                model.collapse()
                try await pause()
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-terminal-compact.png")
                model.editTaskList()
                try await pause()
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-task-edit.png")
                model.taskShelfVisible = false
                let result: [String: Any] = [
                    "ok": true, "checks": checks, "keyboardFocusVerified": keyboardFocusVerified,
                ]
                try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-command-window-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-command-window-checks.json"))
                exit(1)
            }
        }
    }
#endif
