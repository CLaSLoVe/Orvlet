#if DEBUG
    import AppKit
    import SwiftUI

    @MainActor
    enum LocalDataCheck {
        static var windows: [NSWindow] = []
        static func run() async {
            let suite = "orvlet-local-data-check-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.settings.appearance = .light
            model.settings.reduceMotion = true
            var checks: [String] = []
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw AppError.message(name) }
                checks.append(name)
            }
            do {
                let plan = SurfacePlan(components: [], width: 300, height: 160, title: "Saved design")
                let first = SideTask(kind: .workspace, title: "Currency converter", plan: plan)
                let second = SideTask(kind: .timer, title: "Tea timer", pausedSeconds: 180, duration: 180)
                model.sideTasks = [first, second]
                model.adaptive.cache.put(plan, key: "https://example.com/card")
                model.interfaceMemory.remember(first, purpose: "Convert currency")
                defaults.set("retained preference", forKey: "unrelated")
                let templates = [
                    BuiltinCards.timer(finished: false).html, BuiltinCards.calendar(structured: true).html,
                ]
                let expected =
                    (defaults.data(forKey: "surfaces.v1")?.count ?? 0)
                    + (defaults.data(forKey: "interfaceRecipes.v1")?.count ?? 0)
                try check(
                    expected > 0 && model.storedBytes(for: .interfaces) == expected,
                    "Interface size includes both saved layouts and reusable recipes")
                let cleared = await model.clearLocalData(.interfaces)
                try check(
                    cleared && model.adaptive.cache.entries.isEmpty && model.interfaceMemory.storedBytes == 0,
                    "Clear removes both in-memory user cache stores")
                try check(
                    model.storedBytes(for: .interfaces) == 0 && SurfaceCache(defaults: defaults).entries.isEmpty
                        && InterfaceMemory(defaults: defaults).storedBytes == 0,
                    "Cleared user recipes and layouts remain empty after reload")
                try check(
                    templates == [
                        BuiltinCards.timer(finished: false).html, BuiltinCards.calendar(structured: true).html,
                    ] && BuiltinCards.categories.count == 6,
                    "Compiled built-in defaults remain available after clearing")
                try check(
                    model.sideTasks.count == 2 && model.sideTasks[1].pausedSeconds == 180
                        && defaults.string(forKey: "unrelated") == "retained preference",
                    "Clearing designs preserves open tasks, timer state and unrelated preferences")

                model.messages = [
                    ChatMessage(taskID: first.id, text: "Convert 100 USD to CNY", isUser: true),
                    ChatMessage(taskID: first.id, text: "Your converter is ready.", isUser: false),
                    ChatMessage(taskID: second.id, text: "A three-minute tea timer", isUser: true),
                ]
                defaults.set(try JSONEncoder().encode(model.messages), forKey: "conversation.v1")
                model.conversationDrafts = [first.id: "Use EUR", second.id: "Five minutes"]
                model.newTaskDraft = "Another task"
                model.conversationTaskID = first.id
                model.command = "Use EUR"
                model.busy = true
                try check(
                    !model.clearChatMessages(taskID: first.id) && model.messages.count == 3,
                    "In-flight messages cannot be cleared and reappear later")
                model.busy = false
                try check(
                    model.clearChatMessages(taskID: first.id) && model.messages.count == 1
                        && model.messages[0].taskID == second.id, "Task-scoped clear preserves the other conversation")
                try check(
                    model.command.isEmpty && model.conversationDrafts[first.id] == nil
                        && model.conversationDrafts[second.id] == "Five minutes"
                        && model.newTaskDraft == "Another task", "Task-scoped clear only removes its own draft")
                let restoredMessages = try JSONDecoder().decode(
                    [ChatMessage].self, from: defaults.data(forKey: "conversation.v1")!)
                try check(
                    restoredMessages.count == 1 && restoredMessages[0].taskID == second.id,
                    "Scoped deletion persists without restoring removed messages")
                try check(
                    model.clearChatMessages() && model.messages.isEmpty && model.conversationDrafts.isEmpty
                        && model.newTaskDraft.isEmpty && model.storedBytes(for: .conversations) == 0,
                    "Global clear removes all messages and drafts with zero saved bytes")
                try check(model.sideTasks.map(\.id) == [first.id, second.id], "Chat clearing retains task cards")

                model.sessions.put(SavedSession(url: "https://example.com", title: "Example"))
                model.history = [HistoryEntry(date: Date(), title: "Example", url: "https://example.com", kind: "page")]
                defaults.set(try JSONEncoder().encode(model.history), forKey: "history")
                try check(model.storedBytes(for: .pages) > 0, "Recent page size includes history and resume records")
                let clearedPages = await model.clearLocalData(.pages)
                try check(
                    clearedPages && model.sessions.entries.isEmpty && model.history.isEmpty
                        && model.storedBytes(for: .pages) == 0, "Recent-page clear removes both persistent stores")

                // Seed isolated preview data. No live user data is read or cleared.
                model.adaptive.cache.put(plan, key: "https://example.com/card")
                model.interfaceMemory.remember(first, purpose: "Convert currency")
                model.sessions.put(SavedSession(url: "https://example.com", title: "Example"))
                model.messages = [
                    ChatMessage(taskID: first.id, text: "Convert 100 USD to CNY", isUser: true),
                    ChatMessage(
                        taskID: first.id,
                        text: "Your converter is ready. You can change the amount or swap the currencies on the card.",
                        isUser: false),
                ]
                defaults.set(try JSONEncoder().encode(model.messages), forKey: "conversation.v1")
                let settings = window(
                    SettingsView(model: model, initialTab: 4), size: NSSize(width: 520, height: 710),
                    title: "Orvlet Settings")
                try await Task.sleep(for: .milliseconds(700))
                try await SideScreenCheck.snapshot(settings, path: "/tmp/orvlet-data-light.png")
                model.settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(300))
                try await SideScreenCheck.snapshot(settings, path: "/tmp/orvlet-data-dark.png")
                model.settings.appearance = .light
                model.conversationTaskID = first.id
                model.conversationHistoryVisible = true
                model.command = ""
                let command = window(
                    CommandPanelView(model: model).background(CalmVisualStyle.windowFill(.light)),
                    size: NSSize(width: 520, height: model.commandWindowHeight), title: "Orvlet Conversation")
                try await Task.sleep(for: .milliseconds(400))
                try await SideScreenCheck.snapshot(command, path: "/tmp/orvlet-data-command.png")
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: .prettyPrinted)
                    .write(to: URL(fileURLWithPath: "/tmp/orvlet-local-data-checks.json"))
                if !CommandLine.arguments.contains("--keep-open") { exit(0) }
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-local-data-checks.json"))
                if !CommandLine.arguments.contains("--keep-open") { exit(1) }
            }
        }
        static func window<V: View>(_ view: V, size: NSSize, title: String) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: 180, y: 160), size: size), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = title
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            return window
        }
    }
#endif
