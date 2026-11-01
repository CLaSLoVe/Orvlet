#if DEBUG
import AppKit
import SwiftUI
import WebKit

@MainActor
enum SideScreenCheck {
    static func run(_ model: PetModel, delegate: AppDelegate) async {
        var checks: [String] = []
        var timerDispatchMilliseconds = 0.0
        func check(_ ok: Bool, _ label: String) throws {
            guard ok else { throw AgentError.message("Check failed: " + label) }
            checks.append(label)
        }
        func pause() async throws { try await Task.sleep(for:.milliseconds(450)) }
        func descendants(_ root: NSView) -> [WKWebView] { (root as? WKWebView).map { [$0] } ?? root.subviews.flatMap(descendants) }
        func cardView() async throws -> WKWebView {
            for _ in 0..<30 {
                for web in descendants(delegate.detailPanel.contentView!) {
                    if (try? await web.evaluateJavaScript("typeof window.updateCard === 'function'")) as? Bool == true { return web }
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            throw AgentError.message("Generated card WebView did not load")
        }
        do {
            model.isLiveTest = true; model.persistHistory = false; model.settings = ModelSettings(); model.settings.autoAdapt = false
            model.settings.appearance = .light; model.settings.reduceMotion = true
            let screen = NSRect(x:-1440,y:0,width:1440,height:900)
            let anchors = [NSRect(x:-1428,y:12,width:313,height:32),NSRect(x:-325,y:12,width:313,height:32),
                           NSRect(x:-1428,y:856,width:313,height:32),NSRect(x:-325,y:856,width:313,height:32),
                           NSRect(x:-900,y:440,width:313,height:32)]
            try check(anchors.allSatisfy { anchor in
                let size = NSSize(width:560,height:420)
                let layout = ShellLayout.place(anchor:anchor,content:size,orientation:.horizontal,screen:screen)
                return screen.contains(layout.frame) && layout.compact == anchor && !anchor.intersects(layout.content)
            },"One shell stays on screen while preserving corner and center compact anchors")
            try check(PetModel.timerSeconds("计时12分钟") == 720 && PetModel.timerSeconds("timer 1.5 minutes") == 90 && PetModel.timerSeconds("不要计时12分钟") == nil, "Fast timer parsing accepts exact requests only")
            try check(PetModel.timerSeconds("帮我计时十分钟") == 600 && PetModel.timerSeconds("请设一个半小时的计时器") == 1800 && PetModel.timerSeconds("计时一分半") == 90 && PetModel.timerSeconds("start a timer for 1 hour 20 minutes") == 4800,"Common Chinese and English durations bypass model interpretation")
            try check(PetModel.timerSeconds("比如计时十分钟") == nil && PetModel.timerSeconds("解释一下计时10分钟") == nil,"Examples and explanations do not start a timer")
            model.busy = true; model.latestIntent = "Keep the unrelated task"
            let dispatchStart = Date()
            model.command = "帮我计时十分钟"; model.sendCommand()
            timerDispatchMilliseconds = Date().timeIntervalSince(dispatchStart) * 1000
            try check(timerDispatchMilliseconds < 500 && model.busy && model.latestIntent == "Keep the unrelated task" && abs(model.sideTasks.last!.deadline!.timeIntervalSince(dispatchStart)-600) < 0.1,"A timer starts locally while the agent is busy, without queuing or changing its request")
            model.timerAction(model.sideTasks.last!.id,action:"stop"); model.sideTasks.removeAll(); model.busy = false
            let received = Date().addingTimeInterval(-120)
            let delayed = try model.startTimer(seconds:600,receivedAt:received)
            try check(abs(model.sideTasks.last!.deadline!.timeIntervalSince(received)-600) < 0.001 && model.sideTasks.last!.remaining < 481,"Delayed interpretation does not add its latency to the timer deadline")
            model.timerAction(delayed,action:"stop"); model.sideTasks.removeAll()
            let timer = try model.startTimer(seconds:720,title:"Tea break")
            model.timerAction(timer,action:"toggle")
            try check(model.sideTasks.first?.deadline == nil && (model.sideTasks.first?.remaining ?? 0) > 718,"Pause retains remaining time")
            model.timerAction(timer,action:"toggle")
            try check(model.sideTasks.first?.deadline != nil,"Resume uses retained duration")
            model.dismissTask(timer)
            try check(model.sideTasks.first?.deadline != nil && model.visibleTasks.isEmpty,"Hiding does not stop a timer")
            model.selectTask(timer)
            model.selectChat(true); try await pause()
            try check(model.commandPanelVisible && delegate.commandPanel?.isVisible == true && delegate.commandPanel !== delegate.panel && !model.showingWeb,"Shortcut opens an independent input window without opening the webpage")
            model.selectChat(false)
            try check(!model.commandPanelVisible && model.sideTasks.first?.deadline != nil,"Dismissing command panel leaves tasks running")
            var bad = SideTask(kind:.result,title:"Unsafe").presentation; bad.html = "<script>window.bad=true</script>"
            var rejected = false
            do { _ = try bad.validated() } catch { rejected = true }
            try check(rejected,"Generated executable scripts are rejected")
            var unknown = SideTask(kind:.result,title:"Unknown").presentation
            unknown.html = "<button data-action='unregistered'>Go</button>"
            rejected = false
            do { try unknown.validateActions(["expand"]) } catch { rejected = true }
            try check(rejected,"Unknown generated action IDs are rejected before display")
            unknown.html = "<button>Unbound</button>"
            rejected = false
            do { try unknown.validateActions(["expand"]) } catch { rejected = true }
            try check(rejected,"Unbound decorative buttons are rejected in generated markup")
            let observation = try await model.browser.action(["action":"navigate","url":"http://127.0.0.1:19244/fixture"])
            var plan = SurfacePlan(components:[],width:320,height:180,title:"Library")
            plan.markup = CardMarkup(html:"<section class='library'><small>LISTENING</small><h2 data-bind='title'></h2><p data-bind='status'></p><button data-action='next'>Next item</button></section>",compactHTML:"<div class='small'><button data-action='expand'><strong data-bind='title'></strong></button><button data-action='next'>Next</button></div>",css:".library{display:grid;gap:14px;padding:10px}.small{display:flex;gap:8px;align-items:center;height:50px}.small button:first-child{flex:1;text-align:left;border:0;background:none}h2{font-size:19px}",height:170)
            plan.actions = [BoundCardAction(id:"next",binding:PageBinding(action:"click",role:"button",name:"Next item")), BoundCardAction(id:"toggle",binding:PageBinding(action:"media",operation:"toggle"))]
            var invalidType = plan
            invalidType.actions = [BoundCardAction(id:"next",binding:PageBinding(action:"type",role:"button",name:"Next item"))]
            rejected = false
            do { _ = try invalidType.validated(observation:observation) } catch { rejected = true }
            try check(rejected,"A real button cannot be misrepresented as a text input")
            let checked = try plan.validated(observation:observation)
            try check(checked.markup != nil && checked.actions?.count == 2,"HTML plan preserves layout with validated action registry")
            model.install(checked)
            try check(model.surface.markup == checked.markup,"Installing an HTML-only plan preserves its generated layout")
            model.hasCustomSurface = true; model.upsertWebTask(checked,activate:true)
            let first = model.browser
            model.pinned = true; model.selectTask(first.id,expanded:true,preferSource:false)
            delegate.panel.orderFrontRegardless()
            try await pause()
            let web = try await cardView()
            try await pause()
            let rendered = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
            try check(rendered.contains("Test library") && rendered.contains("Next"),"Generated HTML actually renders with host state")
            _ = try await web.evaluateJavaScript("document.querySelector('[data-action=next]').click()")
            try await pause()
            try check((try await first.webView.evaluateJavaScript("document.querySelector('#result').textContent")) as? String == "Track Two","HTML button bridge operates the real bound webpage")
            let signature = try await web.evaluateJavaScript("window.__sentinel=42; true")
            _ = signature
            model.sideTasks[model.sideTasks.firstIndex(where:{$0.id == first.id})!].title = "Changed track"
            try await pause()
            try check((try await web.evaluateJavaScript("window.__sentinel")) as? Int == 42,"Live state updates do not reload the generated document")
            // Keep the first source alive while another source becomes active.
            try model.prepareBrowserForNewTask()
            let second = model.browser
            _ = try await second.action(["action":"navigate","url":"http://127.0.0.1:19244/fixture?second"])
            model.upsertWebTask(checked,activate:true)
            model.cardAction(first.id,action:"next",value:nil); try await pause()
            try check(first !== second && model.parkedBrowsers.count == 1,"Web tasks retain separate live source contexts")
            try check((try await second.webView.evaluateJavaScript("document.querySelector('#result').textContent")) as? String == "","Background card actions do not operate the foreground task")
            try check(model.visibleTasks.count == 3,"Two web tasks and timer coexist")
            _ = try await first.action(["action":"media","operation":"play"])
            model.collapse(); try await pause()
            let anchor = delegate.ambientFrame
            for _ in 0..<3 {
                model.toggleTaskPresentation(first.id); try await pause()
                try check(delegate.ambientFrame == anchor && !model.collapsed && !model.showingWeb && delegate.detailPanel.isVisible,
                          "Opening the music card preserves the ambient entry point")
                try check(!model.shellLayout.compact.intersects(model.shellLayout.content) && model.shellLayout.frame == model.shellLayout.compact.union(model.shellLayout.content),"Compact controls and details share one contiguous window without overlap")
                model.pointerChanged(false); try await pause()
                try check(!model.collapsed,"Click expansion survives pointer exit")
                model.toggleTaskPresentation(first.id)
                try check(model.collapsed && !model.shellExpanded && delegate.ambientFrame == anchor,"The same stationary entry closes details")
            }
            model.selectTask(first.id,expanded:true,preferSource:true)
            let shellWindowNumber = delegate.panel.windowNumber
            let persistentSource = first.webView
            try await pause()
            try await snapshot(delegate.panel,path:"/tmp/orvlet-unified-source.png")
            let sourceFrame = delegate.panel.frame
            model.selectChat(true); try await pause()
            try check(delegate.panel.windowNumber == shellWindowNumber && model.commandPanelVisible && model.showingWeb && delegate.commandPanel !== delegate.panel && delegate.panel.frame == sourceFrame,"Independent input leaves the expanded webpage and its window untouched")
            model.taskShelfVisible = true; try await pause()
            try check(!model.commandPanelVisible && model.taskShelfVisible && delegate.panel.windowNumber == shellWindowNumber,"Opening the task list dismisses input without creating another task window")
            model.selectTask(first.id,expanded:true,preferSource:true); try await pause()
            try check(!model.taskShelfVisible && !model.commandPanelVisible && model.showingWeb && first.webView === persistentSource,"Returning to a task reuses its live webpage")
            model.collapse()
            let timeBefore = (try await first.webView.evaluateJavaScript("document.querySelector('audio').currentTime")) as? Double ?? 0
            try await Task.sleep(for:.milliseconds(1100))
            let timeAfter = (try await first.webView.evaluateJavaScript("document.querySelector('audio').currentTime")) as? Double ?? 0
            try check(timeAfter > timeBefore,"Source playback continues while the detail window is hidden")
            model.selectTask(timer,expanded:true)
            model.pinned = true
            delegate.dismissDetails(at:NSPoint(x:-10000,y:-10000))
            try check(!model.collapsed,"Pinned details ignore outside clicks")
            model.pinned = false
            delegate.dismissDetails(at:NSPoint(x:-10000,y:-10000))
            try check(model.collapsed && !model.shellExpanded,"Outside click dismisses unpinned details")
            model.selectTask(timer,expanded:true)
            let selectedBefore = model.selectedTaskID
            model.controlMedia(first.id,operation:"pause"); try await pause()
            try check((try await first.observe())["playing"] as? Bool == false && model.selectedTaskID == selectedBefore && model.quickMediaTasks.contains(where:{$0.id == first.id}),"Music can be paused while the timer is selected, without switching tasks")
            model.collapse(); model.pinned = true
            try check(model.windowSize == NSSize(width:136,height:116) && model.microMediaTasks.count == 1 && model.microTimerTasks.count == 1 && model.overflowTaskCount == 1,"Vertical ambient mode keeps music and a timer in two bounded slots")
            try await pause()
            try await snapshot(delegate.panel,path:"/tmp/orvlet-calm-music-timer.png")
            let restingFrame = delegate.panel.frame
            let restingIDs = model.ambientTasks.map(\.id)
            model.setCompactLayout(.horizontal); try await pause()
            try check(delegate.panel.frame.size == NSSize(width:352,height:44) && model.ambientTasks.map(\.id) == restingIDs,"Horizontal layout keeps the same controls in a bounded 44-point strip")
            try await snapshot(delegate.panel,path:"/tmp/orvlet-calm-horizontal.png")
            model.setCompactLayout(.vertical); try await pause()
            try check(delegate.panel.frame == restingFrame,"Switching orientation back restores the stationary top-left anchor")
            let legacySettings = try JSONDecoder().decode(ModelSettings.self,from:Data("{}".utf8))
            var savedSettings = legacySettings; savedSettings.compactLayout = .horizontal
            try check(legacySettings.compactLayout == .vertical && (try JSONDecoder().decode(ModelSettings.self,from:JSONEncoder().encode(savedSettings))).compactLayout == .horizontal,"Old settings default to vertical and orientation round-trips")
            let originals = model.sideTasks
            for n in 1...40 {
                var extra = SideTask(kind:.timer,title:"Background timer \(n)")
                extra.duration = 6000; extra.deadline = Date().addingTimeInterval(6000 + Double(n)); extra.status = "Counting down"
                model.sideTasks.append(extra)
            }
            model.reconcileTasks(); try await pause()
            try check(delegate.panel.frame == restingFrame && model.ambientTasks.map(\.id) == restingIDs && model.overflowTaskCount == 41,"Forty extra tasks are tucked away without growing or reordering the ambient area")
            let storeName = "orvlet.stack-check." + UUID().uuidString
            let store = UserDefaults(suiteName:storeName)!
            defer { store.removePersistentDomain(forName:storeName) }
            let savedTasks = PetModel(defaults:store); savedTasks.sideTasks = model.sideTasks; savedTasks.persistSideTasks()
            let restoredTasks = PetModel(defaults:store); restoredTasks.loadSideTasks()
            try check(restoredTasks.sideTasks.count == model.sideTasks.count && restoredTasks.sideTasks.filter { $0.deadline != nil }.count == 41,"Task persistence retains all running timers beyond the old thirty-task limit")
            restoredTasks.taskClock?.invalidate()
            let overflowTimer = model.sideTasks.last!.id
            model.timerAction(overflowTimer,action:"toggle")
            try check(model.sideTasks.last?.deadline == nil && model.ambientTasks.map(\.id) == restingIDs,"An overflow timer can pause without changing the ambient controls")
            model.timerAction(overflowTimer,action:"toggle")
            try check(model.sideTasks.last?.deadline != nil,"An overflow timer can resume independently")
            model.controlMedia(second.id,operation:"play"); try await pause()
            model.controlMedia(second.id,operation:"pause"); try await pause()
            try check((try await second.observe())["playing"] as? Bool == false && model.ambientTasks.map(\.id) == restingIDs,"Overflow music remains independently controllable without moving the primary controls")
            let oldWindows = Set(NSApp.windows.map { $0.windowNumber })
            model.taskShelfVisible = true; try await pause()
            try check(model.taskShelfVisible && model.shellExpanded && !NSApp.windows.contains(where:{$0.isVisible && !oldWindows.contains($0.windowNumber)}),"Task list replaces content without creating another window")
            try await snapshot(delegate.panel,path:"/tmp/orvlet-calm-task-shelf.png")
            model.setCompactLayout(.horizontal); try await pause()
            try check(model.taskShelfVisible && model.shellLayout.edge != .left && model.shellLayout.edge != .right,"Changing orientation keeps the task list open in the same shell")
            model.setCompactLayout(.vertical); try await pause()
            model.taskShelfVisible = false; try await pause()
            model.sideTasks[model.sideTasks.count-1].deadline = Date().addingTimeInterval(-1)
            model.tickTasks()
            try check(model.ambientTasks.contains(where:{$0.id == overflowTimer}) && model.microMediaTasks.first?.id == first.id,"An overflow timer surfaces at completion while music stays available")
            let nextDue = model.sideTasks[model.sideTasks.count-2].id
            model.sideTasks[model.sideTasks.count-2].deadline = Date().addingTimeInterval(-1)
            model.tickTasks()
            try check(model.ambientTasks.contains(where:{$0.id == nextDue}),"A newer timer completion is not buried behind an earlier completed timer")
            model.sideTasks = originals; model.reconcileTasks(); model.refreshTaskClock()
            let count = model.sideTasks.count
            model.addCalendarCard(["verified":false,"title":"Unverified"])
            try check(model.sideTasks.count == count,"Unverified calendar results do not become success cards")
            model.addCalendarCard(["verified":true,"title":"Design catch-up","start":"2026-11-02 14:00","end":"15:00","location":"Room 204","status":"created"])
            let calendarID = model.selectedTaskID!
            try check(model.selectedSideTask?.detail.contains("Room 204") == true,"Verified calendar card retains event details")
            if let i = model.sideTasks.firstIndex(where:{$0.id == calendarID}) { model.sideTasks[i].expires = Date().addingTimeInterval(-1) }
            model.pointerInside = false; model.tickTasks()
            try check(!model.visibleTasks.contains(where:{$0.id == calendarID}),"Completed calendar card retires without interrupting other tasks")
            model.selectTask(timer,expanded:true); model.pinned = true; try await pause()
            try await snapshot(delegate.detailPanel, path:"/tmp/orvlet-card-expanded.png")
            model.collapse(); model.pinned = true; try await pause()
            try await snapshot(delegate.panel,path:"/tmp/orvlet-card-compact.png")
            model.selectChat(true); try await pause()
            try await snapshot(delegate.commandPanel!,path:"/tmp/orvlet-command.png")
            model.selectChat(false)
            if let i = model.sideTasks.firstIndex(where:{$0.id == timer}) { model.sideTasks[i].deadline = Date().addingTimeInterval(-1); model.sideTasks[i].hidden = true }
            model.tickTasks()
            try check(model.sideTasks.first(where:{$0.id == timer})?.finished == true && model.visibleTasks.contains(where:{$0.id == timer}),"A hidden timer returns a completion card exactly when due")
            model.timerAction(timer,action:"stop")
            try check(model.sideTasks.first(where:{$0.id == timer})?.status == "Stopped" && model.sideTasks.first(where:{$0.id == timer})?.deadline == nil,"Stopping a timer clears its deadline independently of hiding")
            checks += try await InteractionCheck.run(model,delegate:delegate)
            checks += try await TaskExperienceCheck.run(model,delegate:delegate)
            checks += try await PreparationCheck.run(model,delegate:delegate)
            let output: [String:Any] = ["ok":true,"checks":checks,"timerDispatchMilliseconds":timerDispatchMilliseconds]
            try JSONSerialization.data(withJSONObject:output,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-side-screen-checks.json"))
            if !CommandLine.arguments.contains("--keep-open") { exit(0) }
        } catch {
            let output: [String:Any] = ["ok":false,"checks":checks,"error":error.localizedDescription]
            try? JSONSerialization.data(withJSONObject:output,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/tmp/orvlet-side-screen-checks.json"))
            exit(1)
        }
    }
    static func snapshot(_ window: NSWindow, path: String) async throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        if let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:URL(fileURLWithPath:path)) }
    }
}
#endif
