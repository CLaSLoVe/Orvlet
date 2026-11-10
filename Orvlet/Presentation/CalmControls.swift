import SwiftUI

struct CalmMediaControl: View {
    @ObservedObject var model: AppModel
    let task: SideTask
    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleTaskPresentation(task.id)
            } label: {
                HStack(spacing: 6) {
                    TaskActivityGlyph(model: model, task: task, symbol: "waveform")
                    Text(task.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1).frame(
                        width: 52, alignment: .leading)
                }.frame(width: 78, height: 28)
            }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(task.title).accessibilityLabel(
                "Open " + task.title)
            Button {
                model.taskRanking.record(task.id, .control)
                model.controlMedia(task.id, operation: "toggle")
            } label: {
                Image(systemName: task.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 28)
            }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(
                (task.playing ? "Pause " : "Play ") + task.title
            )
            .accessibilityLabel((task.playing ? "Pause " : "Play ") + task.title)
        }.frame(width: 108, height: 28)
    }
}

struct CalmTimerControl: View {
    @ObservedObject var model: AppModel
    let task: SideTask
    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleTaskPresentation(task.id)
            } label: {
                HStack(spacing: 6) {
                    TaskActivityGlyph(model: model, task: task, symbol: task.finished ? "checkmark" : "timer")
                    Text(task.finished ? "Done" : task.state["remaining"] ?? "")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 52, alignment: .leading)
                }.frame(width: 78, height: 28)
            }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(task.title).accessibilityLabel(
                task.title + ", " + (task.state["remaining"] ?? ""))
            Button {
                model.taskRanking.record(task.id, .control)
                model.timerAction(task.id, action: "toggle")
            } label: {
                Image(systemName: task.finished ? "arrow.clockwise" : task.deadline == nil ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .medium)).frame(width: 24, height: 28)
            }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(
                task.state["toggleLabel"] ?? "Pause timer"
            )
            .accessibilityLabel((task.state["toggleLabel"] ?? "Pause") + " " + task.title)
        }.frame(width: 108, height: 28)
    }
}

struct CalmTaskControl: View {
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel
    let task: SideTask
    var body: some View {
        Group {
            if let label = task.terminalLabel {
                HStack(spacing: 4) {
                    Button {
                        model.openTaskConversation(task.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Text(task.status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width: 78, height: 28, alignment: .leading)
                    }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(label)
                    Button {
                        model.closeTask(task.id)
                    } label: {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(
                            width: 24, height: 28
                        )
                        .background {
                            Circle().trim(from: 0, to: max(0, min(1, (task.expires?.timeIntervalSinceNow ?? 0) / 10)))
                                .stroke(model.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90)).frame(width: 23, height: 23)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Acknowledge and close " + task.title)
                }.frame(width: 108, height: 28)
            } else if model.isPreparingTask(task) {
                Button {
                    if task.id == model.requestCardID {
                        model.openTaskConversation(task.id)
                    } else {
                        model.toggleTaskPresentation(task.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        TaskActivityGlyph(model: model, task: task, symbol: "hourglass")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                            Text(model.taskActivity(task)?.label ?? model.preparationLabel).font(
                                .system(size: 9, weight: .medium, design: .rounded)
                            ).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width: 82, alignment: .leading)
                    }.frame(width: 108, height: 28)
                }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(
                    task.title + " · " + model.preparationLabel)
            } else if task.customCompact == true {
                HStack(spacing: 6) {
                    HTMLCardView(
                        markup: task.presentation, compact: true, state: task.state,
                        allowedActions: task.allowedActions,
                        appearance: model.settings.appearance, accent: model.settings.theme.hex,
                        reduceMotion: model.motionReduced, action: { _, _ in }
                    )
                    .frame(width: task.kind == .timer || task.isMediaTask ? 78 : 108, height: 28)
                    .overlay(alignment: .leading) {
                        TaskActivityGlyph(model: model, task: task).allowsHitTesting(false)
                    }
                    .overlay {
                        WindowDragArea(
                            onClick: { model.toggleTaskPresentation(task.id) },
                            onOutsideDrop: { model.closeTask(task.id) }, taskID: task.id,
                            taskPreview: model.dragAppearance(task.id),
                            dragging: { model.draggingTaskID = $0 ? task.id : nil })
                    }
                    .accessibilityLabel(task.title)
                    if task.kind == .timer || task.isMediaTask {
                        Button {
                            model.taskRanking.record(task.id, .control)
                            if task.kind == .timer {
                                model.timerAction(task.id, action: "toggle")
                            } else {
                                model.controlMedia(task.id, operation: "toggle")
                            }
                        } label: {
                            Image(
                                systemName: task.kind == .timer
                                    ? (task.finished
                                        ? "arrow.clockwise" : task.deadline == nil ? "play.fill" : "pause.fill")
                                    : task.playing ? "pause.fill" : "play.fill"
                            )
                            .font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 28)
                        }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).accessibilityLabel(
                            (task.state["toggleLabel"] ?? "Toggle") + " " + task.title)
                    }
                }.frame(width: 108, height: 28)
            } else if model.quickMediaTasks.contains(where: { $0.id == task.id }) {
                CalmMediaControl(model: model, task: task)
            } else if task.kind == .timer {
                CalmTimerControl(model: model, task: task)
            } else if let markup = task.markup ?? task.plan?.markup, !markup.compactHTML.isEmpty {
                HTMLCardView(
                    markup: markup, compact: true, state: task.state, allowedActions: task.allowedActions,
                    appearance: model.settings.appearance, accent: model.settings.theme.hex,
                    reduceMotion: model.motionReduced, action: { _, _ in }
                )
                .frame(width: 108, height: 28)
                .overlay(alignment: .leading) { TaskActivityGlyph(model: model, task: task).allowsHitTesting(false) }
                .overlay {
                    WindowDragArea(
                        onClick: { model.toggleTaskPresentation(task.id) }, onOutsideDrop: { model.closeTask(task.id) },
                        taskID: task.id, taskPreview: model.dragAppearance(task.id),
                        dragging: { model.draggingTaskID = $0 ? task.id : nil })
                }
                .accessibilityLabel(task.title).help(task.title)
            } else {
                Button {
                    model.toggleTaskPresentation(task.id)
                } label: {
                    HStack(spacing: 6) {
                        TaskActivityGlyph(model: model, task: task)
                        Text(task.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 108, height: 28)
                }.buttonStyle(TaskCardButtonStyle(model: model, id: task.id)).help(task.title).accessibilityLabel(
                    "Open " + task.title)
            }
        }.frame(width: 120, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(
                    scheme == .dark
                        ? Color.white.opacity(hovering ? 0.10 : 0.055) : Color.white.opacity(hovering ? 0.98 : 0.76)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.95), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.08 : 0.035), radius: 2, y: 1)
            }
            .opacity(model.draggingTaskID == task.id ? 0.3 : 1)
            .animation(CalmMotion.animation(reduced: model.motionReduced), value: model.draggingTaskID)
            .onHover { hovering = $0 }
            .animation(CalmMotion.response(reduced: model.motionReduced), value: hovering)
            .contextMenu {
                Button("Chat") { model.openTaskConversation(task.id) }
                Button("Hide") { model.dismissTask(task.id) }
            }
    }
}

struct CalmStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if model.settings.compactLayout == .vertical {
                VStack(spacing: 4) {
                    toolbar.frame(width: 120, height: 28)
                    ForEach(model.ambientTasks) { task in CalmTaskControl(model: model, task: task).transition(.opacity)
                    }
                }.padding(.vertical, 6).frame(width: 136)
            } else {
                HStack(spacing: 6) {
                    toolbar.frame(width: 84, height: 28)
                    ForEach(model.ambientTasks) { task in CalmTaskControl(model: model, task: task).transition(.opacity)
                    }
                }.padding(.horizontal, 8).frame(height: 44)
            }
        }
        .animation(CalmMotion.layout(reduced: model.motionReduced), value: model.ambientTasks.map(\.id))
        .background { WindowDragArea() }
        .contextMenu {
            Button("Settings…") { model.onSettings?() }
            Button("Hide strip") { model.hide() }
        }
    }
    var toolbar: some View {
        ZStack {
            Text(model.settings.compactLayout == .vertical ? "orvlet" : "")
                .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.5)
                .foregroundStyle(CalmVisualStyle.tint(model.accent, scheme: scheme).opacity(0.8))
                .overlay { WindowDragArea() }
            HStack {
                Button {
                    model.taskShelfVisible.toggle()
                } label: {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .medium)).frame(
                        width: 28, height: 26
                    )
                    .overlay(alignment: .topTrailing) {
                        if model.overflowTaskCount > 0 {
                            Text(model.overflowTaskCount > 9 ? "9+" : "\(model.overflowTaskCount)")
                                .font(.system(size: 7, weight: .semibold, design: .rounded)).monospacedDigit()
                                .padding(.horizontal, 2).frame(minWidth: 10).frame(height: 10)
                                .background(
                                    scheme == .dark
                                        ? Color(red: 0.23, green: 0.22, blue: 0.29)
                                        : Color(red: 0.88, green: 0.87, blue: 0.94), in: Capsule())
                        }
                    }
                }.buttonStyle(WindowDragButtonStyle()).help("All tasks · \(model.overflowTaskCount) tucked away")
                    .accessibilityLabel("All tasks, \(model.overflowTaskCount) tucked away")
                Spacer(minLength: 4)
                Button {
                    model.selectChat(!model.commandPanelVisible)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 26)
                        .background(model.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topTrailing) {
                            if model.hasTaskWork {
                                if model.motionReduced {
                                    Image(systemName: "hourglass").font(.system(size: 6)).padding(1)
                                } else {
                                    ProgressView().controlSize(.mini).scaleEffect(0.5).frame(width: 10, height: 10)
                                }
                            } else if model.hasUnreadReply {
                                Circle().fill(CalmVisualStyle.tint(model.accent, scheme: scheme)).frame(
                                    width: 4, height: 4
                                ).padding(2)
                            }
                        }
                }.buttonStyle(WindowDragButtonStyle()).help("Ask Orvlet · " + model.settings.shortcut.title)
                    .accessibilityLabel("Ask Orvlet")
            }.foregroundStyle(CalmVisualStyle.tint(model.accent, scheme: scheme))
        }
    }
}

/// An on-demand list, not another permanent dashboard. All task actions retain their owning IDs.
struct CalmTaskShelf: View {
    @ObservedObject var model: AppModel
    @State private var hoveredTask: UUID?
    @State private var draggedTask: UUID?
    @State private var dropTarget: UUID?
    @State private var dropAfter = false
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Tasks").font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer(minLength: 0)
                Button {
                    model.taskListEditing.toggle()
                } label: {
                    Image(systemName: model.taskListEditing ? "checkmark" : "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium)).frame(width: 28, height: 28)
                }.foregroundStyle(.secondary)
                    .help(model.taskListEditing ? "Done" : "Edit tasks")
                    .accessibilityLabel(model.taskListEditing ? "Done" : "Edit tasks")
                Button {
                    model.selectChat(true)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 28)
                }.buttonStyle(WindowDragButtonStyle()).foregroundStyle(.secondary)
                    .help("Add task").accessibilityLabel("Add task")
            }.frame(height: 28).background { WindowDragArea() }
            if let error = model.lastActionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.orderedTasks) { task in
                        row(task)
                            .overlay(alignment: dropAfter ? .bottom : .top) {
                                if dropTarget == task.id {
                                    Capsule().fill(model.accent).frame(height: 2).padding(.horizontal, 6)
                                        .allowsHitTesting(false)
                                }
                            }
                            .opacity(draggedTask == task.id ? 0.65 : 1)
                    }
                    if model.sideTasks.isEmpty {
                        Text("Your tasks will appear here.").foregroundStyle(.secondary).font(.system(size: 12))
                            .padding(16)
                    }
                }.animation(CalmMotion.layout(reduced: model.motionReduced), value: model.orderedTasks.map(\.id))
            }.frame(maxHeight: 300)
        }.buttonStyle(.plain).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(model.settings.appearance.scheme)
            .onExitCommand { model.taskShelfVisible = false }
    }
    func row(_ task: SideTask) -> some View {
        HStack(spacing: 6) {
            Group {
                if hoveredTask == task.id || draggedTask == task.id {
                    Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(
                        .secondary)
                } else {
                    TaskActivityGlyph(model: model, task: task)
                }
            }
            .frame(width: 24, height: 32).contentShape(Rectangle())
            .help("Drag to reorder or close " + task.title).accessibilityLabel("Reorder " + task.title)
            .overlay {
                TaskDragHandle(
                    appearance: model.dragAppearance(task.id), close: { model.closeTask(task.id) },
                    begin: {
                        draggedTask = task.id
                        model.draggingTaskID = task.id
                    },
                    preview: { offset in
                        let ids = model.orderedTasks.map(\.id)
                        if let index = ids.firstIndex(of: task.id), offset != 0, ids.indices.contains(index + offset) {
                            dropTarget = ids[index + offset]
                            dropAfter = offset > 0
                        } else {
                            dropTarget = nil
                        }
                    }, commit: { offset in model.moveTask(task.id, by: offset) },
                    end: {
                        draggedTask = nil
                        model.draggingTaskID = nil
                        dropTarget = nil
                    }
                )
                .accessibilityHidden(true)
            }
            Button {
                model.taskRanking.record(task.id, .open)
                if model.selectTask(task.id, expanded: true) { model.taskShelfVisible = false }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.system(size: 12)).lineLimit(1)
                        Text(
                            model.taskActivity(task)?.label
                                ?? (task.hidden
                                    ? "Hidden"
                                    : task.kind == .timer && !task.finished
                                        ? (task.state["remaining"] ?? "") + " · " + task.status : task.status)
                        )
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.help("Open " + task.title)
            if model.taskListEditing {
                Button {
                    model.dismissTask(task.id)
                } label: {
                    Image(systemName: "eye.slash").frame(width: 26, height: 30)
                }
                .disabled(task.hidden).help("Hide " + task.title).accessibilityLabel("Hide " + task.title)
                Button {
                    model.closeTask(task.id)
                } label: {
                    Image(systemName: "xmark").frame(width: 26, height: 30)
                }
                .help("Close " + task.title).accessibilityLabel("Close " + task.title)
            } else if task.terminalLabel == nil
                && (task.kind == .timer || model.quickMediaTasks.contains(where: { $0.id == task.id }))
            {
                Button {
                    model.taskRanking.record(task.id, .control)
                    if task.kind == .timer {
                        model.timerAction(task.id, action: "toggle")
                    } else {
                        model.controlMedia(task.id, operation: "toggle")
                    }
                } label: {
                    Image(
                        systemName: task.kind == .timer
                            ? (task.finished ? "arrow.clockwise" : task.deadline == nil ? "play.fill" : "pause.fill")
                            : task.playing ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 11)).frame(width: 28, height: 32)
                }.help(task.state["toggleLabel"] ?? "Toggle").accessibilityLabel(
                    (task.state["toggleLabel"] ?? "Toggle") + " " + task.title)
            }
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                .primary.opacity(hoveredTask == task.id ? 0.045 : 0.025), in: RoundedRectangle(cornerRadius: 10)
            )
            .onHover { if $0 { hoveredTask = task.id } else if hoveredTask == task.id { hoveredTask = nil } }
            .contextMenu {
                Button("Chat") { model.openTaskConversation(task.id) }
                Button("Hide") { model.dismissTask(task.id) }.disabled(task.hidden)
                Divider()
                Button("Remove from Tasks") { model.closeTask(task.id) }
            }
            .animation(CalmMotion.response(reduced: model.motionReduced), value: hoveredTask == task.id)

    }
}

struct CalmMediaRail: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.quickMediaTasks) { task in CalmMediaControl(model: model, task: task) }
            }.padding(.horizontal, 10)
        }.frame(height: 32).background(.primary.opacity(0.025))
    }
}

extension AppModel {
    var quickMediaTasks: [SideTask] {
        sideTasks.filter { task in
            task.kind == .web && task.isMediaTask && (task.id == browser.id || parkedBrowsers[task.id] != nil)
        }
    }
    /// Automatic priorities are the default; an explicit user order always wins.
    var automaticTaskOrder: [SideTask] {
        let media = quickMediaTasks.filter { !$0.hidden }
        let timers = visibleTasks.filter { $0.kind == .timer }
        let firstTimer =
            timers.filter { $0.finished && $0.status != "Stopped" }.max {
                ($0.completedAt ?? $0.created) < ($1.completedAt ?? $1.created)
            } ?? timers.first
        var result = [SideTask]()
        func append(_ task: SideTask?) {
            if let task, !result.contains(where: { $0.id == task.id }) { result.append(task) }
        }
        append(visibleTasks.first { $0.id == ambientRequestID })
        if !result.contains(where: { $0.isMediaTask }) {
            append(media.first(where: { $0.id == preferredMediaTaskID }) ?? media.first)
        }
        append(firstTimer)
        for task in media + timers + sideTasks { append(task) }
        return result
    }
    var orderedTasks: [SideTask] {
        let fallback = automaticTaskOrder
        let explicit = !taskOrder.isEmpty
        let order = explicit ? taskOrder : learnedTaskOrder
        guard !order.isEmpty else { return fallback }
        let lookup = Dictionary(uniqueKeysWithValues: sideTasks.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result = order.compactMap { id -> SideTask? in
            guard seen.insert(id).inserted else { return nil }
            return lookup[id]
        }
        for task in explicit ? sideTasks : fallback where seen.insert(task.id).inserted { result.append(task) }
        if !explicit {
            let urgent = fallback.filter {
                $0.id == ambientRequestID
                    || ($0.kind == .timer
                        && (($0.finished && $0.status != "Stopped") || ($0.deadline != nil && $0.remaining <= 60)))
            }
            let urgentIDs = Set(urgent.map(\.id))
            result = urgent + result.filter { !urgentIDs.contains($0.id) }
        }
        return result
    }
    var ambientTasks: [SideTask] {
        Array(orderedTasks.filter { !$0.hidden }.prefix(min(6, max(1, settings.compactTaskLimit))))
    }
    /// Insert before a stable task ID; nil appends. Nothing is recreated or stopped.
    func moveTask(_ id: UUID, before target: UUID?) {
        guard id != target, sideTasks.contains(where: { $0.id == id }),
            target == nil || sideTasks.contains(where: { $0.id == target })
        else { return }
        let original = orderedTasks.map(\.id)
        var ids = original.filter { $0 != id }
        let index = target.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex
        ids.insert(id, at: index)
        if let old = original.firstIndex(of: id), old != index {
            taskRanking.record(id, index < old ? .promote : .demote)
        }
        taskOrder = ids
        taskRanking.schedule()
        persistSideTasks()
        onResize?(windowSize)
    }
    func moveTask(_ id: UUID, by offset: Int) {
        let ids = orderedTasks.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        let remaining = ids.filter { $0 != id }
        let destination = index + offset
        moveTask(id, before: destination < remaining.count ? remaining[destination] : nil)
    }
    func resetTaskOrder() {
        taskOrder = []
        learnedTaskOrder = []
        persistSideTasks()
        taskRanking.schedule()
        onResize?(windowSize)
    }
    func setCompactTaskLimit(_ value: Int) {
        let limit = min(6, max(1, value))
        guard settings.compactTaskLimit != limit else { return }
        settings.compactTaskLimit = limit
        if !isLiveTest { settings.save() }
        onResize?(windowSize)
    }
    var overflowTaskCount: Int { sideTasks.count - ambientTasks.count }
    var microMediaTasks: [SideTask] {
        ambientTasks.filter { task in quickMediaTasks.contains(where: { $0.id == task.id }) }
    }
    var microTimerTasks: [SideTask] { ambientTasks.filter { $0.kind == .timer } }
    var microWidth: Double { Double(100 + ambientTasks.count * 126) }
    func setCompactLayout(_ layout: CompactLayout) {
        guard settings.compactLayout != layout else { return }
        settings.compactLayout = layout
        if !isLiveTest { settings.save() }
        onResize?(windowSize)
    }
}
