import SwiftUI
import AppKit
import WebKit
import Combine

enum SideTaskKind: String, Codable { case web, timer, calendar, result }
struct SideTask: Identifiable, Codable {
    var id = UUID()
    var kind: SideTaskKind
    var title: String
    var detail = ""
    var status = ""
    var sourceURL: String? = nil
    var plan: SurfacePlan? = nil
    var markup: CardMarkup? = nil
    var created = Date()
    var expires: Date? = nil
    var hidden = false
    var deadline: Date? = nil
    var pausedSeconds: Double? = nil
    var duration: Double? = nil
    var completedAt: Date? = nil
    var finished = false
    var playing = false
    var hasMedia = false
    var mediaPrimary: Bool? = nil
    var listening: Bool? = nil // Verified task intent survives transient player/ad DOM changes.
    var prefersSource: Bool? = nil // Watching/browsing may explicitly prefer the source.
    var liveValues: [String:String]? = nil
    var isMediaTask: Bool { kind == .web && (listening == true || mediaPrimary == true || (hasMedia && mediaPrimary == nil)) }
    var opensSourceByDefault: Bool { kind == .web && (prefersSource ?? !isMediaTask) }
    mutating func updateMediaRole(primary: Bool?, url: String?) {
        if let url, let previous = sourceURL, previous != url {
            mediaPrimary = nil
            if URL(string:previous)?.host != URL(string:url)?.host { listening = false; prefersSource = nil }
        }
        // Primary media is a page capability, not a requirement on generated bindings.
        // Keep the established role across hidden/replaced players on the same page.
        if primary == true { mediaPrimary = true }
        else if mediaPrimary != true, let primary { mediaPrimary = primary }
    }
    var generated = false
    var symbol: String {
        switch kind { case .web: return isMediaTask ? "music.note" : "globe"; case .timer: return "timer"; case .calendar: return "calendar"; case .result: return status == "Needs attention" ? "exclamationmark.circle" : "checkmark.circle" }
    }
    var remaining: Double { max(0, deadline?.timeIntervalSinceNow ?? pausedSeconds ?? 0) }
    var state: [String:String] {
        let seconds = Int(ceil(remaining))
        return ["title":title,"detail":detail,"status":status,
                "remaining":String(format:"%02d:%02d", seconds / 60, seconds % 60),
                "toggleLabel":kind == .timer ? (finished ? "Restart" : deadline == nil ? "Resume" : "Pause") : (playing ? "Pause" : "Play")].merging(liveValues ?? [:]) { _, reading in reading }
    }
    var allowedActions: Set<String> {
        var result: Set<String> = ["expand", "dismiss"]
        if kind == .web { result.insert("source"); result.formUnion((plan?.actions ?? []).map(\.id)); if isMediaTask { result.insert("toggle") } }
        if kind == .timer { result.formUnion(["toggle", "restart", "stop"]) }
        if kind == .calendar { result.insert("calendar") }
        return result
    }
    /// Honest instant fallback for local tasks and old saved surfaces, replaced by generated markup when available.
    var presentation: CardMarkup {
        if let markup { return markup }
        if let markup = plan?.markup { return markup }
        let toggle = kind == .timer || isMediaTask ? "<button data-action='toggle' data-bind='toggleLabel'></button>" : ""
        let primary = kind == .timer ? "<strong class='time' data-bind='remaining'></strong>" : "<strong data-bind='title'></strong>"
        let extra = kind == .calendar ? "<button data-action='calendar'>Open Calendar</button>" : kind == .web ? "<button data-action='source'>Open page</button>" : ""
        return CardMarkup(html:"<section class='card'>" + (kind == .timer ? "<small data-bind='title'></small>" : "") + "\(primary)<small data-bind='status'></small><p data-bind='detail'></p><footer>\(toggle)\(extra)</footer></section>",
                          compactHTML:"<section class='mini'><button class='summary' data-action='expand'>\(primary)<small data-bind='status'></small></button>\(toggle)</section>",
                          css:".card{display:grid;gap:12px;padding:6px}.time{font-size:34px;font-variant-numeric:tabular-nums;font-weight:500}.mini{display:flex;align-items:center;gap:10px;height:50px}.summary{display:grid;text-align:left;gap:3px;min-width:0;flex:1;border:0;background:none;padding:0}.summary strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}.mini .time{font-size:24px}footer{display:flex;gap:8px}p{font-size:12px;line-height:1.5;white-space:pre-line}", height:kind == .timer ? 165 : 150)
    }
}

extension PetModel {
    func beginAmbientRequest(_ text: String) {
        var task = SideTask(kind:.result,title:String(text.prefix(80)))
        task.status = "Preparing…"
        requestCardID = task.id; requestPageID = nil; ambientRequestID = task.id
        sideTasks.append(task)
        onResize?(windowSize); onShow?()
    }
    func finishAmbientRequest() {
        if let id = requestCardID { sideTasks.removeAll { $0.id == id }; if ambientRequestID == id { ambientRequestID = nil } }
        requestCardID = nil; requestPageID = nil
        persistSideTasks(); reconcileTasks()
    }
    func failAmbientRequest(_ message: String) {
        let id = requestCardID ?? requestPageID
        if let i = sideTasks.firstIndex(where:{$0.id == id}) {
            sideTasks[i].status = "Needs attention"; sideTasks[i].detail = message
            if sideTasks[i].kind == .result { requestCardID = nil }
        }
    }
    func isPreparingTask(_ task: SideTask) -> Bool {
        task.id == requestCardID || (busy && task.id == requestPageID && !task.isMediaTask)
    }
    var preparationLabel: String {
        switch activity {
        case "Reading page…": return "Reading…"
        case "Opening page…": return "Opening…"
        case "Building controls…": return "Preparing view…"
        case "Stopping…": return "Stopping…"
        default: return "Preparing…"
        }
    }
    var visibleTasks: [SideTask] { sideTasks.filter { !$0.hidden } }
    var selectedSideTask: SideTask? { visibleTasks.first { $0.id == selectedTaskID } ?? visibleTasks.first }
    func loadSideTasks() {
        if let data = preferences.data(forKey:"sideTasks.v1"), let saved = try? JSONDecoder().decode([SideTask].self, from:data) {
            sideTasks = saved.map { original in
                var task = original
                if task.kind == .web { task.hidden = true; task.playing = false; task.status = "Resume page" }
                return task
            }
        }
        reconcileTasks()
        refreshTaskClock()
    }
    func persistSideTasks() {
        guard persistHistory, !isLiveTest else { return }
        if let data = try? JSONEncoder().encode(sideTasks.filter { $0.id != requestCardID }) { preferences.set(data, forKey:"sideTasks.v1") }
    }
    func reconcileTasks() {
        if !visibleTasks.contains(where:{ $0.id == selectedTaskID }) { selectedTaskID = visibleTasks.first?.id }
        if visibleTasks.isEmpty && !commandPanelVisible && !hasUnreadReply && !busy { onHide?() }
        onResize?(windowSize)
    }
    func toggleTaskPresentation(_ id: UUID) {
        if !collapsed && !taskShelfVisible && !commandPanelVisible && selectedTaskID == id { collapse() }
        else { selectTask(id,expanded:true) }
    }
    @discardableResult
    func selectTask(_ id: UUID, expanded: Bool = false, preferSource: Bool? = nil) -> Bool {
        if id == requestCardID { selectChat(true); return true }
        guard let task = sideTasks.first(where: { $0.id == id }) else { return false }
        lastActionError = nil
        if task.kind == .web, id != browser.id, parkedBrowsers[id] == nil {
            guard parkedBrowsers.count < 2 else {
                lastActionError = "Three pages are already open. Close one from the task list, then try again."
                return false
            }
            guard let raw = task.sourceURL, let url = URL(string:raw) else {
                lastActionError = "This task no longer has a page address."
                return false
            }
            let restored = BrowserController(model:self,id:id)
            parkedBrowsers[id] = restored; browserRevision += 1
            Task {
                restored.webView.load(URLRequest(url:url))
                let page = try? await restored.settledObservation(navigation:true)
                if let i = sideTasks.firstIndex(where: { $0.id == id }) {
                    if let plan = task.plan, let page, let checked = try? plan.validated(observation:page) { sideTasks[i].plan = checked; try? await restored.bindReadings(checked.readings ?? []) }
                    else { sideTasks[i].plan = nil; sideTasks[i].status = "Open page to continue" }
                }
            }
        }
        if task.hidden, let i = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[i].hidden = false; sideTasks[i].expires = nil }
        if commandPanelVisible { selectChat(false,restoreFocus:false) }
        taskShelfVisible = false
        selectedTaskID = id
        webExpanded = expanded && (preferSource ?? task.opensSourceByDefault) && task.kind == .web; collapsed = !expanded; clickExpanded = expanded
        onResize?(windowSize); onShow?()
        refreshHover()
        if expanded && task.kind != .web && !task.generated { decorateTask(id) }
        return true
    }
    func openTaskFromCommand(_ id: UUID) {
        guard selectTask(id,expanded:true) else { return }
        selectChat(false,restoreFocus:false)
        onFocusDetails?()
    }
    func dismissTask(_ id: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        // Hiding a card does not stop its underlying task.
        sideTasks[i].hidden = true
        if selectedTaskID == id { collapse() }
        persistSideTasks(); reconcileTasks()
    }
    func upsertWebTask(_ plan: SurfacePlan? = nil, activate: Bool = false) {
        guard !webURL.isEmpty else { return }
        let id = browser.id
        if let old = sideTasks.firstIndex(where: { $0.kind == .web && $0.sourceURL == webURL && $0.id != id && parkedBrowsers[$0.id] == nil }) { sideTasks.remove(at:old) }
        let index = sideTasks.firstIndex { $0.id == id }
        var card = index.map { sideTasks[$0] } ?? SideTask(id:id, kind:.web, title:trackTitle)
        if let previous = card.sourceURL, URL(string:previous)?.host != URL(string:webURL)?.host { endBackgroundListening(clearTaskIntent:true) }
        card.updateMediaRole(primary:browser.lastState["mediaPrimary"] as? Bool,url:webURL)
        if backgroundListening { card.listening = true; card.prefersSource = false }
        if card.sourceURL != webURL { card.plan = nil; card.liveValues = nil }
        card.title = trackTitle; card.sourceURL = webURL
        card.hasMedia = hasMedia; card.playing = isPlaying
        card.plan = plan ?? card.plan ?? surface; card.generated = card.plan?.markup != nil
        card.status = card.isMediaTask ? (hasMedia ? (isPlaying ? "Playing" : "Paused") : "Loading…") : (URL(string:webURL)?.host ?? "Ready")
        if activate { card.hidden = false }
        if let index { sideTasks[index] = card } else { sideTasks.append(card) }
        if requestPageID == id {
            if let placeholder = requestCardID { sideTasks.removeAll { $0.id == placeholder } }
            requestCardID = nil; ambientRequestID = id
        }
        if selectedTaskID == nil || (activate && !(backgroundRequest && shellExpanded)) { selectedTaskID = id }
        persistSideTasks(); onResize?(windowSize)
        if activate { onShow?() }
    }
    func updateBackgroundTask(_ id: UUID, data: [String:Any]) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        sideTasks[i].updateMediaRole(primary:data["mediaPrimary"] as? Bool,url:data["url"] as? String)
        if let title = data["title"] as? String { sideTasks[i].title = title }
        if let url = data["url"] as? String {
            if sideTasks[i].sourceURL != url { sideTasks[i].plan = nil; sideTasks[i].generated = false; sideTasks[i].liveValues = nil }
            sideTasks[i].sourceURL = url
        }
        if let media = data["hasMedia"] as? Bool { sideTasks[i].hasMedia = media }
        updateLiveReadings(id,data:data)
        if let playing = data["playing"] as? Bool { sideTasks[i].playing = playing; if sideTasks[i].isMediaTask { sideTasks[i].status = sideTasks[i].hasMedia ? (playing ? "Playing" : "Paused") : "Loading…" } }
    }
    func updateLiveReadings(_ id: UUID, data: [String:Any]) {
        guard let i = sideTasks.firstIndex(where:{$0.id == id}), let readings = sideTasks[i].plan?.readings, !readings.isEmpty,
              let values = data["readings"] as? [String:String] else { return }
        let bound = Dictionary(uniqueKeysWithValues:readings.map { ($0.key,values[$0.key] ?? "—") })
        if sideTasks[i].liveValues != bound { sideTasks[i].liveValues = bound }
    }
    func closeTask(_ id: UUID) {
        if id == requestCardID {
            let page = requestPageID
            cancel(); requestCardID = nil; requestPageID = nil
            if let page { closeWebTask(page) }
            if ambientRequestID == id { ambientRequestID = nil }
        }
        guard let task = sideTasks.first(where:{$0.id == id}) else { return }
        if task.kind == .web { closeWebTask(id); return }
        sideTasks.removeAll { $0.id == id }
        if selectedTaskID == id { collapse() }
        refreshTaskClock(); persistSideTasks(); reconcileTasks()
    }
    func prepareBrowserForNewTask() throws {
        guard !externalBrowser, !webURL.isEmpty, hasCustomSurface || hasMedia else { return }
        upsertWebTask(surface, activate:true)
        guard parkedBrowsers.count < 2 else { throw AgentError.message("Three web tasks are already open. Close a page from its card before opening another.") }
        parkedBrowsers[browser.id] = browser
        endBackgroundListening()
        browser = BrowserController(model:self)
        webURL = ""; webTitle = ""; hasMedia = false; isPlaying = false; mediaType = ""
        hasCustomSurface = false; surface = .empty; webExpanded = false
        browserRevision += 1
    }
    var liveBrowsers: [BrowserController] { Array(parkedBrowsers.values).sorted { $0.id.uuidString < $1.id.uuidString } + [browser] }
    func activateSelectedSource() {
        guard let task = selectedSideTask, task.kind == .web, task.id != browser.id,
              let selected = parkedBrowsers.removeValue(forKey:task.id) else { return }
        if !webURL.isEmpty { parkedBrowsers[browser.id] = browser }
        browser = selected
        backgroundListening = task.listening == true
        webURL = task.sourceURL ?? ""; webTitle = task.title; surface = task.plan ?? .webpage
        hasMedia = task.hasMedia; isPlaying = task.playing; hasCustomSurface = task.plan != nil
        webLoading = selected.loading; webError = nil
        if !selected.lastState.isEmpty { selected.updateState(selected.lastState) }
        browserRevision += 1
    }
    func controlMedia(_ id: UUID, operation: String) {
        guard ["play","pause","toggle","next"].contains(operation),
              let task = sideTasks.first(where: { $0.id == id }), task.isMediaTask else { return }
        // A direct pause takes precedence over the agent's pending playback verification.
        if busy && requestPageID == id && (operation == "pause" || (operation == "toggle" && task.playing)) { cancel() }
        let controller = id == browser.id ? browser : parkedBrowsers[id]
        Task {
            do {
                if externalBrowser && id == browser.id { _ = try await performBrowserAction(["action":"media","operation":operation]) }
                else if let controller { _ = try await controller.action(["action":"media","operation":operation]) }
            } catch { if let i = sideTasks.firstIndex(where:{$0.id == id}) { sideTasks[i].status = "Open page to continue" } }
        }
    }
    func selectedMediaCommand(_ operation: String) -> Bool {
        let target = selectedSideTask.flatMap { $0.kind == .web && $0.isMediaTask ? $0 : nil }
            ?? quickMediaTasks.first(where: { $0.playing }) ?? quickMediaTasks.first
        guard let target else { return false }
        controlMedia(target.id,operation:operation)
        return true
    }
    func closeWebTask(_ id: UUID) {
        if id == browser.id {
            if busy && agent.operatedPage { cancel() }
            adaptive.task?.cancel(); cancelRestoration()
            browser.dispose()
            browser = BrowserController(model:self)
            webURL = ""; webTitle = ""; hasMedia = false; isPlaying = false; hasCustomSurface = false; surface = .empty
        } else if let old = parkedBrowsers.removeValue(forKey:id) { old.dispose() }
        let closingSelected = selectedTaskID == id
        sideTasks.removeAll { $0.id == id }; browserRevision += 1
        if closingSelected { collapse() }
        persistSideTasks(); reconcileTasks()
    }
    func cardAction(_ id: UUID, action: String, value: String?) {
        guard let task = sideTasks.first(where: { $0.id == id }), task.allowedActions.contains(action) else { return }
        switch action {
        case "expand": selectTask(id, expanded:true)
        case "dismiss": dismissTask(id)
        case "source": selectedTaskID = id; clickExpanded = true; collapsed = false; webExpanded = true; onResize?(windowSize); onShow?()
        case "calendar": NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Calendar.app"))
        default:
            if task.kind == .timer { timerAction(id, action:action); return }
            guard task.kind == .web else { return }
            let controller = id == browser.id ? browser : parkedBrowsers[id]
            let bound = task.plan?.actions?.first { $0.id == action }
            let binding = bound?.binding ?? (action == "toggle" && task.hasMedia ? PageBinding(action:"media",operation:"toggle") : nil)
            guard let binding else { return }
            Task {
                do {
                    var arguments = binding.dictionary
                    if let value { arguments["text"] = value }
                    if externalBrowser && id == browser.id { _ = try await performBrowserAction(arguments) }
                    else if let controller {
                        // Validate against the owning page just before execution, not another task's page.
                        let observation = try await controller.observe()
                        if let plan = task.plan, bound != nil { _ = try plan.validated(observation:observation) }
                        _ = try await controller.action(arguments)
                        if let submit = bound?.submit { _ = try await controller.action(submit.dictionary) }
                    }
                    if bound?.revealSource == true && binding.action != "media" {
                        selectedTaskID = id; clickExpanded = true; collapsed = false; webExpanded = true
                        onResize?(windowSize); onShow?()
                    }
                } catch {
                    if let i = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[i].status = "Control changed · open page" }
                }
            }
        }
    }
    @discardableResult func startTimer(seconds: Double, title: String = "Timer", receivedAt: Date = Date()) throws -> UUID {
        guard seconds.isFinite, seconds >= 1, seconds <= 86400 * 7 else { throw AgentError.message("Choose a timer between one second and seven days.") }
        var task = SideTask(kind:.timer, title:title.isEmpty ? "Timer" : String(title.prefix(80)))
        task.created = receivedAt; task.duration = seconds; task.deadline = receivedAt.addingTimeInterval(seconds); task.status = "Counting down"
        sideTasks.append(task); selectedTaskID = task.id
        collapsed = true; clickExpanded = false; webExpanded = false
        persistSideTasks(); refreshTaskClock(); onResize?(windowSize); onShow?()
        if task.deadline! <= Date() { tickTasks() }
        return task.id
    }
    func timerAction(_ id: UUID, action: String) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = sideTasks[i]
        if action == "stop" { task.deadline = nil; task.pausedSeconds = 0; task.finished = true; task.hidden = true; task.status = "Stopped" }
        else if action == "restart" || task.finished {
            task.deadline = Date().addingTimeInterval(task.duration ?? 60); task.pausedSeconds = nil; task.finished = false; task.completedAt = nil; task.status = "Counting down"
        } else if task.deadline != nil { task.pausedSeconds = task.remaining; task.deadline = nil; task.status = "Paused" }
        else { task.deadline = Date().addingTimeInterval(task.pausedSeconds ?? 60); task.pausedSeconds = nil; task.status = "Counting down" }
        sideTasks[i] = task; persistSideTasks(); refreshTaskClock(); reconcileTasks()
    }
    func refreshTaskClock() {
        taskClock?.invalidate(); taskClock = nil
        guard sideTasks.contains(where: { $0.deadline != nil || ($0.expires != nil && !$0.hidden) }) else { return }
        taskClock = Timer.scheduledTimer(withTimeInterval:1, repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTasks() }
        }
    }
    func tickTasks() {
        var changed = false
        for i in sideTasks.indices {
            if let end = sideTasks[i].deadline, end <= Date() {
                sideTasks[i].deadline = nil; sideTasks[i].finished = true; sideTasks[i].completedAt = Date(); sideTasks[i].status = "Time is up"
                sideTasks[i].hidden = false; sideTasks[i].pausedSeconds = 0
                if selectedTaskID == nil { selectedTaskID = sideTasks[i].id }
                if !isLiveTest { NSSound.beep() }
                onShow?(); changed = true
            }
            if let end = sideTasks[i].expires, end <= Date(), !sideTasks[i].hidden {
                // A result under inspection stays until the user leaves.
                if pointerInside && selectedTaskID == sideTasks[i].id { continue }
                sideTasks[i].hidden = true; changed = true
            }
        }
        objectWillChange.send()
        if changed { persistSideTasks(); reconcileTasks(); refreshTaskClock() }
    }
    func addCalendarCard(_ result: [String:Any]) {
        guard result["verified"] as? Bool == true else { return }
        let event = result
        var task = SideTask(kind:.calendar, title:event["title"] as? String ?? "Calendar event")
        task.status = result["status"] as? String == "exists" ? "Already in Calendar" : "Added to Calendar"
        task.detail = [event["start"] as? String,event["end"] as? String,event["location"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:"\n")
        task.expires = Date().addingTimeInterval(18)
        sideTasks.append(task); selectedTaskID = task.id; collapsed = true; clickExpanded = false; webExpanded = false
        persistSideTasks(); refreshTaskClock(); onResize?(windowSize); onShow?()
    }
    func decorateTask(_ id: UUID) {
        guard !isLiveTest, settings.main.isConfigured, !decoratingTasks.contains(id), let task = sideTasks.first(where: { $0.id == id }) else { return }
        decoratingTasks.insert(id)
        Task {
            defer { decoratingTasks.remove(id) }
            do {
                let response = try await APIClient.complete(endpoint:settings.main, key:try await SecretStore.load("main"), messages:[
                    ["role":"system","content":CardMarkup.prompt + " Return ONLY the markup object {html,css,height}. The task is already running/verified. Generate presentation only; never change facts or perform actions."],
                    ["role":"user","content":AgentController.json(["task":task.kind.rawValue,"state":task.state,"allowedActions":Array(task.allowedActions)])]
                ], tools:[])
                var content = (response["content"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                if content.hasPrefix("```"), let first = content.firstIndex(of:"\n"), let end = content.range(of:"```", options:.backwards) { content = String(content[content.index(after:first)..<end.lowerBound]) }
                let markup = try JSONDecoder().decode(CardMarkup.self,from:Data(content.utf8)).validated()
                try markup.validateActions(task.allowedActions)
                guard let i = sideTasks.firstIndex(where: { $0.id == id }), !sideTasks[i].hidden else { return }
                sideTasks[i].markup = markup; sideTasks[i].generated = true; persistSideTasks(); onResize?(windowSize)
            } catch { /* Keep the truthful working local fallback; generation is never required to run a timer. */ }
        }
    }
    /// Restricted local grammar: recognize explicit timer requests, never examples or explanations.
    static func timerSeconds(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"。！!.")).lowercased()
        let patterns = [
            #"^(?:请|麻烦)?(?:帮我|给我)?(?:设置|设|开始|开)?(?:一?个)?(?:倒计时|计时器|计时|定时器|定时)\s*(.+?)(?:吧|谢谢)?$"#,
            #"^(?:请|麻烦)?(?:帮我|给我)?(?:设置|设|开始|开)(?:一?个)?\s*(.+?)(?:的)?(?:倒计时|计时器|计时|定时器|定时)(?:吧|谢谢)?$"#,
            #"^(?:please\s+)?(?:(?:set|start)\s+(?:a\s+)?(?:timer|countdown)(?:\s+for)?|timer|countdown)\s+(.+?)(?:\s+please)?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern:pattern),
                  let match = regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
                  let range = Range(match.range(at:1),in:text) else { continue }
            if let seconds = localDuration(String(text[range])) { return seconds }
        }
        return nil
    }
    static func localDuration(_ raw: String) -> Double? {
        let source = raw.replacingOccurrences(of:" ",with:"")
        let pattern = #"(\d+(?:\.\d+)?|[零〇一二两三四五六七八九十百千]+|半)(小时|钟头|分钟|秒钟|分|秒|hours?|hrs?|minutes?|mins?|seconds?|secs?)(半)?"#
        guard let regex = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return nil }
        let matches = regex.matches(in:source,range:NSRange(source.startIndex...,in:source))
        guard !matches.isEmpty, matches.reduce(0,{ $0 + $1.range.length }) == (source as NSString).length else { return nil }
        var total: Double = 0
        for match in matches {
            guard let nr = Range(match.range(at:1),in:source), let ur = Range(match.range(at:2),in:source), let amount = localNumber(String(source[nr])) else { return nil }
            let unit = String(source[ur])
            let multiplier: Double = unit.contains("小时") || unit.contains("钟头") || unit.hasPrefix("h") ? 3600 : unit.hasPrefix("分") || unit.hasPrefix("m") ? 60 : 1
            total += (amount + (match.range(at:3).location == NSNotFound ? 0 : 0.5)) * multiplier
        }
        return total.isFinite && total > 0 ? total : nil
    }
    static func localNumber(_ text: String) -> Double? {
        if let number = Double(text) { return number }
        if text == "半" { return 0.5 }
        let digits: [Character:Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let units: [Character:Int] = ["十":10,"百":100,"千":1000]
        var total = 0, digit = 0
        for c in text {
            if let n = digits[c] { digit = n }
            else if let n = units[c] { total += max(1,digit) * n; digit = 0 }
            else { return nil }
        }
        return Double(total + digit)
    }
}
