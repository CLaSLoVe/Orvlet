#if DEBUG
    import AppKit
    import SwiftUI

    @MainActor
    enum PlaybackActivityCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ condition: Bool, _ label: String) throws {
                try StateMachineCheck.require(condition, label, &checks)
            }
            let suite = "orvlet-playback-activity-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.settings.reduceMotion = true
            let browser = model.browser
            let id = browser.id
            browser.setUserPlaybackPaused(true)
            defer { browser.dispose() }
            let url = "https://www.youtube.com/watch?v=jfKfPfyJRdk"
            var task = SideTask(id: id, kind: .web, title: "lofi hip hop radio 📚 beats to relax/study to")
            task.sourceURL = url
            task.status = "Paused"
            task.listening = true
            task.hasMedia = true
            task.prefersSource = false
            task.musicQueue = MusicQueue()
            let other = SideTask(kind: .result, title: "Unfinished request", status: "Task failed")
            model.sideTasks = [task, other]
            model.recordTaskOutcome(id, .succeeded)
            for playing in [false, true] {
                model.sideTasks[0].playing = playing
                model.sideTasks[0].status = playing ? "Playing" : "Paused"
                try check(model.taskActivity(model.sideTasks[0]) == nil,
                    "A completed music request keeps the player's \(model.sideTasks[0].status) state and control visible")
            }
            model.sideTasks[0] = task
            model.recordTaskOutcome(other.id, .succeeded)
            try check(model.taskActivity(other) == .succeeded,
                "Non-media tasks still show their completion receipt")
            let failureMessage = model.appendMessage("The previous request was incomplete.", isUser: false, taskID: id)
            let page: [String: Any] = [
                "url": url, "title": task.title, "channel": "Lofi Girl", "hasMedia": true,
                "playing": false, "live": true, "mediaPrimary": true, "readyState": 4,
            ]
            model.recordTaskOutcome(id, .failed)
            model.recordTaskOutcome(other.id, .failed)
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivityReceipts[id] == nil && model.taskActivity(model.sideTasks[0]) == nil,
                "A verified paused player clears an obsolete request failure without requiring playback")
            try check(
                model.messages.contains { $0.id == failureMessage } && !model.sideTasks[0].playing,
                "Clearing a stale badge preserves conversation evidence and never starts playback")
            try check(
                model.taskActivity(model.sideTasks[1]) == .failed,
                "Recovering one player cannot clear another task's failure")
            model.sideTasks[0].status = "Task failed"
            model.receiveMusicState(id, data: page)
            try check(
                model.sideTasks[0].status == "Paused", "Live recovery also clears a persisted obsolete failure label")

            model.recordTaskOutcome(id, .failed)
            model.receiveMusicState(id, data: page.merging(["adPlaying": true]) { _, new in new })
            try check(
                model.taskActivityReceipts[id]?.activity == .failed, "An advertisement cannot certify music recovery")
            model.receiveMusicState(
                id, data: page.merging(["url": "https://example.org/another-page"]) { _, new in new })
            try check(
                model.taskActivityReceipts[id]?.activity == .failed, "Another page cannot clear this player's failure")
            model.musicErrors[id] = "Source cannot play"
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivity(model.sideTasks[0]) == .failed && model.musicErrors[id] != nil,
                "A current playback error remains visible despite retained media metadata")
            model.musicErrors[id] = nil
            model.sideTasks[0].dataIssue = "Source unavailable"
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivity(model.sideTasks[0]) == .stale && model.taskActivityReceipts[id] != nil,
                "Unavailable live readings are not erased by media readiness")
            model.sideTasks[0].dataIssue = AppModel.missingPageReadingsIssue
            model.sideTasks[0].plan = .webpage
            model.updateLiveReadings(id, data: ["ok": true])
            try check(model.sideTasks[0].dataIssue != nil, "A control acknowledgement is not evidence of source recovery")
            model.updateLiveReadings(id, data: page.merging(["url": "https://example.org/another-page"]) { _, new in new })
            try check(model.sideTasks[0].dataIssue != nil, "Another page cannot retire this card's reading error")
            model.updateLiveReadings(id, data: page)
            model.receiveMusicState(id, data: page)
            try check(model.sideTasks[0].dataIssue == nil && model.taskActivity(model.sideTasks[0]) == nil,
                "Removing obsolete DOM bindings clears their persisted update warning on a healthy native player")
            model.sideTasks[0].plan?.readings = [CardReading(key: "track", selector: "#track")]
            let missing = page.merging(["readings": [String: String]()]) { _, new in new }
            model.updateLiveReadings(id, data: missing)
            try check(model.messages.last?.issueSource == "readings" && model.messages.last?.text.contains("track") == true,
                "A live-reading failure identifies the unavailable field in chat")
            model.receiveMusicState(id, data: missing)
            try check(model.taskActivity(model.sideTasks[0]) == .stale,
                "A still-bound missing reading remains visible even while its player works")
            let healthy = page.merging(["readings": ["track": "Track title"]]) { _, new in new }
            model.updateLiveReadings(id, data: healthy)
            try check(model.sideTasks[0].dataIssue == nil && model.sideTasks[0].liveValues?["track"] == "Track title",
                "A recovered bound reading clears its own warning and refreshes the displayed value")
            model.sideTasks[0].dataIssue = "Browser disconnected"
            model.updateLiveReadings(id, data: healthy)
            try check(model.sideTasks[0].dataIssue == "Browser disconnected",
                "Successful DOM readings cannot erase a browser connection failure")
            model.sideTasks[0].plan?.readings = []
            model.updateLiveReadings(id, data: healthy)
            try check(model.sideTasks[0].dataIssue == "Browser disconnected",
                "Dropping DOM bindings cannot erase unrelated source errors")
            model.sideTasks[0].dataIssue = nil
            var raisedWindows = 0
            model.onShow = { raisedWindows += 1 }
            let beforeIssues = model.messages.count
            for _ in 0..<4 { model.reportTaskIssue(id, source: .browser, detail: "HTTP 503. The page service is unavailable.") }
            try check(model.messages.count == beforeIssues + 1 && model.messages.last?.taskID == id
                && model.messages.last?.text.contains("HTTP 503") == true,
                "Repeated source failures create one detailed message in the owning task chat")
            try check(raisedWindows == 0 && model.feedback == nil,
                "Background error reporting neither opens a window nor creates an interrupting popup")
            model.messages = try JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(model.messages))
            model.reportTaskIssue(id, source: .browser, detail: "HTTP 503. The page service is unavailable.")
            try check(model.messages.count == beforeIssues + 1, "Error deduplication survives conversation persistence")
            model.resolveTaskIssue(id, source: .browser)
            try check(model.messages.last?.issueResolved == true && model.messages.last?.text.contains("HTTP 503") == true,
                "Recovery preserves the detailed chat record while ending the current incident")
            model.reportTaskIssue(id, source: .browser, detail: "HTTP 503. The page service is unavailable.")
            try check(model.messages.count == beforeIssues + 2, "A failure after recovery is recorded as a new incident")
            model.reportTaskIssue(other.id, source: .browser, detail: "HTTP 503. The page service is unavailable.")
            model.resolveTaskIssue(id, source: .browser)
            try check(model.messages.last?.taskID == other.id && model.messages.last?.issueResolved != true,
                "Resolving one task does not alter another task's failure history")
            model.onShow = nil
            let resourceA = model.work.retain(title: "First source", values: ["value": "1"], definition: WorkDefinition(), design: WorkDesign(), goalID: nil)
            let resourceB = model.work.retain(title: "Second source", values: ["value": "2"], definition: WorkDefinition(), design: WorkDesign(), goalID: nil)
            let combined = UUID()
            try model.work.putView(WorkView(id: combined, artifacts: [resourceA, resourceB], selected: resourceA, layout: .together, title: "Comparison"))
            model.reportTaskIssue(resourceA, source: .data, detail: "HTTP 503")
            model.reportTaskIssue(resourceB, source: .data, detail: "HTTP 503")
            model.resolveTaskIssue(resourceA, source: .data)
            let combinedMessages = model.messages.filter { $0.taskID == combined }
            try check(combinedMessages.count == 2 && combinedMessages.first?.issueResolved == true
                && combinedMessages.last?.issueResolved != true,
                "Multiple sources in one card retain independent error incidents and recovery")
            model.work.removeView(combined)
            model.busy = true
            model.beginAmbientRequest("Change the music", taskID: id)
            model.recordTaskOutcome(id, .failed)
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivityReceipts[id]?.activity == .failed
                    && model.taskActivity(model.sideTasks[0])?.isWorking == true,
                "An active request retains ownership until its outcome is known")
            model.activeRequest = nil
            model.busy = false
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivityReceipts[id] == nil,
                "The first healthy observation after request completion removes the stale failure")

            model.recordTaskOutcome(id, .interfaceFailed)
            model.receiveMusicState(id, data: page)
            try check(
                model.taskActivityReceipts[id]?.activity == .interfaceFailed,
                "Playback recovery does not claim to repair a separate view failure")
            model.taskActivityReceipts[id] = TaskActivityReceipt(
                activity: .failed, created: Date().addingTimeInterval(-9))
            try check(
                model.taskActivity(model.sideTasks[0]) == nil,
                "An old request failure cannot become a permanent badge on a usable card")
            model.taskActivityReceipts[other.id] = TaskActivityReceipt(activity: .failed, created: .distantPast)
            try check(
                model.taskActivity(model.sideTasks[1]) == .failed,
                "A genuinely failed placeholder remains identifiable after its transient receipt expires")
            model.taskActivityReceipts[id] = TaskActivityReceipt(activity: .needsInput, created: .distantPast)
            try check(
                model.taskActivity(model.sideTasks[0]) == .needsInput, "An unanswered clarification remains available")

            // Exercise the real direct-control path against a held local player; no sound or external source is opened.
            _ = try await browser.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
            // Changing hosts clears listening intent; explicitly opt this local fixture into music controls.
            if let index = model.sideTasks.firstIndex(where: { $0.id == id }) {
                model.sideTasks[index].listening = true
            }
            model.recordTaskOutcome(id, .failed)
            model.musicErrors[id] = "Earlier control failed"
            model.sideTasks[0].plan = .webpage
            model.sideTasks[0].dataIssue = AppModel.missingPageReadingsIssue
            try await model.performMusicControl(id, operation: "pause")
            try check(
                model.taskActivityReceipts[id] == nil && model.musicErrors[id] == nil && !model.isPlaying
                    && model.sideTasks[0].dataIssue == nil,
                "A verified native pause clears old control errors and request badges together")
            browser.dispose()
            model.sideTasks = [task]
            model.musicPlayback[id] = MusicPlayback(page)
            model.selectedTaskID = id
            model.collapsed = false
            model.clickExpanded = true
            model.webExpanded = false
            model.taskShelfVisible = false
            model.recordTaskOutcome(id, .succeeded)
            model.settings.compactLayout = .vertical
            let detailSize = model.windowSize
            let compactSize = model.compactSize
            model.shellLayout = ShellLayout(
                frame: NSRect(x: 0, y: 0, width: detailSize.width + compactSize.width, height: detailSize.height),
                compact: NSRect(x: detailSize.width, y: detailSize.height - compactSize.height,
                    width: compactSize.width, height: compactSize.height),
                content: NSRect(origin: .zero, size: detailSize), edge: .left)
            try check(
                model.selectedSideTask?.id == id && model.ambientTasks.contains { $0.id == id }
                    && model.shellLayout.localVisibleContent.width == detailSize.width,
                "Recovery snapshots include the expanded player and its compact task row")
            for dark in [false, true] {
                model.settings.appearance = dark ? .dark : .light
                let size = model.shellLayout.frame.size
                let view = NSHostingView(
                    rootView: ContentView(model: model).frame(width: size.width, height: size.height))
                let window = NSPanel(
                    contentRect: NSRect(x: -16000, y: -16000, width: size.width, height: size.height),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderBack(nil)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                try await SideScreenCheck.snapshot(
                    window, path: "/tmp/orvlet-playback-recovered-\(dark ? "dark" : "light").png")
                window.orderOut(nil)
            }
            model.taskShelfVisible = true
            model.settings.appearance = .light
            model.sideTasks[0].playing = true
            model.sideTasks[0].status = "Playing"
            model.musicPlayback[id] = MusicPlayback(page.merging(["playing": true]) { _, new in new })
            model.recordTaskOutcome(id, .succeeded)
            let shelfSize = model.shellContentSize!
            let size = NSSize(width: shelfSize.width + compactSize.width,
                              height: max(shelfSize.height, compactSize.height))
            model.shellLayout = ShellLayout(frame: NSRect(origin: .zero, size: size),
                compact: NSRect(x: shelfSize.width, y: size.height - compactSize.height,
                                width: compactSize.width, height: compactSize.height),
                content: NSRect(x: 0, y: size.height - shelfSize.height,
                                width: shelfSize.width, height: shelfSize.height), edge: .left)
            let shelf = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
            let shelfPanel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -16000, y: -16000), size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            shelfPanel.appearance = NSAppearance(named: .aqua)
            shelfPanel.contentView = shelf
            shelfPanel.orderBack(nil)
            shelf.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            try await SideScreenCheck.snapshot(shelfPanel, path: "/tmp/orvlet-playback-task-shelf.png")
            shelfPanel.orderOut(nil)
            model.taskShelfVisible = false
            model.conversationTaskID = id
            let chat = NSHostingView(rootView: TaskConversationHistoryView(model: model).frame(width: 440, height: 350)
                .background(CalmVisualStyle.windowFill(.light)).preferredColorScheme(.light))
            let chatPanel = NSPanel(contentRect: NSRect(x: -18000, y: -18000, width: 440, height: 350),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            chatPanel.contentView = chat
            chatPanel.orderBack(nil)
            chat.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            try await SideScreenCheck.snapshot(chatPanel, path: "/tmp/orvlet-error-conversation.png")
            chatPanel.orderOut(nil)
            try check(model.visibleConversation.contains { $0.issueSource == "browser" && $0.text.contains("HTTP 503") }
                && model.visibleConversation.allSatisfy { $0.taskID == id },
                "The actual chat view renders the task's concrete error details without unrelated messages")
            checks.append("Recovered music header and collapsed card render without failure badges in both appearances")
            return checks
        }
    }
#endif
