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
                if CommandLine.arguments.contains("--hold-preview") {
                    _ = try await settings(delegate: delegate)
                    model.settings.reduceMotion = false
                    let id = try model.startTimer(seconds: 600, title: "Tea timer")
                    model.selectTask(id, expanded: true)
                    return
                }
                let checks = try await run(model, delegate: delegate) + settings(delegate: delegate)
                try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-motion-checks.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(withJSONObject: [
                    "ok": false, "checks": [], "error": error.localizedDescription,
                ]).write(to: URL(fileURLWithPath: "/tmp/orvlet-motion-checks.json"))
                exit(1)
            }
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
                try await wait(55)
                guard let command = delegate.commandPanel else {
                    throw AppError.message("Animated input window missing")
                }
                try check(
                    command.isVisible && command.alphaValue > 0 && command.alphaValue < 1,
                    "Alt-Space fades the independent input window into view")
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
