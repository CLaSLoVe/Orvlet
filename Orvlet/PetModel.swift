import SwiftUI
import WebKit
import Combine

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var url: String
    var kind: String
}
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

@MainActor
final class PetModel: ObservableObject {
    @Published var shellLayout = ShellLayout(frame:NSRect(x:0,y:0,width:110,height:32),compact:NSRect(x:0,y:0,width:110,height:32),content:.zero,edge:nil)
    @Published var hasUnreadReply = false
    var backgroundRequest = false
    @Published var taskShelfVisible = false {
        didSet {
            if taskShelfVisible && commandPanelVisible { selectChat(false,restoreFocus:false) }
            onResize?(windowSize)
            if taskShelfVisible { onShow?() }
            refreshStackAttention()
        }
    }
    var shellExpanded: Bool { taskShelfVisible || !collapsed }
    var shellContentSize: NSSize? {
        if taskShelfVisible { return NSSize(width:320,height:380) }
        return collapsed ? nil : windowSize
    }
    @Published var sideTasks: [SideTask] = []
    @Published var selectedTaskID: UUID?
    @Published var commandPanelVisible = false { didSet { refreshStackAttention() } }
    @Published var browserRevision = 0
    var parkedBrowsers: [UUID:BrowserController] = [:]
    var taskClock: Timer?
    var decoratingTasks: Set<UUID> = []
    var requestReceivedAt = Date()
    @Published var shortcutStatus = "Ready"
    var onShortcutChanged: (() -> Void)?
    var onCommandResize: ((Double) -> Void)?
    var onCommandPanel: ((Bool, Bool) -> Void)?
    var onFocusDetails: (() -> Void)?
    @Published var surface = SurfacePlan.empty
    @Published var collapsed = true { didSet { refreshStackAttention() } }
    var clickExpanded = false
    var menuTracking = false { didSet { refreshStackAttention() } }
    @Published var chatVisible = false // Composer focus; the webpage remains visible.
    @Published var commandFocusRequest = 0
    @Published var addressFocusRequest = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var webExpanded = false
    @Published private(set) var preferredWebSize = NSSize(width: 320, height: 220)
    let preferences: UserDefaults
    lazy var sessions = SessionStore(defaults: preferences)
    @Published var recentSessions: [SavedSession] = []
    @Published var restoringSession = false
    private var restoreTask: Task<Void,Never>?
    private var restoreRevision = 0
    private var lastSessionSave = Date.distantPast
    private var queuedRestoreAction: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        preferences = defaults
        if let saved = defaults.dictionary(forKey: "webWindowSize"),
           let w = saved["width"] as? Double, let h = saved["height"] as? Double, w.isFinite, h.isFinite {
            preferredWebSize = Self.boundedWebSize(NSSize(width: w, height: h))
        }
    }
    static let minimumWebSize = NSSize(width: 280, height: 200)
    static func boundedWebSize(_ size: NSSize) -> NSSize {
        NSSize(width: min(10000, max(minimumWebSize.width, size.width)), height: min(10000, max(minimumWebSize.height, size.height)))
    }
    var showingWeb: Bool { !collapsed && webExpanded }
    func rememberWebSize(_ size: NSSize) {
        guard showingWeb, size.width.isFinite, size.height.isFinite else { return }
        preferredWebSize = Self.boundedWebSize(size)
        if !isLiveTest { preferences.set(["width": preferredWebSize.width, "height": preferredWebSize.height], forKey: "webWindowSize") }
    }
    func toggleWebPin() {
        pinned.toggle()
    }
    @Published var isPlaying = false
    @Published var hasMedia = false
    @Published var mediaType = ""
    @Published var volume: Double = 1
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var webTitle = ""
    @Published var webURL = ""
    @Published var webLoading = false
    @Published var webError: String?
    @Published var command = ""
    @Published var messages: [ChatMessage] = []
    @Published var busy = false { didSet { refreshHover() } }
    @Published var activity = ""
    @Published var requestCardID: UUID?
    var requestPageID: UUID?
    @Published var ambientRequestID: UUID?
    @Published var buildingSurface = false
    @Published var surfaceOrigin = ""
    @Published var pinned = false { didSet { refreshHover() } }
    @Published var history: [HistoryEntry] = []
    @Published var settings = ModelSettings.load() {
        didSet {
            if oldValue.inactiveStackOpacity != settings.inactiveStackOpacity { onStackOpacity?(stackOpacity) }
            if oldValue.blockAds != settings.blockAds {
                for browser in liveBrowsers { Task { await browser.configureAdBlocking() } }
            }
        }
    }
    @Published var adBlockingError: String?
    @Published private(set) var stackDimmed = false { didSet { onStackOpacity?(stackOpacity) } }
    var stackHasKeyboardFocus = false { didSet { refreshStackAttention() } }
    private var stackAttentionTask: Task<Void,Never>?
    var onStackOpacity: ((Double) -> Void)?
    var stackOpacity: Double { stackDimmed ? min(1,max(0.1,settings.inactiveStackOpacity)) : 1 }
    private var stackNeedsAttention: Bool { pointerInside || shellExpanded || commandPanelVisible || menuTracking || activeInteractions > 0 || stackHasKeyboardFocus }
    func refreshStackAttention() {
        stackAttentionTask?.cancel(); stackAttentionTask = nil
        if stackNeedsAttention { stackDimmed = false; return }
        guard !stackDimmed else { return }
        stackAttentionTask = Task { [weak self] in
            do {
                try await Task.sleep(for:.seconds(3))
                guard let self, !self.stackNeedsAttention else { return }
                self.stackDimmed = true
            } catch { }
        }
    }
    @Published var bridgeStatus = ""
    @Published var browserConnected = false
    @Published var externalBrowser = false
    @Published var pointerInside = false
    private var previewHovered = false
    @Published var backgroundListening = false
    private var hoverTask: Task<Void, Never>?
    private var activeInteractions = 0
    @Published var lastActionError: String?
    var persistHistory = true
    var isLiveTest = false
    var taskFailed = false
    var latestIntent = ""
    var lastInteraction = ""
    var hasCustomSurface = false
    var accent: Color { settings.theme.color }
    var lastObservation: [String: Any] = [:]
    var trackTitle: String { webTitle.isEmpty ? "Orvlet" : webTitle }
    // The same validated, cached component plan supplies the compact interface.
    // Presentation is bounded here; actions remain grounded in the page, not in site/mode presets.
    var compactActions: [SurfaceAction] {
        let actions = surface.components.filter { [.transport, .buttons, .list].contains($0.kind) }.flatMap { $0.actions ?? [] }
        if actions.isEmpty && hasMedia && surface.components.contains(where: { $0.kind == .media }) {
            return [SurfaceAction(label: "Play / Pause", icon: "playpause.fill", binding: PageBinding(action: "media", operation: "toggle"))]
        }
        return Array(actions.prefix(2))
    }
    var compactInput: SurfaceComponent? { surface.components.first { $0.kind == .input } }
    var compactCaption: String {
        if surface.components.contains(where: { $0.kind == .media }) { return trackTitle }
        return surface.components.first(where: { $0.kind == .text })?.label ?? surface.title ?? trackTitle
    }
    var compactSize: NSSize { settings.compactLayout == .vertical ? NSSize(width:136,height:40 + 38 * ambientTasks.count) : NSSize(width:microWidth,height:44) }
    var windowSize: NSSize {
        if showingWeb { return preferredWebSize }
        let card = selectedSideTask
        if collapsed { return compactSize }
        return NSSize(width:328,height:(card?.presentation.height ?? 140) + 30)
    }
    var commandWindowHeight: Double {
        let resultHeight: Double
        if busy { resultHeight = 42 }
        else if let message = messages.last(where: { !$0.isUser }) { resultHeight = min(110,max(52,Double(message.text.count / 65 + 1) * 20 + 28)) }
        else { resultHeight = 52 }
        return 66 + resultHeight + 34
    }
    var onResize: ((NSSize) -> Void)?
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?
    var onSettings: (() -> Void)?
    var agentTask: Task<Void, Never>?
    private var agentStopping = false
    private var messagesAfterStop: [String] = []
    lazy var browser = BrowserController(model: self)
    lazy var agent = AgentController(model: self)
    lazy var calendarService = CalendarService()
    lazy var bridge = LocalBridge(model: self)
    lazy var adaptive = AdaptiveSurfaceEngine(model: self)
    func start() {
        loadSideTasks()
        if let data = preferences.data(forKey: "history"), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) { history = saved }
        if sessions.entries.isEmpty {
            var seen = Set<String>()
            let recent = history.filter { seen.insert($0.url).inserted }.prefix(24)
            for entry in recent.reversed() {
                let plan = SurfaceCache.pageKey(entry.url).flatMap { adaptive.cache.get($0) }
                sessions.put(SavedSession(url:entry.url,title:entry.title,plan:plan,mediaType:entry.kind == "web" ? "" : entry.kind,updated:entry.date))
            }
        }
        recentSessions = sessions.entries
        if settings.allowAgents { bridge.start() }
        if settings.restoreLastSession, let previous = recentSessions.first {
            restoreSession(previous, play: settings.resumePlaybackOnLaunch && previous.wasPlaying)
        }
    }
    func install(_ plan: SurfacePlan, automatic: Bool = false) {
        if automatic && (pinned || !settings.autoAdapt) { return }
        var next = plan
        if automatic && backgroundListening { next.components.removeAll { $0.kind == .web } }
        guard !next.components.isEmpty || next.markup != nil else { return }
        let previousSize = windowSize
        withAnimation(.easeOut(duration: 0.16)) { surface = next.compacted() }
        if windowSize != previousSize { onResize?(windowSize) }
        saveSession(force: true)
        if !busy { upsertWebTask(next) }
        let owner = browser
        Task { try? await owner.bindReadings(next.readings ?? []) }
    }
    // Click expands; pointer exit collapses locally, independent of model/Jev latency.
    func beginBackgroundListening() {
        backgroundListening = true
        if !pinned {
            var controls = surface
            controls.components.removeAll { $0.kind == .web }
            if controls.components.isEmpty && controls.markup == nil {
                controls = SurfacePlan(components: [SurfaceComponent(kind: .media), SurfaceComponent(kind: .transport, actions: [SurfaceAction(label: "Play / Pause", icon: "playpause.fill", binding: PageBinding(action: "media", operation: "toggle"))])], width: 280, height: 120)
            }
            install(controls)
            if !backgroundRequest && !pointerInside && !chatVisible { collapse() }
        }
        refreshHover()
        saveSession(force:true)
    }
    func endBackgroundListening(clearTaskIntent: Bool = false) {
        backgroundListening = false
        if clearTaskIntent, let i = sideTasks.firstIndex(where: { $0.id == browser.id }) { sideTasks[i].listening = false }
        refreshHover()
    }
    func pointerChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        refreshStackAttention()
        if !inside { previewHovered = false }
        refreshHover()
    }
    func previewHoverChanged(_ inside: Bool) {
        previewHovered = inside
        refreshHover()
    }
    func controlInteraction(_ active: Bool) {
        activeInteractions = max(0, activeInteractions + (active ? 1 : -1))
        refreshStackAttention()
        refreshHover()
    }
    #if DEBUG
    var pressedMouseButtonsOverride: Int?
    #endif
    private var pressedMouseButtons: Int {
        #if DEBUG
        if let pressedMouseButtonsOverride { return pressedMouseButtonsOverride }
        #endif
        return NSEvent.pressedMouseButtons
    }
    func refreshHover() {
        hoverTask?.cancel(); hoverTask = nil
        guard !pinned, !chatVisible, !clickExpanded else { return }
        let entering = pointerInside
        if entering {
            guard settings.expandOnHover, previewHovered, collapsed, !webURL.isEmpty, activeInteractions == 0 else { return }
        } else { guard !collapsed else { return } }
        hoverTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(entering ? 160 : 260))
                guard let self else { return }
                while !entering && (self.activeInteractions > 0 || self.pressedMouseButtons != 0) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard !self.pinned, !self.chatVisible,
                      self.pointerInside == entering else { return }
                if entering {
                    guard self.settings.expandOnHover, self.previewHovered, self.activeInteractions == 0, self.pressedMouseButtons == 0 else { return }
                    self.reveal(preview:true)
                } else { self.collapse() }
            } catch { }
        }
    }
    func reveal(preview: Bool = false) {
        hoverTask?.cancel(); clickExpanded = !preview
        collapsed = false; webExpanded = selectedSideTask?.opensSourceByDefault == true
        onResize?(windowSize); onShow?()
    }
    func collapse() {
        taskShelfVisible = false
        pinned = false; clickExpanded = false; hoverTask?.cancel()
        collapsed = true; webExpanded = false
        onResize?(windowSize)
    }
    func selectChat(_ value: Bool, restoreFocus: Bool = true) {
        commandPanelVisible = value; chatVisible = value
        if value {
            hasUnreadReply = false
            commandFocusRequest += 1
        }
        onCommandPanel?(value,restoreFocus)
        refreshHover()
    }
    func dismissDetailsFromOutsideClick() {
        guard !collapsed, !pinned, !chatVisible, !menuTracking else { return }
        collapse()
    }
    func hide() { taskShelfVisible = false; collapse(); onHide?() }
    func showPage() {
        clickExpanded = true
        collapsed = false; webExpanded = true
        onResize?(windowSize); onShow?()
    }
    func requestAddress() {
        command = selectedSideTask?.sourceURL ?? webURL
        selectChat(true)
    }
    func navigateHistory(_ action: String) {
        controlInteraction(true)
        Task {
            defer { controlInteraction(false) }
            do { _ = try await performBrowserAction(["action": action]) }
            catch { webError = error.localizedDescription }
        }
    }
    static func addressURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let value = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    func openURL(_ raw: String, background: Bool = false) {
        guard let url = Self.addressURL(raw) else { webError = "Enter a valid web address."; return }
        do { try prepareBrowserForNewTask() } catch { webError = error.localizedDescription; return }
        saveSession(force:true)
        endBackgroundListening()
        webError = nil; hasCustomSurface = false; taskFailed = false
        latestIntent = raw
        surface = .webpage; collapsed = background; webExpanded = !background; onResize?(windowSize)
        if externalBrowser && browserConnected {
            Task { do { _ = try await bridge.externalAction(["action": "navigate", "url": url.absoluteString]) } catch { webError = error.localizedDescription } }
        } else {
            Task { do { _ = try await performBrowserAction(["action":"navigate","url":url.absoluteString]) } catch { webError = error.localizedDescription } }
        }
    }
    func perform(_ binding: PageBinding, text: String? = nil, value: Double? = nil, then submit: PageBinding? = nil) {
        if restoringSession {
            queuedRestoreAction = { [weak self] in self?.perform(binding, text:text, value:value, then:submit) }
            return
        }
        lastActionError = nil
        controlInteraction(true)
        Task {
            defer { controlInteraction(false) }
            do {
                var input = binding.dictionary
                if let text { input["text"] = text }
                if let value { input["value"] = value }
                _ = try await performBrowserAction(input)
                if let submit { _ = try await performBrowserAction(submit.dictionary) }
                lastInteraction = binding.operation ?? binding.action
            } catch {
                lastActionError = "Page changed. Reconnecting controls…"
                adaptive.bindingFailed()
            }
        }
    }
    func remember(title: String, url: String, kind: String) {
        guard ["https", "http"].contains(URL(string: url)?.scheme ?? "") else { return }
        if let latest = history.first, latest.url == url && latest.title == title, Date().timeIntervalSince(latest.date) < 60 { return }
        history.insert(HistoryEntry(date: Date(), title: title, url: url, kind: kind), at: 0)
        history = Array(history.prefix(500))
        if persistHistory, let data = try? JSONEncoder().encode(history) { preferences.set(data, forKey: "history") }
    }
    func restore(_ entry: HistoryEntry) {
        restoreSession(sessions.get(entry.url) ?? SavedSession(url:entry.url,title:entry.title,mediaType:entry.kind == "web" ? "" : entry.kind), play: false)
    }
    func saveSession(force: Bool = false) {
        guard persistHistory, !isLiveTest, !restoringSession, !webLoading, !externalBrowser,
              SessionStore.validURL(webURL), force || Date().timeIntervalSince(lastSessionSave) > 4 else { return }
        lastSessionSave = Date()
        let old = sessions.get(webURL)
        let plan = hasCustomSurface ? surface : old?.plan
        sessions.put(SavedSession(url:webURL,title:trackTitle,plan:plan,position:max(0,progress),volume:volume,
                                  mediaType:mediaType,listening:backgroundListening,wasPlaying:isPlaying))
        recentSessions = sessions.entries
    }
    func cancelRestoration() {
        restoreRevision += 1; restoreTask?.cancel(); restoreTask = nil
        restoringSession = false; queuedRestoreAction = nil
        let revision = restoreRevision
        Task { [weak self] in
            guard let self, self.restoreRevision == revision, !self.restoringSession else { return }
            await self.browser.webView.setAllMediaPlaybackSuspended(false)
        }
    }
    func restoreSession(_ entry: SavedSession, play: Bool = false) {
        guard SessionStore.validURL(entry.url) else { return }
        saveSession(force:true)
        cancelRestoration(); adaptive.task?.cancel()
        let revision = restoreRevision
        restoringSession = true; webError = nil; taskFailed = false
        externalBrowser = false; webURL = entry.url; webTitle = entry.title
        surface = entry.plan ?? .webpage; hasCustomSurface = false
        backgroundListening = entry.listening; progress = entry.position; volume = entry.volume
        mediaType = entry.mediaType; isPlaying = false; hasMedia = entry.isMedia
        collapsed = true; pinned = false; webExpanded = false
        onResize?(windowSize)
        restoreTask = Task {
            do {
                await browser.webView.setAllMediaPlaybackSuspended(true)
                try Task.checkCancellation()
                let page: [String:Any]
                if browser.webView.url?.absoluteString == entry.url && !webLoading { page = try await observation() }
                else {
                    browser.webView.load(URLRequest(url:URL(string:entry.url)!,cachePolicy:.useProtocolCachePolicy))
                    page = try await browser.settledObservation(navigation:true)
                }
                var latest = page
                if entry.isMedia {
                    let deadline = Date().addingTimeInterval(8)
                    while (latest["hasMedia"] as? Bool != true || (latest["readyState"] as? Int ?? 0) < 1) && Date() < deadline {
                        try await Task.sleep(for:.milliseconds(200)); latest = try await observation()
                    }
                }
                try Task.checkCancellation()
                guard revision == restoreRevision else { return }
                if let plan = entry.plan, let checked = try? plan.validated(observation:latest) {
                    surface = checked; hasCustomSurface = checked.markup != nil; surfaceOrigin = "Restored"
                    try? await browser.bindReadings(checked.readings ?? [])
                    if !isLiveTest, let key = SurfaceCache.pageKey(entry.url) { adaptive.cache.put(checked,key:key) }
                } else { surface = .webpage; hasCustomSurface = false }
                if latest["hasMedia"] as? Bool == true {
                    _ = try? await browser.action(["action":"media","operation":"volume","value":entry.volume])
                    if entry.position > 0, let length = latest["duration"] as? Double, length > entry.position {
                        _ = try? await browser.action(["action":"media","operation":"seek","value":entry.position])
                    }
                }
                await browser.webView.pauseAllMediaPlayback()
                await browser.webView.setAllMediaPlaybackSuspended(false)
                try Task.checkCancellation()
                guard revision == restoreRevision else { return }
                restoringSession = false; upsertWebTask(surface, activate:true); onResize?(windowSize)
                if play { _ = try await browser.action(["action":"media","operation":"play"]) }
                if let queued = queuedRestoreAction { queuedRestoreAction = nil; queued() }
                saveSession(force:true)
                if !hasCustomSurface { adaptive.changed() }
                Diagnostics.record("session_restored",["reusedUI":hasCustomSurface,"playing":isPlaying])
            } catch {
                guard revision == restoreRevision else { return }
                await browser.webView.setAllMediaPlaybackSuspended(false)
                restoringSession = false; queuedRestoreAction = nil
                if !Task.isCancelled { webError = "Could not restore this page. Open it to retry." }
            }
        }
    }
    func clearRecentSessions() {
        cancelRestoration(); sessions.clear(); recentSessions = []; history = []
        preferences.removeObject(forKey:"history")
    }
    func sendCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        requestReceivedAt = Date(); command = ""
        backgroundRequest = true; hasUnreadReply = false
        if commandPanelVisible { selectChat(false) }
        messages.append(ChatMessage(text: text, isUser: true))
        if let seconds = Self.timerSeconds(text) {
            do { _ = try startTimer(seconds:seconds,receivedAt:requestReceivedAt); messages.append(ChatMessage(text:"Timer started.",isUser:false)) }
            catch { messages.append(ChatMessage(text:error.localizedDescription,isUser:false)) }
            return
        }
        let mediaCommands = ["pause":"pause","暂停":"pause","play":"play","播放":"play","继续":"play","next":"next","下一首":"next","切歌":"next"]
        if let operation = mediaCommands[text.lowercased()], selectedMediaCommand(operation) { return }
        latestIntent = text; taskFailed = false
        if ["stop", "cancel", "停止", "取消"].contains(text.lowercased()) {
            cancel(); return
        }
        if busy {
            if agentStopping { messagesAfterStop.append(text); activity = "Request received…" }
            else { agent.steer(text) }
            return
        }
        startCommand(text)
    }
    private func startCommand(_ text: String) {
        if localCommand(text) { return }
        activateSelectedSource()
        guard settings.main.isConfigured else {
            messages.append(ChatMessage(text: "Connect a model in Settings to start.", isUser: false)); onSettings?(); return
        }
        adaptive.task?.cancel()
        agent.operatedPage = false
        busy = true; agentStopping = false; activity = "On it…"
        beginAmbientRequest(text)
        agentTask = Task {
            defer {
                finishAmbientRequest()
                busy = false; activity = ""; agentStopping = false; agentTask = nil
                if !messagesAfterStop.isEmpty {
                    let next = messagesAfterStop.joined(separator: "\n")
                    messagesAfterStop.removeAll(); latestIntent = next; taskFailed = false
                    startCommand(next)
                } else if agent.operatedPage { adaptive.changed() }
            }
            do {
                let reply = try await agent.run(text,receivedAt:requestReceivedAt)
                if !Task.isCancelled, !reply.isEmpty { messages.append(ChatMessage(text: reply, isUser: false)); hasUnreadReply = !commandPanelVisible }
            } catch is CancellationError { taskFailed = true }
            catch { taskFailed = true; if !Task.isCancelled { failAmbientRequest(error.localizedDescription); messages.append(ChatMessage(text: error.localizedDescription, isUser: false)); hasUnreadReply = !commandPanelVisible } }
        }
    }
    func localCommand(_ text: String) -> Bool {
        if let seconds = Self.timerSeconds(text) {
            do { _ = try startTimer(seconds:seconds); messages.append(ChatMessage(text:"Timer started.",isUser:false)) }
            catch { messages.append(ChatMessage(text:error.localizedDescription,isUser:false)) }
            return true
        }
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "收起", "变小", "collapse": collapse(); return true
        case "隐藏", "hide": hide(); return true
        case "展开", "expand": reveal(); return true
        case "设置", "settings": onSettings?(); return true
        case "暂停", "pause": return selectedMediaCommand("pause")
        case "播放", "继续", "play": return selectedMediaCommand("play")
        case "下一首", "切歌", "next": return selectedMediaCommand("next")
        default:
            if text.hasPrefix("https://") || text.hasPrefix("http://") { openURL(text,background:backgroundRequest); return true }
            return false
        }
    }
    func cancel() {
        guard busy else { return }
        agentStopping = true; messagesAfterStop.removeAll(); agent.stop()
        agentTask?.cancel(); activity = "Stopping…"
    }
    func performBrowserAction(_ input: [String: Any]) async throws -> [String: Any] {
        if externalBrowser && browserConnected { return try await bridge.externalAction(input) }
        return try await browser.action(input)
    }
    func observation() async throws -> [String: Any] {
        let result: [String: Any]
        if externalBrowser && browserConnected { result = try await bridge.externalAction(["action": "observe"]) }
        else { result = try await browser.observe() }
        lastObservation = result
        if isLiveTest {
            Diagnostics.record("page_state", result.filter { ["playing", "audible", "hasMedia", "readyState", "muted", "currentTime", "duration", "mediaError"].contains($0.key) })
        }
        return result
    }
}
