#if DEBUG
    import Foundation
    @MainActor
    enum RuntimeLifecycleCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                guard ok else { throw AppError.message(label) }
                checks.append(label)
            }
            let model = AppModel()
            model.isLiveTest = true
            model.persistHistory = false
            model.settings.autoAdapt = false
            defer { model.taskRuntime.stopAll() }
            let markup = CardMarkup(
                html: "<strong data-bind='value'></strong>", compactHTML: "<span data-bind='value'></span>", css: "")
            let epochID = UUID()
            let epoch = TaskSurface(
                title: "Zoned clock", markup: markup, fields: [], actions: [], state: [:],
                runtime: TaskRuntimeSpec(sources: [
                    TaskDataSource(key: "value", kind: .clock, format: .seconds, timeZone: "Asia/Shanghai")
                ]))
            model.publishTaskSurface(try epoch.validated(), id: epochID)
            var zoned = RequestIntent(kind: .general)
            zoned.behavior = .live
            zoned.timeZones = ["Asia/Shanghai"]
            var epochRejected = false
            do { try await TaskVerification.verify(epochID, intent: zoned, model: model) } catch {
                epochRejected = true
            }
            try check(epochRejected, "A Unix epoch value cannot certify a requested local time zone")
            model.closeTask(epochID)
            var surface = TaskSurface(
                title: "Elapsed", markup: markup, fields: [], actions: [], state: [:],
                runtime: TaskRuntimeSpec(sources: [TaskDataSource(key: "value", kind: .elapsed, format: .seconds)]))
            surface = try surface.validated()
            let id = UUID()
            model.publishTaskSurface(surface, id: id)
            try await model.taskRuntime.verify(id)
            let first = model.sideTasks.first(where: { $0.id == id })?.state["value"]
            model.dismissTask(id)
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] != first,
                "Hidden tasks continue sampling independently of the visible card")
            model.taskRuntime.control(id, operation: "pause")
            let paused = model.sideTasks.first(where: { $0.id == id })?.state["value"]
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] == paused,
                "Pausing freezes the elapsed source")
            model.taskRuntime.control(id, operation: "resume")
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] == paused,
                "Resume excludes paused wall time instead of jumping forward")
            try await model.taskRuntime.verify(id)
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] != paused,
                "Resumed source produces new scheduled samples")
            var intent = RequestIntent(kind: .general)
            intent.behavior = .advancing
            try await TaskVerification.verify(id, intent: intent, model: model)
            let saved = try JSONDecoder().decode([SideTask].self, from: JSONEncoder().encode(model.sideTasks))
            let restored = AppModel()
            restored.isLiveTest = true
            restored.persistHistory = false
            restored.sideTasks = saved
            restored.taskRuntime.attach(id)
            try await restored.taskRuntime.verify(id)
            try check(
                restored.sideTasks.first(where: { $0.id == id })?.state["value"] != nil,
                "Restored tasks reconstruct fresh data from saved sources")
            restored.taskRuntime.stopAll()
            model.closeTask(id)
            try check(model.taskRuntime.receipts[id] == nil, "Closing cancels sampling and discards its generation")
            let failed = SideTask(kind: .result, title: "Failed")
            model.sideTasks = [failed]
            model.decorateTask(failed.id)
            try check(model.interfaceJobs.isEmpty, "Failure placeholders do not start interface generation")

            let counterID = UUID()
            surface = TaskSurface(
                title: "Counter", markup: markup, fields: [], actions: [], state: ["value": "0"],
                runtime: TaskRuntimeSpec(
                    sources: [],
                    refresh: TaskRefresh(
                        code: "return {state:{value:String(Number(state.value)+1)}}", intervalSeconds: 1,
                        outputKeys: ["value"])))
            model.publishTaskSurface(try surface.validated(), id: counterID)
            try await model.taskRuntime.verify(counterID)
            try check(
                Int(model.sideTasks.first(where: { $0.id == counterID })!.state["value"]!)! >= 2,
                "Scheduled code actually executes repeatedly through bounded workers")
            model.taskRuntime.control(counterID, operation: "stop")
            let stopped = model.sideTasks.first(where: { $0.id == counterID })!.state["value"]
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == counterID })!.state["value"] == stopped,
                "Stopped recurring calculations never apply late results")
            model.taskRuntime.control(counterID, operation: "restart")
            try check(
                model.sideTasks.first(where: { $0.id == counterID })?.state["value"] == "0",
                "Restart resets scheduled output to its original value before the next interval")
            var bad = surface
            bad.runtime?.refresh?.code = "throw Error('synthetic update failure')"
            model.publishTaskSurface(bad, id: counterID)
            try await Task.sleep(for: .milliseconds(1500))
            try check(
                model.sideTasks.first(where: { $0.id == counterID })?.status == "Update unavailable",
                "A failed refresh is explicitly stale and retains the last result")
            var rejected = false
            let wrong = TaskSurface(
                title: "Broken calculator", markup: markup, fields: ["amount"],
                actions: [TaskSurfaceAction(id: "calculate", kind: .code, code: "return {state:{value:'wrong'}}")],
                state: ["value": "2"],
                checks: [TaskActionCheck(action: "calculate", input: ["amount": "9"], expected: ["value": "3"])])
            do { try await TaskVerification.validateActions(wrong, runtime: model.taskCode, required: true) } catch {
                rejected = true
            }
            try check(rejected, "A handler that disagrees with its changed-input example cannot commit")
            let scheduledID = UUID()
            var scheduled = surface
            scheduled.runtime?.refresh?.intervalSeconds = 30
            model.publishTaskSurface(try scheduled.validated(), id: scheduledID)
            try await model.taskRuntime.verify(scheduledID)
            try check(
                model.sideTasks.first(where: { $0.id == scheduledID })?.state["value"] == "0",
                "Long-interval preparation does not apply a reducer before its due time")
            try check(
                model.sideTasks.first(where: { $0.id == scheduledID })?.status == "Scheduled",
                "A prepared future callback is described as scheduled, not fresh data")
            model.taskRuntime.control(scheduledID, operation: "pause")
            model.taskRuntime.attach(scheduledID)
            try await Task.sleep(for: .milliseconds(400))
            try check(
                model.taskRuntime.receipts[scheduledID]?.prepared == false,
                "Restoring a paused task never prepares or executes its reducer")
            var mixed = scheduled
            mixed.runtime?.sources = [TaskDataSource(key: "clock", kind: .clock, format: .seconds)]
            model.publishTaskSurface(try mixed.validated(), id: scheduledID)
            try await Task.sleep(for: .milliseconds(300))
            let clockValue = model.sideTasks.first(where: { $0.id == scheduledID })?.state["clock"]
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == scheduledID })?.state["clock"] != clockValue,
                "Native sources update independently of a slow reducer schedule")
            rejected = false
            do { _ = try await model.taskCode.run(code: "return {state:{value:1/0}}") } catch { rejected = true }
            try check(rejected, "Non-finite arithmetic cannot silently turn into an empty successful result")
            let memorySuite = "orvlet-runtime-memory-" + UUID().uuidString
            let memoryDefaults = UserDefaults(suiteName: memorySuite)!
            defer { memoryDefaults.removePersistentDomain(forName: memorySuite) }
            let memory = InterfaceMemory(defaults: memoryDefaults)
            if let counter = model.sideTasks.first(where: { $0.id == counterID }) {
                memory.remember(counter, purpose: "Reusable counter")
                rejected = false
                do { _ = try memory.taskSurface(counter.id.uuidString, title: "Fresh counter", state: [:]) } catch {
                    rejected = true
                }
                try check(rejected, "A reused reducer requires fresh initial state rather than replaying old outputs")
                let fresh = try memory.taskSurface(counter.id.uuidString, title: "Fresh counter", state: ["value": "7"])
                try check(
                    fresh.runtime?.refresh?.initialValues?["value"] == "7",
                    "A reused reducer restarts from its new initial value")
            }
            return checks
        }
    }
#endif
