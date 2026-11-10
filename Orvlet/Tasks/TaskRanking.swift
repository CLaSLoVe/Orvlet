import Foundation

/// Local, decaying preferences. No task content is retained in the habit store.
struct TaskHabits: Codable {
    struct Entry: Codable {
        var value = 0.0
        var samples = 0
        var updated = Date()
        var hours: [Int: Double] = [:]
        func decay(at date: Date) -> Double { pow(0.5, max(0, date.timeIntervalSince(updated)) / (14 * 86400)) }
    }
    var categories: [String: Entry] = [:]
    var tasks: [String: Entry] = [:]
    static func category(_ task: SideTask) -> String { task.isMediaTask ? "music" : task.kind.rawValue }
    var hasEvidence: Bool { categories.values.reduce(0) { $0 + $1.samples } >= 3 }
    mutating func record(_ task: SideTask, weight: Double, at date: Date) {
        let hour = Calendar.current.component(.hour, from: date) / 6
        func update(_ entry: Entry?) -> Entry {
            var e = entry ?? Entry(updated: date)
            let decay = e.decay(at: date)
            e.value = min(30, max(-15, e.value * decay + weight))
            e.hours = e.hours.mapValues { $0 * decay }
            e.hours[hour] = min(15, max(-8, (e.hours[hour] ?? 0) + weight))
            e.updated = date
            e.samples = min(10000, e.samples + 1)
            return e
        }
        let category = Self.category(task)
        categories[category] = update(categories[category])
        tasks[task.id.uuidString] = update(tasks[task.id.uuidString])
        if tasks.count > 128 {
            let keep = Set(tasks.sorted { $0.value.updated > $1.value.updated }.prefix(128).map(\.key))
            tasks = tasks.filter { keep.contains($0.key) }
        }
    }
    func score(_ task: SideTask, at date: Date) -> Double {
        let group = categories[Self.category(task)]
        let own = tasks[task.id.uuidString]
        let hour = Calendar.current.component(.hour, from: date) / 6
        return (own?.value ?? 0) * (own?.decay(at: date) ?? 1) * 0.6
            + (group?.value ?? 0) * (group?.decay(at: date) ?? 1) * 0.3
            + (group?.hours[hour] ?? 0) * (group?.decay(at: date) ?? 1) * 0.1
    }
    func payload(for tasks: [SideTask], at date: Date) -> [[String: Any]] {
        tasks.enumerated().map { index, task in
            [
                "candidate": index, "category": Self.category(task), "playing": task.playing,
                "timer_due_soon": task.kind == .timer && task.deadline != nil && task.remaining <= 60,
                "completed": task.finished, "habit_score": score(task, at: date),
                "samples": categories[Self.category(task)]?.samples ?? 0,
            ]
        }
    }
    func ranked(_ tasks: [SideTask], request: UUID?, judgments: [String: Double] = [:], at date: Date) -> [UUID] {
        guard hasEvidence else { return tasks.map(\.id) }
        func priority(_ task: SideTask) -> Int {
            if task.id == request { return 3 }
            if task.kind == .timer
                && ((task.finished && task.status != "Stopped") || (task.deadline != nil && task.remaining <= 60))
            {
                return 2
            }
            if task.isMediaTask && task.playing { return 1 }
            return 0
        }
        func value(_ pair: (offset: Int, element: SideTask)) -> Int {
            let judgment = judgments["task_\(pair.offset)"] ?? 0.5
            let advice = judgment.isFinite && (0...1).contains(judgment) ? (judgment - 0.5) * 4 : 0
            return Int(floor((score(pair.element, at: date) + advice) / 3))
        }
        return tasks.enumerated().sorted { a, b in
            let pa = priority(a.element)
            let pb = priority(b.element)
            if pa != pb { return pa > pb }
            let va = value(a)
            let vb = value(b)
            return va == vb ? a.offset < b.offset : va > vb
        }.map { $0.element.id }
    }
}

@MainActor
final class TaskRanking {
    enum Signal: String { case open, control, promote, demote, hide }
    weak var model: AppModel?
    private(set) var habits: TaskHabits
    private var job: Task<Void, Never>?
    private(set) var revision = 0
    private var lastSignals: [String: Date] = [:]
    private var lastJev = Date.distantPast
    init(model: AppModel) {
        self.model = model
        habits =
            model.preferences.data(forKey: "taskHabits.v1").flatMap {
                try? JSONDecoder().decode(TaskHabits.self, from: $0)
            } ?? TaskHabits()
    }
    func record(_ id: UUID, _ signal: Signal, at date: Date = Date()) {
        guard let model, let task = model.sideTasks.first(where: { $0.id == id }) else { return }
        let key = id.uuidString + signal.rawValue
        guard date.timeIntervalSince(lastSignals[key] ?? .distantPast) >= 10 else { return }
        lastSignals = lastSignals.filter { date.timeIntervalSince($0.value) < 60 }
        lastSignals[key] = date
        let weight: Double
        switch signal {
        case .open: weight = 1
        case .control: weight = 1.5
        case .promote: weight = 4
        case .demote: weight = -2
        case .hide: weight = -3
        }
        habits.record(task, weight: weight, at: date)
        if !model.isLiveTest, model.persistHistory, let data = try? JSONEncoder().encode(habits) {
            model.preferences.set(data, forKey: "taskHabits.v1")
        }
        schedule()
    }
    func schedule() {
        revision += 1
        job?.cancel()
        job = nil
        guard let model, model.sessionStarted, !model.isLiveTest else { return }
        job = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                await self?.refresh()
            } catch {}
        }
    }
    func refresh() async {
        guard let model, canApply, habits.hasEvidence else { return }
        let stamp = revision
        let candidates = model.orderedTasks.filter { !$0.hidden }
        guard candidates.count > 1 else { return }
        let now = Date()
        var judgments: [String: Double] = [:]
        let endpoint = model.settings.fast
        // Only the approved destination receives the anonymous, allowlisted summary.
        if model.settings.useFast, !model.isLiveTest, now.timeIntervalSince(lastJev) >= 300,
            URL(string: endpoint.baseURL)?.host == "api.typesafe.ai", URL(string: endpoint.baseURL)?.scheme == "https"
        {
            lastJev = now
            if let key = try? await SecretStore.loadAvailable(model.settings.fastKeyAccount), !key.isEmpty,
                !Task.isCancelled
            {
                judgments =
                    (try? await Self.judge(habits: habits, tasks: candidates, endpoint: endpoint, key: key, at: now))
                    ?? [:]
            }
        }
        let ids = habits.ranked(candidates, request: model.ambientRequestID, judgments: judgments, at: now)
        apply(ids, revision: stamp, candidates: candidates.map(\.id))
    }
    static func judge(habits: TaskHabits, tasks: [SideTask], endpoint: Endpoint, key: String, at date: Date)
        async throws -> [String: Double]
    {
        let tasks = Array(tasks.prefix(24))
        let questions = Dictionary(
            uniqueKeysWithValues: tasks.indices.map { index in
                (
                    "task_\(index)",
                    "Does candidate \(index) need convenient access now, based on repeated user habits and current activity? Prefer repeated deliberate use over passive duration. No evidence means uncertain. Judge this candidate only."
                )
            })
        return try await JevClient.judge(
            endpoint: endpoint, key: key,
            state: ["candidates": habits.payload(for: tasks, at: date)], questions: questions, timeout: 1.5)
    }
    var canApply: Bool {
        guard let model else { return false }
        return model.taskOrder.isEmpty && !model.shellExpanded && !model.pointerInside && !model.commandPanelVisible
            && !model.menuTracking && !model.stackHasKeyboardFocus && !model.hasTaskWork && model.feedback == nil
    }
    func apply(_ ids: [UUID], revision stamp: Int, candidates: [UUID]) {
        guard let model, !Task.isCancelled, revision == stamp, canApply,
            model.orderedTasks.filter({ !$0.hidden }).map(\.id) == candidates,
            ids.count == candidates.count, Set(ids) == Set(candidates)
        else { return }
        if model.learnedTaskOrder != ids {
            model.learnedTaskOrder = ids
            model.onResize?(model.windowSize)
        }
    }
}
