import SwiftUI

struct CalmMediaControl: View {
    @ObservedObject var model: PetModel
    let task: SideTask
    var body: some View {
        HStack(spacing:6) {
            Button { model.toggleTaskPresentation(task.id) } label: {
                HStack(spacing:6) {
                    CalmGlyph(symbol:"waveform",accent:model.accent)
                    Text(task.title).font(.system(size:11,weight:.medium,design:.rounded)).lineLimit(1).frame(width:52,alignment:.leading)
                }.frame(width:78,height:28)
            }.buttonStyle(WindowDragButtonStyle()).help(task.title).accessibilityLabel("Open " + task.title)
            Button { model.controlMedia(task.id,operation:"toggle") } label: {
                Image(systemName:task.playing ? "pause.fill" : "play.fill")
                    .font(.system(size:9,weight:.semibold)).frame(width:24,height:28)
            }.buttonStyle(WindowDragButtonStyle()).help((task.playing ? "Pause " : "Play ") + task.title)
                .accessibilityLabel((task.playing ? "Pause " : "Play ") + task.title)
        }.frame(width:108,height:28)
    }
}

struct CalmTimerControl: View {
    @ObservedObject var model: PetModel
    let task: SideTask
    var body: some View {
        HStack(spacing:6) {
            Button { model.toggleTaskPresentation(task.id) } label: {
                HStack(spacing:6) {
                    CalmGlyph(symbol:task.finished ? "checkmark" : "timer",accent:model.accent)
                    Text(task.finished ? "Done" : task.state["remaining"] ?? "")
                        .font(.system(size:11,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width:52,alignment:.leading)
                }.frame(width:78,height:28)
            }.buttonStyle(WindowDragButtonStyle()).help(task.title).accessibilityLabel(task.title + ", " + (task.state["remaining"] ?? ""))
            Button { model.timerAction(task.id,action:"toggle") } label: {
                Image(systemName:task.finished ? "arrow.clockwise" : task.deadline == nil ? "play.fill" : "pause.fill")
                    .font(.system(size:9,weight:.medium)).frame(width:24,height:28)
            }.buttonStyle(WindowDragButtonStyle()).help(task.state["toggleLabel"] ?? "Pause timer")
                .accessibilityLabel((task.state["toggleLabel"] ?? "Pause") + " " + task.title)
        }.frame(width:108,height:28)
    }
}

struct CalmTaskControl: View {
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: PetModel
    let task: SideTask
    var body: some View {
        Group {
            if model.isPreparingTask(task) {
                Button { if task.id == model.requestCardID { model.selectChat(true) } else { model.toggleTaskPresentation(task.id) } } label: {
                    HStack(spacing:6) {
                        CalmGlyph(symbol:"hourglass",accent:model.accent)
                        VStack(alignment:.leading,spacing:1) {
                            Text(task.title).font(.system(size:10,weight:.medium,design:.rounded)).lineLimit(1)
                            Text(model.preparationLabel).font(.system(size:9,weight:.medium,design:.rounded)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width:82,alignment:.leading)
                    }.frame(width:108,height:28)
                }.buttonStyle(WindowDragButtonStyle()).help(task.title + " · " + model.preparationLabel)
            } else if model.quickMediaTasks.contains(where: { $0.id == task.id }) {
                CalmMediaControl(model:model,task:task)
            } else if task.kind == .timer {
                CalmTimerControl(model:model,task:task)
            } else if let markup = task.plan?.markup, !markup.compactHTML.isEmpty {
                HTMLCardView(markup:markup,compact:true,state:task.state,allowedActions:task.allowedActions,
                             appearance:model.settings.appearance,accent:model.settings.theme.hex,action:{ _, _ in })
                    .frame(width:108,height:28)
                    .overlay(alignment:.leading) { CalmGlyph(symbol:task.symbol,accent:model.accent).allowsHitTesting(false) }
                    .overlay { WindowDragArea(onClick:{ model.toggleTaskPresentation(task.id) }) }
                    .accessibilityLabel(task.title).help(task.title)
            } else {
                Button { model.toggleTaskPresentation(task.id) } label: {
                    HStack(spacing:6) {
                        CalmGlyph(symbol:task.symbol,accent:model.accent)
                        Text(task.title).font(.system(size:11,weight:.medium,design:.rounded)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(width:108,height:28)
                }.buttonStyle(WindowDragButtonStyle()).help(task.title).accessibilityLabel("Open " + task.title)
            }
        }.frame(width:120,height:34)
            .background {
                RoundedRectangle(cornerRadius:10).fill(scheme == .dark ? Color.white.opacity(hovering ? 0.10 : 0.055) : Color.white.opacity(hovering ? 0.98 : 0.76))
                    .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.95),lineWidth:0.5))
                    .shadow(color:Color.black.opacity(scheme == .dark ? 0.08 : 0.035),radius:2,y:1)
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Close task") { model.closeTask(task.id) }
                Button("Hide task") { model.dismissTask(task.id) }
            }
    }
}

struct CalmStrip: View {
    @ObservedObject var model: PetModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if model.settings.compactLayout == .vertical {
                VStack(spacing:4) {
                    toolbar.frame(width:120,height:28)
                    ForEach(model.ambientTasks) { task in CalmTaskControl(model:model,task:task) }
                }.padding(.vertical,6).frame(width:136)
            } else {
                HStack(spacing:6) {
                    toolbar.frame(width:84,height:28)
                    ForEach(model.ambientTasks) { task in CalmTaskControl(model:model,task:task) }
                }.padding(.horizontal,8).frame(height:44)
            }
        }
        .background { WindowDragArea() }
        .contextMenu {
            Picker("Layout",selection:Binding(get:{ model.settings.compactLayout },set:{ model.setCompactLayout($0) })) {
                ForEach(CompactLayout.allCases,id:\.self) { Text($0.title).tag($0) }
            }
            Button("All tasks") { model.taskShelfVisible = true }
            Button("Open Orvlet") { model.selectChat(true) }
            Button("Hide strip") { model.hide() }
            Button("Settings…") { model.onSettings?() }
        }
    }
    var toolbar: some View {
        ZStack {
            Text(model.settings.compactLayout == .vertical ? "orvlet" : "")
                .font(.system(size:9,weight:.semibold,design:.rounded)).tracking(0.5)
                .foregroundStyle(CalmVisualStyle.tint(model.accent,scheme:scheme).opacity(0.8))
                .overlay { WindowDragArea() }
            HStack {
                Button { model.taskShelfVisible.toggle() } label: {
                    Image(systemName:"square.stack.3d.up").font(.system(size:11,weight:.medium)).frame(width:28,height:26)
                        .overlay(alignment:.topTrailing) {
                            if model.overflowTaskCount > 0 {
                                Text(model.overflowTaskCount > 9 ? "9+" : "\(model.overflowTaskCount)")
                                    .font(.system(size:7,weight:.semibold,design:.rounded)).monospacedDigit()
                                    .padding(.horizontal,2).frame(minWidth:10).frame(height:10)
                                    .background(scheme == .dark ? Color(red:0.23,green:0.22,blue:0.29) : Color(red:0.88,green:0.87,blue:0.94),in:Capsule())
                            }
                        }
                }.buttonStyle(WindowDragButtonStyle()).help("All tasks · \(model.overflowTaskCount) tucked away")
                    .accessibilityLabel("All tasks, \(model.overflowTaskCount) tucked away")
                Spacer(minLength:4)
                Button { model.selectChat(!model.commandPanelVisible) } label: {
                    Image(systemName:"plus").font(.system(size:11,weight:.medium)).frame(width:28,height:26)
                        .background(model.accent.opacity(0.12),in:RoundedRectangle(cornerRadius:9))
                        .overlay(alignment:.topTrailing) {
                            if model.busy || model.buildingSurface || model.hasUnreadReply {
                                Circle().fill(CalmVisualStyle.tint(model.accent,scheme:scheme)).frame(width:4,height:4).padding(2)
                            }
                        }
                }.buttonStyle(WindowDragButtonStyle()).help("Ask Orvlet · " + model.settings.shortcut.title).accessibilityLabel("Ask Orvlet")
            }.foregroundStyle(CalmVisualStyle.tint(model.accent,scheme:scheme))
        }
    }
}

/// An on-demand list, not another permanent dashboard. All task actions retain their owning IDs.
struct CalmTaskShelf: View {
    @ObservedObject var model: PetModel
    @State private var query = ""
    var matches: [SideTask] {
        model.sideTasks.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing:8) {
            HStack {
                Text("Tasks").font(.system(size:12,weight:.medium))
                Spacer()
                Picker("Layout",selection:Binding(get:{ model.settings.compactLayout },set:{ model.setCompactLayout($0) })) {
                    ForEach(CompactLayout.allCases,id:\.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
                Button { model.taskShelfVisible = false } label: { Image(systemName:"xmark") }.help("Close task list")
            }
            TextField("Find a task",text:$query).textFieldStyle(.roundedBorder).font(.system(size:12))
            if let error = model.lastActionError { Text(error).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            ScrollView {
                LazyVStack(spacing:4) {
                    ForEach(matches) { task in row(task) }
                    if matches.isEmpty { Text(query.isEmpty ? "Your tasks will appear here." : "No matching tasks.").foregroundStyle(.secondary).font(.system(size:12)).padding(16) }
                }
            }.frame(maxHeight:300)
        }.buttonStyle(.plain).padding(12).frame(maxWidth:.infinity,maxHeight:.infinity)
            .preferredColorScheme(model.settings.appearance.scheme)
            .onExitCommand { model.taskShelfVisible = false }
    }
    func row(_ task: SideTask) -> some View {
        HStack(spacing:6) {
            Button {
                if model.selectTask(task.id,expanded:true) { model.taskShelfVisible = false }
            } label: {
                HStack(spacing:8) {
                    Image(systemName:task.symbol).frame(width:16).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:3) {
                        Text(task.title).font(.system(size:12)).lineLimit(1)
                        Text(task.kind == .timer && !task.finished ? (task.state["remaining"] ?? "") + " · " + task.status : task.status)
                            .font(.system(size:10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.help("Open " + task.title)
            if task.kind == .timer || model.quickMediaTasks.contains(where:{$0.id == task.id}) {
                Button {
                    if task.kind == .timer { model.timerAction(task.id,action:"toggle") }
                    else { model.controlMedia(task.id,operation:"toggle") }
                } label: {
                    Image(systemName:task.kind == .timer ? (task.finished ? "arrow.clockwise" : task.deadline == nil ? "play.fill" : "pause.fill") : task.playing ? "pause.fill" : "play.fill")
                        .font(.system(size:11)).frame(width:28,height:32)
                }.help(task.state["toggleLabel"] ?? "Toggle").accessibilityLabel((task.state["toggleLabel"] ?? "Toggle") + " " + task.title)
            }
            Button { model.closeTask(task.id) } label: { Image(systemName:"xmark").font(.system(size:10)).frame(width:26,height:30) }
                .help(task.kind == .timer ? "Stop and close timer" : "Close task").accessibilityLabel("Close " + task.title)
            Menu {
                if task.hidden { Button("Restore task") { model.selectTask(task.id) } }
                else { Button("Hide from compact area") { model.dismissTask(task.id) } }
                if task.kind == .timer {
                    Button("Restart") { model.timerAction(task.id,action:"restart") }
                    Button("Stop timer") { model.timerAction(task.id,action:"stop") }
                }
                if task.kind == .web { Button("Close page",role:.destructive) { model.closeWebTask(task.id) } }
                if task.kind == .calendar { Button("Open Calendar") { model.cardAction(task.id,action:"calendar",value:nil) } }
            } label: { Image(systemName:"ellipsis").frame(width:20,height:30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(.horizontal,7).padding(.vertical,5).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
    }
}

struct CalmMediaRail: View {
    @ObservedObject var model: PetModel
    var body: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                ForEach(model.quickMediaTasks) { task in CalmMediaControl(model:model,task:task) }
            }.padding(.horizontal,10)
        }.frame(height:32).background(.primary.opacity(0.025))
    }
}

extension PetModel {
    var quickMediaTasks: [SideTask] {
        sideTasks.filter { task in
            task.kind == .web && task.isMediaTask && (task.id == browser.id || parkedBrowsers[task.id] != nil)
        }
    }
    /// A fixed two-slot budget. Pausing and selecting never reorder media; timer completion can surface once.
    var ambientTasks: [SideTask] {
        let media = quickMediaTasks.filter { !$0.hidden }
        let timers = visibleTasks.filter { $0.kind == .timer }
        let firstTimer = timers.filter { $0.finished && $0.status != "Stopped" }.max { ($0.completedAt ?? $0.created) < ($1.completedAt ?? $1.created) } ?? timers.first
        var result = [SideTask]()
        if let id = ambientRequestID, let current = visibleTasks.first(where:{$0.id == id}) { result.append(current) }
        if let first = media.first, !result.contains(where:{$0.id == first.id}), result.count < 2 { result.append(first) }
        if let firstTimer, !result.contains(where:{$0.id == firstTimer.id}), result.count < 2 { result.append(firstTimer) }
        for task in media + timers + visibleTasks {
            if result.count == 2 { break }
            if !result.contains(where: { $0.id == task.id }) { result.append(task) }
        }
        return result
    }
    var overflowTaskCount: Int { sideTasks.count - ambientTasks.count }
    var microMediaTasks: [SideTask] { ambientTasks.filter { task in quickMediaTasks.contains(where:{$0.id == task.id}) } }
    var microTimerTasks: [SideTask] { ambientTasks.filter { $0.kind == .timer } }
    var microWidth: Double { Double(100 + ambientTasks.count * 126) }
    func setCompactLayout(_ layout: CompactLayout) {
        guard settings.compactLayout != layout else { return }
        settings.compactLayout = layout
        if !isLiveTest { settings.save() }
        onResize?(windowSize)
    }
}
