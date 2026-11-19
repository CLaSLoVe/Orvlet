#if DEBUG
    import AppKit
    import SwiftUI
    import WebKit

    @MainActor
    enum MotionCheck {
        static func start(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.main = Endpoint()
            do {
                if CommandLine.arguments.contains("--hold-preview"),
                    !CommandLine.arguments.contains("--source-window-check")
                {
                    _ = try await settings(delegate: delegate)
                    model.settings.reduceMotion = false
                    let id = try model.startTimer(seconds: 600, title: "Tea timer")
                    model.selectTask(id, expanded: true)
                    return
                }
                let checks =
                    try await
                    (CommandLine.arguments.contains("--window-core-only")
                    ? coreWindow(model, delegate: delegate)
                    : CommandLine.arguments.contains("--source-window-check")
                        ? sourceResizing(model, delegate: delegate)
                        : run(model, delegate: delegate) + settings(delegate: delegate))
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-motion-checks.json"))
                if CommandLine.arguments.contains("--hold-preview") { return }
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: [
                    "ok": false, "checks": [], "error": error.localizedDescription,
                ]).write(to: URL(fileURLWithPath: "/tmp/orvlet-motion-checks.json"))
                exit(1)
            }
        }

        static func coreWindow(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            model.settings.reduceMotion = true
            model.dismissFeedback()
            model.openURL("http://127.0.0.1:19244/fixture")
            try await Task.sleep(for: .milliseconds(600))
            model.collapse()
            model.setCompactLayout(.vertical)
            let shell = delegate.panel!
            let screen = shell.screen!.visibleFrame
            shell.setFrameOrigin(
                NSPoint(
                    x: screen.maxX - shell.frame.width - 24,
                    y: screen.maxY - shell.frame.height - 90))
            let home = shell.frame
            var checks: [String] = []
            for pinned in [false, true] {
                model.showPage()
                model.pinned = pinned
                let before = shell.frame
                delegate.windowWillStartLiveResize(
                    Notification(name: NSWindow.willStartLiveResizeNotification, object: shell))
                shell.setFrame(
                    NSRect(
                        x: before.minX - 36, y: before.minY - 28,
                        width: before.width + 36, height: before.height + 28), display: true)
                delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: shell))
                delegate.windowDidEndLiveResize(
                    Notification(name: NSWindow.didEndLiveResizeNotification, object: shell))
                model.collapse()
                guard shell.frame == home else {
                    throw AppError.message("Resize/collapse moved the parked card (pinned: \(pinned))")
                }
                checks.append("Resize/collapse returns home, pinned: \(pinned)")
            }
            model.setCompactLayout(.horizontal)
            model.setCompactLayout(.vertical)
            guard shell.frame == home else {
                throw AppError.message("Temporary orientation fitting overwrote the parked position")
            }
            checks.append("Orientation changes near a screen edge preserve the parked position")
            model.showPage()
            model.pinned = true
            shell.moveInteraction(true)
            shell.setFrameOrigin(NSPoint(x: shell.frame.minX - 24, y: shell.frame.minY - 16))
            shell.moveInteraction(false)
            model.collapse()
            guard shell.frame == home.offsetBy(dx: -24, dy: -16) else {
                throw AppError.message("A pinned drag failed to move the parked position")
            }
            checks.append("Intentional pinned drag updates the parked position")
            model.settings.reduceMotion = false
            return checks
        }

        static func sourceResizing(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                guard value else { throw AppError.message(name) }
                checks.append(name)
            }
            model.settings.reduceMotion = true
            model.dismissFeedback()
            model.selectChat(false, restoreFocus: false)
            model.openURL("http://127.0.0.1:19244/fixture")
            try await Task.sleep(for: .milliseconds(600))
            model.showPage()
            for orientation in [CompactLayout.vertical, .horizontal] {
                model.setCompactLayout(orientation)
                for pinned in [false, true] {
                    model.pinned = pinned
                    delegate.resize(to: model.windowSize)
                    let shell = delegate.panel!
                    for change: CGFloat in [70, -50] {
                        let started = shell.frame
                        delegate.windowWillStartLiveResize(
                            Notification(name: NSWindow.willStartLiveResizeNotification, object: shell))
                        let enlarged = NSRect(
                            x: started.minX - change, y: started.minY - change / 2, width: started.width + change,
                            height: started.height + change / 2)
                        shell.setFrame(enlarged, display: true)
                        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: shell))
                        try check(
                            model.shellLayout.frame == shell.frame
                                && model.shellLayout.localVisibleContent.size == model.shellLayout.content.size,
                            "Live source resizing keeps rendered content and hit regions inside the actual frame (pinned: \(pinned))"
                        )
                        let during = model.shellLayout
                        delegate.windowDidEndLiveResize(
                            Notification(name: NSWindow.didEndLiveResizeNotification, object: shell))
                        delegate.resize(to: model.windowSize)
                        try check(
                            shell.frame == during.frame && model.shellLayout.content == during.content,
                            "Releasing a source resize and refreshing data does not snap or reflow the window (orientation: \(orientation), pinned: \(pinned), before: \(during), after: \(model.shellLayout), window: \(shell.frame))"
                        )
                    }
                    if pinned, let screen = shell.screen?.visibleFrame {
                        shell.setFrameOrigin(NSPoint(x: screen.maxX - 8 - shell.frame.width, y: shell.frame.minY))
                        let moved = shell.frame
                        delegate.resize(to: model.windowSize)
                        try check(
                            shell.frame == moved,
                            "A pinned window dragged to the screen edge is not pulled back by its hidden task strip")
                        try check(
                            shell.minSize.width == AppModel.minimumWebSize.width + model.shellLayout.chromeSize.width,
                            "Pinned source minimum width includes only the visible rail")
                    }
                }
            }
            model.setCompactLayout(.vertical)
            model.settings.reduceMotion = false
            model.pinned = false
            try await Task.sleep(for: .milliseconds(60))
            let shell = delegate.panel!
            shell.moveInteraction(true)
            shell.setFrameOrigin(NSPoint(x: shell.frame.minX - 24, y: shell.frame.minY - 20))
            let dragged = shell.frame
            try await Task.sleep(for: .milliseconds(100))
            try check(shell.frame == dragged, "An interrupted pin animation cannot compete with an active window drag")
            shell.moveInteraction(false)
            try await Task.sleep(for: .milliseconds(400))
            try check(
                model.activeInteractions == 0 && model.shellLayout.frame == shell.frame,
                "Releasing a drag restores layout and balances interaction tracking")
            checks += try await sourceReturningHome(model, delegate: delegate)
            checks += try await taskDoubleClick(model, delegate: delegate)
            model.settings.reduceMotion = true
            model.pinned = true
            try await Task.sleep(for: .milliseconds(200))
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-source-resize-pinned.png")
            return checks
        }

        static func sourceReturningHome(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            let shell = delegate.panel!
            model.settings.reduceMotion = true
            for orientation in [CompactLayout.vertical, .horizontal] {
                for farEdge in [false, true] {
                    for pinned in [false, true] {
                        model.collapse()
                        model.setCompactLayout(orientation)
                        let screen = shell.screen!.visibleFrame
                        let size = shell.frame.size
                        let origin = NSPoint(
                            x: orientation == .vertical
                                ? (farEdge ? screen.maxX - size.width - 80 : screen.minX + 80)
                                : screen.midX - size.width / 2,
                            y: orientation == .horizontal && !farEdge
                                ? screen.minY + 80 : screen.maxY - size.height - 80)
                        shell.setFrameOrigin(origin)
                        let home = shell.frame
                        model.showPage()
                        model.pinned = pinned
                        delegate.resize(to: model.windowSize)
                        for delta: CGFloat in [60, -40] {
                            let before = shell.frame
                            delegate.windowWillStartLiveResize(
                                Notification(name: NSWindow.willStartLiveResizeNotification, object: shell))
                            shell.setFrame(
                                NSRect(
                                    x: before.minX - delta / 2, y: before.minY - delta / 2,
                                    width: before.width + delta, height: before.height + delta), display: true)
                            delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: shell))
                            delegate.windowDidEndLiveResize(
                                Notification(name: NSWindow.didEndLiveResizeNotification, object: shell))
                        }
                        // Rail retraction, the task shelf and source/card changes are layouts, not moves.
                        model.pinned.toggle()
                        model.pinned.toggle()
                        model.taskShelfVisible = true
                        delegate.resize(to: model.windowSize)
                        model.taskShelfVisible = false
                        delegate.resize(to: model.windowSize)
                        model.collapse()
                        guard shell.frame == home else {
                            throw AppError.message(
                                "Resizing or switching layouts moved the compact home: \(orientation), \(farEdge), \(pinned), \(home) -> \(shell.frame)"
                            )
                        }
                        checks.append(
                            "Resize/pin/shelf/collapse returns to the parked position: \(orientation), far edge \(farEdge), pinned \(pinned)"
                        )
                        model.showPage()
                        model.pinned = pinned
                        delegate.resize(to: model.windowSize)
                        shell.moveInteraction(true)
                        shell.setFrameOrigin(NSPoint(x: shell.frame.minX + 18, y: shell.frame.minY - 14))
                        shell.moveInteraction(false)
                        model.collapse()
                        guard shell.frame == home.offsetBy(dx: 18, dy: -14) else {
                            throw AppError.message("An intentional expanded drag did not translate the compact home")
                        }
                        checks.append(
                            "Intentional expanded movement translates the parked position without incorporating resize displacement"
                        )
                    }
                }
            }
            return checks
        }

        static func taskDoubleClick(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ condition: Bool, _ label: String) throws {
                guard condition else { throw AppError.message(label) }
                checks.append(label)
            }
            func targets(_ view: NSView) -> [WindowDragArea.DragView] {
                (view as? WindowDragArea.DragView).map { [$0] } ?? view.subviews.flatMap(targets)
            }
            func click(_ view: WindowDragArea.DragView, count: Int) {
                let window = view.window!
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
            let id = model.selectedSideTask!.id
            model.collapse()
            try await Task.sleep(for: .milliseconds(100))
            func title() throws -> WindowDragArea.DragView {
                guard
                    let target = targets(delegate.panel.contentView!).first(where: {
                        $0.identifier?.rawValue == id.uuidString && $0.onDoubleClick != nil
                    })
                else { throw AppError.message("Missing compact task double-click target") }
                return target
            }
            click(try title(), count: 1)
            try await Task.sleep(for: .milliseconds(50))
            click(try title(), count: 2)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(
                model.showingWeb && !model.collapsed,
                "Double-clicking a web task opens its source without a delayed collapse")
            click(try title(), count: 1)
            try check(
                !model.collapsed, "A collapse click waits briefly so its second click cannot land on another window")
            click(try title(), count: 2)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(
                model.showingWeb && !model.collapsed,
                "Double-clicking an already expanded task cancels the pending collapse")
            click(try title(), count: 1)
            WindowDragArea.DragView.cancelPendingClicks()
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(!model.collapsed, "Another pointer or keyboard action cancels a pending single click")
            click(try title(), count: 1)
            WindowDragArea.DragView.cancelPendingClicks()
            model.collapse()
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(model.collapsed, "Escape or outside dismissal cannot be undone by a stale delayed click")
            model.showPage()
            try await Task.sleep(for: .milliseconds(100))
            click(try title(), count: 1)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(model.collapsed, "An ordinary single click still collapses an expanded task")
            model.taskShelfVisible = true
            delegate.resize(to: model.windowSize)
            try await Task.sleep(for: .milliseconds(100))
            guard
                let row = targets(delegate.panel.contentView!).first(where: {
                    $0.onDoubleClick != nil && !$0.allowsWindowDrag
                })
            else { throw AppError.message("Missing task shelf double-click target") }
            click(row, count: 1)
            try check(
                model.taskShelfVisible,
                "Task shelf keeps its row under the pointer until double-click detection completes")
            click(row, count: 2)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            try check(
                model.showingWeb && !model.taskShelfVisible,
                "Task shelf double-click opens the source and does not replay its single click")
            let timer = try model.startTimer(seconds: 60, title: "Click check")
            model.openTaskFromDoubleClick(timer)
            try check(
                !model.showingWeb && !model.collapsed && model.selectedTaskID == timer,
                "Double-clicking a non-web task keeps its ordinary task details")
            model.closeTask(timer)
            model.selectTask(id, expanded: true, preferSource: true)
            return checks
        }

        static func settings(delegate: AppDelegate) async throws -> [String] {
            let suite = "orvlet-motion-settings-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.appearance = .light
            model.settings.reduceMotion = false
            model.settings.allowAgents = false
            delegate.openSettings(tab: 0, for: model)
            guard let window = delegate.settingsWindow, let content = window.contentView else {
                throw AppError.message("Settings window missing")
            }
            // Keep the isolated owner alive when the optional manual preview is open.
            previewModel = model
            func elements(_ root: Any, depth: Int = 0) -> [NSObject] {
                guard depth < 30, let node = root as? NSObject else { return [] }
                let children =
                    node.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? (node.value(forKey: "accessibilityChildren") as? [Any] ?? []) : []
                return [node] + children.flatMap { elements($0, depth: depth + 1) }
            }
            func tabs() -> [NSRect] {
                let nodes = elements(content)
                return (0..<5).compactMap { index in
                    let node = nodes.first {
                        $0.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                            && $0.value(forKey: "accessibilityIdentifier") as? String == "settings-tab-\(index)"
                    }
                    return (node?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            let expected = tabs()
            guard expected.count == 5, expected.allSatisfy({ $0.width >= 90 && $0.height >= 30 }) else {
                throw AppError.message("Five accessible settings tabs must have full, equal hit regions: \(expected)")
            }
            let frame = window.frame
            var checks = ["Five settings tabs expose stable, full-size accessible hit regions"]
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-motion-tabs-start.png")
            model.settingsTabRequested = 4
            try await Task.sleep(for: .milliseconds(80))
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-motion-tabs-moving.png")
            try await Task.sleep(for: .milliseconds(400))
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-motion-tabs-end.png")
            for tab in [2, 4, 1, 3, 0, 4, 2, 3] {
                model.settingsTabRequested = tab
                // Interrupt before the previous indicator/page transition has settled.
                try await Task.sleep(for: .milliseconds(65))
                guard tabs() == expected, window.frame == frame else {
                    throw AppError.message("Rapid settings switching moved a label, hit target or window")
                }
            }
            checks.append("Rapid tab reversals keep labels, hit regions and window geometry stationary")
            try await Task.sleep(for: .milliseconds(450))
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-motion-settings-light.png")
            model.settings.appearance = .dark
            try await Task.sleep(for: .milliseconds(200))
            try await SideScreenCheck.snapshot(window, path: "/tmp/orvlet-motion-settings-dark.png")
            model.settings.reduceMotion = true
            model.settingsTabRequested = 4
            try await Task.sleep(for: .milliseconds(80))
            guard tabs() == expected else { throw AppError.message("Reduce Motion changed tab geometry") }
            checks.append("Reduce Motion switches settings without moving the tab layout")
            model.settings.reduceMotion = false
            model.settings.appearance = .light
            model.settingsTabRequested = 0
            if !CommandLine.arguments.contains("--hold-preview") { window.orderOut(nil) }
            return checks
        }
        private static var previewModel: AppModel?
        static func run(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                guard value else { throw AppError.message(name) }
                checks.append(name)
            }
            func wait(_ ms: Int = 400) async throws { try await Task.sleep(for: .milliseconds(ms)) }
            model.dismissFeedback()
            model.selectChat(false, restoreFocus: false)
            model.settings.reduceMotion = true
            model.setCompactLayout(.vertical)
            let player = model.browser
            _ = try await player.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture"])
            _ = try await player.webView.evaluateJavaScript("document.querySelector('audio').loop=true")
            _ = try await player.action(["action": "media", "operation": "play"])
            model.beginBackgroundListening()
            let playbackStart = (try await player.observe())["currentTime"] as? Double ?? 0
            let id = try model.startTimer(seconds: 600, title: "Motion check")
            model.collapse()
            try await wait(80)
            let compact = delegate.panel.frame
            let anchor = delegate.ambientFrame
            model.settings.reduceMotion = false
            if !model.motionReduced {
                model.selectTask(id, expanded: true)
                try check(
                    delegate.panel.frame == compact,
                    "Opening begins at the displayed frame instead of jumping to its final size")
                try await wait(100)
                let middle = delegate.panel.frame
                try check(
                    middle.width > compact.width + 10 && delegate.ambientFrame == anchor,
                    "An opening frame grows while the compact controls stay anchored: \(middle), \(compact), \(delegate.ambientFrame), \(anchor)"
                )
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-motion-opening.png")
                try await wait()
                let expanded = delegate.panel.frame
                try check(
                    expanded.width > middle.width && model.shellLayout.frame == expanded,
                    "The window reaches its final layout after progressing through intermediate sizes")
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-motion-expanded.png")
                let cardFrame = model.shellLayout.content
                model.pinned = true
                try await wait(70)
                try check(
                    model.shellLayout.content == cardFrame && delegate.panel.frame.width < expanded.width,
                    "Pinning retracts the task rail while the card and its pin button stay anchored")
                model.pinned = false
                try await wait(60)
                model.pinned = true
                try await wait()
                try check(
                    model.shellLayout.content == cardFrame && model.shellLayout.presentedCompact.width == 28,
                    "Rapid pin-unpin-pin finishes at a narrow rail without moving card controls")
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-motion-pinned.png")
                model.pinned = false
                try await wait()
                try check(
                    delegate.panel.frame == expanded && model.shellLayout.content == cardFrame,
                    "Unpin restores the complete task strip at the original card position")
                model.collapse()
                try await wait(65)
                let closing = delegate.panel.frame
                try check(
                    closing.width > compact.width && closing.width < expanded.width,
                    "Closing also progresses through intermediate sizes")
                model.selectTask(id, expanded: true)
                try check(
                    delegate.panel.frame == closing,
                    "Reversing a collapse continues from its current frame without a snap")
                try await wait()
                try check(
                    delegate.panel.frame == expanded && delegate.ambientFrame == anchor,
                    "Rapid open-close-open ends at the latest intent with no anchor drift")
                model.collapse()
                try await wait()
                model.selectTask(id, expanded: true)
                try await wait(60)
                delegate.panel.setFrameOrigin(
                    NSPoint(x: delegate.panel.frame.minX - 30, y: delegate.panel.frame.minY - 20))
                try await wait()
                let dragged = delegate.ambientFrame
                try check(
                    abs(dragged.minX - (anchor.minX - 30)) < 1 && abs(dragged.minY - (anchor.minY - 20)) < 1
                        && delegate.panel.frame.width == expanded.width,
                    "Dragging during expansion rebases the animation instead of leaving a cropped or drifting window")
                delegate.panel.setFrameOrigin(
                    NSPoint(x: delegate.panel.frame.minX + 30, y: delegate.panel.frame.minY + 20))
                model.taskShelfVisible = true
                try await wait()
                try check(
                    model.taskShelfVisible && delegate.ambientFrame == anchor,
                    "The task shelf uses the same anchored animated shell: original=\(anchor), current=\(delegate.ambientFrame), visible=\(model.taskShelfVisible)"
                )
                model.taskShelfVisible = false
                try await wait()
                model.selectChat(true)
                guard let command = delegate.commandPanel else {
                    throw AppError.message("Animated input window missing")
                }
                // Initial SwiftUI layout may occupy more than one animation
                // interval. Check the initial frame, not a lucky 55 ms sample.
                let startsTransparent = command.alphaValue < 1
                try await wait(55)
                try check(
                    command.isVisible && startsTransparent && (0...1).contains(command.alphaValue),
                    "Alt-Space starts the independent input window without an opaque flash")
                model.selectChat(false, restoreFocus: false)
                try check(
                    !model.commandPanelVisible && command.ignoresMouseEvents,
                    "Input dismissal returns interaction immediately while its visual exit finishes")
                model.selectChat(true)
                try await wait(250)
                try check(
                    command.isVisible && abs(command.alphaValue - 1) < 0.001 && !command.ignoresMouseEvents,
                    "Rapidly reopening input cancels its pending hide rather than disappearing later")
                model.selectChat(false, restoreFocus: false)
                try await wait(250)
                try check(
                    !command.isVisible && delegate.panel.frame == expanded,
                    "Input exit completes without moving the task window")
            }
            let playback = try await player.observe()
            try check(
                model.browser === player && playback["playing"] as? Bool == true
                    && abs((playback["currentTime"] as? Double ?? 0) - playbackStart) > 0.1,
                "Window animations keep the same live webpage mounted and audio advancing")
            _ = try await player.action(["action": "media", "operation": "pause"])
            model.settings.reduceMotion = true
            model.collapse()
            try check(delegate.panel.frame == compact, "Reduce Motion settles the compact layout immediately")
            model.selectTask(id, expanded: true)
            try check(
                delegate.panel.frame.width > compact.width && delegate.panel.frame == model.shellLayout.frame,
                "Reduce Motion preserves immediate expanded interaction without a geometry animation")
            model.closeTask(id)
            model.closeWebTask(player.id)
            let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
            for edge in [DetailEdge.left, .right, .above, .below] {
                let layout = ShellLayout.place(
                    anchor: NSRect(x: 600, y: 500, width: 136, height: 116),
                    content: NSSize(width: 328, height: 240), orientation: .vertical, screen: screen, edge: edge)
                let tucked = layout.tuckingCompact()
                try check(
                    tucked.content == layout.content && tucked.compact == layout.compact
                        && !tucked.presentedCompact.intersects(tucked.content)
                        && tucked.frame == tucked.content.union(tucked.presentedCompact),
                    "Pinning on \(edge) preserves the card position and canonical expansion anchor")
            }
            return checks
        }
    }
#endif
