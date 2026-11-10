import Combine
import SwiftUI
import WebKit

/// Observable composition root. Feature behavior lives in the owning folder extensions.
@MainActor
final class AppModel: ObservableObject {
    #if DEBUG
        var calendarOpenCheck: ((Bool) -> Void)?
    #endif
    @Published var shellLayout = ShellLayout(
        frame: NSRect(x: 0, y: 0, width: 110, height: 32), compact: NSRect(x: 0, y: 0, width: 110, height: 32),
        content: .zero, edge: nil)
    @Published var taskListEditing = false
    @Published var draggingTaskID: UUID?
    @Published var requestProgress: [UUID: [String]] = [:]
    var pendingRoutingRequests: [TaskUserRequest] = []
    var taskAliases: [UUID: UUID] = [:]
    var globalRoutingTask: Task<Void, Never>?
    @Published var routingMessage = ""
    @Published var mainServiceState = "unknown"
    @Published var fastServiceState = "unknown"
    var fastTriageRetryAfter = Date.distantPast
    var connectionCheckTask: Task<Void, Never>?
    @Published var setupChecking = false
    @Published var calendarReadiness = AccessReadiness.unchecked
    @Published var storageReadiness = AccessReadiness.unchecked
    @Published var connectionReadiness = AccessReadiness.unchecked
    var readinessTask: Task<Void, Never>?
    var readinessRecheckPending = false
    var readinessPromptPending = false
    var setupDismissed = false
    var onSetup: (() -> Void)?
    var onSetupModels: (() -> Void)?
    @Published var settingsTabRequested: Int?
    #if DEBUG
        var pressedMouseButtonsOverride: Int?
        var readinessConnectionsOverride: (() async -> Void)?
        var readinessStorageOverride: (() throws -> Void)?
    #endif
    @Published var hasUnreadReply = false
    @Published var feedback: RequestFeedback?
    var feedbackTask: Task<Void, Never>?
    var feedbackWakesStack = false
    var backgroundRequest = false
    @Published var taskShelfVisible = false {
        didSet {
            if taskShelfVisible && commandPanelVisible { selectChat(false, restoreFocus: false) }
            onResize?(windowSize)
            if taskShelfVisible { onShow?() }
            refreshStackAttention()
        }
    }
    var motionReduced: Bool { settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var shellExpanded: Bool { taskShelfVisible || !collapsed }
    var shellContentSize: NSSize? {
        if taskShelfVisible { return NSSize(width: 320, height: min(360, 60 + Double(max(1, sideTasks.count)) * 46)) }
        if collapsed { return feedback == nil ? nil : feedbackSize }
        let detail = windowSize
        return NSSize(width: detail.width, height: detail.height + (feedback == nil ? 0 : feedbackSize.height))
    }
    @Published var sideTasks: [SideTask] = [] {
        didSet {
            let signature: (SideTask) -> String = {
                "\($0.id):\($0.kind):\($0.hidden):\($0.playing):\($0.finished):\($0.isMediaTask):\($0.deadline != nil)"
            }
            if oldValue.map(signature) != sideTasks.map(signature) { taskRanking.schedule() }
        }
    }
    @Published var learnedTaskOrder: [UUID] = []
    var sessionStarted = false
    lazy var interfaceMemory = InterfaceMemory(defaults: preferences)
    lazy var taskRanking = TaskRanking(model: self)
    @Published var taskOrder: [UUID] = []
    @Published var selectedTaskID: UUID?
    @Published var editingInterfaceID: UUID?
    @Published var interfaceJobs: [UUID: Task<Void, Never>] = [:]
    @Published var taskActivityReceipts: [UUID: TaskActivityReceipt] = [:] { didSet { refreshStackAttention() } }
    var taskRevisions = TaskRevisionLedger()
    @Published var commandPanelVisible = false { didSet { refreshStackAttention() } }
    @Published var browserRevision = 0
    var parkedBrowsers: [UUID: BrowserController] = [:]
    @Published var musicPlayback: [UUID: MusicPlayback] = [:]
    @Published var musicLoading: Set<UUID> = []
    @Published var musicQueueExpanded: Set<UUID> = []
    @Published var musicErrors: [UUID: String] = [:]
    var musicJobs: [UUID: Task<Void, Never>] = [:]
    var musicRevisions: [UUID: UUID] = [:]
    var taskSourceRestorations: [UUID: Task<Void, Error>] = [:]
    var taskClock: Timer?
    var requestReceivedAt = Date()
    @Published var shortcutStatus = "Ready"
    var onShortcutChanged: (() -> Void)?
    var onCommandResize: ((Double) -> Void)?
    var onCommandPanel: ((Bool, Bool) -> Void)?
    @Published var surface = SurfacePlan.empty
    @Published var collapsed = true { didSet { refreshStackAttention() } }
    var clickExpanded = false
    var menuTracking = false { didSet { refreshStackAttention() } }
    @Published var chatVisible = false  // Composer focus; the webpage remains visible.
    @Published var commandFocusRequest = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var webExpanded = false
    @Published private(set) var preferredWebSize = NSSize(width: 320, height: 220)
    let preferences: UserDefaults
    lazy var sessions = SessionStore(defaults: preferences)
    @Published var recentSessions: [SavedSession] = []
    @Published var restoringSession = false
    var restoreTask: Task<Void, Never>?
    var restoreRevision = 0
    var lastSessionSave = Date.distantPast
    var queuedRestoreAction: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        preferences = defaults
        if let data = defaults.data(forKey: "conversation.v1"),
            let saved = try? JSONDecoder().decode([ChatMessage].self, from: data)
        {
            messages = saved
        }
        archivedTaskHistory =
            defaults.data(forKey: "taskHistory.v1").flatMap { try? JSONDecoder().decode([SideTask].self, from: $0) }
            ?? []
        migrateConversationOwnership()
        if let saved = defaults.dictionary(forKey: "webWindowSize"),
            let w = saved["width"] as? Double, let h = saved["height"] as? Double, w.isFinite, h.isFinite
        {
            preferredWebSize = Self.boundedWebSize(NSSize(width: w, height: h))
        }
    }
    static let minimumWebSize = NSSize(width: 280, height: 200)
    static func boundedWebSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: min(10000, max(minimumWebSize.width, size.width)),
            height: min(10000, max(minimumWebSize.height, size.height)))
    }
    var showingWeb: Bool { !collapsed && webExpanded }
    func rememberWebSize(_ size: NSSize) {
        guard showingWeb, size.width.isFinite, size.height.isFinite else { return }
        preferredWebSize = Self.boundedWebSize(size)
        if !isLiveTest {
            preferences.set(
                ["width": preferredWebSize.width, "height": preferredWebSize.height], forKey: "webWindowSize")
        }
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
    @Published var messages: [ChatMessage] = [] { didSet { persistConversation() } }
    @Published var conversationHistoryVisible = false
    @Published var conversationTaskID: UUID?
    @Published var archivedTaskHistory: [SideTask] = []
    var conversationDrafts: [UUID: String] = [:]
    var newTaskDraft = ""
    @Published var busy = false {
        didSet {
            refreshHover()
            if !busy { taskRanking.schedule() }
        }
    }
    @Published var activity = "" { didSet { recordProgress(activity) } }
    @Published var activeRequest: TaskRequestContext?
    let taskCode = TaskCodeRuntime()
    lazy var apiData = APIDataService(code: taskCode)
    lazy var taskRuntime = TaskRuntimeEngine(store: self, code: taskCode) { id, attempt, error in
        Diagnostics.record(
            "runtime_failure",
            ["taskID": id.uuidString, "attempt": attempt, "type": String(describing: type(of: error))])
    }
    @Published var taskActionJobs: [UUID: Task<Void, Never>] = [:]
    @Published var queuedTaskRequests: [TaskUserRequest] = []
    @Published var ambientRequestID: UUID? { didSet { if oldValue != ambientRequestID { taskRanking.schedule() } } }
    var preferredMediaTaskID: UUID?
    @Published var buildingSurface = false
    @Published var surfaceOrigin = ""
    @Published var pinned = false {
        didSet {
            refreshHover()
            if oldValue != pinned { onResize?(windowSize) }
        }
    }
    var compactRailTucked: Bool { pinned && !collapsed && !taskShelfVisible }
    @Published var history: [HistoryEntry] = []
    @Published var settings = AppSettings.load() {
        didSet {
            if oldValue.useFast != settings.useFast || oldValue.fast != settings.fast {
                fastTriageRetryAfter = .distantPast
                taskRanking.schedule()
            }
            if oldValue.inactiveStackOpacity != settings.inactiveStackOpacity { onStackOpacity?(stackOpacity) }
            if oldValue.blockAds != settings.blockAds {
                for browser in liveBrowsers { Task { await browser.configureAdBlocking() } }
            }
        }
    }
    @Published var modelAccessIssue: String?
    @Published var adBlockingError: String?
    @Published private(set) var stackDimmed = false { didSet { onStackOpacity?(stackOpacity) } }
    var stackHasKeyboardFocus = false { didSet { refreshStackAttention() } }
    var stackAttentionTask: Task<Void, Never>?
    var onStackOpacity: ((Double) -> Void)?
    var stackOpacity: Double { stackDimmed ? min(1, max(0.1, settings.inactiveStackOpacity)) : 1 }
    var stackNeedsAttention: Bool {
        taskActivityReceipts.values.contains { Date().timeIntervalSince($0.created) < 8 } || feedbackWakesStack
            || pointerInside || shellExpanded || commandPanelVisible || menuTracking || activeInteractions > 0
            || stackHasKeyboardFocus
    }
    func refreshStackAttention() {
        stackAttentionTask?.cancel()
        stackAttentionTask = nil
        if stackNeedsAttention {
            stackDimmed = false
            return
        }
        guard !stackDimmed else { return }
        stackAttentionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self, !self.stackNeedsAttention else { return }
                self.stackDimmed = true
                self.taskRanking.schedule()
            } catch {}
        }
    }
    @Published var bridgeStatus = ""
    @Published var browserConnected = false
    @Published var externalBrowser = false
    @Published var pointerInside = false
    var previewHovered = false
    @Published var backgroundListening = false
    var hoverTask: Task<Void, Never>?
    var activeInteractions = 0
    @Published var lastActionError: String?
    var persistHistory = true
    var isLiveTest = false { didSet { if isLiveTest && !oldValue { messages = [] } } }
    var taskFailed = false
    var latestIntent = ""
    var lastInteraction = ""
    var hasCustomSurface = false
    var accent: Color { settings.theme.color }
    var lastObservation: [String: Any] = [:]
    var trackTitle: String { webTitle.isEmpty ? "Orvlet" : webTitle }
    var compactSize: NSSize {
        settings.compactLayout == .vertical
            ? NSSize(width: 136, height: 40 + 38 * ambientTasks.count) : NSSize(width: microWidth, height: 44)
    }
    var windowSize: NSSize {
        if showingWeb { return preferredWebSize }
        let card = selectedSideTask
        if collapsed { return compactSize }
        if let card, usesMusicCard(card) {
            return NSSize(width: 328, height: musicCardHeight(card) + 30)
        }
        return NSSize(width: 328, height: (card?.presentation.height ?? 140) + 30)
    }
    var commandWindowHeight: Double {
        let resultHeight: Double
        if conversationHistoryVisible {
            resultHeight = historyContentHeight
        } else if editingInterfaceID != nil {
            resultHeight = 42
        } else if busy {
            resultHeight = 42
        } else if let message = visibleConversation.last(where: { !$0.isUser }) {
            resultHeight = min(110, max(52, Double(message.text.count / 65 + 1) * 20 + 28))
        } else {
            resultHeight = 52
        }
        return 66 + resultHeight + 34
    }
    var onResize: ((NSSize) -> Void)?
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?
    var onSettings: (() -> Void)?
    var agentTask: Task<Void, Never>?
    var agentStopping = false
    var requestIsStopping: Bool { agentStopping }
    var messagesAfterStop: [String] = []
    let playbackCoordinator = PlaybackCoordinator()
    lazy var browser = BrowserController(model: self)
    lazy var agent = AgentController(model: self)
    lazy var calendarService = CalendarService()
    lazy var bridge = LocalBridge(model: self)
    lazy var adaptive = InterfaceComposer(model: self)
    func start() {
        sessionStarted = true
        loadSideTasks()
        if let data = preferences.data(forKey: "history"),
            let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        {
            history = saved
        }
        if sessions.entries.isEmpty {
            var seen = Set<String>()
            let recent = history.filter { seen.insert($0.url).inserted }.prefix(24)
            for entry in recent.reversed() {
                let plan = SurfaceCache.pageKey(entry.url).flatMap { adaptive.cache.get($0) }
                sessions.put(
                    SavedSession(
                        url: entry.url, title: entry.title, plan: plan,
                        mediaType: entry.kind == "web" ? "" : entry.kind, updated: entry.date))
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
        browser.rememberMediaSurface(plan, url: webURL)
        var next = plan
        if automatic && backgroundListening { next.components.removeAll { $0.kind == .web } }
        guard !next.components.isEmpty || next.markup != nil else { return }
        let previousSize = windowSize
        withAnimation(CalmMotion.animation(reduced: motionReduced)) { surface = next.compacted() }
        if windowSize != previousSize { onResize?(windowSize) }
        saveSession(force: true)
        if !busy { upsertWebTask(next) }
        let owner = browser
        Task { try? await owner.bindReadings(next.readings ?? []) }
    }
    // Click expands; pointer exit collapses locally, independent of model/Jev latency.
    func beginBackgroundListening() {
        preferredMediaTaskID = browser.id
        backgroundListening = true
        if !pinned {
            var controls = surface
            controls.components.removeAll { $0.kind == .web }
            if controls.components.isEmpty && controls.markup == nil {
                controls = SurfacePlan(
                    components: [
                        SurfaceComponent(kind: .media),
                        SurfaceComponent(
                            kind: .transport,
                            actions: [
                                SurfaceAction(
                                    label: "Play / Pause", icon: "playpause.fill",
                                    binding: PageBinding(action: "media", operation: "toggle"))
                            ]),
                    ], width: 280, height: 120)
            }
            install(controls)
            if !backgroundRequest && !pointerInside && !chatVisible { collapse() }
        }
        refreshHover()
        saveSession(force: true)
    }
    func endBackgroundListening(clearTaskIntent: Bool = false) {
        backgroundListening = false
        if clearTaskIntent, let i = sideTasks.firstIndex(where: { $0.id == browser.id }) {
            sideTasks[i].listening = false
        }
        refreshHover()
    }
    func performBrowserAction(_ input: [String: Any]) async throws -> [String: Any] {
        if externalBrowser && browserConnected { return try await bridge.externalAction(input) }
        if input["action"] as? String == "media", let operation = input["operation"] as? String,
            ["next", "previous"].contains(operation),
            let task = sideTasks.first(where: { $0.id == browser.id }), task.isMediaTask,
            MusicTrack.videoID(task.sourceURL ?? "") != nil
        {
            // Model tools and card controls must traverse the same queue, not YouTube recommendations.
            try await performMusicControl(task.id, operation: operation)
            return try await browser.observe()
        }
        return try await browser.action(input)
    }
    func observation() async throws -> [String: Any] {
        let result: [String: Any]
        if externalBrowser && browserConnected {
            result = try await bridge.externalAction(["action": "observe"])
        } else {
            result = try await browser.observe()
        }
        lastObservation = result
        if isLiveTest {
            Diagnostics.record(
                "page_state",
                result.filter {
                    ["playing", "audible", "hasMedia", "readyState", "muted", "currentTime", "duration", "mediaError"]
                        .contains($0.key)
                })
        }
        return result
    }
}
