#if DEBUG
    import AppKit
    import WebKit

    @MainActor
    enum ClockCheck {
        static func renderedClock(_ model: AppModel, id: UUID, delegate: AppDelegate) async throws -> [String: Any] {
            func descendants(_ view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
            }
            guard model.selectTask(id, expanded: true, preferSource: false),
                let task = model.sideTasks.first(where: { $0.id == id })
            else { throw AppError.message("The requested clock task is unavailable") }
            let keys = Set((task.plan?.readings ?? []).map(\.key))
            func read() async throws -> [String: [String]] {
                var values: [String: [String]] = [:]
                for web in descendants(delegate.panel.contentView!) {
                    let js =
                        "typeof window.updateCard==='function'?{compact:document.documentElement.dataset.compact==='true',values:[...document.querySelectorAll('[data-bind]')].filter(e=>"
                        + JSONText.encode(Array(keys)) + ".includes(e.dataset.bind)).map(e=>e.textContent)}:null"
                    if let result = try? await web.evaluateJavaScript(js) as? [String: Any],
                        let texts = result["values"] as? [String], !texts.isEmpty
                    {
                        values[result["compact"] as? Bool == true ? "compact" : "expanded"] = texts
                    }
                }
                return values
            }
            var first: [String: [String]] = [:]
            for _ in 0..<50 {
                first = try await read()
                if first.count == 2, first.values.allSatisfy({ $0.allSatisfy { !$0.isEmpty && $0 != "—" } }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(2))
            let second = try await read()
            guard first.count == 2, second.count == 2, first["compact"] != second["compact"],
                first["expanded"] != second["expanded"]
            else {
                throw AppError.message(
                    "The actual compact and expanded clock text must both advance: \(first) → \(second)")
            }
            return ["first": first, "second": second]
        }
        static func submit(_ model: AppModel, _ prompt: String) async throws {
            model.command = prompt
            model.sendCommand()
            let deadline = Date().addingTimeInterval(240)
            while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if model.busy {
                model.cancel()
                throw AppError.message("The live request timed out")
            }
            guard !model.taskFailed else {
                throw AppError.message(model.feedback?.text ?? "The request stopped before completion")
            }
        }
        static func checkMusic(_ model: AppModel, clockID: UUID, delegate: AppDelegate) async throws -> [String: Any] {
            model.settings.taskStartPolicy = .taskFirst
            try await submit(
                model,
                "Play DREAM FUNK on YouTube. Keep the existing live clock task. Prepare a calm generated player with live track title and transport controls, then verify audible playback. This is a listening task."
            )
            guard let music = model.sideTasks.first(where: { $0.isMediaTask && $0.playing }),
                let source = model.liveBrowsers.first(where: { $0.id == music.id })
            else { throw AppError.message("No verified live music task") }
            let timer = try model.startTimer(seconds: 600, title: "Tea")
            model.setCompactTaskLimit(3)
            model.selectTask(music.id, expanded: true, preferSource: false)
            try await Task.sleep(for: .seconds(1))
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-live-player.png")
            let before = (try await source.observe())["currentTime"] as? Double ?? 0
            let concurrentClock = try await renderedClock(model, id: clockID, delegate: delegate)
            let after = try await source.observe()
            guard after["playing"] as? Bool == true, (after["currentTime"] as? Double ?? 0) > before + 0.2 else {
                throw AppError.message("Changing the expanded task interrupted music")
            }
            model.controlMedia(music.id, operation: "pause")
            try await Task.sleep(for: .seconds(3))
            let paused = try await source.observe()
            guard paused["playing"] as? Bool == false, source.userPausedPlayback,
                model.selectedTaskID == clockID
            else {
                throw AppError.message(
                    "Background pause: playing=\(String(describing:paused["playing"])), hold=\(source.userPausedPlayback), foreground=\(model.selectedTaskID == clockID), controllerRetained=\(model.parkedBrowsers[music.id] === source), role=\(model.sideTasks.first(where:{$0.id == music.id})?.isMediaTask == true), issue=\(model.feedback?.text ?? "none")"
                )
            }
            model.timerAction(timer, action: "toggle")
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-live-multitasking.png")
            return [
                "music": music.title, "tasks": model.sideTasks.count, "musicContinuedDuringClockInteraction": true,
                "pauseStayedPaused": true,
                "timerPaused": model.sideTasks.first(where: { $0.id == timer })?.deadline == nil,
                "renderedClock": concurrentClock,
            ]
        }
        static func throughAgent(_ model: AppModel, delegate: AppDelegate) async throws {
            let suite = "orvlet-clock-memory-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            model.interfaceMemory = InterfaceMemory(defaults: defaults)
            model.sideTasks = []
            model.messages = []
            model.backgroundRequest = true
            Diagnostics.begin("/tmp/orvlet-clock-agent.jsonl")
            try await submit(model, "time.is")
            guard model.sideTasks.count == 1, let task = model.sideTasks.first, task.kind == .web,
                !task.isMediaTask, task.plan?.readings?.isEmpty == false
            else {
                throw AppError.message(
                    "The raw time.is request must create exactly one live webpage card, without a player or static duplicate."
                )
            }
            model.collapse()
            delegate.panel.orderFrontRegardless()
            try await Task.sleep(for: .seconds(2))
            let first = model.sideTasks[0].liveValues ?? [:]
            try await Task.sleep(for: .seconds(2))
            let second = model.sideTasks[0].liveValues ?? [:]
            guard !first.isEmpty, first != second else {
                throw AppError.message("Time readings did not advance from the real page.")
            }
            let initialRendered = try await renderedClock(model, id: task.id, delegate: delegate)
            model.reviseInterface(
                task.id,
                instruction:
                    "Make the time the main value; keep the compact view to the time only, with seconds and tabular digits. Keep the shared calm style. Preserve live webpage readings."
            )
            try await Task.sleep(for: .milliseconds(600))
            guard model.taskActivity(model.sideTasks[0])?.isWorking == true else {
                throw AppError.message("Interface work has no visible task state.")
            }
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-clock-editing.png")
            for _ in 0..<900 {
                if !model.busy && model.interfaceJobs[task.id] == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let edited = model.sideTasks.first, edited.customCompact == true,
                !model.interfaceMemory.recipes.isEmpty
            else {
                throw AppError.message("The real edit did not save a reusable design.")
            }
            model.selectTask(task.id, expanded: true, preferSource: false)
            try await Task.sleep(for: .seconds(1))
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-clock-edited.png")
            let editedRendered = try await renderedClock(model, id: task.id, delegate: delegate)
            model.closeTask(task.id)
            model.messages = []
            try await submit(model, "请再次打开 time.is 看准确时间，沿用我之前修改过的简洁界面。")
            guard model.sideTasks.count == 1, let reused = model.sideTasks.first, reused.kind == .web,
                reused.interfaceRecipeID == edited.interfaceRecipeID,
                reused.presentation.hasSameDesign(as: edited.presentation)
            else {
                throw AppError.message(
                    "Saved design check: count=\(model.sideTasks.count), kind=\(model.sideTasks.first?.kind.rawValue ?? "none"), recipe=\(model.sideTasks.first?.interfaceRecipeID == edited.interfaceRecipeID), markup=\(model.sideTasks.first?.presentation == edited.presentation)"
                )
            }
            try await Task.sleep(for: .seconds(2))
            let reusedFirst = model.sideTasks[0].liveValues ?? [:]
            try await Task.sleep(for: .seconds(2))
            let reusedSecond = model.sideTasks[0].liveValues ?? [:]
            guard !reusedFirst.isEmpty, reusedFirst != reusedSecond else {
                throw AppError.message("Reused design did not receive fresh live readings.")
            }
            model.selectTask(reused.id, expanded: true, preferSource: false)
            try await Task.sleep(for: .seconds(1))
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-clock-reused.png")
            let reusedRendered = try await renderedClock(model, id: reused.id, delegate: delegate)
            let multitasking =
                CommandLine.arguments.contains("--with-music")
                ? try await checkMusic(model, clockID: reused.id, delegate: delegate) : [:]
            try JSONSerialization.data(
                withJSONObject: [
                    "multitasking": multitasking, "renderedInitial": initialRendered, "renderedEdited": editedRendered,
                    "renderedReused": reusedRendered, "ok": true, "taskCount": model.sideTasks.count, "first": first,
                    "second": second, "reusedFirst": reusedFirst, "reusedSecond": reusedSecond,
                    "sameEditedMarkup": true, "semanticSelection": true,
                ], options: .prettyPrinted
            ).write(to: URL(fileURLWithPath: "/tmp/orvlet-clock-agent-check.json"))
        }
        static func beijingCorrection(_ model: AppModel, delegate: AppDelegate) async throws {
            model.messages = []
            model.sideTasks = []
            model.backgroundRequest = true
            Diagnostics.begin("/tmp/orvlet-beijing-agent.jsonl")
            let page = try await model.browser.action(["action": "navigate", "url": "https://time.is/New_York"])
            let readings = page["readables"] as? [[String: Any]] ?? []
            guard let time = readings.first(where: { $0["role"] as? String == "time" })?["selector"] as? String,
                let place = readings.first(where: { $0["role"] as? String == "h1" })?["selector"] as? String
            else {
                throw AppError.message("The public clock source did not expose its time and location")
            }
            let markup = CardMarkup(
                html:
                    "<section class='calm-surface'><small data-bind='place'></small><strong class='calm-value' data-bind='clock'></strong></section>",
                compactHTML: "<span class='calm-value' data-bind='clock'></span>", css: "", height: 120)
            let plan = SurfacePlan(
                components: [], width: 320, height: 150, title: "New York", markup: markup, actions: [],
                readings: [CardReading(key: "place", selector: place), CardReading(key: "clock", selector: time)])
            model.install(try plan.validated(observation: page))
            model.upsertWebTask(plan, activate: true)
            let id = model.browser.id
            model.editInterface(id)
            try await submit(model, "改成北京时间，显示实时秒数。")
            guard !model.taskFailed, model.sideTasks.count == 1, let task = model.sideTasks.first, task.id == id,
                task.sourceURL != "https://time.is/New_York", task.plan?.readings?.count ?? 0 >= 2,
                model.messages.filter(\.isUser).last?.taskID == id,
                model.messages.last?.taskID == id
            else { throw AppError.message("The semantic edit did not update the original task and its conversation") }
            let live = try await model.observation()
            guard
                (live["readables"] as? [[String: Any]])?.contains(where: {
                    ($0["evidenceRole"] as? String == "primary")
                        && ((($0["text"] as? String ?? "").localizedCaseInsensitiveContains("Beijing"))
                            || (($0["text"] as? String ?? "").contains("北京")))
                }) == true
            else {
                throw AppError.message("The live source does not identify Beijing")
            }
            let rendered = try await renderedClock(model, id: id, delegate: delegate)
            try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-beijing-correction.png")
            try JSONSerialization.data(
                withJSONObject: [
                    "ok": true, "source": task.sourceURL ?? "", "sameTask": true, "replyAttributed": true,
                    "rendered": rendered,
                ], options: .prettyPrinted
            ).write(to: URL(fileURLWithPath: "/tmp/orvlet-beijing-check.json"))
        }
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            if let index = CommandLine.arguments.firstIndex(of: "--model-override"),
                CommandLine.arguments.indices.contains(index + 1)
            {
                model.settings.main.model = CommandLine.arguments[index + 1]
            }
            model.settings.appearance = .light
            model.latestIntent =
                "Use this page as a live clock. Generate a useful compact view of its current time and location, with live readings. It is not a music task."
            var stage = "Loading public page"
            do {
                if CommandLine.arguments.contains("--beijing-only") {
                    try await beijingCorrection(model, delegate: delegate)
                    exit(0)
                }
                if CommandLine.arguments.contains("--list-provider-models") {
                    guard let endpoint = model.settings.main.completionURL else {
                        throw AppError.message("No endpoint")
                    }
                    let url = endpoint.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                        "models")
                    var request = URLRequest(url: url)
                    request.setValue("Bearer " + (try await model.loadModelKey()), forHTTPHeaderField: "Authorization")
                    let (data, response) = try await ModelClient.session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw AppError.message("Model catalogue unavailable")
                    }
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let ids = (payload?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.filter {
                        $0.lowercased().contains("deepseek") || $0.lowercased().contains("kimi")
                            || $0.lowercased().contains("glm")
                    }
                    try JSONSerialization.data(withJSONObject: ids, options: .prettyPrinted).write(
                        to: URL(fileURLWithPath: "/tmp/orvlet-provider-models.json"))
                    exit(0)
                }
                if CommandLine.arguments.contains("--music-only") {
                    // The full check covers AI clock creation/edit/reuse separately.
                    // Keep a real live clock alongside music without repeating those provider calls.
                    model.sideTasks = []
                    model.messages = []
                    model.backgroundRequest = true
                    Diagnostics.begin("/tmp/orvlet-music-agent.jsonl")
                    let page = try await model.browser.action(["action": "navigate", "url": "https://time.is/"])
                    guard
                        let selector = (page["readables"] as? [[String: Any]] ?? []).first(where: {
                            $0["role"] as? String == "time"
                        })?["selector"] as? String
                    else { throw AppError.message("Live clock reading unavailable") }
                    var plan = SurfacePlan(components: [], width: 300, height: 100, title: "Clock")
                    plan.readings = [CardReading(key: "clock", selector: selector)]
                    plan.markup = CardMarkup(
                        html:
                            "<section class='calm-surface'><strong class='calm-value' data-bind='clock'></strong></section>",
                        compactHTML:
                            "<div class='calm-glance'><strong class='calm-value' data-bind='clock'></strong></div>",
                        css: "", height: 100)
                    model.install(try plan.validated(observation: page))
                    model.upsertWebTask(plan, activate: true)
                    let result = try await checkMusic(model, clockID: model.browser.id, delegate: delegate)
                    try JSONSerialization.data(
                        withJSONObject: ["ok": true, "multitasking": result], options: .prettyPrinted
                    ).write(to: URL(fileURLWithPath: "/tmp/orvlet-music-check.json"))
                    exit(0)
                }
                if CommandLine.arguments.contains("--through-agent") {
                    try await throughAgent(model, delegate: delegate)
                    exit(0)
                }
                let page = try await model.browser.action(["action": "navigate", "url": "https://time.is/"])
                try JSONSerialization.data(withJSONObject: page, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-clock-observation.json"))
                if CommandLine.arguments.contains("--observe-only") {
                    let readings = page["readables"] as? [[String: Any]] ?? []
                    guard
                        let selector = readings.first(where: { $0["role"] as? String == "time" })?["selector"]
                            as? String
                    else { throw AppError.message("No observed time element") }
                    try await model.browser.bindReadings([CardReading(key: "clock", selector: selector)])
                    let first = (try await model.browser.observe())["readings"] as? [String: String] ?? [:]
                    try await Task.sleep(for: .seconds(2))
                    let second = (try await model.browser.observe())["readings"] as? [String: String] ?? [:]
                    let ok = !first.isEmpty && first != second && page["mediaPrimary"] as? Bool == false
                    try JSONSerialization.data(
                        withJSONObject: [
                            "ok": ok, "modelGenerationTested": false, "first": first, "second": second,
                            "selector": selector,
                        ], options: .prettyPrinted
                    ).write(to: URL(fileURLWithPath: "/tmp/orvlet-clock-readings.json"))
                    exit(ok ? 0 : 1)
                }
                guard model.settings.main.isConfigured else {
                    throw AppError.message("Configure a model in Settings before running a live provider check.")
                }
                stage = "Reading existing local credential"
                guard !(try await SecretStore.load("main")).isEmpty else {
                    throw AppError.message("No saved model key is available to this test process")
                }
                stage = "Generating with configured provider"
                let plan = try await model.adaptive.compose(page).validated(observation: page)
                guard let markup = plan.markup, !markup.compactHTML.isEmpty, plan.readings?.isEmpty == false,
                    !plan.bindings.contains(where: { $0.action == "media" })
                else { throw AppError.message("Provider must generate a live non-media compact card") }
                stage = "Checking generated live card"
                model.install(plan)
                model.upsertWebTask(plan, activate: true)
                model.collapse()
                delegate.panel.orderFrontRegardless()
                try await Task.sleep(for: .seconds(2))
                let first = model.selectedSideTask?.liveValues ?? [:]
                try await Task.sleep(for: .seconds(2))
                let second = model.selectedSideTask?.liveValues ?? [:]
                guard !second.isEmpty, first != second, model.microMediaTasks.isEmpty else {
                    throw AppError.message("Clock readings must advance and must not be a player")
                }
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-clock-compact.png")
                model.selectTask(model.browser.id, expanded: true, preferSource: false)
                try await Task.sleep(for: .seconds(1))
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-clock-expanded.png")
                let result: [String: Any] = [
                    "ok": true, "plan": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)),
                    "first": first, "second": second, "mediaPrimary": page["mediaPrimary"] ?? false,
                ]
                try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-clock-check.json"))
                exit(0)
            } catch {
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "stage": stage, "error": error.localizedDescription],
                    options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-clock-check.json"))
                exit(1)
            }
        }
    }
#endif
