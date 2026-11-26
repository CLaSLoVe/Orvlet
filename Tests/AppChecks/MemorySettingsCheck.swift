#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum MemorySettingsCheck {
    static func run() async throws -> [String] {
        let suite = "orvlet-memory-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.settings.reduceMotion = true
        model.settings.appearance = .light
        let first = SideTask(kind: .workspace, title: "Weekly export")
        let other = SideTask(kind: .workspace, title: "Reading list")
        model.sideTasks = [first, other]
        let source = ChatMessage(taskID: first.id, text: "Export prices in Hong Kong dollars.", isUser: true)
        let second = ChatMessage(taskID: other.id, text: "Read my saved articles.", isUser: true)
        model.messages = [source, second]
        var ledger = TaskMemoryLedger()
        ledger.facts = [TaskMemoryFact(topic: "Currency", quote: source.text, kind: .constraint,
                                       sources: [source.id], updated: source.date)]
        var checks: [String] = []
        func require(_ value: Bool, _ label: String) throws {
            try StateMachineCheck.require(value, label, &checks)
        }
        try require(model.memoryDB.write(ledger, scope: "task", key: first.id.uuidString), "Settings fixture saved a task requirement")
        let site = "https://example.org/api/favorites"
        model.siteMemory.recordAPI(url: site, status: 403, taskID: other.id)
        guard let fact = model.taskMemoryItems.first, let entry = model.siteMemoryItems.first else {
            throw AppError.message("Settings fixture missing task memory or website experience")
        }
        let panel = NSPanel(contentRect: NSRect(x: -16000, y: -16000, width: 520, height: 710),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.orderOut(nil) }
        let focus = BackgroundFocusCheck()
        let view = NSHostingView(rootView: SettingsView(model: model, initialTab: 4))
        panel.contentView = view
        panel.orderBack(nil)
        func press(_ identifier: String) async throws {
            for _ in 0..<20 {
                view.layoutSubtreeIfNeeded()
                if let button = accessibleElement(identifier, in: view),
                   button.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
                   !frame.isEmpty {
                    let point = panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                    guard view.bounds.contains(view.convert(point, from: nil)) else {
                        throw AppError.message("Settings control fell outside the viewport: " + identifier + " " + NSStringFromRect(frame))
                    }
                    let uptime = ProcessInfo.processInfo.systemUptime
                    func event(_ type: NSEvent.EventType) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: uptime,
                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                            pressure: type == .leftMouseDown ? 1 : 0)!
                    }
                    // AppKit buttons can track synchronously inside mouseDown. Keep both events local to this panel.
                    NSApp.postEvent(event(.leftMouseUp), atStart: true)
                    panel.sendEvent(event(.leftMouseDown))
                    try await Task.sleep(for: .milliseconds(200))
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw AppError.message("Settings control missing: " + identifier)
        }
        try await press("review-saved-memory")
        try require(accessibleElement("forget-" + entry.id, in: view) != nil,
                    "Settings displays a separate control for the website observation")
        for appearance in [AppAppearance.light, .dark] {
            model.settings.appearance = appearance
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-saved-memory-" + appearance.rawValue + ".png")
        }
        try await press("forget-" + fact.id)
        try require(model.taskMemoryItems.count == 1, "Selecting Forget leaves the fact available until confirmation")
        try await press("confirm-forget-" + fact.id)
        try require(model.taskMemoryItems.isEmpty && model.siteMemoryItems.count == 1,
                    "Confirming Forget removes the selected fact and preserves the site observation")
        panel.orderOut(nil)
        try require(!focus.tookFocus, "Reviewing and forgetting memory in the offscreen settings preserves desktop focus")

        _ = model.memoryDB.write(ledger, scope: "task", key: first.id.uuidString)
        model.siteMemory.recordAPI(url: "https://reading.example/api/favorites", status: 401, taskID: first.id)
        try require(model.clearChatMessages(taskID: first.id) && model.taskMemoryItems.isEmpty
                    && model.siteMemoryItems.map(\.id) == [entry.id] && model.messages.map(\.id) == [second.id],
                    "Clearing one task removes its facts and site contributions, preserving another conversation")
        let clearedPages = await model.clearLocalData(.pages)
        try require(clearedPages && model.siteMemoryItems.isEmpty && model.messages.map(\.id) == [second.id],
                    "Clearing recent pages forgets site observations and retains conversation text")
        defaults.set(try JSONEncoder().encode([source, second]), forKey: "conversation.v1")
        defaults.set([first.id.uuidString: true], forKey: "pendingConversationClear.v1")
        let reopened = AppModel(defaults: defaults)
        try require(reopened.messages.map(\.id) == [second.id] && defaults.object(forKey: "pendingConversationClear.v1") == nil,
                    "Restart completes an interrupted task clear before the next conversation")
        defaults.set(try JSONEncoder().encode([source, second]), forKey: "conversation.v1")
        defaults.set([first.id.uuidString: false], forKey: "pendingConversationClear.v1")
        let memoryOnly = AppModel(defaults: defaults)
        try require(memoryOnly.messages.map(\.id) == [source.id, second.id] && !memoryOnly.hasPendingMemoryClear(first.id),
                    "Retrying a pending memory deletion preserves later messages")
        return checks
    }

    private static func accessibleElement(_ identifier: String, in node: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 32 else { return nil }
        if node.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
        guard node.responds(to: NSSelectorFromString("accessibilityChildren")),
              let children = node.value(forKey: "accessibilityChildren") as? [NSObject] else { return nil }
        for child in children {
            if let result = accessibleElement(identifier, in: child, depth: depth + 1) { return result }
        }
        return nil
    }
}
#endif
