import SwiftUI
import AppKit
import QuartzCore

@main
struct OrvletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Open address…") { delegate.model.requestAddress() }.keyboardShortcut("l", modifiers: .command)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PetModel()
    var panel: PetPanel!
    // Task details stay attached to the compact shell; command input is a separate panel.
    var detailPanel: PetPanel! { panel }
    private var detailEdge: DetailEdge?
    private var lastOrientation: CompactLayout?
    private var lastContentSize: NSSize?
    var ambientFrame: NSRect { model.shellLayout.compact }
    private var compactAnchor: NSPoint?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var commandPanel: PetPanel?
    var previousApplication: NSRunningApplication?
    lazy var shortcut = GlobalShortcut { [weak self] in
        guard let self else { return }
        self.model.selectChat(!self.model.commandPanelVisible)
    }
    private var programmaticResizeCount = 0
    private var userResizeActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        let liveChecks = ["--calendar-check", "--clock-check", "--conversation-check", "--scenario-check", "--live-check"]
        if liveChecks.contains(where:CommandLine.arguments.contains), !CommandLine.arguments.contains("--allow-live-services") {
            fputs("Live checks use public websites and may send observations to your configured model provider. Re-run with --allow-live-services to opt in.\n",stderr)
            exit(2)
        }
        if CommandLine.arguments.contains("--calendar-check") {
            Task { await CalendarCheck.run(model) }
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            Task { await SelfCheck.run(model: model) }
            return
        }
        #endif
        let size = model.compactSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel = PetPanel(contentRect: NSRect(x: screen.maxX - size.width - 42, y: screen.maxY - size.height - 80,
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
        model.onResize = { [weak self] size in self?.resize(to: size) }
        model.onStackOpacity = { [weak self] value in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.model.settings.reduceMotion ? 0 : (value == 1 ? 0.12 : 0.25)
                self.panel.animator().alphaValue = value
            }
        }
        model.refreshStackAttention()
        model.onHide = { [weak self] in self?.panel.orderOut(nil) }
        model.onShow = { [weak self] in self?.panel.orderFrontRegardless() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onCommandResize = { [weak self] _ in self?.resizeCommandPanel() }
        model.onCommandPanel = { [weak self] visible, restoreFocus in self?.showCommandPanel(visible,restoreFocus:restoreFocus) }
        model.onFocusDetails = { [weak self] in self?.detailPanel.makeKeyAndOrderFront(nil) }
        model.onShortcutChanged = { [weak self] in self?.registerShortcut() }
        resize(to:model.windowSize)
        registerShortcut()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hexagon", accessibilityDescription: "Orvlet")
        let menu = NSMenu()
        for (title, action, key) in [("Ask Orvlet", #selector(askOrvlet), ""), ("Show cards", #selector(showPet), ""),
                                    ("Settings…", #selector(showSettings), ","),
                                    ("Quit Orvlet", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        #if DEBUG
        if CommandLine.arguments.contains("--listening-check") {
            Task { await ListeningCheck.run(model,delegate:self) }; return
        }
        if CommandLine.arguments.contains("--protection-check") {
            Task { await ProtectionCheck.run(model,delegate:self) }; return
        }
        if CommandLine.arguments.contains("--command-window-check") {
            Task { await CommandWindowCheck.run(model,delegate:self) }
            return
        }
        if CommandLine.arguments.contains("--clock-check") {
            Task { await ClockCheck.run(model,delegate:self) }
            return
        }
        if CommandLine.arguments.contains("--preparation-check") {
            model.isLiveTest = true; model.persistHistory = false; model.settings.autoAdapt = false; model.settings.appearance = .light
            Task {
                do {
                    let checks = try await PreparationCheck.run(model,delegate:self)
                    try JSONSerialization.data(withJSONObject:["ok":true,"checks":checks],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-preparation-checks.json"))
                    exit(0)
                } catch {
                    try? JSONSerialization.data(withJSONObject:["ok":false,"error":error.localizedDescription],options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-preparation-checks.json"))
                    exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--side-screen-check") {
            Task { await SideScreenCheck.run(model, delegate:self) }
            return
        }
        if CommandLine.arguments.contains("--conversation-check") {
            Task { await ConversationCheck.run(model) }
            return
        }
        if CommandLine.arguments.contains("--scenario-check") {
            Task { await ScenarioCheck.run(model, delegate:self) }
            return
        }
        if CommandLine.arguments.contains("--layout-check") {
            Task { await LiveCheck.layout(model) }
            return
        }
        if CommandLine.arguments.contains("--live-check") {
            model.settings.allowAgents = false
            Task { await LiveCheck.run(model) }
            return
        }
        #endif
        if model.settings.blockAds { Task { _ = try? await AdBlocker.ruleList() } }
        model.start()
        if !model.visibleTasks.isEmpty { panel.orderFrontRegardless() }
        if !model.settings.main.isConfigured { showCommandPanel(true) }
    }

    func resize(to size: NSSize) {
        guard let panel, !userResizeActive else { return }
        programmaticResizeCount += 1
        defer { programmaticResizeCount -= 1 }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let compact = model.compactSize
        let origin = compactAnchor ?? NSPoint(x:panel.frame.minX,y:panel.frame.maxY)
        compactAnchor = origin
        let anchor = NSRect(x:min(max(screen.minX+8,origin.x),screen.maxX-compact.width-8),
                            y:min(max(screen.minY+8,origin.y-compact.height),screen.maxY-compact.height-8),
                            width:compact.width,height:compact.height)
        if !model.shellExpanded || lastOrientation != model.settings.compactLayout { detailEdge = nil }
        lastOrientation = model.settings.compactLayout
        let requested = model.shellContentSize
        var layout = ShellLayout.place(anchor:anchor,content:requested,orientation:model.settings.compactLayout,screen:screen,edge:detailEdge)
        if model.shellExpanded, requested == lastContentSize, model.shellLayout.compact == anchor,
           model.shellLayout.edge == detailEdge {
            // Moving the whole shell also moves its internal anchor; a data refresh must not realign it.
            layout = model.shellLayout
        }
        lastContentSize = requested
        detailEdge = layout.edge
        if model.showingWeb && !model.taskShelfVisible {
            panel.styleMask.insert(.resizable)
            let vertical = layout.edge == .left || layout.edge == .right
            panel.minSize = NSSize(width:PetModel.minimumWebSize.width + (vertical ? compact.width : 0),height:PetModel.minimumWebSize.height + (vertical ? 0 : compact.height))
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width:44,height:30)
        }
        if model.shellLayout != layout { model.shellLayout = layout }
        if panel.frame != layout.frame { panel.setFrame(layout.frame,display:true) }
        panel.hasShadow = true
        panel.contentView?.layer?.cornerRadius = 16
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { model.stackHasKeyboardFocus = true }
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { model.stackHasKeyboardFocus = false }
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, programmaticResizeCount == 0, !userResizeActive else { return }
        let delta = NSPoint(x:panel.frame.minX-model.shellLayout.frame.minX,y:panel.frame.minY-model.shellLayout.frame.minY)
        var layout = model.shellLayout
        layout.frame = panel.frame
        layout.compact.origin.x += delta.x; layout.compact.origin.y += delta.y
        if layout.edge != nil { layout.content.origin.x += delta.x; layout.content.origin.y += delta.y }
        model.shellLayout = layout
        compactAnchor = NSPoint(x:layout.compact.minX,y:layout.compact.maxY)
    }

    func dismissDetails(at point: NSPoint) {
        guard !model.menuTracking else { return }
        if model.commandPanelVisible {
            if commandPanel?.frame.contains(point) == true { return }
            model.selectChat(false,restoreFocus:false)
        }
        guard !panel.frame.contains(point) else { return }
        model.taskShelfVisible = false
        if !model.pinned { model.collapse() }
    }

    private func installDismissalMonitors() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.isLiveTest else { return }
                self.dismissDetails(at:NSEvent.mouseLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.window === self.commandPanel,
                   event.keyCode == 53 || (event.charactersIgnoringModifiers?.lowercased() == "w" && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command) {
                    self.model.selectChat(false)
                    return nil
                }
                if event.window === self.panel, event.charactersIgnoringModifiers?.lowercased() == "w",
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    if self.model.taskShelfVisible { self.model.taskShelfVisible = false }
                    else if !self.model.collapsed, let id = self.model.selectedTaskID { self.model.closeTask(id) }
                    else { self.model.hide() }
                    return nil
                }
                if event.keyCode == 53, event.window === self.panel {
                    if self.model.taskShelfVisible { self.model.taskShelfVisible = false }
                    else { self.model.collapse() }
                    return nil
                }
            } else {
                if self.model.commandPanelVisible && event.window !== self.commandPanel { self.model.selectChat(false,restoreFocus:false) }
                if event.window !== self.panel && event.window !== self.commandPanel { self.dismissDetails(at:NSEvent.mouseLocation) }
            }
            return event
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, programmaticResizeCount == 0 else { return }
        userResizeActive = true; model.controlInteraction(true)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, userResizeActive else { return }
        userResizeActive = false
        let old = model.shellLayout
        let vertical = old.edge == .left || old.edge == .right
        let size = NSSize(width:panel.frame.width-(vertical ? model.compactSize.width : 0),height:panel.frame.height-(vertical ? 0 : model.compactSize.height))
        var anchor = old.compact
        if old.edge == .left { anchor.origin.x = panel.frame.maxX-anchor.width }
        else { anchor.origin.x = panel.frame.minX }
        if old.edge == .above { anchor.origin.y = panel.frame.minY }
        else { anchor.origin.y = panel.frame.maxY-anchor.height }
        compactAnchor = NSPoint(x:anchor.minX,y:anchor.maxY)
        model.rememberWebSize(size)
        resize(to:model.windowSize); model.controlInteraction(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        model.saveSession(force:true); model.persistSideTasks(); shortcut.unregister()
    }
    func registerShortcut() {
        model.shortcutStatus = shortcut.register(model.settings.shortcut) ? "Ready" : "Shortcut is in use. Choose another combination."
    }
    @objc func askOrvlet() { model.selectChat(true) }
    private func makeCommandPanel() -> PetPanel {
        let window = PetPanel(contentRect:NSRect(x:0,y:0,width:440,height:model.commandWindowHeight),
                              styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.title = "Ask Orvlet"
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.isMovableByWindowBackground = false; window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView:CommandWindowView(model:model))
        hosting.sizingOptions = []; hosting.autoresizingMask = [.width,.height]
        window.contentView = hosting
        return window
    }
    func resizeCommandPanel() {
        guard let window = commandPanel else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(model.commandWindowHeight,screen.height-32)
        let frame = NSRect(x:min(max(window.frame.minX,screen.minX+16),screen.maxX-440-16),
                           y:min(max(window.frame.maxY-height,screen.minY+16),screen.maxY-height-16),width:440,height:height)
        if window.frame != frame { window.setFrame(frame,display:true) }
    }
    func showCommandPanel(_ visible: Bool, restoreFocus: Bool = true) {
        if visible {
            if previousApplication == nil { previousApplication = NSWorkspace.shared.frontmostApplication }
            let fresh = commandPanel == nil
            if fresh { commandPanel = makeCommandPanel() }
            guard let window = commandPanel else { return }
            let screen = NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)})?.visibleFrame ?? NSScreen.main!.visibleFrame
            if fresh || !window.frame.intersects(screen) {
                window.setFrameOrigin(NSPoint(x:screen.midX-window.frame.width/2,y:screen.midY+screen.height*0.12-window.frame.height/2))
            }
            model.commandPanelVisible = true; model.chatVisible = true
            resizeCommandPanel()
            window.makeKeyAndOrderFront(nil)
            model.commandFocusRequest += 1
        } else {
            model.commandPanelVisible = false; model.chatVisible = false
            commandPanel?.orderOut(nil)
            if restoreFocus, let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication.activate(options:[])
            }
            previousApplication = nil
        }
    }

    @objc func showPet() { panel.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 710),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Orvlet"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
