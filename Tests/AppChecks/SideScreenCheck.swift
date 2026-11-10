#if DEBUG
    import AppKit
    import SwiftUI
    import WebKit

    @MainActor
    enum SideScreenCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            var checks: [String] = []
            var timerDispatchMilliseconds = 0.0
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message("Check failed: " + label) }
                checks.append(label)
            }
            func pause() async throws { try await Task.sleep(for: .milliseconds(450)) }
            func descendants(_ root: NSView) -> [WKWebView] {
                (root as? WKWebView).map { [$0] } ?? root.subviews.flatMap(descendants)
            }
            func cardView() async throws -> WKWebView {
                for _ in 0..<30 {
                    for web in descendants(delegate.panel.contentView!) {
                        if (try? await web.evaluateJavaScript("typeof window.updateCard === 'function'")) as? Bool
                            == true
                        {
                            return web
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw AppError.message("Generated card WebView did not load")
            }
            do {
                model.isLiveTest = true
                model.persistHistory = false
                model.settings = AppSettings()
                model.settings.compactTaskLimit = 2  // These geometry cases deliberately exercise two visible slots.
                model.settings.autoAdapt = false
                model.settings.appearance = .light
                model.settings.reduceMotion = true
                let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
                let anchors = [
                    NSRect(x: -1428, y: 12, width: 313, height: 32), NSRect(x: -325, y: 12, width: 313, height: 32),
                    NSRect(x: -1428, y: 856, width: 313, height: 32), NSRect(x: -325, y: 856, width: 313, height: 32),
                    NSRect(x: -900, y: 440, width: 313, height: 32),
                ]
                try check(
                    anchors.allSatisfy { anchor in
                        let size = NSSize(width: 560, height: 420)
                        let layout = ShellLayout.place(
                            anchor: anchor, content: size, orientation: .horizontal, screen: screen)
                        return screen.contains(layout.frame) && layout.compact == anchor
                            && !anchor.intersects(layout.content)
                    }, "One shell stays on screen while preserving corner and center compact anchors")
                try check(
                    AppModel.timerSeconds("计时12分钟") == 720 && AppModel.timerSeconds("timer 1.5 minutes") == 90
                        && AppModel.timerSeconds("不要计时12分钟") == nil, "Fast timer parsing accepts exact requests only")
                try check(
                    AppModel.timerSeconds("帮我计时十分钟") == 600 && AppModel.timerSeconds("请设一个半小时的计时器") == 1800
                        && AppModel.timerSeconds("计时一分半") == 90
                        && AppModel.timerSeconds("start a timer for 1 hour 20 minutes") == 4800,
                    "Common Chinese and English durations bypass model interpretation")
                try check(
                    AppModel.timerSeconds("比如计时十分钟") == nil && AppModel.timerSeconds("解释一下计时10分钟") == nil,
                    "Examples and explanations do not start a timer")
                model.busy = true
                model.latestIntent = "Keep the unrelated task"
                model.agent.interpretationOverride = { _ in RequestIntent(kind: .general) }
                let dispatchStart = Date()
                model.command = "帮我计时十分钟"
                model.sendCommand()
                timerDispatchMilliseconds = Date().timeIntervalSince(dispatchStart) * 1000
                for _ in 0..<20 {
                    if model.globalRoutingTask == nil { break }
                    try await pause()
                }
                try check(
                    timerDispatchMilliseconds < 500 && model.busy && model.queuedTaskRequests.last?.isNewTask == true,
                    "Global requests route without blocking input or silently controlling the selected task")
                model.agent.interpretationOverride = nil
                model.queuedTaskRequests = []
                model.sideTasks.removeAll()
                model.busy = false
                let received = Date().addingTimeInterval(-120)
                let delayed = try model.startTimer(seconds: 600, receivedAt: received)
                try check(
                    abs(model.sideTasks.last!.deadline!.timeIntervalSince(received) - 600) < 0.001
                        && model.sideTasks.last!.remaining < 481,
                    "Delayed interpretation does not add its latency to the timer deadline")
                model.timerAction(delayed, action: "stop")
                model.sideTasks.removeAll()
                let timer = try model.startTimer(seconds: 720, title: "Tea break")
                model.timerAction(timer, action: "toggle")
                try check(
                    model.sideTasks.first?.deadline == nil && (model.sideTasks.first?.remaining ?? 0) > 718,
                    "Pause retains remaining time")
                model.timerAction(timer, action: "toggle")
                try check(model.sideTasks.first?.deadline != nil, "Resume uses retained duration")
                model.dismissTask(timer)
                try check(
                    model.sideTasks.first?.deadline != nil && model.visibleTasks.isEmpty, "Hiding does not stop a timer"
                )
                model.selectTask(timer)
                model.selectChat(true)
                try await pause()
                try check(
                    model.commandPanelVisible && delegate.commandPanel?.isVisible == true
                        && delegate.commandPanel !== delegate.panel && !model.showingWeb,
                    "Shortcut opens an independent input window without opening the webpage")
                model.selectChat(false)
                try check(
                    !model.commandPanelVisible && model.sideTasks.first?.deadline != nil,
                    "Dismissing command panel leaves tasks running")
                var bad = SideTask(kind: .result, title: "Unsafe").presentation
                bad.html = "<script>window.bad=true</script>"
                var rejected = false
                do { _ = try bad.validated() } catch { rejected = true }
                try check(rejected, "Generated executable scripts are rejected")
                var unknown = SideTask(kind: .result, title: "Unknown").presentation
                unknown.html = "<button data-action='unregistered'>Go</button>"
                rejected = false
                do { try unknown.validateActions(["expand"]) } catch { rejected = true }
                try check(rejected, "Unknown generated action IDs are rejected before display")
                unknown.html = "<button>Unbound</button>"
                rejected = false
                do { try unknown.validateActions(["expand"]) } catch { rejected = true }
                try check(rejected, "Unbound decorative buttons are rejected in generated markup")
                let observation = try await model.browser.action([
                    "action": "navigate", "url": "http://127.0.0.1:19244/fixture",
                ])
                var plan = SurfacePlan(components: [], width: 320, height: 180, title: "Library")
                plan.markup = CardMarkup(
                    html:
                        "<section class='library'><small>LISTENING</small><h2 data-bind='title'></h2><p data-bind='status'></p><button data-action='next'>Next item</button></section>",
                    compactHTML:
                        "<div class='small'><button data-action='expand'><strong data-bind='title'></strong></button><button data-action='next'>Next</button></div>",
                    css:
                        ".library{display:grid;gap:14px;padding:10px}.small{display:flex;gap:8px;align-items:center;height:50px}.small button:first-child{flex:1;text-align:left;border:0;background:none}h2{font-size:19px}",
                    height: 170)
                plan.actions = [
                    BoundCardAction(
                        id: "next", binding: PageBinding(action: "click", role: "button", name: "Next item")),
                    BoundCardAction(id: "toggle", binding: PageBinding(action: "media", operation: "toggle")),
                ]
                var invalidType = plan
                invalidType.actions = [
                    BoundCardAction(id: "next", binding: PageBinding(action: "type", role: "button", name: "Next item"))
                ]
                rejected = false
                do { _ = try invalidType.validated(observation: observation) } catch { rejected = true }
                try check(rejected, "A real button cannot be misrepresented as a text input")
                let checked = try plan.validated(observation: observation)
                try check(
                    checked.markup != nil && checked.actions?.count == 2,
                    "HTML plan preserves layout with validated action registry")
                model.install(checked)
                try check(
                    model.surface.markup == checked.markup,
                    "Installing an HTML-only plan preserves its generated layout")
                model.hasCustomSurface = true
                model.upsertWebTask(checked, activate: true)
                let first = model.browser
                model.pinned = true
                model.selectTask(first.id, expanded: true, preferSource: false)
                delegate.panel.orderFrontRegardless()
                try await pause()
                let web = try await cardView()
                try await pause()
                let rendered = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
                try check(
                    rendered.contains("Test library") && rendered.contains("Next"),
                    "Generated HTML actually renders with host state")
                _ = try await web.evaluateJavaScript("document.querySelector('[data-action=next]').click()")
                try await pause()
                try check(
                    (try await first.webView.evaluateJavaScript("document.querySelector('#result').textContent"))
                        as? String == "Track Two", "HTML button bridge operates the real bound webpage")
                let signature = try await web.evaluateJavaScript("window.__sentinel=42; true")
                _ = signature
                model.sideTasks[model.sideTasks.firstIndex(where: { $0.id == first.id })!].title = "Changed track"
                try await pause()
                try check(
                    (try await web.evaluateJavaScript("window.__sentinel")) as? Int == 42,
                    "Live state updates do not reload the generated document")
                // Keep the first source alive while another source becomes active.
                try model.prepareBrowserForNewTask()
                let second = model.browser
                _ = try await second.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?second"])
                model.upsertWebTask(checked, activate: true)
                model.cardAction(first.id, action: "next", value: nil)
                try await pause()
                try check(
                    first !== second && model.parkedBrowsers.count == 1,
                    "Web tasks retain separate live source contexts")
                try check(
                    (try await second.webView.evaluateJavaScript("document.querySelector('#result').textContent"))
                        as? String == "", "Background card actions do not operate the foreground task")
                try check(model.visibleTasks.count == 3, "Two web tasks and timer coexist")
                _ = try await first.webView.evaluateJavaScript("document.querySelector('audio').loop=true")
                _ = try await first.action(["action": "media", "operation": "play"])
                model.collapse()
                try await pause()
                let anchor = delegate.ambientFrame
                for _ in 0..<3 {
                    model.toggleTaskPresentation(first.id)
                    try await pause()
                    if delegate.ambientFrame != anchor || model.collapsed || model.showingWeb
                        || !delegate.panel.isVisible
                    {
                        try await snapshot(delegate.panel, path: "/tmp/orvlet-anchor-failure.png")
                        throw AppError.message(
                            "Music expansion: anchor=\(anchor), actual=\(delegate.ambientFrame), collapsed=\(model.collapsed), source=\(model.showingWeb), visible=\(delegate.panel.isVisible), feedback=\(model.feedback?.kind as Any)"
                        )
                    }
                    try check(
                        delegate.ambientFrame == anchor && !model.collapsed && !model.showingWeb
                            && delegate.panel.isVisible,
                        "Opening the music card preserves the ambient entry point")
                    try check(
                        !model.shellLayout.compact.intersects(model.shellLayout.content)
                            && model.shellLayout.frame == model.shellLayout.compact.union(model.shellLayout.content),
                        "Compact controls and details share one contiguous window without overlap")
                    model.pointerChanged(false)
                    try await pause()
                    try check(!model.collapsed, "Click expansion survives pointer exit")
                    let beforeToggle =
                        "selected=\(String(describing: model.selectedTaskID)), shelf=\(model.taskShelfVisible), command=\(model.commandPanelVisible), collapsed=\(model.collapsed)"
                    model.toggleTaskPresentation(first.id)
                    if !model.collapsed || model.shellExpanded || delegate.ambientFrame != anchor {
                        throw AppError.message(
                            "Music collapse (before: \(beforeToggle)): anchor=\(anchor), actual=\(delegate.ambientFrame), collapsed=\(model.collapsed), expanded=\(model.shellExpanded), selected=\(String(describing:model.selectedTaskID)), first=\(first.id)"
                        )
                    }
                    try check(
                        model.collapsed && !model.shellExpanded && delegate.ambientFrame == anchor,
                        "The same stationary entry closes details")
                }
                model.selectTask(first.id, expanded: true, preferSource: true)
                let shellWindowNumber = delegate.panel.windowNumber
                let persistentSource = first.webView
                try await pause()
                try await snapshot(delegate.panel, path: "/tmp/orvlet-unified-source.png")
                let sourceFrame = delegate.panel.frame
                model.selectChat(true)
                try await pause()
                if !model.commandPanelVisible || !model.showingWeb || delegate.panel.frame != sourceFrame {
                    throw AppError.message(
                        "Input expansion: before=\(sourceFrame), after=\(delegate.panel.frame), input=\(model.commandPanelVisible), source=\(model.showingWeb), feedback=\(model.feedback?.kind as Any)"
                    )
                }
                try check(
                    delegate.panel.windowNumber == shellWindowNumber && model.commandPanelVisible && model.showingWeb
                        && delegate.commandPanel !== delegate.panel && delegate.panel.frame == sourceFrame,
                    "Independent input leaves the expanded webpage and its window untouched")
                model.taskShelfVisible = true
                try await pause()
                try check(
                    !model.commandPanelVisible && model.taskShelfVisible
                        && delegate.panel.windowNumber == shellWindowNumber,
                    "Opening the task list dismisses input without creating another task window")
                model.selectTask(first.id, expanded: true, preferSource: true)
                try await pause()
                try check(
                    !model.taskShelfVisible && !model.commandPanelVisible && model.showingWeb
                        && first.webView === persistentSource, "Returning to a task reuses its live webpage")
                model.collapse()
                let timeBefore =
                    (try await first.webView.evaluateJavaScript("document.querySelector('audio').currentTime"))
                    as? Double ?? 0
                try await Task.sleep(for: .milliseconds(1100))
                let timeAfter =
                    (try await first.webView.evaluateJavaScript("document.querySelector('audio').currentTime"))
                    as? Double ?? 0
                try check(
                    abs(timeAfter - timeBefore) > 0.1, "Source playback continues while the detail window is hidden")
                model.selectTask(timer, expanded: true)
                model.pinned = true
                delegate.dismissDetails(at: NSPoint(x: -10000, y: -10000))
                try check(!model.collapsed, "Pinned details ignore outside clicks")
                model.pinned = false
                delegate.dismissDetails(at: NSPoint(x: -10000, y: -10000))
                try check(model.collapsed && !model.shellExpanded, "Outside click dismisses unpinned details")
                model.selectTask(timer, expanded: true)
                let selectedBefore = model.selectedTaskID
                model.controlMedia(first.id, operation: "pause")
                try await pause()
                try check(
                    (try await first.observe())["playing"] as? Bool == false && model.selectedTaskID == selectedBefore
                        && model.quickMediaTasks.contains(where: { $0.id == first.id }),
                    "Music can be paused while the timer is selected, without switching tasks")
                model.collapse()
                model.pinned = true
                try check(
                    model.windowSize == NSSize(width: 136, height: 116) && model.microMediaTasks.count == 1
                        && model.microTimerTasks.count == 1 && model.overflowTaskCount == 1,
                    "Vertical ambient mode keeps music and a timer in two bounded slots")
                try await pause()
                try await snapshot(delegate.panel, path: "/tmp/orvlet-calm-music-timer.png")
                let restingFrame = delegate.panel.frame
                let restingIDs = model.ambientTasks.map(\.id)
                model.setCompactLayout(.horizontal)
                try await pause()
                try check(
                    delegate.panel.frame.size == NSSize(width: 352, height: 44)
                        && model.ambientTasks.map(\.id) == restingIDs,
                    "Horizontal layout keeps the same controls in a bounded 44-point strip")
                try await snapshot(delegate.panel, path: "/tmp/orvlet-calm-horizontal.png")
                model.setCompactLayout(.vertical)
                try await pause()
                try check(
                    delegate.panel.frame == restingFrame,
                    "Switching orientation back restores the stationary top-left anchor")
                let legacySettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
                var savedSettings = legacySettings
                savedSettings.compactLayout = .horizontal
                try check(
                    legacySettings.compactLayout == .vertical
                        && (try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(savedSettings)))
                            .compactLayout == .horizontal,
                    "Old settings default to vertical and orientation round-trips")
                var limitSettings = legacySettings
                limitSettings.compactTaskLimit = 5
                try check(
                    legacySettings.compactTaskLimit == 3 && AppSettings().compactTaskLimit == 3
                        && (try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(limitSettings)))
                            .compactTaskLimit == 5,
                    "Visible-task limit defaults to three and survives settings round-trip")
                let excessive = try JSONDecoder().decode(
                    AppSettings.self, from: Data("{\"compactTaskLimit\":999}".utf8))
                let negative = try JSONDecoder().decode(AppSettings.self, from: Data("{\"compactTaskLimit\":-1}".utf8))
                try check(
                    excessive.compactTaskLimit == 6 && negative.compactTaskLimit == 1,
                    "Invalid persisted display limits stay within the supported range")
                model.setCompactTaskLimit(1)
                try await pause()
                try check(
                    model.ambientTasks.count == 1 && delegate.panel.frame.size == NSSize(width: 136, height: 78),
                    "Changing the limit to one immediately resizes the vertical stack")
                model.setCompactTaskLimit(3)
                try await pause()
                try check(
                    model.ambientTasks.count == 3 && model.overflowTaskCount == 0
                        && delegate.panel.frame.size == NSSize(width: 136, height: 154),
                    "Increasing the limit reveals existing tasks without recreating them")
                model.setCompactLayout(.horizontal)
                try await pause()
                try check(
                    delegate.panel.frame.size == NSSize(width: 478, height: 44),
                    "Horizontal stack honors the same configurable limit")
                model.setCompactTaskLimit(2)
                model.setCompactLayout(.vertical)
                try await pause()
                try check(
                    model.ambientTasks.map(\.id) == restingIDs && delegate.panel.frame == restingFrame,
                    "Restoring the limit and layout preserves the original anchor and task controls")
                let orderingStoreName = "orvlet.order-check." + UUID().uuidString
                let orderingStore = UserDefaults(suiteName: orderingStoreName)!
                defer { orderingStore.removePersistentDomain(forName: orderingStoreName) }
                let ordered = AppModel(defaults: orderingStore)
                ordered.settings = AppSettings()
                ordered.settings.compactTaskLimit = 2
                let a = SideTask(kind: .workspace, title: "Alpha")
                var b = SideTask(kind: .timer, title: "Beta")
                b.deadline = Date().addingTimeInterval(900)
                let c = SideTask(kind: .workspace, title: "Gamma")
                ordered.sideTasks = [a, b, c]
                ordered.moveTask(c.id, before: b.id)
                try check(
                    ordered.orderedTasks.map(\.id) == [c.id, b.id, a.id]
                        && ordered.ambientTasks.map(\.id) == [c.id, b.id],
                    "Manual ordering also decides which tasks occupy the limited compact slots")
                ordered.moveTask(a.id, by: -1)
                ordered.moveTask(c.id, by: 1)
                try check(
                    ordered.orderedTasks.map(\.id) == [a.id, c.id, b.id],
                    "Earlier and later controls move exactly one position in the displayed order")
                ordered.ambientRequestID = b.id
                ordered.sideTasks[1].finished = true
                ordered.sideTasks[1].completedAt = Date()
                try check(
                    ordered.orderedTasks.map(\.id) == [a.id, c.id, b.id] && ordered.sideTasks[1].deadline == b.deadline,
                    "Task updates and completion cannot override manual order or alter execution state")
                let d = SideTask(kind: .workspace, title: "Delta")
                ordered.sideTasks.append(d)
                ordered.moveTask(a.id, before: nil)
                try check(
                    ordered.orderedTasks.map(\.id) == [c.id, b.id, d.id, a.id],
                    "New tasks append to manual order and dropping after the final row moves to the end")
                ordered.dismissTask(c.id)
                try check(
                    ordered.ambientTasks.map(\.id) == [b.id, d.id],
                    "Hidden tasks keep their position but do not consume a compact slot")
                ordered.selectTask(c.id)
                try check(
                    ordered.ambientTasks.map(\.id) == [c.id, b.id],
                    "Restoring a hidden task recovers its manual position")
                ordered.persistSideTasks()
                let recovered = AppModel(defaults: orderingStore)
                recovered.settings = AppSettings()
                recovered.loadSideTasks()
                try check(
                    recovered.orderedTasks.map(\.id) == [c.id, b.id, d.id, a.id],
                    "Manual order survives a fresh model and disk-backed task restore")
                recovered.taskClock?.invalidate()
                ordered.closeTask(c.id)
                ordered.moveTask(UUID(), before: a.id)
                try check(
                    ordered.orderedTasks.map(\.id) == [b.id, d.id, a.id],
                    "Closing a task or receiving a stale drag cannot corrupt remaining order")
                ordered.resetTaskOrder()
                try check(
                    ordered.taskOrder.isEmpty && orderingStore.stringArray(forKey: "taskOrder.v1") == [],
                    "Reset order clears the saved override and restores automatic priorities")
                ordered.taskClock?.invalidate()
                let originals = model.sideTasks
                for n in 1...40 {
                    var extra = SideTask(kind: .timer, title: "Background timer \(n)")
                    extra.duration = 6000
                    extra.deadline = Date().addingTimeInterval(6000 + Double(n))
                    extra.status = "Counting down"
                    model.sideTasks.append(extra)
                }
                model.reconcileTasks()
                try await pause()
                try check(
                    delegate.panel.frame == restingFrame && model.ambientTasks.map(\.id) == restingIDs
                        && model.overflowTaskCount == 41,
                    "Forty extra tasks are tucked away without growing or reordering the ambient area")
                let storeName = "orvlet.stack-check." + UUID().uuidString
                let store = UserDefaults(suiteName: storeName)!
                defer { store.removePersistentDomain(forName: storeName) }
                let savedTasks = AppModel(defaults: store)
                savedTasks.sideTasks = model.sideTasks
                savedTasks.persistSideTasks()
                let restoredTasks = AppModel(defaults: store)
                restoredTasks.loadSideTasks()
                try check(
                    restoredTasks.sideTasks.count == model.sideTasks.count
                        && restoredTasks.sideTasks.filter { $0.deadline != nil }.count == 41,
                    "Task persistence retains all running timers beyond the old thirty-task limit")
                restoredTasks.taskClock?.invalidate()
                let overflowTimer = model.sideTasks.last!.id
                model.timerAction(overflowTimer, action: "toggle")
                try check(
                    model.sideTasks.last?.deadline == nil && model.ambientTasks.map(\.id) == restingIDs,
                    "An overflow timer can pause without changing the ambient controls")
                model.timerAction(overflowTimer, action: "toggle")
                try check(model.sideTasks.last?.deadline != nil, "An overflow timer can resume independently")
                model.controlMedia(second.id, operation: "play")
                try await pause()
                model.controlMedia(second.id, operation: "pause")
                try await pause()
                try check(
                    (try await second.observe())["playing"] as? Bool == false
                        && model.ambientTasks.map(\.id) == restingIDs,
                    "Overflow music remains independently controllable without moving the primary controls")
                let oldWindows = Set(NSApp.windows.map { $0.windowNumber })
                model.taskShelfVisible = true
                try await pause()
                try check(
                    model.taskShelfVisible && model.shellExpanded
                        && !NSApp.windows.contains(where: { $0.isVisible && !oldWindows.contains($0.windowNumber) }),
                    "Task list replaces content without creating another window")
                try await snapshot(delegate.panel, path: "/tmp/orvlet-calm-task-shelf.png")
                model.setCompactLayout(.horizontal)
                try await pause()
                try check(
                    model.taskShelfVisible && model.shellLayout.edge != .left && model.shellLayout.edge != .right,
                    "Changing orientation keeps the task list open in the same shell")
                model.setCompactLayout(.vertical)
                try await pause()
                model.taskShelfVisible = false
                try await pause()
                model.sideTasks[model.sideTasks.count - 1].deadline = Date().addingTimeInterval(-1)
                model.tickTasks()
                try check(
                    model.ambientTasks.contains(where: { $0.id == overflowTimer })
                        && model.microMediaTasks.first?.id == first.id,
                    "An overflow timer surfaces at completion while music stays available")
                let nextDue = model.sideTasks[model.sideTasks.count - 2].id
                model.sideTasks[model.sideTasks.count - 2].deadline = Date().addingTimeInterval(-1)
                model.tickTasks()
                try check(
                    model.ambientTasks.contains(where: { $0.id == nextDue }),
                    "A newer timer completion is not buried behind an earlier completed timer")
                model.sideTasks = originals
                model.reconcileTasks()
                model.refreshTaskClock()
                let count = model.sideTasks.count
                model.addCalendarCard(["verified": false, "title": "Unverified"])
                try check(model.sideTasks.count == count, "Unverified calendar results do not become success cards")
                model.addCalendarCard([
                    "verified": true, "title": "Design catch-up", "start": "2026-11-02 14:00", "end": "15:00",
                    "location": "Room 204", "status": "created",
                ])
                let calendarID = model.selectedTaskID!
                try check(
                    model.selectedSideTask?.detail.contains("Room 204") == true,
                    "Verified calendar card retains event details")
                if let i = model.sideTasks.firstIndex(where: { $0.id == calendarID }) {
                    model.sideTasks[i].expires = Date().addingTimeInterval(-1)
                }
                model.pointerInside = false
                model.tickTasks()
                try check(
                    !model.visibleTasks.contains(where: { $0.id == calendarID }),
                    "Completed calendar card retires without interrupting other tasks")
                model.selectTask(timer, expanded: true)
                model.pinned = true
                try await pause()
                try await snapshot(delegate.panel, path: "/tmp/orvlet-card-expanded.png")
                model.collapse()
                model.pinned = true
                try await pause()
                try await snapshot(delegate.panel, path: "/tmp/orvlet-card-compact.png")
                model.selectChat(true)
                try await pause()
                try await snapshot(delegate.commandPanel!, path: "/tmp/orvlet-command.png")
                model.selectChat(false)
                if let i = model.sideTasks.firstIndex(where: { $0.id == timer }) {
                    model.sideTasks[i].deadline = Date().addingTimeInterval(-1)
                    model.sideTasks[i].hidden = true
                }
                model.tickTasks()
                try check(
                    model.sideTasks.first(where: { $0.id == timer })?.finished == true
                        && model.visibleTasks.contains(where: { $0.id == timer }),
                    "A hidden timer returns a completion card exactly when due")
                model.timerAction(timer, action: "stop")
                try check(
                    model.sideTasks.first(where: { $0.id == timer })?.status == "Stopped"
                        && model.sideTasks.first(where: { $0.id == timer })?.deadline == nil,
                    "Stopping a timer clears its deadline independently of hiding")
                checks += try await InteractionCheck.run(model, delegate: delegate)
                checks += try await TaskExperienceCheck.run(model, delegate: delegate)
                checks += try await PreparationCheck.run(model, delegate: delegate)
                model.selectChat(false)
                model.collapse()
                model.taskShelfVisible = false
                model.sideTasks.removeAll()
                model.reconcileTasks()
                model.setCompactLayout(.vertical)
                let anchorBeforeReceipt = model.shellLayout.compact
                model.deliverReply(
                    "No event has been added. What is the event called? Reply with Title: followed by its name.",
                    kind: .needsInput)
                try await pause()
                try check(
                    model.shellLayout.compact == anchorBeforeReceipt && delegate.panel.isVisible
                        && !model.commandPanelVisible && model.collapsed,
                    "Visible receipt keeps the vertical stack anchored and input window closed")
                try await snapshot(delegate.panel, path: "/tmp/orvlet-feedback-vertical.png")
                model.dismissFeedback()
                try check(model.shellLayout.content == .zero, "Dismiss returns the shell to compact-only geometry")
                model.setCompactLayout(.horizontal)
                let horizontalAnchor = model.shellLayout.compact
                model.deliverReply("Calendar permission was denied. No event has been added.", kind: .failure)
                try await pause()
                try check(
                    model.shellLayout.compact == horizontalAnchor && model.shellLayout.content.width > 0,
                    "Horizontal stack also shows the receipt without moving existing controls")
                try await snapshot(delegate.panel, path: "/tmp/orvlet-feedback-horizontal.png")
                model.dismissFeedback()
                checks += try await TaskSurfaceUICheck.run(model, delegate: delegate)
                checks += try await TaskRankingCheck.run()
                checks += try InterfaceRevisionCheck.run()
                let output: [String: Any] = [
                    "ok": true, "checks": checks, "timerDispatchMilliseconds": timerDispatchMilliseconds,
                ]
                try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-side-screen-checks.json"))
                if !CommandLine.arguments.contains("--keep-open") { exit(0) }
            } catch {
                let output: [String: Any] = ["ok": false, "checks": checks, "error": error.localizedDescription]
                try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-side-screen-checks.json"))
                exit(1)
            }
        }
        static func snapshot(_ window: NSWindow, path: String) async throws {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
#endif
