#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum InteractionCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async throws -> [String] {
            var checks: [String] = []
            func check(_ value: Bool, _ name: String) throws {
                guard value else { throw AppError.message("Check failed: " + name) }
                checks.append(name)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(450)) }
            func views(_ view: NSView) -> [WindowDragArea.DragView] {
                (view as? WindowDragArea.DragView).map { [$0] } ?? view.subviews.flatMap(views)
            }
            var compactHitTargetsValid = true
            func gesture(_ view: WindowDragArea.DragView, delta: NSPoint = .zero) {
                guard let window = view.window else { return }
                let local = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                if window === delegate.panel && window.contentView?.hitTest(local) !== view {
                    compactHitTargetsValid = false
                }
                let start = window.convertPoint(toScreen: local)
                func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                }
                view.mouseDown(with: event(.leftMouseDown, start))
                let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
                if delta != .zero { view.mouseDragged(with: event(.leftMouseDragged, end)) }
                view.mouseUp(with: event(.leftMouseUp, end))
            }
            model.collapse()
            try await pause()
            guard let media = model.microMediaTasks.first,
                let button = views(delegate.panel.contentView!).first(where: {
                    abs($0.bounds.width - 24) < 1 && $0.onClick != nil && $0.identifier?.rawValue == media.id.uuidString
                }),
                let title = views(delegate.panel.contentView!).first(where: {
                    abs($0.bounds.width - 78) < 1 && $0.onClick != nil && $0.identifier?.rawValue == media.id.uuidString
                })
            else {
                throw AppError.message("Draggable compact targets missing")
            }
            let original = delegate.panel.frame
            let wasPlaying = model.sideTasks.first(where: { $0.id == media.id })!.playing
            gesture(button, delta: NSPoint(x: -36, y: 20))
            try await pause()
            try check(
                delegate.panel.frame.origin == original.origin
                    && model.sideTasks.first(where: { $0.id == media.id })!.playing == wasPlaying,
                "Dragging inside a compact task neither moves the window nor toggles playback")
            gesture(title, delta: NSPoint(x: -24, y: 12))
            try await pause()
            try check(model.collapsed, "Dragging task text does not accidentally open details")
            gesture(button, delta: NSPoint(x: 1, y: 1))
            try await pause()
            try check(
                model.sideTasks.first(where: { $0.id == media.id })!.playing != wasPlaying,
                "A small click wobble still activates the real playback control once")
            gesture(button)
            try await pause()
            gesture(title)
            try await pause()
            try check(
                !model.collapsed && !model.showingWeb && delegate.panel.isVisible,
                "A normal click on draggable music text opens its player card")
            try check(
                compactHitTargetsValid, "Visible compact controls route pointer input to their drag-or-click targets")
            guard
                let header = views(delegate.panel.contentView!).first(where: {
                    $0.onClick == nil && abs($0.bounds.height - 30) < 1
                })
            else { throw AppError.message("Detail drag header missing") }
            let detailBefore = delegate.panel.frame
            gesture(header, delta: NSPoint(x: -24, y: 24))
            try await pause()
            let moved = delegate.panel.frame
            delegate.resize(to: model.windowSize)
            try check(
                moved.origin != detailBefore.origin && delegate.panel.frame == moved,
                "Dragging the detail header keeps its new position across state updates")
            if let timer = model.sideTasks.first(where: { $0.kind == .timer }) {
                if timer.terminalLabel != nil { model.timerAction(timer.id, action: "restart") }
                model.selectTask(timer.id, expanded: true)
                try await pause()
                func webViews(_ view: NSView) -> [WKWebView] {
                    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
                }
                var card: WKWebView?
                for web in webViews(delegate.panel.contentView!) {
                    if (try? await web.evaluateJavaScript("typeof window.updateCard === 'function'")) as? Bool == true {
                        card = web
                        break
                    }
                }
                guard let card else { throw AppError.message("Generated timer card missing") }
                let before = delegate.panel.frame.origin
                _ = try await card.evaluateJavaScript(
                    "document.querySelector('strong').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,screenX:100,screenY:100,button:0})); document.dispatchEvent(new MouseEvent('mousemove',{screenX:130,screenY:112})); document.dispatchEvent(new MouseEvent('mouseup')); true"
                )
                try await pause()
                try check(
                    delegate.panel.frame.origin == NSPoint(x: before.x + 30, y: before.y - 12),
                    "Generated card text can drag its window through the trusted host bridge")
                let after = delegate.panel.frame.origin
                _ = try await card.evaluateJavaScript(
                    "document.querySelector('button').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,screenX:100,screenY:100,button:0})); document.dispatchEvent(new MouseEvent('mousemove',{screenX:150,screenY:140})); document.dispatchEvent(new MouseEvent('mouseup')); true"
                )
                try await pause()
                try check(
                    delegate.panel.frame.origin == after,
                    "Generated action controls are excluded from background dragging")
            }
            model.collapse()
            delegate.panel.setFrame(original, display: true)
            model.command = "A draft to preserve"
            model.selectChat(true)
            try await pause()
            guard
                let footer = views(delegate.commandPanel!.contentView!).first(where: {
                    $0.onClick == nil && $0.bounds.width > 60 && $0.bounds.width < 250 && $0.bounds.height < 30
                })
            else { throw AppError.message("Command window drag area missing") }
            gesture(footer, delta: NSPoint(x: -40, y: -24))
            let movedCommand = delegate.commandPanel!.frame
            model.selectChat(false, restoreFocus: false)
            model.selectChat(true)
            try await pause()
            try check(
                delegate.commandPanel!.frame == movedCommand && model.command == "A draft to preserve",
                "Command window retains a dragged position and draft on reopening (before: \(movedCommand), after: \(delegate.commandPanel!.frame), draft: \(model.command))"
            )
            model.toggleTaskPresentation(media.id)
            try await pause()
            try check(
                !model.commandPanelVisible && !model.collapsed && !model.showingWeb,
                "Clicking a task card while the composer is open closes input and opens that task's details")

            let spare = BrowserController(model: model)
            model.parkedBrowsers[spare.id] = spare
            var unavailable = SideTask(kind: .web, title: "Saved page")
            unavailable.sourceURL = "http://127.0.0.1:19244/fixture?saved"
            unavailable.hidden = true
            model.sideTasks.append(unavailable)
            let selection = model.selectedTaskID
            let failed = model.selectTask(unavailable.id, expanded: true)
            try check(
                !failed && model.lastActionError != nil && model.selectedTaskID == selection
                    && model.sideTasks.last!.hidden,
                "An unavailable saved page reports why without changing selection or visibility")
            model.parkedBrowsers.removeValue(forKey: spare.id)
            spare.dispose()
            model.sideTasks.removeAll { $0.id == unavailable.id }
            model.lastActionError = nil
            if let other = model.quickMediaTasks.first(where: { $0.id != media.id }) {
                model.closeWebTask(other.id)
                try check(
                    !model.collapsed && !model.showingWeb && model.selectedTaskID == media.id,
                    "Closing a background page preserves the foreground player card")
            }
            model.hide()
            delegate.showPet()
            model.toggleTaskPresentation(media.id)
            try check(
                !model.collapsed && !model.showingWeb,
                "After hiding and showing the app, one click opens the music card again")
            model.dismissTask(media.id)
            try check(model.collapsed, "Hiding the selected task closes its details without opening another task")
            model.selectTask(media.id)
            model.collapse()
            try await pause()
            if let closingTitle = views(delegate.panel.contentView!).first(where: {
                $0.onOutsideDrop != nil && abs($0.bounds.width - 78) < 1
                    && $0.identifier?.rawValue == media.id.uuidString
            }) {
                let previousReducedMotion = model.settings.reduceMotion
                defer { model.settings.reduceMotion = previousReducedMotion }
                model.settings.reduceMotion = false
                let shell = delegate.panel!
                let shellBeforeDrag = shell.frame
                let start = shell.convertPoint(
                    toScreen: closingTitle.convert(
                        NSPoint(x: closingTitle.bounds.midX, y: closingTitle.bounds.midY), to: nil))
                let outside = NSPoint(x: shell.frame.minX - 110, y: start.y)
                func pointer(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type, location: shell.convertPoint(fromScreen: point), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 1, pressure: 1)!
                }
                closingTitle.mouseDown(with: pointer(.leftMouseDown, start))
                closingTitle.mouseDragged(with: pointer(.leftMouseDragged, outside))
                try await pause()
                guard let preview = closingTitle.dragPreviewPanel else {
                    throw AppError.message("Drag preview missing")
                }
                try check(
                    preview.isVisible && closingTitle.outsideDropArmed && model.draggingTaskID == media.id
                        && model.sideTasks.contains(where: { $0.id == media.id }),
                    "Dragging outside shows a floating close preview before removing the task")
                try check(
                    !preview.canBecomeKey && preview.ignoresMouseEvents && shell.frame == shellBeforeDrag,
                    "Drag preview neither takes focus nor moves the task window")
                try await SideScreenCheck.snapshot(preview, path: "/tmp/orvlet-drag-close-preview.png")
                let originalAppearance = preview.appearance
                preview.appearance = NSAppearance(named: .darkAqua)
                try await pause()
                try await SideScreenCheck.snapshot(preview, path: "/tmp/orvlet-drag-close-dark.png")
                preview.appearance = originalAppearance
                try await pause()
                try await SideScreenCheck.snapshot(shell, path: "/tmp/orvlet-drag-source.png")
                closingTitle.mouseDragged(with: pointer(.leftMouseDragged, start))
                try await pause()
                try check(
                    !closingTitle.outsideDropArmed && closingTitle.dragPreviewPanel === preview,
                    "Dragging back retracts the close state on the same floating card")
                closingTitle.mouseUp(with: pointer(.leftMouseUp, start))
                try await pause()
                try check(
                    closingTitle.dragPreviewPanel == nil && model.draggingTaskID == nil
                        && model.sideTasks.contains(where: { $0.id == media.id }),
                    "Releasing inside returns the card without closing or activating it")
                closingTitle.mouseDown(with: pointer(.leftMouseDown, start))
                closingTitle.mouseDragged(with: pointer(.leftMouseDragged, outside))
                let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: shell.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                    keyCode: 53)!
                closingTitle.keyDown(with: escape)
                try await pause()
                closingTitle.mouseUp(with: pointer(.leftMouseUp, outside))
                try check(
                    closingTitle.dragPreviewPanel == nil && model.draggingTaskID == nil
                        && model.sideTasks.contains(where: { $0.id == media.id }),
                    "Escape retracts the preview and prevents a later outside release from closing")
                model.settings.reduceMotion = true
                try await pause()
                closingTitle.mouseDown(with: pointer(.leftMouseDown, start))
                closingTitle.mouseDragged(with: pointer(.leftMouseDragged, outside))
                try await pause()
                try check(
                    closingTitle.dragPreviewPanel?.isVisible == true && closingTitle.outsideDropArmed,
                    "Reduced motion keeps the visible close affordance")
                closingTitle.keyDown(with: escape)
                try await pause()
                model.settings.reduceMotion = false
                try await pause()
                closingTitle.mouseDown(with: pointer(.leftMouseDown, start))
                closingTitle.mouseDragged(with: pointer(.leftMouseDragged, outside))
                try await pause()
                closingTitle.mouseUp(with: pointer(.leftMouseUp, outside))
                try check(
                    model.sideTasks.contains(where: { $0.id == media.id }) && closingTitle.dragPreviewPanel != nil,
                    "Outside release plays dismissal before removing the card")
                try await pause()
                try check(
                    !model.sideTasks.contains(where: { $0.id == media.id })
                        && model.archivedTaskHistory.contains(where: { $0.id == media.id })
                        && closingTitle.dragPreviewPanel == nil,
                    "Dropping outside closes the owning task after animation and retains its history")
                var detachedDrops = 0
                let detached = WindowDragArea.DragView(frame: NSRect(x: 0, y: 0, width: 78, height: 28))
                detached.onOutsideDrop = { detachedDrops += 1 }
                detached.taskPreview = model.dragAppearance(media.id)
                shell.contentView!.addSubview(detached)
                detached.mouseDown(with: pointer(.leftMouseDown, start))
                detached.mouseDragged(with: pointer(.leftMouseDragged, outside))
                try await pause()
                if let screen = shell.screen {
                    let edge = NSPoint(x: screen.visibleFrame.maxX - 1, y: screen.visibleFrame.minY + 1)
                    detached.mouseDragged(with: pointer(.leftMouseDragged, edge))
                    try await pause()
                    try check(
                        detached.dragPreviewPanel.map { screen.visibleFrame.contains($0.frame) } == true,
                        "Drag preview and close hint remain visible at the screen edge")
                    detached.mouseDragged(with: pointer(.leftMouseDragged, outside))
                }
                detached.mouseUp(with: pointer(.leftMouseUp, outside))
                detached.removeFromSuperview()
                try await pause()
                try check(
                    detachedDrops == 1 && detached.dragPreviewPanel == nil,
                    "A source view replacement during dismissal cannot lose or duplicate the committed close")
                shell.contentView!.addSubview(detached)
                detached.mouseDown(with: pointer(.leftMouseDown, start))
                detached.mouseDragged(with: pointer(.leftMouseDragged, outside))
                detached.removeFromSuperview()
                detached.mouseUp(with: pointer(.leftMouseUp, outside))
                try await pause()
                try check(
                    detachedDrops == 1 && detached.dragPreviewPanel == nil,
                    "Removing the source before release cancels the uncommitted drag preview")
            } else {
                throw AppError.message("Compact outside-drop target missing")
            }
            if CommandLine.arguments.contains("--keep-open") {
                model.selectTask(media.id)
                model.collapse()
            }
            return checks
        }
    }
#endif
