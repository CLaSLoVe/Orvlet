#if DEBUG
    import AppKit
    import WebKit

    /// Real provider, short human requests, real generated controls, no keyword mocks.
    @MainActor
    enum DeliveryCheck {
        static func number(_ text: String) -> Double? {
            Double(
                text.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "").trimmingCharacters(
                    in: .whitespaces))
        }
        static func path(_ name: String) -> String {
            FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        }
        static func exportArtifacts() {
            let names =
                [
                    "orvlet-delivery-check.json", "orvlet-delivery-restore.json", "orvlet-delivery-tasks.json",
                    "orvlet-delivery.jsonl", "orvlet-delivery-restore.jsonl", "orvlet-delivery-media.json",
                    "orvlet-delivery-media.jsonl", "orvlet-delivery-history.json", "orvlet-delivery-history.jsonl",
                    "orvlet-delivery-history-index.png", "orvlet-delivery-history-thread.png",
                ]
                + ["clock", "zones", "stopwatch", "counter", "calculator", "restored", "media"].map {
                    "orvlet-delivery-\($0).png"
                }
            for name in names {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path(name))),
                    let line = try? JSONSerialization.data(withJSONObject: [
                        "artifact": name, "base64": data.base64EncodedString(),
                    ])
                {
                    FileHandle.standardOutput.write(line)
                    FileHandle.standardOutput.write(Data([10]))
                }
            }
        }
        static func submit(_ model: AppModel, _ text: String, taskID: UUID? = nil) async throws -> Double {
            let start = Date()
            if let taskID { model.editInterface(taskID) } else { model.selectChat(true) }
            model.command = text
            model.sendCommand()
            while model.busy && Date().timeIntervalSince(start) < 150 { try await Task.sleep(for: .milliseconds(100)) }
            guard !model.busy else {
                model.cancel()
                throw AppError.message("Request exceeded 150 seconds")
            }
            guard !model.taskFailed else { throw AppError.message(model.messages.last?.text ?? "Request failed") }
            return Date().timeIntervalSince(start)
        }
        static func cardViews(_ delegate: AppDelegate) -> [WKWebView] {
            func descendants(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
            }
            return delegate.panel.contentView.map(descendants) ?? []
        }
        static func rendered(_ model: AppModel, id: UUID, delegate: AppDelegate, advancing: Bool) async throws
            -> [String: Any]
        {
            guard model.selectTask(id, expanded: true, preferSource: false) else {
                throw AppError.message("Task unavailable")
            }
            try await Task.sleep(for: .milliseconds(800))
            func read() async -> [String: [String]] {
                var result: [String: [String]] = [:]
                let task = model.sideTasks.first { $0.id == id }!
                let keys = Array(task.taskSurface?.runtime?.keys ?? Set(task.taskSurface?.state.keys.map { $0 } ?? []))
                for web in cardViews(delegate) {
                    let js =
                        "typeof window.updateCard==='function'?{compact:document.documentElement.dataset.compact==='true',values:[...document.querySelectorAll('[data-bind]')].filter(e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&"
                        + JSONText.encode(keys) + ".includes(e.dataset.bind)).map(e=>e.textContent)}:null"
                    if let data = try? await web.evaluateJavaScript(js) as? [String: Any],
                        let values = data["values"] as? [String], !values.isEmpty
                    {
                        result[data["compact"] as? Bool == true ? "compact" : "expanded"] = values
                    }
                }
                return result
            }
            let first = await read()
            try await Task.sleep(for: .milliseconds(2200))
            let later = await read()
            guard first.count == 2, later.count == 2,
                later.values.allSatisfy({ $0.allSatisfy { !$0.isEmpty && $0 != "—" } })
            else { throw AppError.message("Both actual rendered views need nonempty bound values") }
            if advancing {
                guard first["compact"] != later["compact"], first["expanded"] != later["expanded"] else {
                    throw AppError.message("Rendered values did not advance in both views")
                }
            }
            return ["first": first, "later": later]
        }
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            let suite = "orvlet-delivery-" + UUID().uuidString
            let isolated = UserDefaults(suiteName: suite)!
            model.interfaceMemory = InterfaceMemory(defaults: isolated)
            func finish(_ status: Int32) -> Never {
                isolated.removePersistentDomain(forName: suite)
                exit(status)
            }
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.settings.appearance = .light
            model.backgroundRequest = true
            model.taskRuntime.stopAll()
            model.sideTasks = []
            model.messages = []
            model.archivedTaskHistory = []
            let restoring = CommandLine.arguments.contains("--delivery-restore")
            let media = CommandLine.arguments.contains("--delivery-media")
            let history = CommandLine.arguments.contains("--delivery-history")
            let reportName =
                history
                ? "orvlet-delivery-history.json"
                : restoring
                    ? "orvlet-delivery-restore.json"
                    : media ? "orvlet-delivery-media.json" : "orvlet-delivery-check.json"
            Diagnostics.begin(
                path(
                    history
                        ? "orvlet-delivery-history.jsonl"
                        : restoring
                            ? "orvlet-delivery-restore.jsonl"
                            : media ? "orvlet-delivery-media.jsonl" : "orvlet-delivery.jsonl"))
            var results: [[String: Any]] = []
            var step = "clock"
            func complete() throws -> Never {
                try JSONEncoder().encode(model.sideTasks).write(
                    to: URL(fileURLWithPath: path("orvlet-delivery-tasks.json")), options: .atomic)
                try JSONSerialization.data(withJSONObject: ["ok": true, "results": results], options: .prettyPrinted)
                    .write(to: URL(fileURLWithPath: path("orvlet-delivery-check.json")))
                model.taskRuntime.stopAll()
                exportArtifacts()
                finish(0)
            }
            do {
                if history {
                    step = "task history with real model"
                    let clockSeconds = try await submit(model, "给个时钟")
                    guard let clock = model.sideTasks.last, clock.taskSurface?.runtime != nil else {
                        throw AppError.message("Clock not created")
                    }
                    let calcSeconds = try await submit(model, "做个AA分账工具，120元3个人，能改金额和人数")
                    guard let calc = model.sideTasks.last, calc.id != clock.id, calc.taskSurface != nil else {
                        throw AppError.message("Separate calculator not created")
                    }
                    let changeSeconds = try await submit(model, "改成北京时间，保留秒数", taskID: clock.id)
                    guard model.sideTasks.count == 2, model.taskHistoryItems.count == 2,
                        Set(model.messages.compactMap(\.taskID)) == Set([clock.id, calc.id]),
                        model.sideTasks.first(where: { $0.id == clock.id })?.taskSurface?.runtime?.sources.contains(
                            where: { $0.timeZone == "Asia/Shanghai" }) == true
                    else {
                        throw AppError.message("Actual task creation or correction orphaned/mixed a conversation")
                    }
                    model.openTaskHistory()
                    delegate.resizeCommandPanel()
                    delegate.commandPanel?.resignKey()
                    try await Task.sleep(for: .milliseconds(500))
                    guard let panel = delegate.commandPanel else { throw AppError.message("History window missing") }
                    try await SideScreenCheck.snapshot(panel, path: path("orvlet-delivery-history-index.png"))
                    model.openTaskConversation(clock.id)
                    delegate.resizeCommandPanel()
                    panel.resignKey()
                    try await Task.sleep(for: .milliseconds(500))
                    guard model.visibleConversation.count >= 4,
                        !model.visibleConversation.contains(where: { $0.taskID == calc.id })
                    else { throw AppError.message("Task transcript contains unrelated calculator messages") }
                    try await SideScreenCheck.snapshot(panel, path: path("orvlet-delivery-history-thread.png"))
                    model.closeTask(clock.id)
                    guard model.restoreHistoryTask(clock.id) else {
                        throw AppError.message("Actual generated clock cannot be restored from history")
                    }
                    try await model.taskRuntime.verify(clock.id)
                    try JSONSerialization.data(
                        withJSONObject: [
                            "ok": true, "clockSeconds": clockSeconds, "calculatorSeconds": calcSeconds,
                            "correctionSeconds": changeSeconds, "tasks": 2,
                            "clockMessages": model.messages.filter { $0.taskID == clock.id }.count,
                            "calculatorMessages": model.messages.filter { $0.taskID == calc.id }.count,
                            "restoredClockRunning": true,
                        ], options: .prettyPrinted
                    ).write(to: URL(fileURLWithPath: path(reportName)))
                    model.taskRuntime.stopAll()
                    exportArtifacts()
                    finish(0)
                }
                if media {
                    step = "media coexistence"
                    model.sideTasks = try JSONDecoder().decode(
                        [SideTask].self, from: FileHandle.standardInput.readDataToEndOfFile())
                    for task in model.sideTasks where task.taskSurface?.runtime != nil {
                        model.taskRuntime.attach(task.id)
                    }
                    guard
                        let clock = model.sideTasks.first(where: {
                            $0.taskSurface?.runtime?.sources.contains(where: { $0.kind == .clock }) == true
                        })
                    else { throw AppError.message("Clock missing") }
                    let seconds = try await submit(model, "播放 dream funk")
                    let initial = try await model.observation()
                    model.selectTask(clock.id, expanded: true)
                    model.dismissTask(clock.id)
                    model.collapse()
                    try await Task.sleep(for: .seconds(3))
                    let later = try await model.observation()
                    guard later["audible"] as? Bool == true,
                        (later["currentTime"] as? Double ?? 0) > (initial["currentTime"] as? Double ?? 0)
                    else { throw AppError.message("Music did not continue while switching and hiding another task") }
                    try await model.taskRuntime.verify(clock.id)
                    // Selecting a running local task must make its pause local, not pause music.
                    model.selectTask(clock.id, expanded: true)
                    model.command = "暂停"
                    model.sendCommand()
                    try await Task.sleep(for: .milliseconds(300))
                    let isolated = try await model.observation()
                    guard model.sideTasks.first(where: { $0.id == clock.id })?.runtimeState?.phase == .paused,
                        isolated["playing"] as? Bool == true
                    else { throw AppError.message("Local pause affected the wrong task") }
                    model.taskRuntime.control(clock.id, operation: "resume")
                    _ = try await model.performBrowserAction(["action": "media", "operation": "pause"])
                    guard try await model.observation()["playing"] as? Bool == false else {
                        throw AppError.message("Music pause failed")
                    }
                    _ = try await model.performBrowserAction(["action": "media", "operation": "play"])
                    model.collapse()
                    try await Task.sleep(for: .seconds(2))
                    guard try await model.observation()["audible"] as? Bool == true else {
                        throw AppError.message("Music resume failed")
                    }
                    try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-media.png"))
                    _ = try await model.performBrowserAction(["action": "media", "operation": "pause"])
                    try JSONSerialization.data(
                        withJSONObject: [
                            "ok": true, "request": "播放 dream funk", "seconds": seconds, "audibleAdvancement": true,
                            "hiddenRuntime": true, "localPauseIsolation": true, "musicPauseResume": true,
                        ], options: .prettyPrinted
                    ).write(to: URL(fileURLWithPath: path(reportName)))
                    model.taskRuntime.stopAll()
                    exportArtifacts()
                    finish(0)
                }
                if restoring {
                    let tasks = try JSONDecoder().decode(
                        [SideTask].self, from: FileHandle.standardInput.readDataToEndOfFile())
                    model.sideTasks = tasks
                    for task in tasks where task.taskSurface?.runtime != nil { model.taskRuntime.attach(task.id) }
                    guard
                        let clock = tasks.first(where: {
                            $0.taskSurface?.runtime?.sources.contains(where: { $0.kind == .clock }) == true
                        })
                    else { throw AppError.message("Saved clock missing") }
                    for task in tasks where task.taskSurface?.runtime != nil {
                        try await model.taskRuntime.verify(task.id)
                    }
                    if let counter = tasks.first(where: { $0.taskSurface?.runtime?.refresh != nil }),
                        let key = counter.taskSurface?.runtime?.refresh?.outputKeys.first
                    {
                        let current = model.sideTasks.first(where: { $0.id == counter.id })?.state[key]
                        guard current != counter.state[key] else {
                            throw AppError.message("Restored scheduled calculation did not continue from saved state")
                        }
                    }
                    let view = try await rendered(model, id: clock.id, delegate: delegate, advancing: true)
                    try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-restored.png"))
                    try JSONSerialization.data(
                        withJSONObject: ["ok": true, "restored": view, "tasks": tasks.count], options: .prettyPrinted
                    ).write(to: URL(fileURLWithPath: path("orvlet-delivery-restore.json")))
                    model.taskRuntime.stopAll()
                    exportArtifacts()
                    finish(0)
                }
                let elapsed = try await submit(model, "给个时钟")
                guard let clock = model.sideTasks.last, clock.taskSurface?.runtime != nil, model.webURL.isEmpty else {
                    throw AppError.message("A local clock should run without a webpage")
                }
                results.append([
                    "request": "给个时钟", "seconds": elapsed,
                    "rendered": try await rendered(model, id: clock.id, delegate: delegate, advancing: true),
                ])
                try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-clock.png"))
                step = "timezone correction"
                let correction = try await submit(model, "同时显示北京和伦敦的时间，保留秒数", taskID: clock.id)
                guard model.sideTasks.count == 1, let changed = model.sideTasks.first,
                    changed.taskSurface?.runtime?.sources.contains(where: { $0.timeZone == "Asia/Shanghai" }) == true,
                    changed.taskSurface?.runtime?.sources.contains(where: { $0.timeZone == "Europe/London" }) == true
                else { throw AppError.message("Timezone correction did not change actual sources in the same task") }
                results.append([
                    "request": "同时显示北京和伦敦的时间，保留秒数", "seconds": correction,
                    "rendered": try await rendered(model, id: clock.id, delegate: delegate, advancing: true),
                ])
                try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-zones.png"))
                if CommandLine.arguments.contains("--clock-only") { try complete() }
                step = "stopwatch"
                let stopwatchTime = try await submit(model, "做个秒表，可以暂停和继续")
                guard let stopwatch = model.sideTasks.last, stopwatch.id != clock.id, let sw = stopwatch.taskSurface,
                    sw.runtime?.sources.contains(where: { $0.kind == .elapsed }) == true,
                    let toggle = sw.actions.first(where: {
                        $0.kind == .runtime && ["toggle", "pause"].contains($0.operation ?? "")
                    })
                else { throw AppError.message("Stopwatch needs real elapsed source and local controls") }
                let swView = try await rendered(model, id: stopwatch.id, delegate: delegate, advancing: true)
                model.cardAction(stopwatch.id, action: toggle.id, value: nil)
                let frozen = model.sideTasks.first(where: { $0.id == stopwatch.id })!.liveValues
                try await Task.sleep(for: .milliseconds(1400))
                guard model.sideTasks.first(where: { $0.id == stopwatch.id })!.liveValues == frozen else {
                    throw AppError.message("Generated pause did not freeze stopwatch")
                }
                let resume = sw.actions.first(where: {
                    $0.kind == .runtime && ["toggle", "resume"].contains($0.operation ?? "")
                })
                guard let resume else { throw AppError.message("Generated stopwatch has no resume") }
                model.cardAction(stopwatch.id, action: resume.id, value: nil)
                try await model.taskRuntime.verify(stopwatch.id)
                results.append([
                    "request": "做个秒表，可以暂停和继续", "seconds": stopwatchTime, "pauseResume": true, "rendered": swView,
                ])
                try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-stopwatch.png"))
                step = "scheduled calculation"
                let counterTime = try await submit(model, "做个从0开始、每两秒自动加1的计数器，可以暂停和继续")
                guard let counter = model.sideTasks.last, let refresh = counter.taskSurface?.runtime?.refresh,
                    refresh.intervalSeconds == 2
                else { throw AppError.message("Counter needs a real two-second scheduled calculation") }
                let c1 = counter.liveValues
                try await Task.sleep(for: .milliseconds(2300))
                guard model.sideTasks.first(where: { $0.id == counter.id })?.liveValues != c1 else {
                    throw AppError.message("Scheduled calculation did not update")
                }
                guard
                    let pauseCounter = counter.taskSurface?.actions.first(where: {
                        $0.kind == .runtime && ["toggle", "pause"].contains($0.operation ?? "")
                    }),
                    let resumeCounter = counter.taskSurface?.actions.first(where: {
                        $0.kind == .runtime && ["toggle", "resume"].contains($0.operation ?? "")
                    })
                else { throw AppError.message("Counter has no generated pause/resume controls") }
                model.cardAction(counter.id, action: pauseCounter.id, value: nil)
                let pausedCounter = model.sideTasks.first(where: { $0.id == counter.id })?.liveValues
                try await Task.sleep(for: .milliseconds(2300))
                guard model.sideTasks.first(where: { $0.id == counter.id })?.liveValues == pausedCounter else {
                    throw AppError.message("Counter pause did not cancel future updates")
                }
                model.cardAction(counter.id, action: resumeCounter.id, value: nil)
                try await model.taskRuntime.verify(counter.id)
                results.append([
                    "request": "做个从0开始、每两秒自动加1的计数器，可以暂停和继续", "seconds": counterTime,
                    "rendered": try await rendered(model, id: counter.id, delegate: delegate, advancing: true),
                ])
                try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-counter.png"))
                step = "calculator"
                let calcTime = try await submit(model, "做个AA分账工具，120元3个人，能改金额和人数")
                guard let calc = model.sideTasks.last, let cs = calc.taskSurface,
                    let action = cs.actions.first(where: { $0.kind == .code }), cs.fields.count == 2
                else { throw AppError.message("Calculator needs editable inputs and a local action") }
                guard let amount = cs.fields.first(where: { (cs.state[$0] ?? "") == "120" }),
                    let people = cs.fields.first(where: { (cs.state[$0] ?? "") == "3" })
                else { throw AppError.message("Calculator's initial inputs do not match the request") }
                _ = try await rendered(model, id: calc.id, delegate: delegate, advancing: false)
                let fields = [amount: "150", people: "5"]
                // Exercise the rendered form and its real button -> native bridge.
                var clicked = false
                for web in cardViews(delegate) {
                    let js =
                        "(()=>{if(typeof window.updateCard!=='function'||document.documentElement.dataset.compact==='true')return false;const values="
                        + JSONText.encode(fields)
                        + ";for(const [key,value] of Object.entries(values)){const e=[...document.querySelectorAll('[data-field]')].find(e=>e.dataset.field===key);if(!e)return false;e.value=value;e.dispatchEvent(new Event('input',{bubbles:true}));}const b=[...document.querySelectorAll('button[data-action]')].find(e=>e.dataset.action==='"
                        + action.id + "');if(!b)return false;b.click();return true;})()"
                    if (try? await web.evaluateJavaScript(js)) as? Bool == true { clicked = true }
                }
                try await Task.sleep(for: .milliseconds(600))
                guard clicked,
                    model.sideTasks.first(where: { $0.id == calc.id })?.state.values.contains(where: {
                        number($0) == 30
                    }) == true
                else { throw AppError.message("Actual generated button did not calculate 150 / 5 = 30") }
                results.append([
                    "request": "做个AA分账工具，120元3个人，能改金额和人数", "seconds": calcTime, "renderedButton150div5": 30,
                ])
                try await SideScreenCheck.snapshot(delegate.panel, path: path("orvlet-delivery-calculator.png"))
                step = "invalid calculator input"
                model.cardAction(calc.id, action: action.id, value: JSONText.encode([amount: "150", people: "0"]))
                try await Task.sleep(for: .milliseconds(600))
                guard let invalid = model.sideTasks.first(where: { $0.id == calc.id }),
                    invalid.status == "Input needs attention",
                    invalid.state[people] == "0", invalid.state.values.contains(where: { number($0) == 30 }),
                    model.messages.last?.taskID == calc.id
                else {
                    throw AppError.message("Invalid input must preserve the last result and belong to the calculator")
                }
                try await model.taskRuntime.verify(clock.id)
                results.append(["invalidInputPreservedResult": true, "otherTaskStillRunning": true])
                // Restore a valid input before saving the deliverable acceptance examples.
                model.cardAction(calc.id, action: action.id, value: JSONText.encode(fields))
                try await Task.sleep(for: .milliseconds(600))
                step = "persistence"
                try complete()
            } catch {
                try? JSONEncoder().encode(model.sideTasks).write(
                    to: URL(fileURLWithPath: path("orvlet-delivery-tasks.json")), options: .atomic)
                model.cancel()
                model.taskRuntime.stopAll()
                try? JSONSerialization.data(
                    withJSONObject: [
                        "ok": false, "stage": step, "error": error.localizedDescription, "results": results,
                    ], options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: path(reportName)))
                exportArtifacts()
                finish(1)
            }
        }
    }
#endif
