#if DEBUG
import AppKit
import SwiftUI
import WebKit
import os

@MainActor
enum ParallelCardsCheck {
    static func checkSavedReading(_ model: AppModel, subject: String) async throws {
        let args = CommandLine.arguments
        let id = args.firstIndex(of: "--snapshot-id").flatMap { args.dropFirst($0 + 1).first }.flatMap(UUID.init(uuidString:))
        let current = args.contains("--current-snapshot")
        let cached = current || id != nil
        let shelves = current ? ["sideTasks.v1"] : ["sideTasks.v1", "taskHistory.v1"]
        let candidates = shelves.compactMap { UserDefaults.standard.data(forKey: $0) }
            .flatMap { (try? JSONDecoder().decode([SideTask].self, from: $0)) ?? [] }
        let readings = candidates.filter { $0.taskSurface?.apiData != nil && (!current || !$0.hidden) }
        let match: SideTask?
        if let id {
            match = readings.first { $0.id == id }
        } else {
            match = readings.first { $0.title.localizedCaseInsensitiveContains(subject) } ?? readings.first { task in
                (task.liveValues ?? [:]).values.contains { $0.localizedCaseInsensitiveContains(subject) }
            }
        }
        guard let saved = match else { throw AppError.message("The named reading is absent from the saved shelf") }
        model.sideTasks = [saved]
        if CommandLine.arguments.contains("--invalid-visual") {
            // Replay a malformed proposal against the actual public source in the isolated check.
            var recipe = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.taskSurface!.apiData!)) as! [String: Any]
            for hostKey in ["interfaceLanguage", "customLayout"] { recipe.removeValue(forKey: hostKey) }
            recipe["visuals"] = [["kind": "line", "label": "History", "columns": [["key": "missing", "label": "Missing"]]]]
            model.beginAmbientRequest(saved.title, taskID: saved.id)
            model.agent.nativeRequestActive = true
            model.agent.activeTaskID = saved.id
            let result = try await model.agent.execute("query_api", ["title": saved.title, "source": recipe])
            guard result["verified"] as? Bool == true, model.sideTasks.first?.taskSurface?.apiData?.visuals?.isEmpty == true else {
                throw AppError.message("The defective chart blocked the live reading")
            }
            model.agent.nativeRequestActive = false
            model.finishAmbientRequest()
        }
        if cached {
            let before = try await render(saved, compact: true, index: 2)
            print(JSONText.encode(["currentTitle": saved.title, "before": before]))
        }
        model.upgradeStandardCard(saved.id)
        if !cached {
            guard let job = model.refreshAPIData(saved.id) else { throw AppError.message("Refresh could not start") }
            await job.value
        }
        guard let task = model.sideTasks.first, task.dataIssue == nil,
            let key = task.taskSurface?.apiData?.card?.primaryKey, let value = task.state[key], !value.isEmpty
        else { throw AppError.message("The reading could not be refreshed") }
        let compact = try await render(task, compact: true, index: 3)
        let expanded = try await render(task, compact: false, index: 3)
        print(JSONText.encode(["compact": compact, "expanded": expanded, "value": value]))
        guard compact.localizedCaseInsensitiveContains(subject), compact.contains(value), expanded.contains(value) else {
            throw AppError.message("The named reading does not match across both views")
        }
    }

    /// Cold start using ordinary submissions, verified API state and the rendered views.
    static func verifyReadings(_ model: AppModel, cases: ArraySlice<String>) async throws {
        let grouped = CommandLine.arguments.contains("--one-request")
        guard !cases.isEmpty, cases.count.isMultiple(of: 3), model.sideTasks.isEmpty else {
            throw AppError.message("Use an empty shelf and triples of request, expected identity and visible name")
        }
        Diagnostics.storage = model.preferences
        Diagnostics.benchmarkEvents = []
        defer {
            for item in Diagnostics.benchmarkEvents ?? [] where item["event"] as? String == "tool_error" { print(JSONText.encode(item)) }
            Diagnostics.benchmarkEvents = nil
            let events = Diagnostics.storage.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []
            for event in events.suffix(240) where ["request_finished", "recovery_switch", "triage_score", "round", "request_triage_failed"].contains(event["event"] as? String) {
                print(JSONText.encode(event))
            }
            Diagnostics.storage = .standard
        }
        // Reproduce the reported failure on a different public dataset. Only the broken
        // definitions are injected. All transport, validation and recovery decisions run live.
        if CommandLine.arguments.contains("--inject-calculation-failure") {
            var step = 0
            model.agent.completionOverride = { turns in
                step += 1
                let call: RequestStep
                switch step {
                case 1: call = RequestStep(tool: "load_tools", arguments: JSONText.encode(["family": "data"]))
                case 2:
                    let source: [String: Any] = ["url": "https://api.github.com/repos/apple/swift-nio",
                        "fields": [["key": "entity", "label": "Repository", "pointer": "/full_name"], ["key": "stars", "label": "Stars", "pointer": "/stargazers_count"]],
                        "outputs": [["key": "count", "label": "Stars"]], "expectations": ["entity": "apple/swift-nio"],
                        "calculation": "return {state:{unrelated:1}};"]
                    call = RequestStep(tool: "query_api", arguments: JSONText.encode(["title": "SwiftNIO", "source": source]))
                case 3:
                    call = RequestStep(tool: "repair_step", arguments: JSONText.encode(["changes": ["$.source.calculation": "return {state:{stillWrong:2}};"]]))
                default:
                    guard let agent = RequestRun.current?.agent, agent.recovery.switched else { throw AppError.message("Did not reach live recovery") }
                    agent.completionOverride = nil
                    return try await agent.decide(turns, key: model.loadModelKey(for: agent.requestConnection))
                }
                return ["tool_calls": [call.call]]
            }
        }
        let sequential = CommandLine.arguments.contains("--in-sequence")
        let start = Date()
        func settle() async throws {
            while model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
                guard Date().timeIntervalSince(start) < 240 else { throw AppError.message("Timed out waiting for readings") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        var submissions: [(UUID, String, String)] = []
        let args = Array(cases)
        for i in stride(from: 0, to: args.count, by: 3) {
            if grouped, let first = submissions.first {
                submissions.append((first.0, args[i + 1], args[i + 2]))
                continue
            }
            model.selectChat(true)
            model.command = args[i]
            model.sendCommand()
            guard let id = model.messages.last(where: { $0.isUser && $0.text == args[i] })?.id else {
                throw AppError.message("Request was not submitted")
            }
            submissions.append((id, args[i + 1], args[i + 2]))
            if sequential { try await settle() }
        }
        try await settle()
        var owners: Set<UUID> = []
        var failed = false
        for (i, entry) in submissions.enumerated() {
            let id = grouped ? model.sideTasks.first(where: { task in
                task.taskSurface?.apiData?.fields.contains(where: { task.state[$0.key]?.caseInsensitiveCompare(entry.1) == .orderedSame }) == true
            })?.id : model.messages.first { $0.id == entry.0 }?.taskID
            guard let task = model.sideTasks.first(where: { $0.id == id }), let spec = task.taskSurface?.apiData,
                let primary = spec.card?.primaryKey ?? spec.displayRows.first?.key, let value = task.state[primary], !value.isEmpty, value != "—",
                owners.insert(task.id).inserted, task.state["sourceChecked"]?.isEmpty == false,
                spec.fields.contains(where: { task.state[$0.key]?.caseInsensitiveCompare(entry.1) == .orderedSame }) else {
                if let task = model.sideTasks.first(where: { $0.id == id }), let spec = task.taskSurface?.apiData {
                    print(JSONText.encode(["title": task.title, "seenAt": task.state["sourceChecked"] ?? "", "owner": task.id.uuidString,
                        "bindings": spec.fields.map { [$0.key, String((task.state[$0.key] ?? "").prefix(50))] }]))
                }
                for (index, other) in model.sideTasks.enumerated() where other.taskSurface != nil {
                    print(JSONText.encode(["actualCompact": try await render(other, compact: true, index: index),
                        "actualExpanded": try await render(other, compact: false, index: index)]))
                }
                print("Missing verified reading for " + entry.1 + ": " + (model.messages.last { !$0.isUser && $0.taskID == id }?.text ?? "no result"))
                failed = true
                continue
            }
            let compact = try await render(task, compact: true, index: i)
            let expanded = try await render(task, compact: false, index: i)
            print(JSONText.encode(["identity": entry.1, "title": task.title, "compact": compact, "value": value,
                "source": task.state["sourceHost"] ?? "", "elapsed": Date().timeIntervalSince(start)]))
            let aliases = entry.2.split(separator: "|")
            if !aliases.contains(where: { compact.localizedCaseInsensitiveContains(String($0)) }) || !compact.contains(value) || !expanded.contains(value) { failed = true }
        }
        guard !failed, !grouped || model.sideTasks.count == submissions.count else { throw AppError.message("Reading acceptance failed") }
    }

    static func verifyEdgeRequest(_ model: AppModel, join: Bool) async throws {
        Diagnostics.storage = model.preferences
        defer {
            let events = model.preferences.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []
            for event in events where ["round", "cards_partitioned", "recovery_switch", "calculation_bound_inputs", "request_finished", "tool_error"].contains(event["event"] as? String) {
                print(JSONText.encode(event))
            }
            Diagnostics.storage = .standard
        }
        let answerOnly = CommandLine.arguments.contains("--verify-calculated-answer")
        if answerOnly {
            model.command = "请用计算工具核算。只回复剩余分钟数，不用做卡：整片82分钟，正片已剪3段，每段17分钟，另外剪完片尾8分钟。"
        } else {
            model.command = join
            ? "查 GitHub 上 apple/swift-nio 和 Alamofire/Alamofire 这两个仓库各有多少颗星。如果两者都有公开的 Star 数，算出相差几颗星。只留一张快照卡，把两个原数也写上。"
            : "给我两张独立的卡。一张叫 Juniper，这座陶窑的目标是900摄氏度，现在887度。另一张叫 Night Shift，这期播客要剪到50分钟，目前剪了35分钟。两张都只看离目标还差多少，单位各用自己的。片尾另外剪好的2分钟只算进播客。"
        }
        fputs("Submitting edge request\n", stderr)
        model.sendCommand()
        let start = Date()
        while model.busy || model.globalRoutingTask != nil {
            guard Date().timeIntervalSince(start) < 200 else { throw AppError.message("Timed out before completing the request") }
            try await Task.sleep(for: .milliseconds(100))
        }
        fputs("Execution finished; inspecting cards\n", stderr)
        let cards = model.sideTasks
        if answerOnly {
            let reply = model.messages.last(where: { !$0.isUser })?.text ?? ""
            guard reply.contains("23"), cards.allSatisfy({ $0.taskSurface == nil && $0.terminalLabel != nil }),
                model.agent.codeReceipt != nil else { throw AppError.message("Expected a computed text answer, received " + reply) }
            print(JSONText.encode(["answer": reply, "seconds": Date().timeIntervalSince(start)]))
            return
        }
        guard cards.count == (join ? 1 : 2), cards.allSatisfy({ $0.taskSurface != nil }) else {
            throw AppError.message("Unexpected cards: " + cards.map { $0.title + " " + $0.detail }.joined(separator: " | "))
        }
        var labels = Set<String>()
        for (index, task) in cards.enumerated() {
            fputs("Rendering card " + task.title + "\n", stderr)
            let compact = try await render(task, compact: true, index: index)
            let expanded = try await render(task, compact: false, index: index)
            print(JSONText.encode(["compact": compact, "expanded": expanded, "seconds": Date().timeIntervalSince(start)]))
            if join {
                var numbers: [Int] = []
                for repo in ["apple/swift-nio", "Alamofire/Alamofire"] {
                    let sample = try await model.apiData.sample(url: "https://api.github.com/repos/" + repo, previous: nil)
                    guard let count = APIDataSpec.value("/stargazers_count", in: sample.response) as? Int else { throw AppError.message("Missing independent source reading") }
                    numbers.append(count)
                }
                numbers.append(abs(numbers[0] - numbers[1]))
                let displayed = expanded.replacingOccurrences(of: ",", with: "")
                guard numbers.allSatisfy({ displayed.contains(String($0)) }) else { throw AppError.message("Source/comparison mismatch: " + String(describing: numbers)) }
                let events = model.preferences.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []
                guard events.contains(where: { $0["event"] as? String == "calculation_bound_inputs" && ($0["candidateCount"] as? Int ?? 0) >= 2 }) else { throw AppError.message("Missing source bindings for the calculation") }
            } else {
                guard let name = ["Juniper", "Night Shift"].first(where: { compact.localizedCaseInsensitiveContains($0) }),
                    labels.insert(name).inserted, compact.contains("13") else { throw AppError.message("Lost subject, exception or shared instruction") }
            }
        }
    }

    static func verifyPlacement(_ model: AppModel, scenario: String) async throws {
        Diagnostics.storage = model.preferences
        Diagnostics.benchmarkEvents = []
        defer {
            for event in Diagnostics.benchmarkEvents ?? [] where ["tool_error", "round", "api", "model_request", "model_error", "decision_context"].contains(event["event"] as? String ?? "") {
                print(JSONText.encode(event))
            }
            for event in model.preferences.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []
                where ["card_placement", "placement_fallback", "ownership_resolved", "round"].contains(event["event"] as? String) {
                print(JSONText.encode(event))
            }
            Diagnostics.benchmarkEvents = nil
            Diagnostics.storage = .standard
        }
        let pair = "我要看微软和苹果的股价"
        func submit(_ text: String, in conversation: UUID? = nil, editing id: UUID? = nil) async throws {
            if let id { model.editInterface(id) } else { model.selectChat(true, conversation: conversation) }
            model.command = text
            let start = Date()
            model.sendCommand()
            while model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
                guard Date().timeIntervalSince(start) < 210 else { throw AppError.message("Timed out: " + text) }
                try await Task.sleep(for: .milliseconds(100))
            }
            for timer in model.visibleTasks where timer.kind == .timer {
                print(JSONText.encode(["timerID":timer.id.uuidString, "timerLabel":timer.timerSubject, "remaining":timer.state["remaining"] ?? ""]))
                if CommandLine.arguments.contains("--capture-timer") {
                    let view = NSHostingView(rootView: CalmTimerControl(model: model, task: timer)
                        .padding(8).background(.white).environment(\.colorScheme, .light))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = view
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw AppError.message("Could not capture timer control")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw AppError.message("Could not encode timer control")
                    }
                    print("TIMER_IMAGE " + png.base64EncodedString())
                }
            }
            print(JSONText.encode(["request": text, "seconds": Date().timeIntervalSince(start),
                "reply": model.messages.last(where: { !$0.isUser })?.text ?? "",
                "tasks": model.sideTasks.map { ["id": $0.id.uuidString, "title": $0.title, "status": $0.status, "issue": $0.kind == .result ? $0.detail : ""] }]))
        }
        func quotes(_ symbols: [String: String], excluding: Set<UUID> = []) async throws -> [String: UUID] {
            let cards = model.visibleTasks.filter { !excluding.contains($0.id) }
            guard cards.count == symbols.count else {
                for card in cards {
                    if let source = card.taskSurface?.apiData {
                        print(JSONText.encode(["identity": AgentController.placementContext(card),
                            "source": source.url, "fields": source.fields.map { [$0.key, $0.pointer, $0.unit ?? ""] }]))
                    }
                }
                throw AppError.message("Unexpected visible card count: " + String(cards.count))
            }
            var ids: [String: UUID] = [:]
            // Providers can assert a legal name instead of a trading symbol.
            // Recognize only exact source-bound identities, never the generated title.
            let issuerNames = ["MSFT": ["Microsoft Corporation", "Microsoft Corp."],
                               "AAPL": ["Apple Inc.", "Apple Inc"],
                               "TSLA": ["Tesla, Inc.", "Tesla Inc", "Tesla, Inc"],
                               "GOOG": ["Alphabet Inc.", "Alphabet Inc. Class C"],
                               "GOOGL": ["Alphabet Inc.", "Alphabet Inc. Class A"]]
            for (index, task) in cards.enumerated() {
                let evidence = model.work.view(task.id).flatMap { model.work.artifact($0.selected)?.evidence }
                    .flatMap { try? JSONSerialization.jsonObject(with:$0) }
                let specPointer = task.taskSurface?.apiData?.primarySourcePointer
                let record = specPointer.flatMap { pointer -> [String:Any]? in
                    let parent = pointer.split(separator:"/").dropLast().joined(separator:"/")
                    return evidence.flatMap { APIDataSpec.value("/" + parent,in:$0) as? [String:Any] }
                }
                guard let spec = task.taskSurface?.apiData,
                    let symbol = symbols.keys.first(where: { symbol in
                        (record?.values.compactMap(APIDataSpec.scalar).contains(where:{ value in
                            ([symbol] + (issuerNames[symbol] ?? [])).contains { value.caseInsensitiveCompare($0) == .orderedSame }
                        }) ?? false)
                            || spec.fields.contains { task.state[$0.key]?.caseInsensitiveCompare(symbol) == .orderedSame }
                            || (spec.expectations ?? [:]).keys.contains { key in
                                (issuerNames[symbol] ?? []).contains { task.state[key]?.caseInsensitiveCompare($0) == .orderedSame }
                            }
                    }), ids[symbol] == nil, let key = spec.card?.primaryKey, let value = task.state[key],
                    value.range(of: #"[0-9]+"#, options: .regularExpression) != nil else {
                    print(JSONText.encode(["rendered": try await render(task, compact: true, index: index), "fields": task.taskSurface?.apiData?.fields.map { [$0.key, task.state[$0.key] ?? ""] } ?? []]))
                    throw AppError.message("Missing verified quote: " + task.title)
                }
                let compact = try await render(task, compact: true, index: index)
                let expanded = try await render(task, compact: false, index: index)
                print(JSONText.encode(["symbol": symbol, "compact": compact, "source": task.state["sourceHost"] ?? ""]))
                let names = symbols[symbol]!.components(separatedBy: "|") + [["MSFT": "微软", "AAPL": "苹果", "TSLA": "特斯拉"][symbol] ?? symbols[symbol]!]
                guard names.contains(where: compact.localizedCaseInsensitiveContains), compact.contains(value), expanded.contains(value)
                else { throw AppError.message("Unidentifiable quote: " + compact) }
                ids[symbol] = task.id
            }
            return ids
        }
        let companies = ["MSFT": "Microsoft", "AAPL": "Apple"]
        func pairIDs() async throws -> [String: UUID] {
            try await submit(pair)
            return try await quotes(companies)
        }
        switch scenario {
        case "local-document", "record-source":
            let destination: URL
            let card: SideTask
            if scenario == "local-document" {
                let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
                defer { try? FileManager.default.removeItem(at: fixture) }
                try "item,quantity\nInk,3\nPaper,5\n".write(to: fixture, atomically: true, encoding: .utf8)
                model.command = "把这个 CSV 按数量从大到小排，给我 sorted.csv"
                try model.attachWorkFiles([fixture])
                try await submit(model.command)
                guard let task = model.visibleTasks.first, let file = task.workFile,
                    model.visibleTasks.count == 1 else { throw AppError.message("Missing file card") }
                destination = try file.existingURL()
                let contents = try String(contentsOf: destination, encoding: .utf8)
                guard contents.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n") == "item,quantity\nPaper,5\nInk,3",
                    try await render(task, compact: true, index: 0).contains("sorted.csv"),
                    try await render(task, compact: false, index: 0).contains("Paper,5"),
                    !JSONText.encode(AgentContext.task(task)).contains("Paper,5") else { throw AppError.message("Wrong document or preview") }
                card = task
            } else {
                try await submit("给我看 apple/swift-nio 的 star 数，双击能去仓库主页")
                guard let task = model.visibleTasks.first, let raw = task.state["recordPageURL"],
                    let url = URL(string: raw), url.host == "github.com", url.path == "/apple/swift-nio",
                    task.taskSurface?.apiData != nil else { throw AppError.message("Missing verified record link") }
                print(JSONText.encode(["compact": try await render(task, compact: true, index: 0),
                    "expanded": try await render(task, compact: false, index: 0)]))
                card = task
                destination = url
            }
            guard model.handoffSource == nil else { throw AppError.message("Background execution opened a source") }
            let workingBrowser = model.browser
            model.openTaskFromDoubleClick(card.id)
            guard let source = model.visibleHandoff, source.destination == destination, model.browser === workingBrowser,
                source.taskID == card.id else { throw AppError.message("Handoff escaped the side screen") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: HandoffSourceView(source: source))
            window.contentView?.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            if let web = source.webView {
                for _ in 0..<250 {
                    if let location = try? await web.evaluateJavaScript("document.readyState !== 'loading' && document.title ? location.href : ''") as? String,
                        location == destination.absoluteString { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard web.window === window, web.url == destination, !(web.title ?? "").isEmpty, !source.failed else { throw AppError.message("Orvlet browser did not load the source") }
            } else {
                guard source.document == (try String(contentsOf: destination, encoding: .utf8)) else { throw AppError.message("Incomplete document handoff") }
            }
            print(JSONText.encode(["openedInsideOrvlet": destination.lastPathComponent, "card": card.title]))
            model.collapse()
            guard model.visibleHandoff == nil, model.visibleTasks.contains(where: { $0.id == card.id }) else { throw AppError.message("Lost original card") }
        case "player-placement", "player-queue", "player-change":
            let track = MusicTrack(id: "abcdefghijk", title: "Study radio")
            var player = SideTask(id: model.browser.id, kind: .web, title: track.title)
            player.listening = true
            player.sourceURL = track.url
            player.intent = "放点适合工作的音乐"
            player.musicQueue = MusicQueue(current: track, volume: 0, muted: true)
            model.settings.taskStartPolicy = .interfaceFirst
            model.sideTasks = [player]
            if scenario == "player-change" {
                let source = model.browser
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = source.webView
                window.contentView?.layoutSubtreeIfNeeded()
                defer { window.orderOut(nil) }
                try await submit(ProcessInfo.processInfo.environment["ORVLET_PLAYER_CHANGE_REQUEST"] ?? "想听lofi")
                guard model.visibleTasks.map(\.id) == [player.id], let task = model.visibleTasks.first,
                    task.musicQueue?.current?.id != track.id, task.musicQueue?.previous.contains(track) == true,
                    let browser = model.musicBrowser(player.id) else { throw AppError.message("Track change lost its player or history") }
                let state = try await browser.observe()
                print(JSONText.encode(state.filter { ["title","url","readyState","playing","muted","hasMedia","mediaError","adPlaying","currentTime"].contains($0.key) }))
                guard state["playing"] as? Bool == true, state["muted"] as? Bool == true else { throw AppError.message("Unverified muted playback") }
                print(JSONText.encode(["player": player.id.uuidString, "cards": 1, "nowPlaying": task.title, "muted": true]))
            } else if scenario == "player-queue" {
                try await submit("加一首爵士到待播")
                guard model.visibleTasks.map(\.id) == [player.id],
                    let queue = model.visibleTasks.first?.musicQueue, queue.current?.id == track.id,
                    !queue.upcoming.isEmpty else { throw AppError.message("Queue request did not retain the original player and track") }
                print(JSONText.encode(["player": player.id.uuidString, "cards": 1, "queued": queue.upcoming.count]))
            } else {
                for (request, reuse) in [("想听lofi", true), ("放点 bossa nova", true), ("再来一个轻快点的", true), ("另开一个播放器放爵士", false)] {
                    let result = try await model.agent.understand(request, clarification: nil, key: nil)
                    let reused = result.targetTaskID == player.id.uuidString
                    print(JSONText.encode(["input": request, "layout": result.placement?.layout.rawValue ?? "", "owner": result.targetTaskID ?? "new"]))
                    guard reused == reuse, result.clarificationQuestion == nil,
                        result.placement?.members.contains(where: { $0.retainedID != nil }) != true else {
                        throw AppError.message("Unexpected player destination for " + request)
                    }
                }
                var other = SideTask(kind: .web, title: "Acoustic radio")
                other.listening = true
                player.playing = true
                model.sideTasks = [other, player]
                let choice = try await model.agent.understand("换点爵士听听", clarification: nil, key: nil)
                guard choice.targetTaskID == player.id.uuidString else { throw AppError.message("Did not target the playing session") }
                print(JSONText.encode(["input": "换点爵士听听", "players": 2, "usedPlayingPlayer": true]))
            }
        case "owned-browser":
            let center = NSWorkspace.shared.notificationCenter
            let activations = OSAllocatedUnfairLock(initialState: 0)
            let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.processIdentifier == ProcessInfo.processInfo.processIdentifier { activations.withLock { $0 += 1 } }
            }
            defer { center.removeObserver(token) }
            try await submit("在 Orvlet 里打开 https://example.org，留着这一页")
            guard model.visibleTasks.count == 1, let card = model.visibleTasks.first, card.kind == .web,
                let source = model.liveBrowsers.first(where: { $0.id == card.id }),
                source.webView.url?.host == "example.org", !model.showingWeb else {
                throw AppError.message("Background work did not leave one collapsed internal page")
            }
            model.openTaskFromDoubleClick(card.id)
            let title = try await source.webView.evaluateJavaScript("document.title") as? String
            let activationCount = activations.withLock { $0 }
            guard model.showingWeb, model.browser === source, title == "Example Domain",
                activationCount == 0, NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw AppError.message("Lost the original page or activated the test application")
            }
            print(JSONText.encode(["openedInsideOrvlet": title ?? "", "card": card.title, "testAppActivations": activationCount]))
        case "three":
            try await submit("看看微软、苹果和谷歌的股价")
            let symbol = model.visibleTasks.contains { $0.state.values.contains("GOOGL") } ? "GOOGL" : "GOOG"
            _ = try await quotes(companies.merging([symbol: "Alphabet|Google|谷歌"]) { _, new in new })
        case "compact-pair":
            try await submit("微软苹果股价")
            _ = try await quotes(companies)
        case "refresh-one":
            let before = try await pairIDs()
            let checked = model.visibleTasks.first { $0.id == before["AAPL"] }?.dataUpdatedAt
            try await submit("刷新一下苹果")
            let after = try await quotes(companies)
            let refreshed = model.visibleTasks.first { $0.id == after["AAPL"] }?.dataUpdatedAt
            print(JSONText.encode(["checkedBefore": checked?.timeIntervalSince1970 ?? 0, "checkedAfter": refreshed?.timeIntervalSince1970 ?? 0]))
            guard before == after, let checked, let refreshed, refreshed > checked else { throw AppError.message("Missing in-place refresh") }
        case "compare-existing":
            let before = try await pairIDs()
            try await submit("比较一下这两家")
            let combined = model.visibleTasks.filter { !before.values.contains($0.id) }
            guard combined.count == 1, let card = combined.first, card.taskSurface != nil,
                try await quotes(companies, excluding: [card.id]) == before else { throw AppError.message("Expected originals and one comparison") }
            let expanded = try await render(card, compact: false, index: 2)
            let compact = try await render(card, compact: true, index: 2)
            print(JSONText.encode(["comparison": card.id.uuidString, "compact": compact, "expanded": expanded]))
            guard [["MSFT","Microsoft","微软"],["AAPL","Apple","苹果"]].allSatisfy({ $0.contains(where: expanded.localizedCaseInsensitiveContains) }),
                Set(expanded.matches(of: /[0-9]+[.][0-9]+/).map { String($0.output) }).count >= 2 else { throw AppError.message("Comparison lost a reading") }
        case "mixed":
            try await submit("微软股价")
            let before = try await quotes(["MSFT": "Microsoft"])
            try await submit("定个8分钟倒计时")
            guard let timer = model.visibleTasks.first(where: { $0.duration == 480 }), let deadline = timer.deadline else { throw AppError.message("Missing eight-minute timer") }
            try await submit("也看看苹果股价")
            let after = try await quotes(companies, excluding: [timer.id])
            guard before["MSFT"] == after["MSFT"], model.visibleTasks.first(where: { $0.id == timer.id })?.deadline == deadline,
                deadline > Date() else { throw AppError.message("Mixed follow-up changed earlier state") }
        case "answer-existing":
            let before = try await pairIDs()
            try await submit("17加26等于多少？只回复数字")
            let reply = model.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print(JSONText.encode(["answer":reply]))
            guard try await quotes(companies) == before, reply == "43" else { throw AppError.message("Answer or retained shelf differs") }
        case "replace-close":
            let before = try await pairIDs()
            try await submit("把苹果换成特斯拉")
            let replaced = try await quotes(["MSFT": "Microsoft", "TSLA": "Tesla"])
            guard before["MSFT"] == replaced["MSFT"], before["AAPL"] == replaced["TSLA"] else { throw AppError.message("Wrong replacement target") }
            try await submit("把特斯拉关了")
            let receipt = model.messages.last(where: { !$0.isUser })?.text ?? ""
            guard ["取消", "结束", "cancelled", "finished", "关闭", "closed"].contains(where: receipt.localizedCaseInsensitiveContains),
                model.feedback?.kind != .failure else { throw AppError.message("Missing closure acknowledgement: " + receipt) }
            // Normal terminal receipts can briefly remain in the visible list.
            if let done = model.visibleTasks.first(where: { $0.id == replaced["TSLA"] && $0.terminalLabel != nil }), let until = done.expires {
                while model.visibleTasks.contains(where: { $0.id == done.id }) && Date() < until.addingTimeInterval(2) {
                    try await Task.sleep(for: .milliseconds(160))
                }
            }
            let final = try await quotes(["MSFT": "Microsoft"])
            guard final["MSFT"] == before["MSFT"] else { throw AppError.message("Closing a card affected its sibling") }
        case "repeated":
            try await submit("看看微软和微软的股价")
            _ = try await quotes(["MSFT":"Microsoft"])
        case "word-flip", "stage-cues", "proof-review", "proof-self":
            let request: String
            let actionPattern: String
            let expected: String
            switch scenario {
            case "word-flip":
                request = "背个词，正面 obscure，背面 晦涩"
                actionPattern = "flip|reveal|show|turn|翻|看|显示"
                expected = "晦涩"
            case "stage-cues":
                request = "排练提词，依次是落座、亮灯、谢幕"
                actionPattern = "next|advance|forward|下一|继续"
                expected = "亮灯|lights? (up|on)|light the"
            default:
                request = scenario == "proof-self" ? "海报校样，我来标通过或退回" : "海报校样，帮我标通过或退回"
                actionPattern = "approve|accept|pass|通过"
                expected = "approved|accepted|passed|已通过|通过"
            }
            try await submit(request)
            guard model.visibleTasks.count == 1, let card = model.visibleTasks.first,
                let surface = card.taskSurface else { throw AppError.message("Expected one generated card") }
            let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 300, height: 320),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let web = try await SimpleTaskPilot.expanded(model, task: card, window: window)
            let controls = try await web.evaluateJavaScript("""
                [...document.querySelectorAll('[data-action]')].filter(e=>e.getClientRects().length && !e.disabled)
                    .map(e=>({id:e.dataset.action,label:e.innerText || e.getAttribute('aria-label') || ''}))
                """) as? [[String: String]] ?? []
            let valuesJS = """
                [...document.querySelectorAll('[data-bind]')].filter(e=>e.getClientRects().length && !e.closest('button'))
                    .map(e=>e.innerText).join(' | ')
                """
            let before = try await web.evaluateJavaScript(valuesJS) as? String ?? ""
            SimpleTaskPilot.emit(["before": before, "controls": controls, "fields": surface.fields])
            if scenario == "word-flip", (try await web.evaluateJavaScript("document.querySelector('#surface').innerText") as? String ?? "").contains(expected) {
                throw AppError.message("The back is already visible before revealing it")
            }
            let options: String.CompareOptions = [.caseInsensitive, .regularExpression]
            guard let control = controls.first(where: {
                ($0["label"] ?? "").range(of: actionPattern, options: options) != nil
                    || ($0["id"] ?? "").range(of: actionPattern, options: options) != nil
            }), let action = control["id"] else { throw AppError.message("Requested control missing") }
            try await SimpleTaskPilot.click(web, action: action)
            for _ in 0..<100 {
                let after = try await web.evaluateJavaScript(valuesJS) as? String ?? ""
                if model.visibleTasks.count == 1, let current = model.visibleTasks.first, current.id == card.id,
                    current.state != card.state, before != after, after.range(of: expected, options: options) != nil {
                    let compact = try await render(current, compact: true, index: 0)
                    let expanded = try await render(current, compact: false, index: 0)
                    SimpleTaskPilot.emit(["clicked": control, "after": after, "compact": compact, "expanded": expanded,
                                          "id": current.id.uuidString])
                    return
                }
                try await Task.sleep(for: .milliseconds(120))
            }
            throw AppError.message("Control did not produce the expected visible result: " +
                ((try await web.evaluateJavaScript(valuesJS)) as? String ?? ""))
        case "retained-observation":
            // Replay the broken scheduled recipe, using real transport and worker results.
            let url = "https://api.github.com/repos/apple/swift-nio"
            let bindings = [["name":"count","observation":url,"pointer":"/stargazers_count"],
                            ["name":"repo","observation":url,"pointer":"/full_name"]]
            let steps: [(String, [String: Any])] = [
                ("load_tools", ["family":"data"]),
                ("inspect_api", ["url":url]),
                ("run_code", ["bindings":bindings,"code":"return {state:{count:input.count}}"]),
                ("query_api", ["title":"SwiftNIO","source":["url":url,"refreshSeconds":60,
                    "fields":[["key":"repo","label":"Repository","pointer":"/full_name"],
                              ["key":"count","label":"Stars","pointer":"/missingCount"]],
                    "expectations":["repo":"apple/swift-nio"]]]),
                ("present_ui", ["title":"SwiftNIO","form":["compactKey":"count","inputs":[],"buttons":[],
                    "outputs":[["key":"count","label":"Stars"]]],"actions":[],"state":[:],"complete":true])
            ]
            var index = 0
            model.agent.completionOverride = { _ in
                guard steps.indices.contains(index) else { throw AppError.message("Injected end of repair attempts") }
                let (tool, args) = steps[index]
                index += 1
                return ["tool_calls": [RequestStep(tool:tool, arguments:JSONText.encode(args)).call]]
            }
            try await submit("帮我跟踪 SwiftNIO 的星数")
            guard model.visibleTasks.count == 1, let task = model.visibleTasks.first, let surface = task.taskSurface,
                surface.apiData == nil, surface.runtime == nil, let count = task.state["count"], Int(count) != nil,
                model.messages.last?.text.contains(count) == true, task.interfaceIssue != nil
            else { throw AppError.message("Missing verified partial result after the schedule failed") }
            let display = try await render(task, compact:false,index:0)
            guard display.contains(count), display.contains("api.github.com") else { throw AppError.message("Missing observed result/source") }
            SimpleTaskPilot.emit(["id":task.id.uuidString, "count":1,"value":count,"expanded":display,"issue":task.interfaceIssue ?? ""])
        case "compiled-license-picker", "compiled-branch-picker":
            let metric = scenario == "compiled-license-picker" ? "许可证" : "默认分支"
            try await submit("看下 python/cpython 和 python/mypy 的" + metric + "，做成能切换项目的卡")
            guard model.visibleTasks.count == 1, let first = model.visibleTasks.first, first.taskSurface != nil else {
                throw AppError.message("Expected one executable project picker")
            }
            let view = model.work.view(first.id)
            let switchingResults = view?.layout == .select
            let initialResult = model.work.view(first.id).flatMap { model.work.artifact($0.selected) }
            let before = try await render(first,compact:false,index:0)
            let beforeCompact = try await render(first,compact:true,index:0)
            let window = NSWindow(contentRect:NSRect(x:-16000,y:-16000,width:300,height:320),styleMask:.borderless,backing:.buffered,defer:false)
            defer { window.orderOut(nil) }
            window.orderBack(nil)
            let web = try await SimpleTaskPilot.expanded(model,task:first,window:window)
            let controls = try await web.evaluateJavaScript("[...document.querySelectorAll('select')].map(e=>({key:e.dataset.field,value:e.value,options:[...e.options].map(o=>({value:o.value,label:o.textContent}))}))") as? [[String:Any]] ?? []
            let control = controls.first { control in
                let labels = (control["options"] as? [[String:String]] ?? []).map { $0["label"] ?? "" }.joined(separator:" ")
                return labels.localizedCaseInsensitiveContains("cpython") && labels.localizedCaseInsensitiveContains("mypy")
            }
            let controlKey = control?["key"] as? String
            let choice = (control?["options"] as? [[String:String]])?.first { $0["value"] != control?["value"] as? String }
            let target = choice?["value"]
            let targetName = choice.map { ($0["label"] ?? "").localizedCaseInsensitiveContains("mypy") ? "mypy" : "cpython" }
                ?? ((first.state["currentValue"] ?? before).localizedCaseInsensitiveContains("cpython") ? "mypy" : "cpython")
            if let controlKey, let target {
                _ = try await web.evaluateJavaScript("(()=>{const e=[...document.querySelectorAll('select')].find(e=>e.dataset.field===" + JSONText.encode(controlKey) + ");e.value=" + JSONText.encode(target) + ";e.dispatchEvent(new Event('change',{bubbles:true}));if(!e.dataset.change){const b=[...document.querySelectorAll('button[data-action]')].find(b=>!['refreshData','expand','dismiss'].includes(b.dataset.action));if(b)b.click()}return e.value})()")
            } else {
                let buttons = try await web.evaluateJavaScript("[...document.querySelectorAll('button[data-action]')].map(b=>({id:b.dataset.action,label:b.innerText}))") as? [[String:String]] ?? []
                guard let action = buttons.first(where:{ ($0["label"] ?? "").localizedCaseInsensitiveContains(targetName) })?["id"] else {
                    throw AppError.message("Missing project choice control: " + before)
                }
                try await SimpleTaskPilot.click(web,action:action)
            }
            var changed: SideTask?
            for _ in 0..<200 {
                if let task = model.visibleTasks.first, task.id == first.id, task.status == "Ready", task.dataIssue == nil, task.state != first.state,
                    switchingResults ? model.work.view(first.id)?.selected.uuidString == target
                        : ((controlKey == nil || task.state[controlKey!] == target) && model.work.view(first.id).flatMap { model.work.artifact($0.selected)?.revision } != initialResult?.revision) {
                    changed = task; break
                }
                try await Task.sleep(for:.milliseconds(150))
            }
            guard let changed, model.visibleTasks.count == 1 else { throw AppError.message("Project selection did not update the same card") }
            let afterCompact = try await render(changed,compact:true,index:1)
            guard afterCompact.localizedCaseInsensitiveContains(targetName) else { throw AppError.message("Collapsed identity did not follow project selection: " + afterCompact) }
            let after = try await render(changed,compact:false,index:1)
            let sample = model.agent.observations.sample("https://api.github.com/repos/python/" + targetName)
            let response = sample?.response
                ?? model.work.view(changed.id).flatMap { model.work.artifact($0.selected)?.evidence }.flatMap { try? JSONSerialization.jsonObject(with:$0) }
            let pointer = scenario == "compiled-branch-picker" ? "/default_branch" : "/license/spdx_id"
            guard let response, let reported = APIDataSpec.scalar(APIDataSpec.value(pointer,in:response)),
                after.contains(reported) else { throw AppError.message("Selection does not show the chosen project's observed value") }
            print(JSONText.encode(["scenario":scenario,"id":first.id.uuidString,"count":1,"before":before,"beforeCompact":beforeCompact,
                "after":after,"afterCompact":afterCompact,"observed":reported]))
        case "source-recovery-currency", "source-recovery-repository", "cold-source-currency", "cold-source-repository", "source-definition-repair":
            let trace = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-" + scenario + ".jsonl")
            FileManager.default.createFile(atPath: trace.path, contents: Data())
            Diagnostics.file = trace
            defer { Diagnostics.file = nil }
            FileHandle.standardOutput.write(Data(("TRACE " + trace.path + "\n").utf8))
            let inject = scenario.hasPrefix("source-recovery")
            let currency = scenario.hasSuffix("currency")
            var failedHost: String?
            var attempts: [[String: String]] = []
            model.apiData = APIDataService(code: model.taskCode, fetch: { address in
                let host = URL(string: address)?.host ?? ""
                if inject && failedHost == nil { failedHost = host }
                if inject && host == failedHost {
                    attempts.append(["host": host, "status": "injected-unavailable"])
                    throw URLError(.cannotConnectToHost)
                }
                do {
                    let response = try await PublicDataClient().fetch(address)
                    attempts.append(["host": host, "status": "received", "url": address])
                    return response
                } catch {
                    attempts.append(["host": host, "status": "failed", "reason": error.localizedDescription])
                    throw error
                }
            })
            defer { print(JSONText.encode(["sourceAttempts": attempts])) }
            if scenario == "source-definition-repair" {
                var step = 0
                model.agent.completionOverride = { turns in
                    step += 1
                    let call: RequestStep
                    switch step {
                    case 1: call = RequestStep(tool: "load_tools", arguments: JSONText.encode(["family":"data"]))
                    case 2: call = RequestStep(tool: "inspect_api", arguments: JSONText.encode(["url":"https://api.github.com/repos/apple/swift-nio"]))
                    case 3:
                        let source: [String:Any] = ["url":"https://api.github.com/repos/apple/swift-nio",
                            "fields":[["key":"entity","label":"Repository","pointer":"/full_name"],["key":"stars","label":"Stars","pointer":"/stargazers_count"]],
                            "expectations":["entity":"apple/swift-nio"], "outputs":[["key":"count","label":"Stars","unitKey":"starsLiteral"]],
                            "calculation":"return {state:{count:state.stars}};", "glance":["valueKey":"count"],
                            "card":["kind":"reading","subject":"SwiftNIO","primaryKey":"count"]]
                        call = RequestStep(tool: "query_api", arguments: JSONText.encode(["title":"SwiftNIO","source":source]))
                    case 4: call = RequestStep(tool:"repair_step", arguments:JSONText.encode(["changes":["$.source.glance":NSNull()]]))
                    default:
                        guard let agent = RequestRun.current?.agent,
                            !agent.recovery.exhausted("query_api",["source":["url":"https://api.github.com/repos/apple/swift-nio","calculation":"x"]]) else {
                            throw AppError.message("Independent schema errors incorrectly exhausted a healthy source")
                        }
                        agent.completionOverride = nil
                        return try await agent.decide(turns, key:model.loadModelKey(for:agent.requestConnection))
                    }
                    return ["tool_calls":[call.call]]
                }
            }
            try await submit(currency ? "港币兑人民币，给我一个能改金额的卡" : "看看 apple/swift-nio 的 star 数")
            guard model.visibleTasks.count == 1, let task = model.visibleTasks.first,
                task.kind != .result, task.terminalLabel == nil else { throw AppError.message("Source recovery did not deliver one usable card") }
            let compact = try await render(task, compact: true, index: 0)
            let expanded = try await render(task, compact: false, index: 0)
            guard compact.range(of: #"[0-9]+"#, options: .regularExpression) != nil else { throw AppError.message("No reading in recovered card: " + JSONText.encode(["compact":compact,"expanded":expanded,"state":task.state,"plan":task.plan?.readings?.map(\.key) ?? []])) }
            if inject {
                guard failedHost != nil, attempts.contains(where: { $0["status"] == "received" && $0["host"] != failedHost }) || task.taskSurface == nil else {
                    throw AppError.message("No actual alternative source was used")
                }
            }
            if currency {
                guard let surface = task.taskSurface, surface.hasEditableOperation,
                    let primary = surface.apiData?.card?.primaryKey, let initial = Double(task.state[primary] ?? "") else {
                    throw AppError.message("Recovery lost the editable source tool")
                }
                let row = surface.apiData?.displayRows.first { $0.key == primary }
                let unit = (surface.apiData?.card?.unitKey ?? row?.unitKey).flatMap { task.state[$0] } ?? row?.unit ?? ""
                guard unit == "CNY" || unit == "人民币" || unit == "RMB" else {
                    throw AppError.message("Recovered measurement has the wrong displayed unit: " + unit)
                }
                let window = NSWindow(contentRect: NSRect(x:-16000,y:-16000,width:300,height:320), styleMask:.borderless, backing:.buffered, defer:false)
                defer { window.orderOut(nil) }
                window.orderBack(nil)
                let web = try await SimpleTaskPilot.expanded(model, task:task, window:window)
                let field = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('input[data-field]')).find(e=>['number','text'].includes(e.type) && !e.disabled && !e.readOnly && Number(e.value)>0)?.dataset.field ?? ''") as? String ?? ""
                guard !field.isEmpty, let amount = Double(task.state[field] ?? "") else { throw AppError.message("No editable amount control: " + expanded) }
                let inputType = try await web.evaluateJavaScript("[...document.querySelectorAll('input')].find(e=>e.dataset.field===" + JSONText.encode(field) + ")?.type ?? ''") as? String ?? ""
                let newAmount = String(amount * 2)
                let script = "(()=>{const e=[...document.querySelectorAll('input')].find(e=>e.dataset.field===" + JSONText.encode(field) + ");e.value=" + JSONText.encode(newAmount) + ";e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return e.value;})()"
                _ = try await web.evaluateJavaScript(script)
                if let action = surface.actions.first(where: { $0.kind == .code }) { try await SimpleTaskPilot.click(web, action: action.id) }
                var changed: SideTask?
                for _ in 0..<160 {
                    if let current = model.visibleTasks.first, current.id == task.id, model.visibleTasks.count == 1,
                        let actual = Double(current.state[primary] ?? ""), current.dataIssue == nil,
                        abs(actual - initial * 2) < 0.03, actual != initial { changed = current; break }
                    try await Task.sleep(for: .milliseconds(150))
                }
                guard let changed else { throw AppError.message("Input did not change the verified output on the same card") }
                print(JSONText.encode(["interaction":"double amount","inputType":inputType,"id":changed.id.uuidString,"count":1,"before":initial,"after":changed.state[primary] ?? "",
                    "rendered":try await render(changed, compact:false,index:1)]))
            }
            print(JSONText.encode(["scenario":scenario,"count":model.visibleTasks.count,"id":task.id.uuidString,
                "title":task.title,"compact":compact,"expanded":expanded]))
        case "verified-reading-retention":
            try await submit("看看 z.ai 股价")
            guard model.visibleTasks.count == 1, let task = model.visibleTasks.first, let surface = task.taskSurface,
                let event = (model.preferences.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []).last(where: {
                    ["verified_reading_fallback","verified_snapshot_retained"].contains($0["event"] as? String ?? "")
                        && $0["taskID"] as? String == task.id.uuidString
                })
            else { throw AppError.message("Expected one verified reading from the fallback renderer") }
            let display = try await render(task, compact: true, index: 0)
            let expanded = try await render(task, compact: false, index: 0)
            let key = surface.apiData?.card?.primaryKey ?? CardMarkup.bindingKeys(in: surface.markup.compactHTML).subtracting(["title","status"]).first
            guard let key, let value = task.state[key], value.rangeOfCharacter(from:.decimalDigits) != nil,
                display.contains(value), expanded.contains(value),
                [display, expanded, task.title].contains(where: { $0.localizedCaseInsensitiveContains("Z.AI") || $0.contains("智谱") || $0.contains("2513") })
            else { throw AppError.message("Verified subject or value missing: " + display) }
            SimpleTaskPilot.emit(["id":task.id.uuidString,"count":1,"display":display,"source":surface.apiData?.url ?? expanded,"value":value,"recovery":event["event"] ?? ""])
        case "revise-clock-picker", "revise-currency-picker", "extend-clock-picker", "fixed-source-edit":
            let fixed = scenario == "fixed-source-edit"
            let extend = scenario == "extend-clock-picker" || fixed
            if fixed {
                // Reproduce the API-backed original, irrespective of which method the planner prefers today.
                var fetch = false
                model.agent.completionOverride = { _ in
                    if !fetch { fetch = true; return ["tool_calls": [RequestStep(tool:"load_tools", arguments:JSONText.encode(["family":"reading"])).call]] }
                    return ["tool_calls": [RequestStep(tool:"read_value", arguments:JSONText.encode(["url":"https://timeapi.io/api/time/current/zone?timeZone=Europe%2FHelsinki",
                        "subject":"Finland time", "valueLabel":"Local time", "valuePointer":"/time",
                        "expectedIdentity":"Europe/Helsinki","identityPointer":"/timeZone"])).call]]
                }
            }
            let clock = scenario != "revise-currency-picker"
            try await submit(extend ? "放一张芬兰时间卡" : clock ? "给我一个芬兰的时钟，能换地区" : "给我个港币兑人民币的换算卡")
            guard model.visibleTasks.count == 1, let first = model.visibleTasks.first, first.taskSurface != nil else {
                throw AppError.message("Expected a single initial tool")
            }
            if fixed { model.agent.completionOverride = nil }
            let before = try await render(first, compact: true, index: 0)
            if extend { try await submit("把地区改成可以选的，时间数字放大一点", in: first.id) }
            else { try await submit(clock ? "时间的数字放大一点，保留地区选择" : "结果的数字放大一点，保留币种选择", editing: first.id) }
            guard model.visibleTasks.count == 1, let revised = model.visibleTasks.first, revised.id == first.id,
                !first.presentation.hasSameDesign(as: revised.presentation), !model.taskFailed else {
                throw AppError.message("The original card did not receive the requested edit")
            }
            if !extend, let prior = first.taskSurface?.apiData {
                guard let next = revised.taskSurface?.apiData, prior.url == next.url, prior.inputs == next.inputs,
                    prior.calculation == next.calculation else { throw AppError.message("Appearance edit changed the data method") }
            }
            let window = NSWindow(contentRect: NSRect(x:-16000,y:-16000,width:300,height:320), styleMask:.borderless, backing:.buffered, defer:false)
            defer { window.orderOut(nil) }
            window.orderBack(nil)
            let web = try await SimpleTaskPilot.expanded(model, task:revised, window:window)
            let selectInfo = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('select[data-field]'),s=>({key:s.dataset.field,values:Array.from(s.options,o=>o.value)}))") as? [[String:Any]] ?? []
            let chosen = selectInfo.first { row in
                guard let key = row["key"] as? String, let options = row["values"] as? [String], options.count > 1 else { return false }
                return clock ? options.contains("Asia/Hong_Kong") : revised.state[key] == "CNY" || selectInfo.count == 1
            }
            let key = chosen?["key"] as? String
            guard let key else { throw AppError.message("No bound destination field: " + JSONText.encode(revised.taskSurface?.fields ?? [])) }
            let options = chosen?["values"] as? [String] ?? []
            guard let expected = clock ? "Asia/Hong_Kong" : options.contains("USD") ? "USD" : options.first(where: { $0 != revised.state[key] }) else { throw AppError.message("No alternative") }
            let script = """
                (()=>{const field=[...document.querySelectorAll('select')].find(s=>s.dataset.field===\(JSONText.encode(key)));
                const open=field?.nextElementSibling;if(!open?.getClientRects().length)return 'missing picker';
                open.click();const dialog=document.querySelector('dialog[open]'), search=dialog?.querySelector('input');if(!dialog || (!search && \(clock ? "true" : "false")))return 'missing picker dialog';
                if(search){search.value=\(JSONText.encode(clock ? "HK" : expected));search.dispatchEvent(new Event('input',{bubbles:true}));}
                const choice=[...dialog.querySelectorAll('button')].find(b=>b.value===\(JSONText.encode(expected)));
                if(!choice?.getClientRects().length)return 'missing choice';choice.click();return choice.textContent;})()
                """
            let picked = try await web.evaluateJavaScript(script) as? String ?? ""
            guard !picked.isEmpty, !picked.hasPrefix("missing") else { throw AppError.message(picked) }
            if let local = revised.taskSurface?.actions.first(where: { $0.kind == .code }),
                try await web.evaluateJavaScript("!!document.querySelector('button[data-action=" + JSONText.encode(local.id) + "]')") as? Bool == true {
                try await SimpleTaskPilot.click(web, action: local.id)
            }
            for _ in 0..<180 {
                if let current = model.visibleTasks.first, current.id == first.id, model.visibleTasks.count == 1,
                    current.state[key] == expected, current.dataIssue == nil, model.taskActionJobs[first.id] == nil {
                    let display = try await render(current, compact: false, index: 0)
                    let compact = try await render(current, compact: true, index: 0)
                    if clock, let source = current.taskSurface?.runtime?.sources.first(where: { $0.format == .time }) {
                        guard source.timeZone == expected, [Date(), Date().addingTimeInterval(-1), Date().addingTimeInterval(-2)].contains(where: { display.contains(source.value(at: $0)) }) else { throw AppError.message("Clock display differs from selected zone: " + display) }
                    } else if clock {
                        let format = DateFormatter()
                        format.timeZone = TimeZone(identifier: expected)
                        format.dateFormat = "HH:mm"
                        guard display.contains(format.string(from: Date())) else { throw AppError.message("Unexpected source time: " + display) }
                    } else {
                        let keys = CardMarkup.bindingKeys(in: current.presentation.html).subtracting(current.taskSurface?.fields ?? [])
                        let numbers = keys.filter { key in
                            let read = current.state[key] ?? ""
                            return read.rangeOfCharacter(from: .decimalDigits) != nil && read != revised.state[key] && display.contains(read)
                        }
                        guard !numbers.isEmpty, compact != before else { throw AppError.message("Converted result did not change: " + display) }
                    }
                    SimpleTaskPilot.emit(["id":current.id.uuidString,"count":1,"title":current.title,"before":before,"selected":picked,"canonical":expected,"after":compact])
                    return
                }
                try await Task.sleep(for:.milliseconds(160))
            }
            throw AppError.message("Choice did not commit on the original card")
        case "temperature-tool", "editable-rate", "split-tool":
            let currency = scenario == "editable-rate"
            let split = scenario == "split-tool"
            try await submit(currency ? "港币兑rmb" : split ? "120块三个人平摊，每人多少" : "30摄氏度是多少华氏度")
            guard model.visibleTasks.count == 1, let card = model.visibleTasks.first,
                let surface = card.taskSurface, surface.hasEditableOperation else { throw AppError.message("Expected one editable tool") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320), styleMask: .borderless, backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
            window.orderBack(nil)
            let web = try await SimpleTaskPilot.expanded(model, task: card, window: window)
            SimpleTaskPilot.emit(["cardLoaded": card.title, "fields": surface.fields])
            let roles = surface.apiData?.currencyFields
            let initialInput = split ? 3.0 : 30.0
            let localField = surface.fields.first { Double(card.state[$0] ?? "") == initialInput }
            guard let field = currency ? roles?.amount : localField else { throw AppError.message("No adjustable amount") }
            func edit(_ key: String, _ value: String) async throws {
                let js = "(()=>{const f=[...document.querySelectorAll('[data-field]')].find(e=>e.dataset.field===" + JSONText.encode(key) + ");if(!f||!f.getClientRects().length)return false;f.value=" + JSONText.encode(value) + ";for(const t of ['input','change'])f.dispatchEvent(new Event(t,{bubbles:true}));return f.value===" + JSONText.encode(value) + ";})()"
                guard try await web.evaluateJavaScript(js) as? Bool == true else { throw AppError.message("Field unavailable: " + key) }
                SimpleTaskPilot.emit(["edited": key, "value": value])
                if let action = surface.actions.first(where: { $0.kind == .code }) {
                    try await SimpleTaskPilot.click(web, action: action.id)
                }
            }
            func waitForOutput(_ matches: (SideTask) -> Bool) async throws -> SideTask {
                for _ in 0..<160 {
                    if let current = model.visibleTasks.first, model.visibleTasks.count == 1,
                        current.id == card.id, matches(current) { return current }
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw AppError.message("The card did not recalculate after input")
            }
            let newValue = currency ? "100" : split ? "4" : "0"
            try await edit(field, newValue)
            if currency, let roles, let primary = surface.apiData?.card?.primaryKey {
                guard let initial = Double(card.state[primary] ?? "") else { throw AppError.message("Missing starting rate") }
                let changed = try await waitForOutput { t in
                    guard let v = Double(t.state[primary] ?? "") else { return false }
                    return t.state[roles.amount] == "100" && abs(v - initial * 100) < 0.51
                }
                SimpleTaskPilot.emit(["amount": "100", "pair": changed.state["currencyPair"] ?? "", "result": changed.state[primary] ?? ""])
                try await edit(roles.to, "USD")
                let switched = try await waitForOutput { t in
                    t.taskSurface?.state[roles.to] == "USD" && t.taskSurface?.state[roles.amount] == "100"
                        && (Double(t.state[primary] ?? "") ?? 0) > 0 && t.state[primary] != changed.state[primary]
                }
                print(JSONText.encode(["id": switched.id.uuidString, "display": try await render(switched, compact: false, index: 0)]))
            } else {
                let expected = split ? "30" : "32"
                let pattern = #"(?<![0-9.])"# + expected + #"(?:\.0+)?(?![0-9.])"#
                let changed = try await waitForOutput { t in t.state[field] == newValue && t.state.contains { $0.key != field && $0.value.range(of: pattern, options: .regularExpression) != nil } }
                print(JSONText.encode(["id": changed.id.uuidString, "display": try await render(changed, compact: false, index: 0)]))
            }
        case "chat-followup":
            try await submit("17加26，只回复数字")
            guard let receipt = model.feedback, receipt.kind == .information, receipt.text == "43",
                let owner = receipt.taskID else { throw AppError.message("Expected conversational answer") }
            let feedbackView = NSHostingView(rootView: RequestFeedbackView(model: model, feedback: receipt))
            feedbackView.frame = NSRect(origin: .zero, size: model.feedbackSize)
            let window = NSWindow(contentRect: feedbackView.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = feedbackView
            feedbackView.layoutSubtreeIfNeeded()
            if let bitmap = feedbackView.bitmapImageRepForCachingDisplay(in: feedbackView.bounds) {
                feedbackView.cacheDisplay(in: feedbackView.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { print("CHAT_PREVIEW " + png.base64EncodedString()) }
            }
            model.sendFeedbackReply("再乘以二，只回复数字", to: receipt)
            for _ in 0..<1200 where model.busy { try await Task.sleep(for: .milliseconds(100)) }
            guard model.commandPanelVisible, model.conversationTaskID == owner, model.visibleTasks.isEmpty,
                model.messages.last?.taskID == owner, model.messages.last?.text == "86" else {
                throw AppError.message("Follow-up lost the conversation: " + (model.messages.last?.text ?? ""))
            }
            print(JSONText.encode(["thread": owner.uuidString, "followup": "86"]))
        case "terse-rate", "rate-answer":
            var bossa = SideTask(kind: .web, title: "Bossa Nova")
            var radio = SideTask(kind: .web, title: "Best of lofi")
            bossa.listening = true
            radio.listening = true
            model.sideTasks = [bossa, radio]
            let originalIDs = Set([bossa.id, radio.id])
            if scenario == "rate-answer" {
                try await submit("港币兑rmb，只回复汇率数字")
                let reply = model.messages.last(where: { !$0.isUser })?.text ?? ""
                guard let rate = Double(reply), rate > 0,
                    Set(model.visibleTasks.map(\.id)) == originalIDs else {
                    throw AppError.message("Text-only reading changed the shelf or returned no number")
                }
                break
            }
            try await submit("港币兑rmb")
            let newCards = model.visibleTasks.filter { !originalIDs.contains($0.id) }
            guard originalIDs.isSubset(of: Set(model.visibleTasks.map(\.id))),
                newCards.count == 1, let card = newCards.first, card.taskSurface != nil else {
                throw AppError.message("Expected one verified reading beside the two retained players")
            }
            let compact = try await render(card, compact: true, index: 0)
            let expanded = try await render(card, compact: false, index: 0)
            print(JSONText.encode(["compact": compact, "expanded": expanded, "id": card.id.uuidString]))
            let display = compact + " " + expanded
            guard ["HKD", "港币", "港元", "Hong Kong"].contains(where: display.localizedCaseInsensitiveContains),
                ["CNY", "RMB", "人民币", "yuan", "renminbi"].contains(where: display.localizedCaseInsensitiveContains),
                compact.range(of: #"[0-9]+[.,][0-9]+"#, options: .regularExpression) != nil else {
                throw AppError.message("Missing currencies or compact rate")
            }
        case "measured-glance", "travel-glance":
            let travel = scenario == "travel-glance"
            try await submit(travel ? "做张通勤比较卡，东线32分钟，西线47分钟，看哪条更快" : "做张卡比较 Z.AI 和 Xiaomi 的近一月涨跌幅：Z.AI −29.2%，Xiaomi +6.2%，看谁领先")
            guard model.visibleTasks.count == 1, let card = model.visibleTasks.first, card.taskSurface != nil else {
                throw AppError.message("Missing the comparison card")
            }
            let expanded = try await render(card, compact: false, index: 0)
            let compact = try await render(card, compact: true, index: 0)
            print(JSONText.encode(["compact": compact, "expanded": expanded]))
            let values = compact.replacingOccurrences(of: "％", with: "%")
            if travel {
                guard expanded.contains("32"), expanded.contains("47"),
                    (values.contains("32") || values.contains("15")),
                    ["East", "东"].contains(where: values.localizedCaseInsensitiveContains),
                    ["min", "分钟", "分"].contains(where: values.localizedCaseInsensitiveContains) else {
                    throw AppError.message("Missing commute reading or difference")
                }
                break
            }
            let hasSpread = values.contains("35.4") && ["pp", "p.p.", "pts", "percentage points", "百分点"].contains(where: values.localizedCaseInsensitiveContains)
            guard expanded.contains("29.2"), expanded.contains("6.2"),
                ["Xiaomi", "小米"].contains(where: values.localizedCaseInsensitiveContains),
                (values.contains("6.2") && values.contains("%")) || hasSpread else {
                throw AppError.message("No labeled deciding measurement in the capsule")
            }
        case "list-content":
            try await submit("建个购物清单，先记牛奶")
            guard model.visibleTasks.count == 1, let original = model.visibleTasks.first, original.taskSurface != nil, original.kind != .result else {
                throw AppError.message("Expected one working shopping list")
            }
            let first = try await render(original, compact: false, index: 0)
            let milk = ["牛奶", "milk"]
            let eggs = ["鸡蛋", "egg"]
            guard milk.contains(where: first.localizedCaseInsensitiveContains) else { throw AppError.message("Milk missing from original list: " + first) }
            try await submit("再加鸡蛋")
            guard model.visibleTasks.map(\.id) == [original.id], let updated = model.visibleTasks.first else {
                throw AppError.message("Lost the original list instance")
            }
            let content = try await render(updated, compact: false, index: 0)
            guard milk.contains(where: content.localizedCaseInsensitiveContains),
                eggs.contains(where: content.localizedCaseInsensitiveContains) else { throw AppError.message("Missing list item: " + content) }
            print(JSONText.encode(["listID": updated.id.uuidString, "expanded": content]))
        case "timer-global":
            try await submit("定个5分钟倒计时")
            guard let first = model.visibleTasks.first(where: { $0.duration == 300 }), let deadline = first.deadline else { throw AppError.message("First timer missing") }
            try await submit("再来一个9分钟的")
            guard model.visibleTasks.count == 2, model.visibleTasks.first(where: { $0.id == first.id })?.deadline == deadline,
                deadline > Date(), model.visibleTasks.contains(where: { $0.id != first.id && $0.duration == 540 && $0.deadline != nil }) else { throw AppError.message("Timer append changed old timer") }
        case "repos":
            try await submit("swift-nio 几个 star")
            let first = try await quotes(["apple/swift-nio":"swift-nio|SwiftNIO"])
            try await submit("也看看 Alamofire")
            let final = try await quotes(["apple/swift-nio":"swift-nio|SwiftNIO","Alamofire/Alamofire":"Alamofire"])
            guard first["apple/swift-nio"] == final["apple/swift-nio"] else { throw AppError.message("Repository replaced") }
        case "empty":
            try await submit(pair)
            _ = try await quotes(companies)
        case "existing":
            try await submit("苹果股价")
            let apple = try await quotes(["AAPL": "Apple"])["AAPL"]
            try await submit(pair)
            let final = try await quotes(companies)
            guard final["AAPL"] == apple else { throw AppError.message("Apple was replaced") }
            try await submit(pair)
            let repeated = try await quotes(companies)
            guard final == repeated else { throw AppError.message("Repeated request duplicated cards") }
        case "append":
            try await submit("微软股价")
            let first = try await quotes(["MSFT": "Microsoft"])
            try await submit("再看苹果")
            let second = try await quotes(companies)
            try await submit("再看特斯拉")
            let third = try await quotes(companies.merging(["TSLA": "Tesla"]) { _, new in new })
            guard first["MSFT"] == second["MSFT"], second.allSatisfy({ third[$0.key] == $0.value }) else {
                throw AppError.message("An earlier quote was replaced")
            }
        case "together":
            try await submit("比较一下微软和苹果的股价，放一起看")
            guard model.visibleTasks.count == 1, let task = model.visibleTasks.first, task.taskSurface != nil else {
                throw AppError.message("Expected one comparison surface")
            }
            let expanded = try await render(task, compact: false, index: 0)
            print(JSONText.encode(["expanded": expanded]))
            guard [["Microsoft", "MSFT", "微软"], ["Apple", "AAPL", "苹果"]].allSatisfy({ labels in
                labels.contains(where: expanded.localizedCaseInsensitiveContains)
            }), expanded.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) != nil else {
                throw AppError.message("Comparison missing its named readings")
            }
        case "answer":
            try await submit("17加26等于多少？只回复数字")
            guard model.visibleTasks.isEmpty, model.messages.last?.text.contains("43") == true else {
                throw AppError.message("Expected a conversational answer without a result card")
            }
        case "replace":
            try await submit("苹果股价")
            let original = try await quotes(["AAPL": "Apple"])
            try await submit("把苹果换成微软", in: original["AAPL"])
            let final = try await quotes(["MSFT": "Microsoft"])
            guard final["MSFT"] == original["AAPL"] else { throw AppError.message("Replacement lost the selected card identity") }
        case "timers":
            try await submit("定个7分钟的倒计时")
            guard let timer = model.visibleTasks.first(where: { $0.duration == 420 }) else { throw AppError.message("Missing timer") }
            try await submit("再来个11分钟的", in: timer.id)
            let timers = model.visibleTasks
            guard timers.count == 2, timers.contains(where: { $0.id == timer.id && $0.duration == 420 && $0.deadline != nil }),
                timers.contains(where: { $0.id != timer.id && $0.duration == 660 && $0.deadline != nil }) else {
                throw AppError.message("Timer identity or duration changed")
            }
        default: throw AppError.message("Unknown placement scenario")
        }
    }

    static func verifyComparison(_ model: AppModel) async throws {
        model.command = "做一张报价比较卡：North 报价120元，South 报价95元，显示两份报价和差额。"
        model.sendCommand()
        let start = Date()
        while model.busy || model.globalRoutingTask != nil {
            guard Date().timeIntervalSince(start) < 180 else { throw AppError.message("Timed out waiting for comparison") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.sideTasks.count == 1, let task = model.sideTasks.first, task.taskSurface != nil else {
            throw AppError.message("Comparison did not produce one card")
        }
        let expanded = try await render(task, compact: false, index: 0)
        guard ["North", "South", "120", "95", "25"].allSatisfy({ expanded.localizedCaseInsensitiveContains($0) }) else {
            throw AppError.message("Missing comparison results: " + expanded)
        }
        print(JSONText.encode(["title": task.title, "expanded": expanded, "cards": model.sideTasks.count]))
    }

    static func run(_ model: AppModel) async throws {
        let prompts = [
            "帮我跟一下播客《Night Shift》的剪辑进度。这期目标成片45分钟，已经剪完28分钟，我想随时看到还差多少分钟，之后可以改进度。",
            "帮我看一下 Juniper 这台陶艺窑的温度。今天点火后第0、10、30、45分钟实测分别是21、95、280、410摄氏度。我关心当前窑温，展开用折线图看升温趋势。这批记录已经齐了，只需要查看。",
            "做一张 Kyoto 出差的住宿比价卡。三家酒店每晚含税分别是120、150、135美元，住三晚。让我能比较各自的总价，一眼看到最低总价。"
        ]
        model.settings.interfaceLanguage = "English"
        var ids: [UUID] = []
        for prompt in prompts {
            model.selectChat(true)
            model.command = prompt
            model.sendCommand()
            guard let id = model.messages.last(where: { $0.isUser && $0.text == prompt })?.id else {
                throw AppError.message("Submission did not create its own message")
            }
            ids.append(id)
        }
        let start = Date()
        var peak = 0
        while model.busy || model.globalRoutingTask != nil || !model.pendingRoutingRequests.isEmpty {
            peak = max(peak, model.commandRuns.filter { $0.context?.stage != .understanding }.count)
            guard Date().timeIntervalSince(start) < 300 else { throw AppError.message("Parallel card test timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
        var owners: Set<UUID> = []
        var valid = peak >= 2
        for (i, messageID) in ids.enumerated() {
            guard let id = model.messages.first(where: { $0.id == messageID })?.taskID,
                let task = model.sideTasks.first(where: { $0.id == id }), let surface = task.taskSurface else {
                let failedID = model.messages.first { $0.id == messageID }?.requestID
                print("Last recorded steps: " + (failedID.flatMap { model.requestProgress[$0] } ?? []).joined(separator: " | "))
                print("Missing card \(i): " + (model.messages.last(where: { $0.taskID == model.messages.first(where: { $0.id == messageID })?.taskID && !$0.isUser })?.text ?? "No result"))
                valid = false; continue
            }
            let compact = try await render(task, compact: true, index: i)
            let expanded = try await render(task, compact: false, index: i)
            let value = ["17", "410", "360"][i]
            let english = (compact + expanded + surface.title).range(of: #"[一-鿿㐀-䶿]"#, options: .regularExpression) == nil
            let subjects = ["Night Shift", "Juniper", "Kyoto"]
            let named = compact.components(separatedBy: .newlines).first?.localizedCaseInsensitiveContains(subjects[i]) == true
            let chartOrTable = i == 0 || (i == 1 ? task.presentation.html.contains("data-series") : task.presentation.html.contains("<table") && expanded.contains("450") && expanded.contains("405"))
            let thread = model.messages.first { $0.id == messageID }?.requestID
            let steps = thread.flatMap { model.requestProgress[$0] } ?? []
            print("Progress for card " + String(i) + ": " + steps.joined(separator: " | "))
            print("Subject: " + String(named) + ", component: " + String(chartOrTable))
            valid = valid && owners.insert(id).inserted && named && chartOrTable && !steps.isEmpty
            print(JSONText.encode(["card": i, "title": surface.title, "compact": compact, "expanded": expanded, "English": english]))
            valid = valid && english && compact.contains(value) && expanded.contains(value)
        }
        print("Peak concurrent executing commands: \(peak)")
        guard valid else { throw AppError.message("A rendered card or concurrent execution did not pass") }
    }

    private static func render(_ task: SideTask, compact: Bool, index: Int) async throws -> String {
        let size = compact ? NSSize(width: 108, height: 28) : NSSize(width: 300, height: 320)
        let view = WKWebView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let markup = task.presentation
        view.loadHTMLString(HTMLCardView.document(fragment: compact ? markup.compactHTML : markup.html, css: markup.css, language: markup.interfaceLanguage), baseURL: nil)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof updateCard === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = HTMLCardView.renderState(compact ? task.state : task.expandedDisplayState, compact: compact, appearance: .light, formMode: !compact)
        let text = try await view.evaluateJavaScript("updateCard(" + JSONText.encode(state) + ");document.querySelector('#surface').innerText") as? String ?? ""
        if compact, (try await view.evaluateJavaScript("Array.from(document.querySelectorAll('.calm-value')).some(e=>{const r=document.createRange();r.selectNodeContents(e);return r.getBoundingClientRect().right>document.querySelector('#surface').getBoundingClientRect().right+1})") as? Bool) == true {
            throw AppError.message("The compact primary reading was visibly clipped: " + text)
        }
        if let dir = ProcessInfo.processInfo.environment["ORVLET_CARD_PREVIEWS"] {
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let file = "\(index)-\(compact ? "compact" : "expanded").png"
                if dir == "stdout" { print("PREVIEW " + file + " " + data.base64EncodedString()) }
                else { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file)) }
            }
        }
        return text
    }
}
#endif
