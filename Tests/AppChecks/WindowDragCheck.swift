#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum WindowDragCheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        let suite = "orvlet-window-drag-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.reduceMotion = true
        model.settings.compactLayout = .vertical
        model.settings.appearance = .light
        var task = SideTask(kind: .web, title: "Best of lofi hip hop 2021 ✨ [beats to relax/study to]")
        task.listening = true
        task.prefersSource = false
        task.playing = true
        task.sourceURL = "https://www.youtube.com/watch?v=abcdefghijk"
        task.musicQueue = MusicQueue(current: MusicTrack(id: "abcdefghijk", title: task.title, subtitle: "Lofi Girl"))
        model.sideTasks = [task, SideTask(kind: .result, title: "Time.is 03:27")]
        model.musicPlayback[task.id] = MusicPlayback([
            "hasMedia": true, "seekable": true, "playing": true, "duration": 22257.0, "currentTime": 37.0,
            "title": task.title, "artist": "Lofi Girl", "volume": 1.0,
        ])
        // Render a local playback state without restoring or loading a real source.
        model.selectedTaskID = task.id
        model.collapsed = false
        let anchor = NSRect(x: -15000, y: -15000, width: model.compactSize.width, height: model.compactSize.height)
        model.shellLayout = ShellLayout.place(anchor: anchor, content: model.shellContentSize, orientation: .vertical,
            screen: NSRect(x: -18000, y: -18000, width: 5000, height: 5000), edge: .left)
        // The rail can remain anchored at the bottom after expanding/repositioning.
        model.shellLayout.compact.origin.y = model.shellLayout.frame.minY
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = ShellPanel(contentRect: model.shellLayout.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        var moveStates: [Bool] = []
        panel.onMoveInteraction = { moveStates.append($0) }
        defer {
            panel.orderOut(nil)
            model.browser.dispose()
            model.taskRuntime.stopAll()
        }
        let host = NSHostingView(rootView: ContentView(model: model))
        panel.contentView = host
        panel.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-window-drag-light.png")
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            let local = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
            return host.hitTest(host.convert(local, to: host.superview))
        }
        let blankPoints: [(String, CGFloat, CGFloat)] = [
            ("music left margin", 7, 100), ("music right margin", 320, 100),
            ("title and artist gap", 180, 94), ("below artist", 180, 116),
            ("between timestamps", 165, 145), ("above transport", 165, 162),
            ("transport left gap", 90, 190), ("transport right gap", 240, 190),
            ("below transport", 165, 212), ("rail above tasks", 396, 65),
            ("rail left margin", 331, 190), ("rail right margin", 461, 190),
            ("between task rows", 396, 210), ("below task rows", 396, 249),
        ]
        for (name, x, y) in blankPoints {
            let view = hit(x, y)
            try StateMachineCheck.require(
                (view as? WindowDragArea.DragView).map { $0.allowsWindowDrag && $0.onOutsideDrop == nil } == true,
                "Window dragging owns " + name, &checks)
        }
        // Dispatch only to the offscreen test view. No system mouse or focus events.
        guard let drag = hit(396, 65) as? WindowDragArea.DragView else { throw AppError.message("Missing rail drag") }
        let origin = panel.frame.origin
        let start = host.convert(NSPoint(x: 396, y: host.isFlipped ? 65 : host.bounds.height - 65), to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        drag.mouseDown(with: event(.leftMouseDown, start))
        drag.mouseDragged(with: event(.leftMouseDragged, start.offsetBy(dx: 2, dy: 1)))
        try StateMachineCheck.require(panel.frame.origin == origin, "Click jitter does not move the shell", &checks)
        drag.mouseDragged(with: event(.leftMouseDragged, start.offsetBy(dx: 23, dy: 17)))
        drag.mouseUp(with: event(.leftMouseUp, start))
        try StateMachineCheck.require(panel.frame.origin == origin.offsetBy(dx: 23, dy: 17) && moveStates == [true, false],
            "Dragging rail whitespace moves the whole shell by the pointer delta", &checks)
        for (name, x, y) in [("playback", 164.0, 190.0), ("seek slider", 160, 128), ("queue toggle", 90, 239),
            ("repeat", 30, 185), ("previous", 115, 185), ("next", 213, 185), ("volume", 298, 185)] {
            try StateMachineCheck.require(hit(x, y) != nil && !(hit(x, y) is WindowDragArea.DragView),
                "Music \(name) keeps its own hit region", &checks)
        }
        let rail = model.shellLayout.localCompact
        let row = hit(rail.minX + 60, rail.minY + 50) as? WindowDragArea.DragView
        try StateMachineCheck.require(row?.onOutsideDrop != nil && row?.identifier?.rawValue == task.id.uuidString,
            "Task row keeps task dragging separate from window movement", &checks)
        model.settings.appearance = .dark
        try await Task.sleep(for: .milliseconds(100))
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-window-drag-dark.png")
        // Resize and expand the queue: the exclusion mask must follow live layout.
        model.sideTasks[0].musicQueue?.upcoming = [MusicTrack(id: "bcdefghijkl", title: "Evening study")]
        model.musicQueueExpanded.insert(task.id)
        let larger = NSRect(x: -16000, y: -16000, width: 576, height: 340)
        model.shellLayout = ShellLayout(frame: larger,
            compact: NSRect(x: larger.maxX - 136, y: larger.minY, width: 136, height: model.compactSize.height),
            content: NSRect(x: larger.minX, y: larger.minY, width: 440, height: 340), edge: .left)
        panel.setFrame(larger, display: false)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try StateMachineCheck.require(hit(220, 185) != nil && !(hit(220, 185) is WindowDragArea.DragView),
            "Playback exclusion follows a resized card", &checks)
        try StateMachineCheck.require(hit(100, 270) != nil && !(hit(100, 270) is WindowDragArea.DragView),
            "Expanded queue retains scrolling, track selection and reordering input", &checks)
        try StateMachineCheck.require(hit(220, 320) is WindowDragArea.DragView,
            "Extra space below an expanded queue remains draggable", &checks)
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-window-drag-queue.png")
        panel.orderOut(nil)
        try StateMachineCheck.require(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !panel.isVisible,
            "Drag checks leave desktop focus and visible windows unchanged", &checks)
        return checks
    }
}

private extension NSPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
}
#endif
