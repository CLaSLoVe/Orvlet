#if DEBUG
    import AppKit

    @MainActor
    enum TaskRankingCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            let now = Date()
            let a = SideTask(kind: .workspace, title: "PRIVATE_TITLE")
            var b = SideTask(kind: .calendar, title: "Another private title")
            b.sourceURL = "https://private.invalid/secret"
            var habits = TaskHabits()
            try check(
                habits.ranked([a, b], request: nil, at: now) == [a.id, b.id],
                "No history preserves the familiar default order")
            for n in 0..<8 { habits.record(b, weight: 1.5, at: now.addingTimeInterval(Double(n) * 20)) }
            let later = now.addingTimeInterval(160)
            try check(
                habits.ranked([a, b], request: nil, at: later) == [b.id, a.id],
                "Repeated deliberate use promotes a task")
            let c = SideTask(kind: .calendar, title: "New event")
            try check(
                habits.score(c, at: later) > habits.score(a, at: later),
                "Category habits generalize to new tasks without storing their content")
            try check(
                habits.score(b, at: later.addingTimeInterval(28 * 86400)) < habits.score(b, at: later) / 2,
                "Old habits decay rather than locking the user in forever")
            let snapshot = try JSONDecoder().decode(TaskHabits.self, from: JSONEncoder().encode(habits))
            try check(
                snapshot.ranked([a, b], request: nil, at: later) == [b.id, a.id], "Habit history survives serialization"
            )
            let payload = JSONText.encode(habits.payload(for: [a, b], at: later))
            try check(
                !payload.contains("PRIVATE_TITLE") && !payload.contains("private.invalid")
                    && !payload.contains(a.id.uuidString) && !payload.contains("Another private"),
                "Jev payload contains no titles, URLs, or persistent task IDs")
            try check(
                habits.ranked([a, b], request: a.id, at: later).first == a.id,
                "The current request remains accessible despite established habits")
            var urgent = SideTask(kind: .timer, title: "Due")
            urgent.deadline = Date().addingTimeInterval(30)
            var music = SideTask(kind: .web, title: "Music")
            music.listening = true
            music.playing = true
            try check(
                habits.ranked([b, music, urgent], request: nil, at: later) == [urgent.id, music.id, b.id],
                "An imminent timer and playing music keep direct controls available")
            try check(
                habits.ranked([a, b], request: nil, judgments: ["task_0": .infinity, "task_1": -10], at: later) == [
                    b.id, a.id,
                ], "Malformed model probabilities cannot corrupt the ranking")
            let answer = try await TaskRanking.judge(
                habits: habits, tasks: [a, b],
                endpoint: Endpoint(baseURL: "http://127.0.0.1:19244/v1", model: "fixture"), key: "TEST_ONLY", at: later)
            try check(
                answer.count == 2 && answer.values.allSatisfy { (0...1).contains($0) },
                "The typed Jev request and response work against the local fixture")
            let suite = "orvlet.habits." + UUID().uuidString
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            store.set(try JSONEncoder().encode(habits), forKey: "taskHabits.v1")
            let model = AppModel(defaults: store)
            model.isLiveTest = true
            model.persistHistory = false
            model.sideTasks = [a, b]
            try check(model.taskRanking.habits.hasEvidence, "A fresh model loads learned habits from local storage")
            let count = model.taskRanking.habits.categories["workspace"]?.samples ?? 0
            model.taskRanking.record(a.id, .open, at: later)
            model.taskRanking.record(a.id, .open, at: later.addingTimeInterval(1))
            try check(
                model.taskRanking.habits.categories["workspace"]?.samples == count + 1,
                "Rapid repeated clicks do not manufacture a habit")
            let candidates = model.orderedTasks.map(\.id)
            let revision = model.taskRanking.revision
            model.pointerInside = true
            model.taskRanking.apply([b.id, a.id], revision: revision, candidates: candidates)
            try check(model.learnedTaskOrder.isEmpty, "No reordering while the pointer is on the interface")
            model.pointerInside = false
            model.taskRanking.apply([b.id, a.id], revision: revision, candidates: candidates)
            try check(
                model.orderedTasks.map(\.id) == [b.id, a.id], "A valid recommendation applies only at a quiet boundary")
            model.moveTask(a.id, before: b.id)
            model.taskRanking.apply([b.id, a.id], revision: model.taskRanking.revision, candidates: [a.id, b.id])
            try check(
                model.orderedTasks.map(\.id) == [a.id, b.id],
                "Manual drag order cannot be overwritten by a model response")
            model.resetTaskOrder()
            let stale = model.taskRanking.revision
            model.taskRanking.record(b.id, .hide, at: later)
            model.taskRanking.apply([b.id, a.id], revision: stale, candidates: [a.id, b.id])
            try check(model.learnedTaskOrder.isEmpty, "New human interaction invalidates an older recommendation")
            model.taskRanking.apply([a.id, a.id], revision: model.taskRanking.revision, candidates: [a.id, b.id])
            try check(model.learnedTaskOrder.isEmpty, "Duplicate or missing IDs cannot drop a task")
            return checks
        }
        static func live(_ model: AppModel) async {
            model.isLiveTest = true
            model.persistHistory = false
            var report: [String: Any] = [
                "ok": false, "scope": "Synthetic anonymous categories and aggregate usage only",
            ]
            do {
                let key = try await SecretStore.loadAvailable("fast")
                guard !key.isEmpty else { throw AppError.message("Jev key is unavailable") }
                let endpoint = model.settings.fast
                guard URL(string: endpoint.baseURL)?.host == "api.typesafe.ai" else {
                    throw AppError.message("Configured endpoint differs from approved endpoint")
                }
                let now = Date()
                let a = SideTask(kind: .workspace, title: "Synthetic")
                let b = SideTask(kind: .timer, title: "Synthetic timer")
                var habits = TaskHabits()
                for _ in 0..<5 { habits.record(a, weight: 1, at: now) }
                let start = Date()
                let answers = try await TaskRanking.judge(
                    habits: habits, tasks: [a, b], endpoint: endpoint, key: key, at: now)
                report["ok"] = answers.count == 2 && answers.values.allSatisfy { $0.isFinite && (0...1).contains($0) }
                report["elapsedMilliseconds"] = Date().timeIntervalSince(start) * 1000
                report["answerCount"] = answers.count
            } catch { report["error"] = String(describing: type(of: error)) }
            try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(
                to: URL(fileURLWithPath: "/tmp/orvlet-ranking-live.json"))
            exit(report["ok"] as? Bool == true ? 0 : 1)
        }
    }
#endif
