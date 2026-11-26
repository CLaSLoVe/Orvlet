#if DEBUG
import AppKit
import SwiftUI

/// Exercises the real shell and drag handles in a nonactivating, offscreen panel.
@MainActor
enum CapsuleMotionCheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            try StateMachineCheck.require(value, name, &checks)
        }
        let suite = "orvlet-capsule-motion-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.compactLayout = .vertical
        model.settings.appearance = .light
        model.settings.reduceMotion = false
        let focus = BackgroundFocusCheck()
        let sibling = try model.startTimer(seconds: 300, title: "Tea")
        let id = try model.startTimer(seconds: 300, title: "Focus")
        let notes = SideTask(kind: .workspace, title: "Notes")
        model.sideTasks.append(notes)
        model.taskOrder = [notes.id, sibling, id]
        model.selectTask(id, expanded: true)

        let screen = NSRect(x: -18000, y: -18000, width: 4000, height: 4000)
        let anchor = NSRect(origin: NSPoint(x: -17400, y: -14800), size: model.compactSize)
        let home = ShellLayout.place(anchor: anchor, content: nil, orientation: .vertical, screen: screen)
        let expanded = ShellLayout.place(anchor: anchor, content: model.shellContentSize, orientation: .vertical, screen: screen)
        let panel = ShellPanel(contentRect: home.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.sizingOptions = []
        model.shellLayout = home
        panel.contentView = hosting
        panel.orderBack(nil)
        defer {
            panel.orderOut(nil)
            model.taskClock?.invalidate()
            model.taskRuntime.stopAll()
            defaults.removePersistentDomain(forName: suite)
        }
        func show(_ layout: ShellLayout) async throws {
            model.shellLayout = layout
            panel.setFrame(layout.frame, display: true)
            try await Task.sleep(for: .milliseconds(60))
            hosting.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String, from window: NSWindow) async throws {
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-fluid-" + name + ".png")
        }
        try await show(home)
        guard let timerTool = model.timerTool, let source = model.compactSourceFrames[timerTool.id] else {
            throw AppError.message("Missing shared Timer capsule bounds")
        }
        try check(model.compactSourceFrame(for: model.selectedSideTask) == source && model.compactSourceFrames[id] == nil,
                  "Opening the second countdown animates from the shared Timer capsule")
        for (phase, step) in [("opening", 0.18), ("joining", 0.48), ("expanded", 1.0)] {
            let layout = expanded.transitioning(from: home, progress: step, source: source)
            try await show(layout)
            try await capture(phase, from: panel)
            try check(model.shellLayout.compact == anchor && layout.content.size == expanded.content.size,
                      "Capsule anchor and detail typography keep their final size during " + phase)
        }
        let closing = home.transitioning(from: expanded, progress: 0.46, source: source)
        let reversing = expanded.transitioning(from: closing, progress: 0)
        try check(closing.frame == reversing.frame && closing.compact == reversing.compact && closing.reveal == reversing.reveal,
                  "Changing direction mid-reveal resumes at the displayed shell bounds")
        model.collapse()
        try await show(home)
        let delegate = AppDelegate(model: model)
        delegate.panel = panel
        model.onResize = { [weak delegate] size in delegate?.resize(to: size, in: screen) }
        model.settings.reduceMotion = true
        delegate.resize(to: model.windowSize, in: screen)
        model.settings.reduceMotion = false
        if !model.motionReduced {
            model.selectTask(id, expanded: true)
            for _ in 0..<25 {
                if let fraction = model.shellLayout.reveal?.fraction, fraction > 0.08 { break }
                try await Task.sleep(for: .milliseconds(6))
            }
            let during = model.shellLayout
            try check(during.reveal?.source == source && (during.reveal?.fraction ?? 0) > 0,
                      "The live display clock opens from the selected compact row")
            model.collapse()
            try check(model.shellLayout.reveal == during.reveal,
                      "Reversing the running animation preserves its displayed contour")
            try await Task.sleep(for: .milliseconds(450))
            try check(panel.frame == home.frame && model.shellLayout.reveal == nil,
                      "The reversed animation lands at its original parked position")
        }
        func handle(in view: NSView) -> WindowDragArea.DragView? {
            if let drag = view as? WindowDragArea.DragView, drag.identifier?.rawValue == timerTool.id.uuidString,
               drag.onOutsideDrop != nil, drag.bounds.width > 45 { return drag }
            return view.subviews.lazy.compactMap { handle(in: $0) }.first
        }
        guard let drag = handle(in: hosting) else { throw AppError.message("Missing compact drag handle") }
        let origin = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ dx: CGFloat, _ dy: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x + dx, y: origin.y + dy),
                               modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        drag.mouseDown(with: event(.leftMouseDown, 0, 0))
        for (name, dx, dy) in [("peeling", 32.0, -20.0), ("detached", 150.0, -65.0), ("returning", 19.0, -13.0)] {
            drag.mouseDragged(with: event(.leftMouseDragged, dx, dy))
            try await Task.sleep(for: .milliseconds(90))
            guard let preview = drag.dragPreviewPanel else { throw AppError.message("Missing drag preview during " + name) }
            try check(!NSScreen.screens.contains { $0.frame.intersects(preview.frame) } && !preview.isKeyWindow,
                      "Drag preview stays in the offscreen fixture during " + name)
            try check(drag.outsideDropArmed == (name == "detached"), "Close affordance follows the pointer during " + name)
            try await capture(name, from: preview)
        }
        drag.mouseUp(with: event(.leftMouseUp, 19, -13))
        try await Task.sleep(for: .milliseconds(600))
        try check(model.draggingTaskID == nil && drag.dragPreviewPanel == nil && model.visibleTasks.contains { $0.id == id },
                  "Dropping back into the stack restores the capsule and releases the preview")

        guard let index = model.sideTasks.firstIndex(where: { $0.id == id }) else { throw AppError.message("Lost timer") }
        model.sideTasks[index].deadline = Date().addingTimeInterval(-1)
        model.tickTasks()
        try await Task.sleep(for: .milliseconds(220))
        try await capture("attention", from: panel)
        guard let receipt = model.sideTasks[index].pendingTimerReminderID else { throw AppError.message("Missing Focus alarm") }
        try check(model.capsuleAttention[id]?.eventID == receipt && model.capsuleAttention[sibling] == nil
                  && model.compactAttention(for: timerTool)?.eventID == receipt && model.compactAttention(for: notes) == nil,
                  "The running countdown's receipt lights the shared Timer outline and leaves Notes at rest")
        try await Task.sleep(for: .milliseconds(2100))
        try await capture("settled", from: panel)
        model.tickTasks()
        try check(model.capsuleAttention.isEmpty, "A subsequent timer tick leaves both capsule edges at rest")
        model.settings.appearance = .dark
        model.settings.reduceMotion = true
        guard let other = model.sideTasks.firstIndex(where: { $0.id == sibling }) else { throw AppError.message("Missing Tea") }
        model.sideTasks[other].deadline = Date().addingTimeInterval(-1)
        model.tickTasks()
        try await Task.sleep(for: .milliseconds(170))
        try await capture("dark-reduced", from: panel)
        guard let secondReceipt = model.sideTasks[other].pendingTimerReminderID else { throw AppError.message("Missing Tea alarm") }
        try check(model.motionReduced && Set(model.reminders.map(\.id)).isSuperset(of: [receipt, secondReceipt])
                  && secondReceipt != receipt && model.microTimerTasks.count == 1
                  && model.compactAttention(for: timerTool)?.eventID == secondReceipt && model.compactAttention(for: notes) == nil,
                  "Two countdowns keep distinct alarms and reuse the same outline with Reduce Motion")
        model.acknowledgeTimerFromTool(id)
        model.acknowledgeTimerFromTool(sibling)
        panel.orderOut(nil)
        try check(!focus.tookFocus,
                  "Capsule motion checks preserve desktop focus")
        return checks
    }
}
#endif
