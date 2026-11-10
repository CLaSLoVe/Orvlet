#if DEBUG
    import AppKit

    /// Synthetic task only: no user files, browsing, or Calendar writes.
    @MainActor
    enum TaskAgentLiveCheck {
        /// A small synthetic cross-capability sample, not a promise about all tasks.
        static func benchmark(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.useFast = false
            model.backgroundRequest = true
            let suite = "orvlet-benchmark-" + UUID().uuidString
            let isolated = UserDefaults(suiteName: suite)!
            model.interfaceMemory = InterfaceMemory(defaults: isolated)
            defer { isolated.removePersistentDomain(forName: suite) }
            let cases: [(String, String)] = [
                ("editable-calculation", "做个可编辑的分账工具：账单 120，3 人均分，可以加服务费百分比（默认 10%）和折扣（默认 0），显示最后总额和人均，保留两位小数。"),
                ("text-transformation", "做一个小工具，粘贴多行文本后去除空行、合并重复行，可以选择是否区分大小写。先用 Apple、apple、Banana 这三行试一下。输入和选项都能修改。"),
                ("public-data", "56 港币等于多少人民币？用最新可获取的参考汇率，注明数据日期。"),
            ]
            var reports: [[String: Any]] = []
            for (name, prompt) in cases {
                for task in model.sideTasks { model.stopTaskActions(task.id) }
                model.sideTasks = []
                model.messages = []
                model.archivedTaskHistory = []
                let trace = "/tmp/orvlet-workflow-" + name + ".jsonl"
                Diagnostics.begin(trace)
                Diagnostics.benchmarkEvents = []
                let start = Date()
                var report: [String: Any] = ["case": name]
                do {
                    _ = try await model.agent.run(prompt)
                    let surface = model.sideTasks.compactMap(\.taskSurface).first
                    guard let surface, !surface.fields.isEmpty else {
                        throw AppError.message("No editable task was produced")
                    }
                    report["ok"] = true
                    report["inputs"] = surface.fields.count
                    report["api"] = surface.apiData != nil
                    report["surface"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(surface))
                } catch {
                    report["ok"] = false
                    report["error"] = error.localizedDescription
                }
                report["seconds"] = Date().timeIntervalSince(start)
                let events = Diagnostics.benchmarkEvents ?? []
                report["events"] = events
                report["modelCalls"] = events.filter { $0["event"] as? String == "api" }.count
                report["repairs"] =
                    events.filter { ["tool_error", "intent_invalid"].contains($0["event"] as? String ?? "") }.count
                report["tools"] = events.filter { $0["event"] as? String == "tool" }.compactMap { $0["name"] }
                reports.append(report)
                try? JSONSerialization.data(withJSONObject: reports, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-workflow-benchmark.json"))
                if report["ok"] as? Bool == true, let id = model.sideTasks.first(where: { $0.taskSurface != nil })?.id {
                    model.selectTask(id, expanded: true)
                    try? await Task.sleep(for: .milliseconds(400))
                    let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "orvlet-benchmark-" + name + ".png")
                    try? await SideScreenCheck.snapshot(delegate.panel, path: imageURL.path)
                    report["screenshot"] = imageURL.path
                }
                print(JSONText.encode(report))
                fflush(stdout)
            }
            if CommandLine.arguments.contains("--keep-open"), let object = reports.first?["surface"],
                let data = try? JSONSerialization.data(withJSONObject: object),
                let surface = try? JSONDecoder().decode(TaskSurface.self, from: data)
            {
                let id = UUID()
                model.publishTaskSurface(surface, id: id)
                model.selectTask(id, expanded: true)
                return
            }
            exit(reports.allSatisfy { $0["ok"] as? Bool == true } ? 0 : 1)
        }
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            model.settings.allowAgents = false
            let clockProbe = CommandLine.arguments.contains("--plain-clock-probe")
            Diagnostics.begin(clockProbe ? "/tmp/orvlet-plain-clock-probe.jsonl" : "/tmp/orvlet-task-agent-live.jsonl")
            model.sideTasks = []
            model.messages = []
            model.backgroundRequest = true
            let prompt =
                clockProbe
                ? "给个时钟"
                : "Create a small bill-splitting tool for a fictional bill of 120 shared equally by 3 people. Run code to calculate the result, then generate an interface with editable amount and people fields, a local Calculate button, and a compact per-person value. This is a synthetic test. Do not open any webpage or use Calendar."
            let started = Date()
            do {
                model.busy = true
                model.beginAmbientRequest(prompt)
                let reply = try await model.agent.run(prompt)
                if clockProbe {
                    Diagnostics.record(
                        "probe_result",
                        [
                            "reply": reply,
                            "tasks": model.sideTasks.map {
                                ["kind": $0.kind.rawValue, "title": $0.title, "status": $0.status]
                            },
                        ])
                    exit(0)
                }
                model.busy = false
                model.finishAmbientRequest()
                guard let task = model.sideTasks.first(where: { $0.kind == .workspace }),
                    let surface = task.taskSurface, surface.fields.count >= 2,
                    let calculation = surface.actions.first(where: { $0.kind == .code }),
                    let code = calculation.code, model.webURL.isEmpty,
                    (task.liveValues ?? [:]).values.contains(where: { Double($0) == 40 })
                else {
                    throw AppError.message("The real agent did not produce a working independent task.")
                }
                // Exercise its own generated handler with changed values. Field names
                // come from the model; the human-like input values are supplied here.
                let amountField = surface.fields.first(where: {
                    $0.lowercased().contains("amount") || $0.lowercased().contains("total")
                        || $0.lowercased().contains("bill")
                })
                let peopleField = surface.fields.first(where: {
                    $0.lowercased().contains("people") || $0.lowercased().contains("person")
                        || $0.lowercased().contains("count") || $0.lowercased().contains("split")
                })
                guard let amountField, let peopleField, amountField != peopleField else {
                    throw AppError.message("Cannot identify the generated form's two inputs.")
                }
                let result = try await model.taskCode.run(
                    code: code, input: [amountField: "150", peopleField: "5"], state: task.liveValues ?? [:])
                guard try TaskValues.decode(result).values.contains(where: { Double($0) == 30 }) else {
                    throw AppError.message("Generated handler did not calculate 150 / 5 correctly.")
                }
                model.cardAction(
                    task.id, action: calculation.id,
                    value: JSONText.encode([amountField: "150", peopleField: "5"]))
                for _ in 0..<100 {
                    if model.taskActionJobs[task.id] == nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard
                    model.sideTasks.first(where: { $0.id == task.id })?.state.values.contains(where: {
                        Double($0) == 30
                    }) == true
                else { throw AppError.message("The generated button failed to update its own task.") }
                model.selectTask(task.id, expanded: true)
                model.pinned = true
                try await Task.sleep(for: .seconds(1))
                try await SideScreenCheck.snapshot(delegate.panel, path: "/tmp/orvlet-task-agent-live.png")
                let report: [String: Any] = [
                    "ok": true, "seconds": Date().timeIntervalSince(started), "taskID": task.id.uuidString,
                    "reply": reply, "surface": try JSONSerialization.jsonObject(with: JSONEncoder().encode(surface)),
                    "changedInputResult": result, "browserOpened": !model.webURL.isEmpty,
                ]
                try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(
                    to: URL(fileURLWithPath: "/tmp/orvlet-task-agent-live.json"))
                exit(0)
            } catch {
                if clockProbe {
                    Diagnostics.record("probe_failure", ["reason": error.localizedDescription])
                    exit(1)
                }
                try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "error": error.localizedDescription], options: .prettyPrinted
                ).write(to: URL(fileURLWithPath: "/tmp/orvlet-task-agent-live.json"))
                exit(1)
            }
        }
    }
#endif
