import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    override convenience init() {
        #if DEBUG
            if let isolated = DebugHarness.pipelineModel() { self.init(model: isolated); return }
        #endif
        self.init(model: AppModel())
    }
    init(model: AppModel) { self.model = model; super.init() }
    var panel: ShellPanel!
    // Task details stay attached to the compact shell; command input is a separate panel.
    private var lastOrientation: CompactLayout?
    private var wasPinned = false
    private var lastContentSize: NSSize?
    var ambientFrame: NSRect { model.shellLayout.compact }
    // The compact strip's parking position is independent of expanded geometry.
    // Only an intentional window move (not resizing or fitting details) moves it.
    private var compactHome: NSRect?
    private var lastShowingWeb = false
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    weak var settingsOwner: AppModel?
    var commandPanel: ShellPanel?
    var previousApplication: NSRunningApplication?
    lazy var shortcut = GlobalShortcut { [weak self] in
        guard let self else { return }
        self.model.selectChat(!self.model.commandPanelVisible)
    }
    private var programmaticResizeCount = 0
    private var userResizeActive = false
    private var userMoveActive = false
    private var moveInterruptedAnimation = false
    private let shellMotion = CalmMotionDriver()
    private let stackFade = CalmMotionDriver()
    private let commandFade = CalmMotionDriver()
    private let commandResize = CalmMotionDriver()
    private let settingsFade = CalmMotionDriver()
    private var targetShellLayout: ShellLayout?
    private var targetCommandFrame: NSRect?
    private var finishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !finishedLaunching else { return }
        finishedLaunching = true
        #if DEBUG
            NSApp.setActivationPolicy(CommandLine.arguments.contains("--background-checks") ? .prohibited : .accessory)
            if DebugHarness.beforeWindows(self) { return }
        #else
            NSApp.setActivationPolicy(.accessory)
        #endif
        let size = model.compactSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel = ShellPanel(
            contentRect: NSRect(
                x: screen.maxX - size.width - 42, y: screen.maxY - size.height - 80,
                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Orvlet"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onMoveInteraction = { [weak self] in self?.windowMoveChanged($0) }
        let hosting = NSHostingView(rootView: ContentView(model: model))
        // The panel owns its size. Intrinsic hosting constraints otherwise fight animated shrinking.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerRadius = 9
        container.layer?.cornerCurve = .continuous
        container.addSubview(hosting)
        panel.contentView = container
        installDismissalMonitors()
        model.onParkCapsule = { [weak self] in self?.parkCapsuleInCorner() }
        model.onResize = { [weak self] size in self?.resize(to: size) }
        model.onStackOpacity = { [weak self] value in
            guard let self, !self.panel.ignoresMouseEvents else { return }
            self.fade(self.panel, to: value, using: self.stackFade, duration: value == 1 ? 0.12 : 0.25)
        }
        model.refreshStackAttention()
        model.onHide = { [weak self] in self?.showShell(false) }
        model.onShow = { [weak self] in self?.showShell(true) }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onSetup = { [weak self] in self?.showSetup() }
        model.onSetupModels = { [weak self] in self?.openSettings(tab: 2) }
        model.onCommandResize = { [weak self] _ in self?.resizeCommandPanel() }
        model.onCommandPanel = { [weak self] visible, restoreFocus in
            self?.showCommandPanel(visible, restoreFocus: restoreFocus)
        }
        model.onShortcutChanged = { [weak self] in self?.registerShortcut() }
        resize(to: model.windowSize)
        registerShortcut()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        #if DEBUG
            statusItem.autosaveName = DebugHarness.selected() == nil ? "OrvletMenuBar" : "OrvletTestMenuBar"
        #else
            statusItem.autosaveName = "OrvletMenuBar"
        #endif
        // The menu is the persistent entry point, including when all task windows are closed.
        statusItem.isVisible = true
        statusItem.button?.toolTip = "Orvlet"
        statusItem.button?.setAccessibilityLabel("Orvlet")
        let statusMark = NSImage(named: "StatusMark")
        statusMark?.isTemplate = true
        statusMark?.accessibilityDescription = "Orvlet"
        statusItem.button?.image = statusMark
        let menu = NSMenu()
        for (title, action, key) in [
            ("Ask Orvlet", #selector(askOrvlet), ""), ("Show cards", #selector(showPet), ""),
            ("Settings…", #selector(showSettings), ","),
            ("Quit Orvlet", #selector(quit), "q"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let item = self?.statusItem else { return }
            Diagnostics.record(
                "status_item",
                [
                    "visible": item.isVisible,
                    "imageLoaded": item.button?.image != nil,
                    "frame": NSStringFromRect(item.button?.window?.frame ?? .zero),
                    "screenFrame": NSStringFromRect(NSScreen.main?.frame ?? .zero),
                    "reasonCode": item.isVisible ? "registered" : "hidden",
                ])
        }
        #if DEBUG
            if DebugHarness.afterWindows(self) { return }
        #endif
        if model.settings.blockAds { Task { _ = try? await AdBlocker.ruleList() } }
        model.start()
        model.checkStartupReadiness()
        if !model.visibleTasks.isEmpty { showShell(true) }
    }

    func parkCapsuleInCorner(in visibleFrame: NSRect? = nil) {
        guard let panel, let screen = visibleFrame ?? panel.screen?.visibleFrame else { return }
        let corner = DockCorner(anchor: compactHome ?? panel.frame, screen: screen)
        compactHome = corner.align(model.compactSize, to: screen.insetBy(dx: 8, dy: 8))
    }

    func resize(to size: NSSize, in visibleFrame: NSRect? = nil) {
        guard let panel, !userResizeActive, !userMoveActive else { return }
        programmaticResizeCount += 1
        defer { programmaticResizeCount -= 1 }
        let compact = model.compactSize
        let home = compactHome ?? panel.frame
        let reference = model.compactRailTucked && model.shellLayout.edge != nil ? model.shellLayout.content : home
        let center = NSPoint(x: reference.midX, y: reference.midY)
        let screen = visibleFrame ?? NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame
            ?? panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let anchor = DockCorner(anchor: home, screen: screen).align(compact, to: home)
        if compactHome == nil { compactHome = anchor }
        let requested = model.shellContentSize
        var layout = ShellLayout.place(anchor: anchor, content: requested,
                                       orientation: model.settings.compactLayout, screen: screen)
        if model.compactRailTucked, let requested {
            let previous = targetShellLayout ?? model.shellLayout
            let card = previous.edge == nil ? layout.content : previous.content
            layout = ShellLayout.pinned(anchor: anchor, detail: card, size: requested, screen: screen,
                alignToCapsule: !wasPinned)
        } else if let target = targetShellLayout, model.shellExpanded, requested == lastContentSize,
           lastShowingWeb == model.showingWeb, lastOrientation == model.settings.compactLayout,
           target.edge == layout.edge, target.corner == layout.corner,
           target.frame.width <= screen.width - 16, target.frame.height <= screen.height - 16,
           target.compact.size == compact, (target.compactViewport != nil) == model.compactRailTucked {
            // A refresh after live resize must keep the exact frame the person released.
            layout = target.fitting(screen)
        }
        let stayingPinned = wasPinned && model.compactRailTucked
        wasPinned = model.compactRailTucked
        lastShowingWeb = model.showingWeb
        lastOrientation = model.settings.compactLayout
        lastContentSize = requested
        let minimum: NSSize
        if model.showingWeb && !model.taskShelfVisible {
            panel.styleMask.insert(.resizable)
            let chrome = layout.chromeSize
            minimum = NSSize(
                width: max(min(AppModel.minimumWebSize.width, layout.content.width) + chrome.width, layout.presentedCompact.width),
                height: max(
                    min(AppModel.minimumWebSize.height, model.windowSize.height) + chrome.height
                        + (model.feedback == nil ? 0 : model.feedbackSize.height), layout.presentedCompact.height))
        } else {
            panel.styleMask.remove(.resizable)
            minimum = NSSize(width: 44, height: 30)
        }
        if targetShellLayout != layout || (!shellMotion.isRunning && panel.frame != layout.frame) {
            let start = model.shellLayout
            targetShellLayout = layout
            let duration =
                model.motionReduced || !panel.isVisible || (stayingPinned && !shellMotion.isRunning)
                ? 0 : (layout.edge == nil ? CalmMotion.collapse : CalmMotion.expand)
            // AppKit enforces minSize immediately. Install the webpage minimum once the
            // transition lands so opening from a small card has no initial size jump.
            panel.minSize = NSSize(width: 44, height: 30)
            if duration > 0 { applyShellLayout(layout.transitioning(from: start, progress: 0)) }
            shellMotion.run(
                duration: duration, window: panel,
                update: { [weak self] t in
                    self?.applyShellLayout(layout.transitioning(from: start, progress: t))
                }, completion: { [weak panel] in panel?.minSize = minimum })
        } else if !shellMotion.isRunning {
            panel.minSize = minimum
        }
        panel.hasShadow = true
        panel.contentView?.layer?.cornerRadius = 16
    }

    private func applyShellLayout(_ layout: ShellLayout) {
        programmaticResizeCount += 1
        defer { programmaticResizeCount -= 1 }
        if panel.frame != layout.frame { panel.setFrame(layout.frame, display: true) }
        // AppKit rounds animated window frames to screen pixels. Track the
        // actual frame so a subsequent user drag cannot accumulate that rounding
        // error into the compact anchor (one pixel per interrupt otherwise).
        var displayed = layout
        displayed.frame = panel.frame
        if model.shellLayout != displayed { model.shellLayout = displayed }
    }
    private func fade(
        _ window: NSWindow, to opacity: Double, using driver: CalmMotionDriver,
        duration: TimeInterval, completion: @escaping () -> Void = {}
    ) {
        let start = window.alphaValue
        driver.run(
            duration: model.motionReduced ? 0 : duration, window: window,
            update: { t in
                window.alphaValue = start + (opacity - start) * t
            }, completion: completion)
    }
    private func showShell(_ visible: Bool) {
        if visible {
            guard !panel.isVisible || panel.ignoresMouseEvents else { return }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            fade(panel, to: model.stackOpacity, using: stackFade, duration: CalmMotion.content)
        } else {
            panel.ignoresMouseEvents = true
            fade(panel, to: 0, using: stackFade, duration: CalmMotion.content) { [weak self] in
                self?.panel.orderOut(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { (settingsOwner ?? model).setupDismissed = true }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { model.stackHasKeyboardFocus = true }
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { model.stackHasKeyboardFocus = false }
    }

    func windowMoveChanged(_ active: Bool) {
        userMoveActive = active
        if active {
            moveInterruptedAnimation = shellMotion.isRunning
            shellMotion.cancel()
            if moveInterruptedAnimation { targetShellLayout = nil }
        } else {
            // AppKit may deliver the last move notification after mouse-up.
            synchronizeWindowMove()
            moveInterruptedAnimation = false
        }
        model.controlInteraction(active)
        if !active { model.onResize?(model.windowSize) }
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, programmaticResizeCount == 0, !userResizeActive else {
            return
        }
        synchronizeWindowMove()
    }

    private func synchronizeWindowMove() {
        let delta = NSPoint(
            x: panel.frame.minX - model.shellLayout.frame.minX, y: panel.frame.minY - model.shellLayout.frame.minY)
        guard delta != .zero else { return }
        let wasAnimating = shellMotion.isRunning
        shellMotion.cancel()
        if model.shellExpanded, let home = compactHome {
            compactHome = home.offsetBy(dx: delta.x, dy: delta.y)
        }
        var layout = model.shellLayout.translated(x: delta.x, y: delta.y)
        layout.frame = panel.frame
        model.shellLayout = layout
        targetShellLayout = wasAnimating || moveInterruptedAnimation ? nil : layout
        if !model.shellExpanded { compactHome = layout.compact }
        if wasAnimating { resize(to: model.windowSize) }
    }

    func dismissDetails(at point: NSPoint) {
        guard !model.menuTracking, !model.sourceIsFullscreen else { return }
        if model.commandPanelVisible {
            if commandPanel?.frame.contains(point) == true { return }
            model.selectChat(false, restoreFocus: false)
        }
        guard !panel.frame.contains(point) else { return }
        model.taskShelfVisible = false
        if !model.pinned { model.collapse() }
    }

    private func installDismissalMonitors() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseUp {
                    self.panel.moveInteraction(false)
                    return
                }
                WindowDragArea.DragView.cancelPendingClicks()
                guard !self.model.isLiveTest else { return }
                self.dismissDetails(at: NSEvent.mouseLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .leftMouseUp, .keyDown,
        ]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                self.panel.moveInteraction(false)
                return event
            }
            // A second click, another control, Escape or an outside action owns
            // the next interaction; never replay a delayed click after it.
            WindowDragArea.DragView.cancelPendingClicks()
            if event.type == .keyDown {
                if event.window === self.panel && event.keyCode == 53 {
                    if self.model.sourceIsFullscreen { self.model.activeWindowPlayer?.exit(); return nil }
                    if self.model.editingWebAddress { return event }
                }
                if let input = self.commandPanel, event.window === input,
                    event.keyCode == 36 || event.keyCode == 76,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
                    let editor = input.firstResponder as? NSTextView, editor.isEditable, !editor.hasMarkedText()
                {
                    if !event.isARepeat { self.model.sendCommand(forceNewTask: true) }
                    return nil
                }
                if event.window === self.commandPanel,
                    event.keyCode == 53
                        || (event.charactersIgnoringModifiers?.lowercased() == "w"
                            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command)
                {
                    self.model.selectChat(false)
                    return nil
                }
                if event.window === self.panel, event.charactersIgnoringModifiers?.lowercased() == "w",
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                {
                    if self.model.taskShelfVisible {
                        self.model.taskShelfVisible = false
                    } else if !self.model.collapsed, let id = self.model.selectedTaskID {
                        self.model.closeTask(id)
                    } else {
                        self.model.hide()
                    }
                    return nil
                }
                if event.keyCode == 53, event.window === self.panel,
                    let drag = self.panel.firstResponder as? WindowDragArea.DragView, drag.didDrag
                {
                    drag.keyDown(with: event)
                    return nil
                }
                if event.keyCode == 53, event.window === self.panel {
                    if self.model.taskShelfVisible {
                        self.model.taskShelfVisible = false
                    } else {
                        self.model.collapse()
                    }
                    return nil
                }
            } else {
                if self.model.commandPanelVisible && event.window !== self.commandPanel {
                    self.model.selectChat(false, restoreFocus: false)
                }
                if event.window !== self.panel && event.window !== self.commandPanel {
                    self.dismissDetails(at: NSEvent.mouseLocation)
                }
            }
            return event
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, programmaticResizeCount == 0,
              model.showingWeb, !model.taskShelfVisible else { return }
        if shellMotion.isRunning, let target = targetShellLayout {
            shellMotion.cancel()
            model.shellLayout = target.resized(to: panel.frame)
        }
        targetShellLayout = nil
        userResizeActive = true
        model.controlInteraction(true)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, userResizeActive else { return }
        synchronizeLiveResize()
        let content = model.shellLayout.content
        model.rememberWebSize(
            NSSize(
                width: content.width, height: content.height - (model.feedback == nil ? 0 : model.feedbackSize.height)))
        lastContentSize = model.shellContentSize
        userResizeActive = false
        model.controlInteraction(false)
        model.onResize?(model.windowSize)
    }
    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, userResizeActive, programmaticResizeCount == 0 else { return }
        synchronizeLiveResize()
    }
    private func synchronizeLiveResize() {
        let layout = model.shellLayout.resized(to: panel.frame)
        model.shellLayout = layout
        targetShellLayout = layout
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.systemBrowserHost.isRunning || NativeChromium.running else { return .terminateNow }
        Task {
            await model.systemBrowserHost.shutdown()
            await model.nativeBrowserHost.shutdown()
            NativeChromium.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        model.readinessTask?.cancel()
        model.connectionCheckTask?.cancel()
        model.saveSession(force: true)
        model.persistSideTasks()
        model.handoffSource?.close()
        for browser in model.liveBrowsers { browser.dispose() }
        model.systemBrowserHost.stop()
        model.nativeBrowserHost.stop()
        shortcut.unregister()
    }
    func registerShortcut() {
        model.shortcutStatus =
            shortcut.register(model.settings.shortcut) ? "Ready" : "Shortcut is in use. Choose another combination."
    }
    @objc func askOrvlet() { model.selectChat(true) }
    @objc func openNativeAddress() { model.requestAddress() }
    private func makeCommandPanel() -> ShellPanel {
        let window = ShellPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: model.commandWindowHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Ask Orvlet"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: CommandWindowView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        return window
    }
    func resizeCommandPanel() {
        guard let window = commandPanel else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(model.commandWindowHeight, screen.height - 32)
        let frame = NSRect(
            x: min(max(window.frame.minX, screen.minX + 16), screen.maxX - 440 - 16),
            y: min(max(window.frame.maxY - height, screen.minY + 16), screen.maxY - height - 16), width: 440,
            height: height)
        guard targetCommandFrame != frame || (!commandResize.isRunning && window.frame != frame) else { return }
        targetCommandFrame = frame
        let start = window.frame
        commandResize.run(
            duration: model.motionReduced || !window.isVisible ? 0 : CalmMotion.expand, window: window,
            update: { t in
                window.setFrame(CalmMotion.blend(start, frame, t), display: true)
            })
    }
    func showCommandPanel(_ visible: Bool, restoreFocus: Bool = true) {
        if visible {
            if previousApplication == nil { previousApplication = NSWorkspace.shared.frontmostApplication }
            let fresh = commandPanel == nil
            if fresh { commandPanel = makeCommandPanel() }
            guard let window = commandPanel else { return }
            let screen =
                NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
                ?? NSScreen.main!.visibleFrame
            if fresh || !NSScreen.screens.contains(where: { window.frame.intersects($0.visibleFrame) }) {
                window.setFrameOrigin(
                    NSPoint(
                        x: screen.midX - window.frame.width / 2,
                        y: screen.midY + screen.height * 0.12 - window.frame.height / 2))
            }
            model.commandPanelVisible = true
            model.chatVisible = true
            resizeCommandPanel()
            if !window.isVisible { window.alphaValue = 0 }
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
            fade(window, to: 1, using: commandFade, duration: CalmMotion.content)
            model.commandFocusRequest += 1
        } else {
            model.commandPanelVisible = false
            model.chatVisible = false
            if let window = commandPanel {
                window.ignoresMouseEvents = true
                window.resignKey()
                fade(window, to: 0, using: commandFade, duration: CalmMotion.content) { window.orderOut(nil) }
            }
            if restoreFocus, let previousApplication,
                previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
            {
                previousApplication.activate(options: [])
            }
            previousApplication = nil
        }
    }

    @objc func showPet() { showShell(true) }
    @objc func quit() { NSApp.terminate(nil) }
    func showSetup(for previewModel: AppModel? = nil) {
        let owner = previewModel ?? model
        owner.setupDismissed = false
        openSettings(tab: 3, for: owner)
    }
    @objc func showSettings() { openSettings(tab: 0) }
    func openSettings(tab: Int, for previewModel: AppModel? = nil) {
        let owner = previewModel ?? model
        let ownerChanged = settingsOwner !== owner
        settingsOwner = owner
        owner.settingsTabRequested = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 710),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Orvlet Settings"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: owner, initialTab: tab))
            window.center()
            settingsWindow = window
        }
        if let window = settingsWindow, !window.isVisible || ownerChanged {
            window.contentView = NSHostingView(rootView: SettingsView(model: owner, initialTab: tab))
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            if !window.isVisible { window.alphaValue = 0 }
            window.makeKeyAndOrderFront(nil)
            fade(window, to: 1, using: settingsFade, duration: CalmMotion.content)
        }
    }
}
