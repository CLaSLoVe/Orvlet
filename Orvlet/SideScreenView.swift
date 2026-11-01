import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject var model: PetModel
    private var scheme: ColorScheme { model.settings.appearance.scheme ?? systemScheme }
    private var content: NSRect { model.shellLayout.localContent }
    private var compact: NSRect { model.shellLayout.localCompact }
    var body: some View {
        ZStack(alignment:.topLeading) {
            if model.shellExpanded {
                // One shared surface, with the original compact controls kept in the same screen position.
                Rectangle().fill(.primary.opacity(0.025))
                    .frame(width:model.settings.compactLayout == .vertical ? compact.width : model.shellLayout.frame.width,
                           height:model.settings.compactLayout == .vertical ? model.shellLayout.frame.height : compact.height)
                    .offset(x:model.settings.compactLayout == .vertical ? compact.minX : 0,
                            y:model.settings.compactLayout == .vertical ? 0 : compact.minY)
            }
            DetailContentView(model:model)
                .frame(width:content.width > 0 ? content.width : model.preferredWebSize.width,
                       height:content.height > 0 ? content.height : model.preferredWebSize.height)
                .offset(x:content.minX,y:content.minY)
                .opacity(!model.collapsed && !model.taskShelfVisible ? 1 : 0)
                .allowsHitTesting(!model.collapsed && !model.taskShelfVisible)
                .accessibilityHidden(model.collapsed || model.taskShelfVisible)
            if model.taskShelfVisible {
                CalmTaskShelf(model:model).frame(width:content.width,height:content.height).offset(x:content.minX,y:content.minY)
            }
            CalmStrip(model:model).frame(width:compact.width,height:compact.height).offset(x:compact.minX,y:compact.minY)
        }
        .frame(width:model.shellLayout.frame.width,height:model.shellLayout.frame.height,alignment:.topLeading)
        .background { WindowDragArea() }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(colors:scheme == .dark
                    ? [Color(red:0.14,green:0.135,blue:0.18).opacity(0.94),Color(red:0.10,green:0.095,blue:0.14).opacity(0.94)]
                    : [Color(red:0.98,green:0.975,blue:1).opacity(0.92),Color(red:0.93,green:0.925,blue:0.965).opacity(0.9)],startPoint:.topLeading,endPoint:.bottomTrailing)
                LinearGradient(colors:[model.accent.opacity(0.055),.clear],startPoint:.topTrailing,endPoint:.bottomLeading)
            }
        }
        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(scheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.9),lineWidth:1))
        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(model.accent.opacity(0.12),lineWidth:0.5))
        .clipShape(RoundedRectangle(cornerRadius:16))
        .environment(\.colorScheme,scheme)
        .preferredColorScheme(model.settings.appearance.scheme)
        .onChange(of:model.compactSize) { _, _ in model.onResize?(model.windowSize) }
        .onHover { model.pointerChanged($0) }
    }
}

struct DetailContentView: View {
    @ObservedObject var model: PetModel
    @State private var inputActive = false
    var body: some View {
        interactionCard
            .overlay(alignment:.topLeading) { sourceHosts }
            .preferredColorScheme(model.settings.appearance.scheme)
            .onExitCommand { model.collapse() }
            .onReceive(NotificationCenter.default.publisher(for:NSMenu.didBeginTrackingNotification)) { _ in model.menuTracking = true }
            .onReceive(NotificationCenter.default.publisher(for:NSMenu.didEndTrackingNotification)) { _ in model.menuTracking = false }
    }
    var interactionCard: some View {
        VStack(spacing:0) {
            HStack(spacing:7) {
                Button { model.collapse() } label: { Image(systemName:"chevron.down").font(.system(size:10)).frame(width:24,height:26) }
                    .buttonStyle(.plain).help("Collapse · Esc").accessibilityLabel("Collapse task details")
                if let task = model.selectedSideTask {
                    Button { model.closeTask(task.id) } label: { Image(systemName:"xmark").font(.system(size:10)).frame(width:24,height:26) }
                        .buttonStyle(.plain).help(task.kind == .timer ? "Stop and close timer" : "Close task").accessibilityLabel("Close " + task.title)
                }
                Text(model.selectedSideTask?.title ?? "Orvlet")
                    .font(.system(size:10,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:4)

                Menu {
                    Button(model.collapsed ? "Expand card" : "Collapse card") { if model.collapsed { model.reveal() } else { model.collapse() } }
                    Toggle("Keep open",isOn:$model.pinned)
                    if let card = model.selectedSideTask {
                        if card.kind == .web {
                            Button("Open source page") { model.cardAction(card.id,action:"source",value:nil) }
                            Button("Close page",role:.destructive) { model.closeWebTask(card.id) }
                        }
                        if card.kind == .timer {
                            Button("Restart timer") { model.timerAction(card.id,action:"restart") }
                            Button("Stop timer",role:.destructive) { model.timerAction(card.id,action:"stop") }
                        }
                        Button("Hide card") { model.dismissTask(card.id) }
                    }
                    Button("Settings…") { model.onSettings?() }
                } label: { Image(systemName:"ellipsis").font(.system(size:11)).frame(width:20,height:23) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if !model.collapsed {
                    Button { model.pinned.toggle() } label: { Image(systemName:model.pinned ? "pin.fill" : "pin").font(.system(size:10)).frame(width:20,height:23) }
                        .buttonStyle(.plain).help("Keep open")
                }
            }.padding(.horizontal,10).frame(height:30).background { WindowDragArea() }
            if model.showingWeb {
                HStack {
                    if let selected = model.selectedSideTask, let source = model.liveBrowsers.first(where: { $0.id == selected.id }) {
                        Button { source.webView.goBack() } label: { Image(systemName:"chevron.left").frame(width:26,height:22) }.help("Back").disabled(!source.webView.canGoBack)
                        Button { source.webView.goForward() } label: { Image(systemName:"chevron.right").frame(width:26,height:22) }.help("Forward").disabled(!source.webView.canGoForward)
                        Button { source.webView.reload() } label: { Image(systemName:"arrow.clockwise") }.help("Reload")
                    }
                    Spacer()
                    Text(model.selectedSideTask?.sourceURL.flatMap { URL(string:$0)?.host } ?? "Source page").lineLimit(1).foregroundStyle(.secondary)
                }.font(.system(size:10)).buttonStyle(.plain).padding(.horizontal,10).frame(height:22).background { WindowDragArea() }
                Spacer(minLength:0)
            } else if let task = model.selectedSideTask {
                HTMLCardView(markup:task.presentation,compact:false,state:task.state,allowedActions:task.allowedActions,
                             appearance:model.settings.appearance,accent:model.settings.theme.hex,
                             action:{ model.cardAction(task.id,action:$0,value:$1) }, interaction: { active in
                    if inputActive != active { inputActive = active; model.controlInteraction(active) }
                }).id(task.id)
            } else {
                Button { model.selectChat(true) } label: {
                    HStack { Image(systemName:"sparkle").foregroundStyle(model.accent); Text("A little help, when you need it."); Spacer(); Text(model.settings.shortcut.title).foregroundStyle(.tertiary) }
                        .font(.system(size:11)).padding(12)
                }.buttonStyle(.plain)
            }
        }
    }
    var sourceHosts: some View {
        GeometryReader { geometry in
          ZStack {
            ForEach(model.liveBrowsers,id:\.id) { browser in
                WebSurface(webView:browser.webView)
                    .frame(width:max(1,geometry.size.width-6),height:max(1,geometry.size.height-56))
                    .opacity(model.showingWeb && model.selectedSideTask?.id == browser.id ? 1 : 0)
                    .allowsHitTesting(model.showingWeb && model.selectedSideTask?.id == browser.id)
                    .accessibilityHidden(!model.showingWeb || model.selectedSideTask?.id != browser.id)
            }
          }.offset(x:3,y:52)
        }
    }

}

struct CommandWindowView: View {
    @ObservedObject var model: PetModel
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { model.settings.appearance.scheme ?? systemScheme }
    var body: some View {
        CommandPanelView(model:model)
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    LinearGradient(colors:scheme == .dark
                        ? [Color(red:0.14,green:0.135,blue:0.18).opacity(0.94),Color(red:0.10,green:0.095,blue:0.14).opacity(0.94)]
                        : [Color(red:0.98,green:0.975,blue:1).opacity(0.92),Color(red:0.93,green:0.925,blue:0.965).opacity(0.9)],startPoint:.topLeading,endPoint:.bottomTrailing)
                }
            }
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(model.accent.opacity(0.18),lineWidth:0.5))
            .clipShape(RoundedRectangle(cornerRadius:16))
            .environment(\.colorScheme,scheme)
            .preferredColorScheme(model.settings.appearance.scheme)
    }
}

struct CommandPanelView: View {
    @ObservedObject var model: PetModel
    @FocusState private var focused: Bool
    @State private var history = false
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"sparkle").font(.system(size:19,weight:.light)).foregroundStyle(model.accent)
                TextField("What can I take care of?",text:$model.command)
                    .textFieldStyle(.plain).font(.system(size:17)).focused($focused).onSubmit(send)
                if model.busy {
                    Button { model.cancel() } label: { Image(systemName:"stop.circle").font(.system(size:18)) }.help("Stop current request")
                }
                Button(action:send) { Image(systemName:"arrow.up.circle.fill").font(.system(size:22)).foregroundStyle(model.accent) }
                    .disabled(model.command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).help("Send")
            }.buttonStyle(.plain).padding(20)
            Divider().opacity(0.3)
            if let error = model.lastActionError { Text(error).font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,6) }
            if model.busy {
                HStack(spacing:8) { ProgressView().controlSize(.small); Text("Taking care of it…"); Spacer(); Text("You can add a message").foregroundStyle(.tertiary) }
                    .font(.system(size:11)).padding(.horizontal,20).padding(.vertical,12)
            } else if history {
                ScrollView { VStack(alignment:.leading,spacing:8) { ForEach(model.messages) { message in
                    Text(message.text).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:message.isUser ? .trailing : .leading)
                } }.padding(12) }.frame(maxHeight:110)
            } else if let last = model.messages.last(where:{ !$0.isUser }) {
                ScrollView { Text(last.text).font(.system(size:13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,14) }
                    .frame(maxHeight:110)
            } else {
                HStack(spacing:8) {
                    suggestion("Play some music",symbol:"music.note",label:"Music")
                    suggestion("Timer 12 minutes",symbol:"timer",label:"Timer")
                    suggestion("Add a calendar event",symbol:"calendar",label:"Calendar")
                    Spacer(minLength:0)
                }.padding(.horizontal,20).padding(.vertical,14)
            }
            HStack {
                Text(model.settings.shortcut.title + " to summon").foregroundStyle(.tertiary).overlay { WindowDragArea() }
                Spacer()
                Button { history.toggle() } label: { Image(systemName:"clock.arrow.circlepath") }.help("Conversation history")
                Button { model.onSettings?() } label: { Image(systemName:"gearshape") }.help("Settings")
                Button { model.selectChat(false) } label: { Text("esc").padding(.horizontal,5).padding(.vertical,2).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:4)) }.help("Return to your work")
            }.font(.system(size:10)).buttonStyle(.plain).padding(.horizontal,20).padding(.bottom,12)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
            .background { WindowDragArea() }
            .preferredColorScheme(model.settings.appearance.scheme).tint(model.accent)
            .onAppear { focused = true }
            .onChange(of:model.commandWindowHeight) { _, height in model.onCommandResize?(height) }
            .onChange(of:model.commandFocusRequest) { _, _ in focused = true }
            .onExitCommand { model.selectChat(false) }
    }
    func suggestion(_ text: String, symbol: String, label: String) -> some View {
        Button { model.command = text; focused = true } label: { Label(label,systemImage:symbol).font(.system(size:10)).padding(8).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
    }
    func send() {
        guard !model.command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        focused = false; model.sendCommand()
    }
}

extension ThemeTone {
    var hex: String {
        switch self { case .iris: return "#a49bdf"; case .mint: return "#7cc4ac"; case .peach: return "#efa878"; case .sky: return "#75bdec"; case .rose: return "#e391ae"; case .stone: return "#b0b8c7" }
    }
}
