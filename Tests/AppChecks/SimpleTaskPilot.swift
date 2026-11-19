#if DEBUG
    import AppKit
    import Combine
    import WebKit

    /// Six synthetic, independently scored tasks. Separate process and defaults per case.
    @MainActor
    enum SimpleTaskPilot {
        static var cardCoordinator: HTMLCardView.Coordinator?
        static var stateSubscription: AnyCancellable?
        struct Example: Decodable {
            let id: String
            let prompt: String
            let inputs: [String]
            let expected: String
            let changes: [[String]]
            let answers: [String]
            var text = false
            var timerSeconds: Double? = nil
        }
        static let examples: [Example] = [
            .init(
                id: "bill", prompt: "做个AA分账工具，120元3个人，能修改金额和人数，显示人均金额。", inputs: ["120", "3"], expected: "40",
                changes: [["120", "4"], ["180", "4"]], answers: ["30", "45"]),
            .init(
                id: "service", prompt: "做个分账小工具：账单120元，3人均分，另加10%的服务费。金额、人数、服务费百分比都能修改，显示人均金额。",
                inputs: ["120", "3", "10"], expected: "44", changes: [["200", "4", "10"], ["200", "4", "0"]],
                answers: ["55", "50"]),
            .init(
                id: "temperature", prompt: "做个摄氏度转华氏度的小工具，初始25摄氏度，能修改摄氏度并显示对应华氏度。", inputs: ["25"], expected: "77",
                changes: [["0"], ["-40"]], answers: ["32", "-40"]),
            .init(
                id: "deduplicate", prompt: "做个逐行文本去重工具，区分大小写，保留首次出现的顺序。输入可以修改。初始文本是这四行：\nApple\napple\nApple\nBanana",
                inputs: ["Apple\napple\nApple\nBanana"], expected: "Apple\napple\nBanana",
                changes: [["red\nblue\nred"], ["A\nA\nB\nB"]], answers: ["red\nblue", "A\nB"], text: true),
            .init(id: "countdown", prompt: "帮我倒计时60秒", inputs: [], expected: "", changes: [], answers: [], timerSeconds: 60),
            .init(
                id: "fixed-rate", prompt: "做个按固定汇率把港币换成人民币的小工具。金额初始100港币，汇率初始每港币0.92人民币，金额和汇率都可以修改，显示人民币结果。不查实时汇率。",
                inputs: ["100", "0.92"], expected: "92", changes: [["250", "0.92"], ["250", "0.90"]],
                answers: ["230", "225"]),
        ]
        static func emit(_ value: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
        static func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AppError.message(message) }
        }
        static func matches(_ actual: String, _ expected: String, text: Bool) -> Bool {
            let value = actual.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
                of: "\r\n", with: "\n")
            if text { return actual.replacingOccurrences(of: "\r\n", with: "\n") == expected }
            // Accept a numeric value with currency/unit adornment, but not a sentence with several numbers.
            let regex = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
            let hits = regex.matches(
                in: value.replacingOccurrences(of: ",", with: ""),
                range: NSRange(location: 0, length: (value.replacingOccurrences(of: ",", with: "") as NSString).length))
            guard hits.count == 1, let want = Double(expected) else { return false }
            let clean = value.replacingOccurrences(of: ",", with: "") as NSString
            guard let got = Double(clean.substring(with: hits[0].range)) else { return false }
            return abs(got - want) < 0.005
        }
        static func expanded(_ model: AppModel, task: SideTask, delegate: AppDelegate) async throws -> WKWebView {
            // Mount the production card document and bridge in a plain WebKit fixture.
            // This checks the generated component, not the SwiftUI shell or task shelf.
            emit(["progress": "mounting-card"])
            let coordinator = HTMLCardView.Coordinator()
            cardCoordinator = coordinator
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(coordinator, name: "card")
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 320), configuration: config)
            emit(["progress": "webview-created"])
            coordinator.view = web
            coordinator.allowed = task.allowedActions
            coordinator.action = { action, value in model.cardAction(task.id, action: action, value: value) }
            func state(_ task: SideTask) -> [String: [String: String]] {
                HTMLCardView.renderState(task.state, compact: false, appearance: .light,
                                         formMode: task.taskSurface != nil, reduceMotion: true)
            }
            coordinator.state = state(task)
            stateSubscription = model.$sideTasks.sink { tasks in
                if let current = tasks.first(where: { $0.id == task.id }) {
                    coordinator.state = state(current)
                    coordinator.pushState()
                }
            }
            web.navigationDelegate = coordinator
            delegate.panel.contentView = web
            emit(["progress": "webview-attached"])
            let markup = task.taskSurface?.markup ?? task.presentation
            web.loadHTMLString(HTMLCardView.document(fragment: markup.html, css: markup.css), baseURL: nil)
            emit(["progress": "html-requested"])
            for _ in 0..<80 {
                if coordinator.loaded,
                    (try? await web.evaluateJavaScript(
                        "typeof window.updateCard==='function' && document.documentElement.dataset.compact!=='true'"))
                        as? Bool == true
                {
                    return web
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppError.message("Expanded card did not mount within 8 seconds")
        }
        static func reading(_ web: WKWebView, key: String) async -> [String] {
            let js =
                "[...document.querySelectorAll('[data-bind]')].filter(e=>e.dataset.bind===" + JSONText.encode(key)
                + " && e.getClientRects().length && getComputedStyle(e).visibility!=='hidden').map(e=>e.matches('input,textarea,select')?e.value:e.textContent)"
            return (try? await web.evaluateJavaScript(js)) as? [String] ?? []
        }
        static func click(_ web: WKWebView, action: String, fields: [String: String] = [:]) async throws {
            let js =
                "(()=>{const values=" + JSONText.encode(fields)
                + ";for(const [key,value] of Object.entries(values)){const e=[...document.querySelectorAll('[data-field]')].find(e=>e.dataset.field===key);if(!e)return 'missing input '+key;e.value=value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));}const b=[...document.querySelectorAll('[data-action]')].find(e=>e.dataset.action==="
                + JSONText.encode(action)
                + " && e.getClientRects().length);if(!b)return 'missing action';b.click();return 'clicked';})()"
            let result = try await web.evaluateJavaScript(js) as? String
            try require(result == "clicked", result ?? "UI action failed")
        }
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            let args = CommandLine.arguments
            let logicOnly = args.contains("--pilot-logic-only")
            let replay = args.contains("--pilot-replay")
            let example: Example
            if args.contains("--pilot-example") {
                do {
                    example = try JSONDecoder().decode(Example.self, from: FileHandle.standardInput.readDataToEndOfFile())
                } catch { emit(["error": error.localizedDescription]); exit(2) }
            } else if let index = args.firstIndex(of: "--pilot-case"), index + 1 < args.count,
                let selected = examples.first(where: { $0.id == args[index + 1] }) {
                example = selected
            } else { emit(["error": "Choose a pilot case or supply a study example"]); exit(2) }
            // Settings and credentials are read from the configured app; task writes are isolated by pipelineModel.
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            model.backgroundRequest = true
            model.onShow = nil
            model.onCommandPanel = nil
            if !logicOnly {
                delegate.panel = ShellPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                delegate.panel.isReleasedWhenClosed = false
                delegate.panel.alphaValue = replay ? 1 : 0
                delegate.panel.ignoresMouseEvents = true
                if replay, let frame = NSScreen.main?.visibleFrame {
                    delegate.panel.setFrameOrigin(NSPoint(x: frame.maxX - 320, y: frame.maxY - 340))
                }
                delegate.panel.orderFrontRegardless()
            }
            let trace = FileManager.default.temporaryDirectory.appendingPathComponent(
                "simple-pilot-\(example.id).jsonl")
            Diagnostics.begin(trace.path)
            let start = Date()
            var row: [String: Any] = [
                "case": example.id, "prompt": example.prompt, "model": model.settings.main.model,
                "providerHost": model.settings.main.completionURL?.host ?? "", "jevEnabled": model.settings.useFast,
                "logicPassed": false, "uiPassed": false, "ok": false, "timeoutSeconds": 1800,
                "modelRequestTimeoutSeconds": Double(model.settings.main.options.timeout) ?? ModelClient.defaultTimeout,
                "builtinMethodsEnabled": true,
                "uiScope": "production HTML document and native bridge in isolated WebKit; excludes SwiftUI shell",
            ]
            var stage = "creation"
            row["logicOnly"] = logicOnly
            row["replay"] = replay
            if logicOnly { row["uiPassed"] = NSNull() }
            var checks: [[String: Any]] = []
            var savedTask: UUID?
            emit(["progress": "started", "case": example.id])
            do {
                if replay {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    let task = try JSONDecoder().decode(SideTask.self, from: data)
                    model.sideTasks = [task]
                    if let duration = example.timerSeconds {
                        model.sideTasks = []
                        _ = try model.startTimer(seconds: duration)
                    }
                } else {
                    model.selectChat(true)
                    model.command = example.prompt
                    model.sendCommand()
                    while model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
                        if Date().timeIntervalSince(start) > 1800 {
                            model.cancel()
                            throw AppError.message("Workflow exceeded 1800 seconds")
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                row["requestSeconds"] = Date().timeIntervalSince(start)
                try require(!model.taskFailed, model.messages.last?.text ?? "Request failed")
                guard let task = model.sideTasks.last(where: { $0.kind != .result }) else {
                    throw AppError.message("No executable task created")
                }
                savedTask = task.id
                row["task"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
                emit(["checkpoint": row])
                emit(["progress": "created", "case": example.id, "seconds": row["requestSeconds"]!])
                if let duration = example.timerSeconds {
                    stage = "timer-logic"
                    try require(task.kind == .timer && task.duration == duration, "Countdown duration differs from the independent oracle")
                    try require(
                        task.deadline != nil && abs(task.deadline!.timeIntervalSince(task.created) - duration) < 0.1,
                        "Timer deadline does not equal its recorded start plus requested duration")
                    let before = task.remaining
                    try await Task.sleep(for: .milliseconds(1200))
                    try require(
                        before - (model.sideTasks.first { $0.id == task.id }!.remaining) > 0.9,
                        "Countdown is not advancing")
                    row["logicPassed"] = true
                    emit(["checkpoint": row])
                    stage = "timer-ui"
                    if logicOnly {
                        model.timerAction(task.id, action: "toggle")
                        let paused = model.sideTasks.first { $0.id == task.id }!
                        try require(paused.deadline == nil, "Timer pause failed")
                        try await Task.sleep(for: .milliseconds(1200))
                        try require(
                            abs(model.sideTasks.first { $0.id == task.id }!.remaining - paused.remaining) < 0.05,
                            "Paused timer changed")
                        model.timerAction(task.id, action: "toggle")
                        try await Task.sleep(for: .milliseconds(1200))
                        try require(
                            model.sideTasks.first { $0.id == task.id }!.remaining < paused.remaining - 0.9,
                            "Timer resume failed")
                    } else {
                        let web = try await expanded(model, task: task, delegate: delegate)
                        var visible = false
                        for _ in 0..<30 {
                            cardCoordinator?.state["values"]?["remaining"] =
                                model.sideTasks.first { $0.id == task.id }!.state["remaining"]
                            cardCoordinator?.pushState()
                            let values = await reading(web, key: "remaining")
                            if values.contains(model.sideTasks.first { $0.id == task.id }!.state["remaining"]!) {
                                visible = true
                                break
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        try require(visible, "Countdown value is not visible in expanded card")
                        row["verifiedVisibleSeconds"] = Date().timeIntervalSince(start)
                        try await click(web, action: "toggle")
                        try await Task.sleep(for: .milliseconds(150))
                        let paused = model.sideTasks.first { $0.id == task.id }!
                        try require(
                            paused.deadline == nil && paused.pausedSeconds != nil, "Actual pause button did not pause")
                        try await Task.sleep(for: .milliseconds(1200))
                        try require(
                            abs(model.sideTasks.first { $0.id == task.id }!.remaining - paused.remaining) < 0.05,
                            "Paused timer changed")
                        try await click(web, action: "toggle")
                        try await Task.sleep(for: .milliseconds(1200))
                        try require(
                            model.sideTasks.first { $0.id == task.id }!.remaining < paused.remaining - 0.9,
                            "Actual resume button did not resume")
                        checks.append(["timerDuration": 60, "pauseResume": true])
                    }
                } else {
                    stage = "logic"
                    guard let surface = task.taskSurface,
                        let action = surface.actions.first(where: { $0.kind == .code }), let code = action.code
                    else {
                        throw AppError.message("No executable local form action")
                    }
                    var keys: [String] = []
                    for initial in example.inputs {
                        let candidates = surface.fields.filter {
                            !keys.contains($0)
                                && matches(task.state[$0] ?? surface.state[$0] ?? "", initial, text: example.text)
                        }
                        try require(candidates.count == 1, "Cannot uniquely identify input initialized to " + initial)
                        keys.append(candidates[0])
                    }
                    let outputKeys = task.state.keys.filter {
                        !surface.fields.contains($0) && matches(task.state[$0]!, example.expected, text: example.text)
                    }
                    try require(
                        !outputKeys.isEmpty, "Initial output does not match independent answer " + example.expected)
                    var consistentKeys = Set(outputKeys)
                    for (i, values) in example.changes.enumerated() {
                        let fields = Dictionary(uniqueKeysWithValues: zip(keys, values))
                        let result = try await model.taskCode.run(code: code, input: fields, state: task.state)
                        let decoded = try TaskValues.decode(result)
                        consistentKeys = consistentKeys.filter {
                            matches(decoded[$0] ?? "", example.answers[i], text: example.text)
                        }
                        checks.append([
                            "stage": "logic", "input": fields, "expected": example.answers[i], "actual": decoded,
                            "ok": !consistentKeys.isEmpty,
                        ])
                    }
                    try require(!consistentKeys.isEmpty, "Changed-input handler failed independent answers")
                    row["logicPassed"] = true
                    row["logicVerifiedSeconds"] = Date().timeIntervalSince(start)
                    row["checks"] = checks
                    emit(["checkpoint": row])
                    stage = "ui"
                    if !logicOnly {
                        let web = try await expanded(model, task: task, delegate: delegate)
                        var outputKey: String?
                        for _ in 0..<30 {
                            for key in consistentKeys {
                                if await reading(web, key: key).contains(where: {
                                    matches($0, example.expected, text: example.text)
                                }) {
                                    outputKey = key
                                    break
                                }
                            }
                            if outputKey != nil { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        guard let outputKey else {
                            throw AppError.message("Correct initial output is not visible in expanded card")
                        }
                        row["verifiedVisibleSeconds"] = Date().timeIntervalSince(start)
                        for (i, values) in example.changes.enumerated() {
                            let fields = Dictionary(uniqueKeysWithValues: zip(keys, values))
                            let operationStart = Date()
                            try await click(web, action: action.id, fields: fields)
                            var valuesSeen: [String] = []
                            var passed = false
                            for _ in 0..<50 {
                                valuesSeen = await reading(web, key: outputKey)
                                if valuesSeen.contains(where: { matches($0, example.answers[i], text: example.text) }) {
                                    passed = true
                                    break
                                }
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            checks.append([
                                "stage": "ui", "input": fields, "expected": example.answers[i], "visible": valuesSeen,
                                "seconds": Date().timeIntervalSince(operationStart), "ok": passed,
                            ])
                            try require(passed, "Actual form did not display " + example.answers[i])
                        }
                    }
                }
                if !logicOnly { row["uiPassed"] = true }
                row["ok"] = true
            } catch {
                row["failureStage"] = stage
                row["error"] = error.localizedDescription
            }
            row["checks"] = checks
            row["totalSeconds"] = Date().timeIntervalSince(start)
            if let id = savedTask, let task = model.sideTasks.first(where: { $0.id == id }) {
                row["finalTask"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
            }
            let events = ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let allowed: Set<String> = [
                "event", "elapsed", "seconds", "model", "usage", "inputTokens", "outputTokens", "totalTokens", "name",
                "stage", "attempt", "category", "reasonCode", "reused", "cardReuse", "routeKnown", "directControl",
                "promptBytes", "toolBytes", "modelCallID", "timeoutSeconds",
            ]
            row["events"] = events.map { $0.filter { allowed.contains($0.key) } }
            let apis = events.filter { $0["event"] as? String == "api" }
            let requests = events.filter { $0["event"] as? String == "model_request" }
            row["modelCalls"] = requests.count
            row["successfulModelResponses"] = apis.count
            row["inputTokens"] = apis.reduce(0) { $0 + ($1["inputTokens"] as? Int ?? 0) }
            row["outputTokens"] = apis.reduce(0) { $0 + ($1["outputTokens"] as? Int ?? 0) }
            row["tokenUsageComplete"] =
                apis.count == requests.count
                && apis.allSatisfy { $0["inputTokens"] != nil && $0["outputTokens"] != nil }
            row["jevCostIncluded"] = false
            row["repairEvents"] =
                events.filter {
                    ["structured_repair", "intent_invalid", "tool_error"].contains($0["event"] as? String ?? "")
                }.count
            if args.contains("--pilot-example") || args.contains("--capture-synthetic-evidence"),
                let data = try? Data(contentsOf: trace) {
                emit(["artifact": "trace.jsonl", "base64": data.base64EncodedString()])
            }
            model.cancel()
            model.taskRuntime.stopAll()
            emit(["report": row])
            if let suite = DebugHarness.pipelineSuite { model.preferences.removePersistentDomain(forName: suite) }
            exit(row["ok"] as? Bool == true ? 0 : 1)
        }
    }
#endif
