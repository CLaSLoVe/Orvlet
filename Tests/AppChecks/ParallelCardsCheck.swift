#if DEBUG
import AppKit
import SwiftUI
import WebKit

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
            for event in Diagnostics.benchmarkEvents ?? [] where event["event"] as? String == "tool_error" {
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
        func submit(_ text: String, in conversation: UUID? = nil) async throws {
            model.selectChat(true, conversation: conversation)
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
                guard let spec = task.taskSurface?.apiData,
                    let symbol = symbols.keys.first(where: { symbol in
                        spec.fields.contains { task.state[$0.key]?.caseInsensitiveCompare(symbol) == .orderedSame }
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
        let state = HTMLCardView.renderState(task.state, compact: compact, appearance: .light, formMode: !compact)
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
