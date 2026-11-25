import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject var model: AppModel
    private var scheme: ColorScheme { model.settings.appearance.scheme ?? systemScheme }
    private var playerFrame: NSRect { NSRect(origin: .zero, size: model.shellLayout.frame.size) }
    private var content: NSRect { model.sourceIsFullscreen ? playerFrame : model.shellLayout.localContent }
    private var viewport: NSRect { model.sourceIsFullscreen ? playerFrame : model.shellLayout.localVisibleContent }
    private var compact: NSRect { model.shellLayout.localCompact }
    private var stripOpacity: Double {
        min(1, compact.width / max(1, model.compactSize.width), compact.height / max(1, model.compactSize.height))
    }
    private var verticalRail: Bool { model.shellLayout.edge == .left || model.shellLayout.edge == .right }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.sourceIsFullscreen && model.shellLayout.edge != nil && !compact.isEmpty {
                // One shared surface, with the original compact controls kept in the same screen position.
                Rectangle().fill(.primary.opacity(0.025 * stripOpacity))
                    .allowsHitTesting(false)
                    .frame(
                        width: verticalRail
                            ? compact.width : model.shellLayout.frame.width,
                        height: verticalRail
                            ? model.shellLayout.frame.height : compact.height
                    )
                    .offset(
                        x: verticalRail ? compact.minX : 0,
                        y: verticalRail ? 0 : compact.minY)
            }
            DetailContentView(model: model)
                .frame(
                    width: content.width > 0 ? content.width : model.preferredWebSize.width,
                    height: content.height > 0
                        ? max(1, content.height - (model.feedback == nil || model.sourceIsFullscreen ? 0 : model.feedbackSize.height))
                        : model.preferredWebSize.height
                )
                .opacity(!model.collapsed && !model.taskShelfVisible ? 1 : 0)
                .animation(
                    CalmMotion.animation(reduced: model.motionReduced),
                    value: !model.collapsed && !model.taskShelfVisible
                )
                .offset(x: content.minX - viewport.minX, y: content.minY - viewport.minY)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .clipped()
                .offset(x: viewport.minX, y: viewport.minY)
                .allowsHitTesting(!model.collapsed && !model.taskShelfVisible)
                .accessibilityHidden(model.collapsed || model.taskShelfVisible)
            ZStack {
                if model.taskShelfVisible { CalmTaskShelf(model: model).transition(.opacity) }
            }
            .animation(CalmMotion.animation(reduced: model.motionReduced), value: model.taskShelfVisible)
            .frame(width: content.width, height: content.height)
            .offset(x: content.minX - viewport.minX, y: content.minY - viewport.minY)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading).clipped()
            .offset(x: viewport.minX, y: viewport.minY)
            .allowsHitTesting(model.taskShelfVisible)
            if !model.sourceIsFullscreen, let feedback = model.feedback, content.width > 0, !model.taskShelfVisible {
                RequestFeedbackView(model: model, feedback: feedback)
                    .id(feedback.id)
                    .frame(width: content.width, height: min(model.feedbackSize.height, content.height))
                    .offset(x: content.minX, y: content.maxY - min(model.feedbackSize.height, content.height))
            }
            if !compact.isEmpty && !model.sourceIsFullscreen {
                CalmStrip(model: model)
                    .frame(width: model.compactSize.width, height: model.compactSize.height)
                    .frame(width: compact.width, height: compact.height, alignment: .topLeading)
                    .clipped().opacity(stripOpacity)
                    .allowsHitTesting(!model.compactRailTucked).accessibilityHidden(model.compactRailTucked)
                    .offset(x: compact.minX, y: compact.minY)
            }
        }
        .frame(width: model.shellLayout.frame.width, height: model.shellLayout.frame.height, alignment: .topLeading)
        .animation(CalmMotion.layout(reduced: model.motionReduced), value: model.sourceIsFullscreen)
        .background { WindowDragArea() }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(
                    colors: scheme == .dark
                        ? [
                            Color(red: 0.14, green: 0.135, blue: 0.18).opacity(0.94),
                            Color(red: 0.10, green: 0.095, blue: 0.14).opacity(0.94),
                        ]
                        : [
                            Color(red: 0.98, green: 0.975, blue: 1).opacity(0.92),
                            Color(red: 0.93, green: 0.925, blue: 0.965).opacity(0.9),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(
                    colors: [model.accent.opacity(0.055), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(
                scheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.9), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.accent.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.calmReducedMotion, model.motionReduced)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(model.settings.appearance.scheme)
        .onChange(of: model.compactSize) { _, _ in model.onResize?(model.windowSize) }
        .onChange(of: model.visibleWindowPlayer.map(ObjectIdentifier.init)) { _, _ in
            if !model.sourceIsFullscreen { model.activeWindowPlayer?.exit() }
        }
        .onHover { model.pointerChanged($0) }
    }
}

struct DetailContentView: View {
    @ObservedObject var model: AppModel
    @State private var inputActive = false
    @State private var showingExitHint = false

    private var toolbarHeight: CGFloat { model.hasWebAddressBar ? 52 : 30 }
    private var reservedHeight: CGFloat {
        model.detailControlsVisible && !model.floatingSourceControls ? toolbarHeight : 0
    }
    var body: some View {
        ZStack(alignment: .top) {
            interactionCard
            sourceHosts
            toolbar
                .background {
                    if model.floatingSourceControls {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.10)) }
                            .shadow(color: .black.opacity(0.13), radius: 5, y: 2)
                    }
                }
                .padding(.horizontal, model.floatingSourceControls ? 4 : 0)
                .padding(.top, model.floatingSourceControls ? 3 : 0)
                .modifier(RevealingControls(visible: model.detailControlsVisible,
                                            height: toolbarHeight + (model.floatingSourceControls ? 3 : 0),
                                            reduced: model.motionReduced))
            if model.sourceIsFullscreen {
                Button { model.activeWindowPlayer?.exit() } label: {
                    Label("Exit fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 28)
                        .foregroundStyle(.white)
                        .background(Color(red: 0.13, green: 0.13, blue: 0.16).opacity(0.92), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.20)) }
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
                }
                .buttonStyle(WindowDragButtonStyle(allowsWindowDrag: false))
                .accessibilityIdentifier("exit-window-player").help("Exit fullscreen · Esc")
                .padding(.top, 7)
                .modifier(RevealingControls(visible: model.pointerNearSourceControls || showingExitHint,
                                           height: 40, reduced: model.motionReduced))
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(point): model.trackSourcePointer(y: point.y)
            case .ended: model.trackSourcePointer(y: nil)
            }
        }
        .task(id: model.sourceIsFullscreen) {
            showingExitHint = model.sourceIsFullscreen
            if showingExitHint {
                do { try await Task.sleep(for: .milliseconds(1400)); showingExitHint = false }
                catch {}
            }
        }
        .preferredColorScheme(model.settings.appearance.scheme)
        .onExitCommand { if model.sourceIsFullscreen { model.activeWindowPlayer?.exit() } else { model.collapse() } }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            model.menuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            model.menuTracking = false
        }
    }
    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    model.collapse()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 24, height: 26)
                }
                .buttonStyle(.plain).help("Collapse · Esc").accessibilityLabel("Collapse task details")
                Button {
                    model.editTaskList()
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).frame(width: 24, height: 26)
                }
                .buttonStyle(.plain).help("Edit tasks").accessibilityLabel("Edit tasks")
                Text(
                    model.visibleHandoff?.isBrowserManager == true ? "Browser extensions" : model.selectedSideTask.map { model.usesMusicCard($0) } == true
                        ? "Music" : model.selectedSideTask?.title ?? "Orvlet"
                )
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                if let task = model.selectedSideTask, let activity = model.taskActivity(task) {
                    TaskActivityGlyph(model: model, task: task)
                    Text(activity.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)

                if let card = model.selectedSideTask {
                    Menu {
                        Button("Chat") { model.openTaskConversation(card.id) }
                        if card.kind == .web || model.visibleHandoff != nil {
                            Button(model.showingWeb ? "Show card" : "Open source page") {
                                if model.showingWeb { model.selectTask(card.id, expanded: true, preferSource: false) }
                                else { model.openTaskFromDoubleClick(card.id) }
                            }
                        } else if card.kind == .timer {
                            Button("Restart timer") { model.timerAction(card.id, action: "restart") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 20, height: 23)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if !model.collapsed {
                    Button {
                        model.pinned.toggle()
                    } label: {
                        Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 10)).frame(
                            width: 20, height: 23)
                    }
                    .buttonStyle(.plain).help(model.pinned ? "Unpin card" : "Keep open")
                    .accessibilityLabel(model.pinned ? "Unpin card" : "Keep open")
                    .accessibilityIdentifier("keep-card-open")
                }
                if model.compactRailTucked { PinnedTasksButton(model: model) }
            }.padding(.horizontal, 10).frame(height: 30).background {
                WindowDragArea(
                    onDoubleClick: model.selectedSideTask.map { task in
                        { model.openTaskFromDoubleClick(task.id) }
                    })
            }
            if model.hasWebAddressBar {
                SourceNavigationBar(model: model)
                    .id(model.visibleWindowPlayer.map(ObjectIdentifier.init))
            }
        }
    }

    var interactionCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: reservedHeight).allowsHitTesting(false)
            if let source = model.visibleHandoff {
                HandoffSourceView(source: source).id(ObjectIdentifier(source))
            } else if model.showingWeb {
                Spacer(minLength: 0)
            } else if let task = model.selectedSideTask, let label = task.terminalLabel,
                ![.timer, .calendar].contains(task.kind)
            {
                HStack(spacing: 12) {
                    Text(label).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        model.closeTask(task.id)
                    } label: {
                        Image(systemName: "checkmark").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Acknowledge and close " + task.title)
                }.padding(16)
                Spacer(minLength: 0)
            } else if let task = model.selectedSideTask, model.usesMusicCard(task) {
                MusicCard(model: model, task: task).id(task.id)
            } else if let task = model.selectedSideTask {
                ZStack {
                    HTMLCardView(
                        markup: task.presentation, compact: false, state: task.expandedDisplayState,
                        allowedActions: task.allowedActions,
                        collectFields: task.kind == .workspace, measuresContent: true, mediaActions: task.mediaActions,
                        appearance: model.settings.appearance, accent: model.settings.theme.hex,
                        reduceMotion: model.motionReduced,
                        action: { model.cardAction(task.id, action: $0, value: $1) },
                        interaction: { active in
                            if inputActive != active {
                                inputActive = active
                                model.controlInteraction(active)
                            }
                        },
                        contentHeight: { height in
                            model.fitCardSurface(task.id, height: height)
                        }
                    ).id(task.id).transition(.opacity)
                }.animation(CalmMotion.animation(reduced: model.motionReduced), value: task.id)
            } else {
                Button {
                    model.selectChat(true)
                } label: {
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(model.accent)
                        Text("A little help, when you need it.")
                        Spacer()
                        Text(model.settings.shortcut.title).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11)).padding(12)
                }.buttonStyle(.plain)
            }
        }
    }
    var sourceHosts: some View {
        GeometryReader { geometry in
            let top = reservedHeight
            let side: CGFloat = top > 0 ? 3 : 0
            let bottom: CGFloat = top > 0 ? 4 : 0
            ZStack {
                ForEach(model.liveBrowsers, id: \.id) { browser in
                    Group {
                        if let page = browser.systemPage {
                            BrowserPageSurface(page: page, visible: model.visibleHandoff == nil && model.showingWeb && model.selectedSideTask?.id == browser.id)
                        } else { WebSurface(webView: browser.webView) }
                    }
                        .frame(width: max(1, geometry.size.width - 2 * side), height: max(1, geometry.size.height - top - bottom))
                        .opacity(model.visibleHandoff == nil && model.showingWeb && model.selectedSideTask?.id == browser.id ? 1 : 0)
                        .allowsHitTesting(model.visibleHandoff == nil && model.showingWeb && model.selectedSideTask?.id == browser.id)
                        .accessibilityHidden(model.visibleHandoff != nil || !model.showingWeb || model.selectedSideTask?.id != browser.id)
                }
            }.offset(x: side, y: top)
        }
    }

}

private struct RevealingControls: ViewModifier {
    let visible: Bool
    let height: CGFloat
    let reduced: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: height, alignment: .top)
            .scaleEffect(visible || reduced ? 1 : 0.985, anchor: .top)
            .offset(y: visible || reduced ? 0 : -9)
            .opacity(visible ? 1 : 0)
            .frame(height: visible ? height : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(reduced ? nil : .smooth(duration: visible ? 0.24 : 0.18), value: visible)
    }
}

struct CommandWindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { model.settings.appearance.scheme ?? systemScheme }
    var body: some View {
        CommandPanelView(model: model)
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    LinearGradient(
                        colors: scheme == .dark
                            ? [
                                Color(red: 0.14, green: 0.135, blue: 0.18).opacity(0.94),
                                Color(red: 0.10, green: 0.095, blue: 0.14).opacity(0.94),
                            ]
                            : [
                                Color(red: 0.98, green: 0.975, blue: 1).opacity(0.92),
                                Color(red: 0.93, green: 0.925, blue: 0.965).opacity(0.9),
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.accent.opacity(0.18), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .environment(\.calmReducedMotion, model.motionReduced)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(model.settings.appearance.scheme)
    }
}

struct CommandPanelView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    @State private var confirmingClear = false
    @State private var clearTaskID: UUID?

    private var hasMessagesToClear: Bool {
        if let id = model.conversationTaskID {
            return model.messages.contains { $0.taskID == id }
                || !(model.conversationDrafts[id] ?? "").isEmpty || !model.command.isEmpty
        }
        return !model.messages.isEmpty || !model.conversationDrafts.isEmpty
            || !model.newTaskDraft.isEmpty || !model.command.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.conversationHistoryVisible && model.conversationTaskID == nil {
                HStack {
                    Text("Task history").font(.system(size: 17, weight: .medium, design: .rounded))
                    Spacer()
                    Button {
                        model.selectChat(true)
                    } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }.help("New task").accessibilityLabel("New task")
                }.buttonStyle(.plain).padding(20)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 19, weight: .light)).foregroundStyle(model.accent)
                    TextField(
                        model.conversationTaskID == nil ? "What can I take care of?" : "Continue this task…",
                        text: $model.command
                    )
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($focused).onSubmit(send)
                    if model.busy && (model.conversationTaskID == nil || model.conversationTaskID.flatMap(model.runOwning) != nil) {
                        Button {
                            model.cancel()
                        } label: {
                            Image(systemName: "stop.circle").font(.system(size: 18))
                        }.help("Stop current request")
                    }
                    Button { model.attachWorkFiles() } label: {
                        Image(systemName: "paperclip").font(.system(size: 15))
                    }.help("Attach local text files").accessibilityLabel("Attach local text files")
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(model.accent)
                    }
                    .disabled(
                        model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.mainServiceState == "checking"
                    ).help("Send · ⌥↩ starts a new task")
                }.buttonStyle(.plain).padding(20)
            }
            Divider().opacity(0.3)
            if model.mainServiceState == "checking" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking model connection…")
                    Spacer()
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            }
            if let error = model.lastActionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(
                    .vertical, 6)
            }
            if model.conversationHistoryVisible {
                TaskConversationHistoryView(model: model).frame(height: model.historyContentHeight)
            } else if let task = model.editingInterfaceTask {
                Text("Editing · " + task.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            } else if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Taking care of it…")
                    Spacer()
                    Text("You can add a message").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11)).padding(.horizontal, 20).padding(.vertical, 12)
            } else if let last = model.visibleConversation.last(where: { !$0.isUser }) {
                ScrollView {
                    Text(last.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading
                    ).padding(.horizontal, 20).padding(.vertical, 14)
                }
                .frame(maxHeight: 110)
            } else {
                HStack(spacing: 8) {
                    suggestion("Play some music", symbol: "music.note", label: "Music")
                    suggestion("Timer 12 minutes", symbol: "timer", label: "Timer")
                    suggestion("Add a calendar event", symbol: "calendar", label: "Calendar")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).padding(.vertical, 14)
            }
            HStack {
                Text(model.settings.shortcut.title + " to summon").foregroundStyle(.tertiary).overlay {
                    WindowDragArea()
                }
                Spacer()
                Button {
                    model.openTaskHistory()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }.help("Task history").accessibilityLabel("Task history")
                Button {
                    clearTaskID = model.conversationTaskID
                    confirmingClear = true
                } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .disabled(!hasMessagesToClear || !model.canClearChatMessages)
                .help(model.conversationTaskID == nil ? "Clear all chat messages…" : "Clear messages in this task…")
                .accessibilityLabel(model.conversationTaskID == nil ? "Clear all chat messages" : "Clear task messages")
                .accessibilityIdentifier("clear-chat-messages")
                Button {
                    model.onSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }.help("Settings")
                Button {
                    model.selectChat(false)
                } label: {
                    Text("esc").padding(.horizontal, 5).padding(.vertical, 2).background(
                        .primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                }.help("Return to your work")
            }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(CalmMotion.animation(reduced: model.motionReduced), value: model.conversationHistoryVisible)
            .background { WindowDragArea() }
            .preferredColorScheme(model.settings.appearance.scheme).tint(model.accent)
            .onAppear { focused = true }
            .onChange(of: model.commandWindowHeight) { _, height in model.onCommandResize?(height) }
            .onChange(of: model.commandFocusRequest) { _, _ in focused = true }
            .onExitCommand { model.selectChat(false) }
            .confirmationDialog(
                clearTaskID == nil ? "Clear all chat messages?" : "Clear messages in this task?",
                isPresented: $confirmingClear, titleVisibility: .visible
            ) {
                Button("Clear messages", role: .destructive) {
                    if !model.clearChatMessages(taskID: clearTaskID) {
                        model.lastActionError = "Wait for the current request to finish, then clear messages."
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    clearTaskID == nil
                        ? "Saved messages and drafts will be removed. Tasks and built-in tools stay. This cannot be undone."
                        : "Only this task’s messages and draft will be removed. The task and other conversations stay. This cannot be undone."
                )
            }
    }
    func suggestion(_ text: String, symbol: String, label: String) -> some View {
        Button {
            model.command = text
            focused = true
        } label: {
            Label(label, systemImage: symbol).font(.system(size: 10)).padding(8).background(
                .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    func send() {
        guard !model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focused = false
        model.sendCommand()
    }
}

extension ThemeTone {
    var hex: String {
        switch self {
        case .iris: return "#a49bdf"
        case .mint: return "#7cc4ac"
        case .peach: return "#efa878"
        case .sky: return "#75bdec"
        case .rose: return "#e391ae"
        case .stone: return "#b0b8c7"
        }
    }
}
