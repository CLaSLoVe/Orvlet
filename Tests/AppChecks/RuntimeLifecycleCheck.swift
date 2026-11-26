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
            func resource(_ id: UUID) -> UUID { model.work.view(id)?.selected ?? id }
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
            try await model.taskRuntime.verify(resource(id))
            let first = model.sideTasks.first(where: { $0.id == id })?.state["value"]
            model.dismissTask(id)
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] != first,
                "Hidden tasks continue sampling independently of the visible card")
            model.taskRuntime.control(resource(id), operation: "pause")
            let paused = model.sideTasks.first(where: { $0.id == id })?.state["value"]
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] == paused,
                "Pausing freezes the elapsed source")
            model.taskRuntime.control(resource(id), operation: "resume")
            try check(
                model.sideTasks.first(where: { $0.id == id })?.state["value"] == paused,
                "Resume excludes paused wall time instead of jumping forward")
            try await model.taskRuntime.verify(resource(id))
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
            try check(model.taskRuntime.receipts[resource(id)] != nil && model.sideTasks.allSatisfy { $0.id != id }, "Closing a view retains its independently running resource")
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
            try await model.taskRuntime.verify(resource(counterID))
            try check(
                Int(model.sideTasks.first(where: { $0.id == counterID })!.state["value"]!)! >= 2,
                "Scheduled code actually executes repeatedly through bounded workers")
            model.taskRuntime.control(resource(counterID), operation: "stop")
            let stopped = model.sideTasks.first(where: { $0.id == counterID })!.state["value"]
            try await Task.sleep(for: .milliseconds(1200))
            try check(
                model.sideTasks.first(where: { $0.id == counterID })!.state["value"] == stopped,
                "Stopped recurring calculations never apply late results")
            model.taskRuntime.control(resource(counterID), operation: "restart")
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
            try await model.taskRuntime.verify(resource(scheduledID))
            try check(
                model.sideTasks.first(where: { $0.id == scheduledID })?.state["value"] == "0",
                "Long-interval preparation does not apply a reducer before its due time")
            try check(
                model.sideTasks.first(where: { $0.id == scheduledID })?.status == "Scheduled",
                "A prepared future callback is described as scheduled, not fresh data")
            model.taskRuntime.control(resource(scheduledID), operation: "pause")
            model.taskRuntime.attach(resource(scheduledID))
            try await Task.sleep(for: .milliseconds(400))
            try check(
                model.taskRuntime.receipts[resource(scheduledID)]?.prepared == false,
                "Restoring a paused task never prepares or executes its reducer")
            var mixed = scheduled
            mixed.runtime?.sources = [TaskDataSource(key: "clock", kind: .clock, format: .seconds)]
            model.publishTaskSurface(try mixed.validated(), id: scheduledID)
            model.taskRuntime.control(resource(scheduledID), operation: "resume")
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

        static func deadlineReminderChecks() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ label: String) throws {
                try StateMachineCheck.require(ok, label, &checks)
            }
            let suite = "orvlet-deadline-reminders-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            func isolatedModel() -> AppModel {
                let result = AppModel(defaults: defaults)
                result.settings.alarmSound = .silent
                result.settings.messageSound = .silent
                return result
            }
            let model = isolatedModel()
            defer {
                model.taskRuntime.stopAll()
                defaults.removePersistentDomain(forName: suite)
            }
            let markup = CardMarkup(html: "<strong data-bind='value'></strong>",
                                    compactHTML: "<span data-bind='value'></span>", css: "")
            let due = Date().addingTimeInterval(60)
            func add(_ format: TaskDataSource.Format, rule: CardReminderRule?, at anchor: Date? = nil) throws -> UUID {
                let id = UUID()
                var surface = TaskSurface(title: "Deadline", markup: markup, fields: [], actions: [], state: [:],
                    runtime: .init(sources: [.init(key: "value", kind: .deadline, format: format, anchor: (anchor ?? due).timeIntervalSince1970)]))
                surface.reminder = rule
                try model.commitTaskSurface(surface, id: id, ticket: nil)
                model.dismissTask(id)
                return id
            }
            let seconds = try add(.seconds, rule: .init(key: "value", condition: .atMost, value: "0", message: "Time is up"))
            let duration = try add(.duration, rule: .init(key: "value", condition: .equals, value: "00:00:00", message: "Time is up"))
            let brief = try add(.seconds, rule: .init(key: "value", condition: .equals, value: "0", message: "Done", persistence: .brief))
            let mislabeled = try add(.seconds, rule: .init(key: "value", condition: .atMost, value: "0", message: "Check the oven", delivery: .brief))
            let headsUp = try add(.seconds, rule: .init(key: "value", condition: .atMost, value: "10", message: "Ten seconds left", delivery: .brief))
            let display = try add(.seconds, rule: nil)
            let alreadyZero = try add(.seconds, rule: .init(key: "value", condition: .equals, value: "0", message: "Past"),
                                      at: .now.addingTimeInterval(-1))
            model.settings.alarmSound = .minuet
            model.settings.messageSound = .keys
            var tones: [ReminderSound] = []
            model.reminderSoundPlaybackCheck = { tone, _ in tones.append(tone) }
            model.taskRuntime.tick(now: due.addingTimeInterval(-5))
            for _ in 0..<100 where !model.reminders.contains(where: { $0.owner == headsUp }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(tones == [.keys] && model.reminders.first?.persistence == .brief,
                      "A generated advance notice uses the message sound once")
            model.taskRuntime.tick(now: due)
            for _ in 0..<100 where model.reminders.count < 5 { try await Task.sleep(for: .milliseconds(10)) }
            let notices = model.reminders
            try check(notices.count == 5 && Set(notices.filter { $0.persistence == .persistent }.map(\.owner)) == [seconds, duration, brief, mislabeled]
                      && tones.filter { $0 == .minuet }.count == 4 && tones.filter { $0 == .keys }.count == 1
                      && !notices.contains { $0.owner == display || $0.owner == alreadyZero },
                      "Hidden generated deadlines always use the alarm sound even when authored as brief; display-only deadlines stay silent")
            // Re-attach samples the next positive reading. An alarm that already rang still needs its own acknowledgement.
            if let source = model.work.view(seconds)?.selected { model.taskRuntime.attach(source) }
            await Task.yield()
            guard let notice = model.reminders.first(where: { $0.owner == seconds }) else {
                throw AppError.message("A later deadline reading erased its unacknowledged alarm")
            }
            model.dismissReminder(notice.id)
            try check(!model.reminders.contains { $0.owner == seconds } && model.reminders.contains { $0.owner == duration },
                      "Acknowledging one generated deadline leaves the other deadline visible")

            let away = try add(.seconds, rule: .init(key: "value", condition: .equals, value: "0", message: "Break over"))
            model.taskRuntime.stopAll()
            guard let source = model.work.view(away)?.selected, let artifact = model.work.artifact(source),
                  (Int(artifact.values["value"] ?? "") ?? 0) > 0,
                  model.work.update(source, expecting: artifact.revision, {
                      $0.definition.runtime?.sources[0].anchor = Date().addingTimeInterval(-60).timeIntervalSince1970
                  }) else { throw AppError.message("Could not prepare a deadline that passed while Orvlet was closed") }
            let resumed = isolatedModel()
            defer { resumed.taskRuntime.stopAll() }
            resumed.loadSideTasks()
            for _ in 0..<100 where !resumed.reminders.contains(where: { $0.owner == away }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let late = resumed.reminders.filter { $0.owner == away }
            try check(late.count == 1 && late.first?.persistence == .persistent && resumed.work.view(away)?.hidden == true,
                      "A hidden generated deadline that passes while Orvlet is closed raises one persistent alarm on return")
            resumed.taskRuntime.stopAll()
            let again = isolatedModel()
            defer { again.taskRuntime.stopAll() }
            again.loadSideTasks()
            await Task.yield()
            let replay = again.reminders.filter { $0.owner == away }
            try check(replay.count == 1 && replay.first?.id == late.first?.id,
                      "Relaunch restores the same unacknowledged generated alarm exactly once")
            if let event = replay.first { again.dismissReminder(event.id) }
            again.taskRuntime.stopAll()
            let acknowledged = isolatedModel()
            defer { acknowledged.taskRuntime.stopAll() }
            acknowledged.loadSideTasks()
            await Task.yield()
            try check(!acknowledged.reminders.contains { $0.owner == away },
                      "An acknowledged generated deadline stays quiet on relaunch")
            acknowledged.taskRuntime.stopAll()

            func addCondition() throws -> UUID {
                let id = UUID()
                var surface = TaskSurface(title: "Pickup", markup: markup, fields: [], actions: [], state: ["value": "1"])
                surface.reminder = .init(key: "value", condition: .atLeast, value: "2", message: "Ready", persistence: .persistent)
                try acknowledged.commitTaskSurface(surface, id: id, ticket: nil)
                acknowledged.dismissTask(id)
                return id
            }
            func update(_ model: AppModel, _ owner: UUID, to value: String, project: Bool = true) throws {
                guard let id = model.work.view(owner)?.selected, let item = model.work.artifact(id),
                      model.work.update(id, expecting: item.revision, { $0.values["value"] = value })
                else { throw AppError.message("Missing condition reminder fixture") }
                if project { model.projectWorkResult(id) }
            }
            let active = try addCondition(), cleared = try addCondition(), replaced = try addCondition()
            let owners: Set<UUID> = [active, cleared, replaced]
            for owner in owners { try update(acknowledged, owner, to: "2") }
            for _ in 0..<100 where acknowledged.reminders.filter({ owners.contains($0.owner) }).count < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard acknowledged.reminders.filter({ owners.contains($0.owner) }).count == 3,
                  let original = acknowledged.reminders.first(where: { $0.owner == active }),
                  var edited = acknowledged.work.view(replaced) else { throw AppError.message("Missing pending condition reminders") }
            try update(acknowledged, active, to: "3", project: false)
            try update(acknowledged, cleared, to: "1", project: false)
            edited.reminder = .init(key: "value", condition: .atLeast, value: "1", message: "Group ready", persistence: .persistent)
            try acknowledged.work.putView(edited)
            let conditionRestore = isolatedModel()
            defer { conditionRestore.taskRuntime.stopAll() }
            conditionRestore.loadSideTasks()
            try check(conditionRestore.reminders.filter { owners.contains($0.owner) }.map(\.id) == [original.id],
                      "Relaunch restores only the still-matching generated condition and keeps its original receipt")
            try update(conditionRestore, active, to: "1")
            for _ in 0..<100 where conditionRestore.reminders.contains(where: { $0.owner == active }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(!conditionRestore.reminders.contains { $0.owner == active },
                      "A restored condition reminder withdraws when the saved result clears")
            try update(conditionRestore, active, to: "2")
            for _ in 0..<100 where !conditionRestore.reminders.contains(where: { $0.owner == active }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let next = conditionRestore.reminders.first(where: { $0.owner == active }), next.id != original.id
            else { throw AppError.message("A resolved condition must rearm when crossed again") }
            conditionRestore.dismissReminder(next.id)
            conditionRestore.taskRuntime.stopAll()
            let confirmed = isolatedModel()
            defer { confirmed.taskRuntime.stopAll() }
            confirmed.loadSideTasks()
            await Task.yield()
            try check(!confirmed.reminders.contains { owners.contains($0.owner) },
                      "Acknowledged, cleared, and replaced conditions stay silent on the next relaunch")
            let decorated = try confirmed.startTimer(seconds: 60, title: "Tea")
            guard var view = confirmed.work.view(decorated), let index = confirmed.sideTasks.firstIndex(where: { $0.id == decorated })
            else { throw AppError.message("Missing native countdown fixture") }
            view.reminder = .init(key: "remainingSeconds", condition: .equals, value: "0", message: "Pour the tea",
                                  intensity: .strong, persistence: .brief)
            try confirmed.work.putView(view)
            try confirmed.projectWorkView(decorated)
            confirmed.settings.alarmSound = .tink
            var sounds: [ReminderIntensity] = []
            confirmed.reminderSoundPlaybackCheck = { _, intensity in sounds.append(intensity) }
            confirmed.sideTasks[index].deadline = .now.addingTimeInterval(-1)
            confirmed.tickTasks()
            await Task.yield()
            let tea = confirmed.reminders.filter { $0.owner == decorated }
            try check(tea.count == 1 && tea.first?.message == "Pour the tea" && tea.first?.intensity == .strong
                      && tea.first?.persistence == .persistent && sounds == [.strong],
                      "A decorated native countdown delivers one persistent alarm with its custom message and intensity")
            return checks
        }
    }
#endif
