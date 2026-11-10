#if DEBUG
    import AppKit

    @MainActor
    enum TaskContinuityCheck {
        static func run(_ model: AppModel, delegate: AppDelegate) async {
            var checks: [String] = []
            func check(_ value: Bool, _ label: String) throws {
                guard value else { throw AppError.message(label) }
                checks.append(label)
            }
            func paused(_ title: String) -> SideTask {
                var task = SideTask(kind: .timer, title: title)
                task.duration = 300
                task.pausedSeconds = 300
                task.status = "Paused"
                return task
            }
            do {
                model.isLiveTest = true
                model.persistHistory = false
                model.settings.autoAdapt = false
                model.settings.reduceMotion = true
                model.settings.appearance = .light
                model.sideTasks = [paused("Focus"), paused("Break")]
                model.selectedTaskID = model.sideTasks[0].id
                model.taskShelfVisible = true
                model.taskListEditing = true
                model.closeTask(model.sideTasks[0].id)
                try check(
                    model.taskShelfVisible && model.taskListEditing,
                    "Removing selected task keeps shelf and edit mode open")
                model.selectedTaskID = model.sideTasks[0].id
                model.dismissTask(model.sideTasks[0].id)
                try check(model.taskShelfVisible, "Hiding selected task keeps shelf open")
                var web = SideTask(kind: .web, title: "Web fixture")
                web.listening = true
                model.sideTasks.append(web)
                model.selectedTaskID = web.id
                model.closeTask(web.id)
                try check(model.taskShelfVisible, "Closing a browser task keeps shelf open")
                var hidden = false
                let originalHide = model.onHide
                model.onHide = { hidden = true }
                model.closeTask(model.sideTasks[0].id)
                try check(model.taskShelfVisible && !hidden, "Removing the final task retains the empty shelf")
                model.onHide = originalHide
                model.collapsed = false
                model.clickExpanded = false
                model.pointerInside = false
                model.refreshHover()
                try await Task.sleep(for: .milliseconds(350))
                try check(model.taskShelfVisible, "Pointer leaving the shelf does not collapse it")
                var older = SideTask(kind: .web, title: "Earlier activity")
                older.listening = true
                var current = SideTask(kind: .web, title: "Current activity")
                current.listening = true
                current.playing = true
                model.sideTasks = [older, current]
                model.selectedTaskID = older.id
                let candidates = JevRequestTriage.candidates(model, explicit: nil)
                try check(candidates.first?.id == current.id, "Current activity is ranked ahead of stale selection")
                let defaults = JevRequestTriage.continuationDefaults(candidates, preferred: current.id)
                try check(
                    defaults[older.id] == current.id && defaults[current.id] == current.id,
                    "Equivalent activities have one default while retaining explicitly selectable instances")
                let request = JevRequestTriage.request(
                    text: "Change content", candidates: candidates, explicit: nil,
                    preferred: model.continuationPreference(in: candidates))
                func answers(_ allocation: String) -> [String: Any] {
                    let choices = [
                        "route": "task_0", "instance": allocation, "budget": "low", "control": "none",
                        "capability": "music",
                    ]
                    return Dictionary(
                        uniqueKeysWithValues: request.questions.map { key, value in
                            let q = value as! [String: Any]
                            let criteria = q["criteria"] as! [String: String]
                            let chosen = choices[key]!
                            return (
                                key,
                                [
                                    "type": "choice", "choice": chosen, "confidence": 1.0,
                                    "probabilities": criteria.mapValues { _ in 0.0 }.merging([chosen: 1.0]) { _, new in
                                        new
                                    },
                                ] as [String: Any]
                            )
                        })
                }
                let continued = try JevRequestTriage.decode(
                    JSONSerialization.data(withJSONObject: ["answers": answers("automatic")]),
                    candidates: candidates, explicit: nil, routes: request.routes)
                try check(
                    continued.target == current.id && continued.routeKnown,
                    "Content changes retain the matched activity")
                let additional = try JevRequestTriage.decode(
                    JSONSerialization.data(withJSONObject: ["answers": answers("additional")]),
                    candidates: candidates, explicit: nil, routes: request.routes)
                try check(
                    additional.additionalInstance && additional.target == nil && !additional.routeKnown,
                    "Additional allocation is verified separately instead of overwriting the matched task")
                let composition = AgentToolRegistry.definitions.first {
                    ($0["function"] as? [String: Any])?["name"] as? String == "compose_ui"
                }!
                let longSelectors = (0..<100).map {
                    ["selector": String(repeating: "section > ", count: 30) + "#item" + String($0)]
                }
                let bounded = SurfacePlan.scopeTool(composition, observation: ["readables": longSelectors])
                try check(
                    JSONText.encode(bounded).utf8.count < JSONText.encode(composition).utf8.count + 2048,
                    "Repeated page selectors cannot inflate construction tool schemas")
                model.sideTasks = [paused("Focus timer"), paused("Break timer"), paused("Reading timer")]
                model.selectedTaskID = model.sideTasks[0].id
                model.collapsed = true
                model.taskShelfVisible = true
                model.taskListEditing = false
                model.reconcileTasks()
                model.onShow?()
                let report: [String: Any] = ["ok": true, "checks": checks]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                    .write(
                        to: FileManager.default.temporaryDirectory.appendingPathComponent(
                            "orvlet-task-continuity-checks.json"))
                print(JSONText.encode(report))
                if !CommandLine.arguments.contains("--preview") { exit(0) }
            } catch {
                print(JSONText.encode(["ok": false, "error": error.localizedDescription, "checks": checks]))
                exit(1)
            }
        }
    }
#endif
