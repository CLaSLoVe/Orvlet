import Foundation

/// Data and scheduling are capabilities owned by the host, independent of HTML.
struct TaskDataSource: Codable, Equatable {
    enum Kind: String, Codable { case clock, elapsed, deadline }
    enum Format: String, Codable { case time, date, iso, seconds, duration }
    var key: String
    var kind: Kind
    var format: Format
    var timeZone: String? = nil
    var hour12: Bool? = nil
    var anchor: Double? = nil  // Unix seconds; elapsed defaults to request time.
    func value(at now: Date) -> String {
        if kind != .clock {
            let value = max(
                0,
                kind == .elapsed
                    ? now.timeIntervalSince1970 - (anchor ?? now.timeIntervalSince1970)
                    : (anchor ?? now.timeIntervalSince1970) - now.timeIntervalSince1970)
            let seconds = Int(value.rounded(kind == .deadline ? .up : .down))
            return format == .seconds
                ? String(seconds) : String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        if format == .seconds { return String(Int(now.timeIntervalSince1970)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        switch format {
        case .time: formatter.dateFormat = hour12 == true ? "h:mm:ss a" : "HH:mm:ss"
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        default: formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        }
        return formatter.string(from: now)
    }
}

struct TaskRefresh: Codable, Equatable {
    var code: String
    var intervalSeconds: Double
    var outputKeys: [String]
    var initialValues: [String: String]? = nil  // Host snapshot for deterministic restart.
}
struct TaskRuntimeSpec: Codable, Equatable {
    var sources: [TaskDataSource]
    var refresh: TaskRefresh? = nil
    var keys: Set<String> { Set(sources.map(\.key) + (refresh?.outputKeys ?? [])) }
    func validated(fields: [String], at date: Date) throws -> TaskRuntimeSpec {
        var result = self
        guard !sources.isEmpty || refresh != nil, sources.count <= 12,
            keys.count == sources.count + (refresh?.outputKeys.count ?? 0), keys.count <= 24,
            keys.isDisjoint(
                with: Set(fields).union(["title", "status", "detail", "runtimeStatus", "clockLocationLabel"])),
            keys.allSatisfy({ $0.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,31}$"#, options: .regularExpression) != nil })
        else {
            throw AppError.message(
                "Runtime outputs need unique named keys, separate from input fields and host state.")
        }
        for index in result.sources.indices {
            let source = result.sources[index]
            guard source.timeZone == nil || TimeZone(identifier: source.timeZone!) != nil else {
                throw AppError.message("Use an IANA time zone for the actual requested place.")
            }
            guard source.kind == .clock ? source.format != .duration : [.duration, .seconds].contains(source.format)
            else {
                throw AppError.message(
                    "Choose time/date/iso/seconds for a clock source and duration/seconds for elapsed/deadline.")
            }
            if source.kind == .deadline && source.anchor == nil {
                throw AppError.message("A deadline source requires Unix seconds for its actual deadline.")
            }
            if let anchor = source.anchor, !anchor.isFinite || abs(anchor) > 1e11 {
                throw AppError.message("Invalid source anchor.")
            }
            if source.kind == .elapsed && source.anchor == nil {
                result.sources[index].anchor = date.timeIntervalSince1970
            }
            if source.kind == .clock && source.timeZone == nil {
                result.sources[index].timeZone = TimeZone.current.identifier
            }
        }
        if let refresh {
            guard refresh.intervalSeconds.isFinite, (1...3600).contains(refresh.intervalSeconds),
                !refresh.code.isEmpty, refresh.code.utf8.count <= 32768, !refresh.outputKeys.isEmpty
            else {
                throw AppError.message(
                    "Scheduled pure-code updates need a 1–3600 second interval, code, and declared outputKeys.")
            }
            if let initial = refresh.initialValues {
                guard Set(initial.keys) == Set(refresh.outputKeys),
                    initial.values.allSatisfy({ $0.utf8.count <= 16000 })
                else {
                    throw AppError.message("Restart values must match the declared scheduled outputs.")
                }
            }
        }
        return result
    }
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "sources": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"],
                        "kind": ["type": "string", "enum": ["clock", "elapsed", "deadline"]],
                        "format": [
                            "type": "string", "enum": ["time", "date", "iso", "seconds", "duration"],
                            "description":
                                "Clock: time=HH:mm:ss including seconds in timeZone; date=local date; iso=technical timestamp; seconds=Unix epoch integer, independent of timeZone, only if explicitly requested. Elapsed/deadline: seconds=interval count, duration=HH:mm:ss.",
                        ],
                        "timeZone": [
                            "type": "string", "description": "IANA zone for clock, e.g. Asia/Shanghai or Europe/London",
                        ],
                        "anchor": [
                            "type": "number",
                            "description":
                                "Unix seconds. Required for deadline; omit for elapsed starting with this request.",
                        ],
                    ], "required": ["key", "kind", "format"],
                ],
            ],
            "refresh": [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description":
                            "Pure synchronous function body(input,state). Use input.now (Unix milliseconds). Return {state:{...}} containing only declared outputKeys. No network, timers or side effects.",
                    ], "intervalSeconds": ["type": "number"],
                    "outputKeys": ["type": "array", "items": ["type": "string"]],
                ], "required": ["code", "intervalSeconds", "outputKeys"],
            ],
        ], "required": ["sources"],
    ]
}

struct TaskRuntimeState: Codable {
    enum Phase: String, Codable { case running, paused, stopped, stale }
    var phase: Phase = .running
    var pausedAt: Date? = nil
    var lastSuccess: Date? = nil
}

/// One local scheduler with a narrow task store and pure-code executor.
/// Hidden/collapsed tasks keep running. Closing disposes them. Stale results never commit.
@MainActor
final class TaskRuntimeEngine {
    private unowned let store: any RuntimeTaskStore
    private let code: any TaskCodeExecuting
    private let onFailure: (UUID, Int, Error) -> Void
    struct Receipt {
        var generation: UUID
        var samples = 0
        var prepared = false
        var updated: Date?
        var values: [String: String] = [:]
    }
    private(set) var receipts: [UUID: Receipt] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var due: [UUID: Date] = [:]
    private var sourceDue: [UUID: Date] = [:]
    private var lastCheckpoint = Date.distantPast
    private var failures: [UUID: Int] = [:]
    private var timer: Timer?
    init(
        store: any RuntimeTaskStore, code: any TaskCodeExecuting,
        onFailure: @escaping (UUID, Int, Error) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.code = code
        self.onFailure = onFailure
    }
    func attach(_ id: UUID) {
        detach(id)
        guard let task = store.runtimeTask(id) else { return }
        guard let checked = try? task.spec.validated(fields: task.fields, at: Date()) else {
            store.updateRuntimeTask(id) {
                $0.dataIssue = "This saved task needs to be recreated."
                $0.state = TaskRuntimeState(phase: .stopped)
            }
            return
        }
        store.updateRuntimeTask(id) { $0.spec = checked }
        receipts[id] = Receipt(generation: UUID())
        due[id] = checked.refresh.map { Date().addingTimeInterval($0.intervalSeconds) } ?? .distantPast
        let phase = task.state.phase
        if let refresh = checked.refresh, refresh.intervalSeconds > 3, phase == .running || phase == .stale {
            let generation = receipts[id]!.generation
            let input = refreshInput(task, now: Date())
            jobs[id] = Task { [weak self] in
                guard let self else { return }
                defer { if receipts[id]?.generation == generation { jobs[id] = nil } }
                do {
                    _ = try await runRefresh(refresh, input: input, state: task.values)
                    try Task.checkCancellation()
                    guard receipts[id]?.generation == generation else { return }
                    receipts[id]?.prepared = true
                    store.updateRuntimeTask(id) { $0.status = "Scheduled" }
                } catch is CancellationError {} catch { fail(id, generation: generation, error: error) }
            }
        }
        startScheduler()
        tick()
    }
    func detach(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel()
        receipts[id] = nil
        due[id] = nil
        sourceDue[id] = nil
        failures[id] = nil
        if receipts.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
    func stopAll() { for id in Array(receipts.keys) { detach(id) } }
    private func startScheduler() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func refreshInput(_ task: RuntimeTask, now: Date) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: task.fields.map { ($0, task.values[$0] ?? "" as Any) })
            .merging(["now": now.timeIntervalSince1970 * 1000]) { _, new in new }
    }
    private func runRefresh(_ refresh: TaskRefresh, input: [String: Any], state: [String: String]) async throws
        -> [String: String]
    {
        let output = try TaskValues.decode(try await code.run(code: refresh.code, input: input, state: state))
        guard Set(output.keys) == Set(refresh.outputKeys) else {
            throw AppError.message("Scheduled output keys must match outputKeys exactly.")
        }
        return output
    }
    func tick(now: Date = Date()) {
        for id in Array(receipts.keys) {
            guard let task = store.runtimeTask(id) else {
                detach(id)
                continue
            }
            let spec = task.spec
            guard task.state.phase == .running || task.state.phase == .stale else { continue }
            // Native sources keep their own cadence and cannot clear a reducer's failure.
            if spec.refresh != nil, !spec.sources.isEmpty, now >= (sourceDue[id] ?? .distantPast) {
                let values = Dictionary(uniqueKeysWithValues: spec.sources.map { ($0.key, $0.value(at: now)) })
                store.updateRuntimeTask(id) { $0.values.merge(values) { _, new in new } }
                receipts[id]?.values.merge(values) { _, new in new }
                sourceDue[id] = now.addingTimeInterval(1)
            }
            guard now >= (due[id] ?? .distantPast), jobs[id] == nil, !store.hasTaskAction(id) else { continue }
            let generation = receipts[id]!.generation
            let sourceValues = Dictionary(uniqueKeysWithValues: spec.sources.map { ($0.key, $0.value(at: now)) })
            due[id] = now.addingTimeInterval(spec.refresh?.intervalSeconds ?? 1)
            if let refresh = spec.refresh {
                let state = task.values.merging(sourceValues) { _, new in new }
                let input = refreshInput(task, now: now)
                jobs[id] = Task { [weak self] in
                    guard let self else { return }
                    defer { if receipts[id]?.generation == generation { jobs[id] = nil } }
                    do {
                        let output = try await runRefresh(refresh, input: input, state: state)
                        try Task.checkCancellation()
                        commit(
                            id, generation: generation, values: sourceValues.merging(output) { _, new in new },
                            date: Date())
                    } catch is CancellationError {} catch { fail(id, generation: generation, error: error) }
                }
            } else {
                commit(id, generation: generation, values: sourceValues, date: now)
            }
        }
    }
    private func commit(_ id: UUID, generation: UUID, values: [String: String], date: Date) {
        guard receipts[id]?.generation == generation else { return }
        guard
            store.updateRuntimeTask(
                id,
                {
                    $0.values.merge(values) { _, new in new }
                    $0.dataUpdatedAt = date
                    $0.dataIssue = nil
                    $0.state = TaskRuntimeState(phase: .running, lastSuccess: date)
                    $0.status = "Running"
                })
        else { return }
        failures[id] = nil
        receipts[id]?.samples += 1
        receipts[id]?.updated = date
        receipts[id]?.values = values
        // Checkpoint evolving reducer state without writing every clock tick.
        if date.timeIntervalSince(lastCheckpoint) >= 10 {
            lastCheckpoint = date
            store.checkpointRuntime()
        }
    }
    private func fail(_ id: UUID, generation: UUID, error: Error) {
        guard receipts[id]?.generation == generation else { return }
        guard
            store.updateRuntimeTask(
                id,
                {
                    $0.state = TaskRuntimeState(phase: .stale, lastSuccess: receipts[id]?.updated)
                    $0.status = "Update unavailable"
                    $0.dataIssue = "Updates are temporarily unavailable. The last value is kept while retrying."
                })
        else { return }
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        due[id] = Date().addingTimeInterval(min(60, pow(2, Double(count))))
        onFailure(id, count, error)
        store.checkpointRuntime()
    }
    func control(_ id: UUID, operation: String) {
        guard let task = store.runtimeTask(id) else { return }
        let old = task.state
        let operation =
            operation == "toggle" ? (old.phase == .paused || old.phase == .stopped ? "resume" : "pause") : operation
        // Unknown controls must not cancel work or change its generation.
        guard ["pause", "stop", "resume", "restart", "refresh"].contains(operation) else { return }
        let now = Date()
        detach(id)
        store.updateRuntimeTask(id) { task in
            task.resumeOnHistoryRestore = nil
            switch operation {
            case "pause", "stop":
                // Repeated pause/stop preserves the start of the paused interval.
                task.state = TaskRuntimeState(
                    phase: operation == "pause" ? .paused : .stopped,
                    pausedAt: old.pausedAt ?? now, lastSuccess: old.lastSuccess)
                task.status = operation == "pause" ? "Paused" : "Stopped"
            default:
                if operation == "restart", let initial = task.spec.refresh?.initialValues {
                    task.values.merge(initial) { _, new in new }
                }
                for index in task.spec.sources.indices where task.spec.sources[index].kind == .elapsed {
                    if operation == "restart" {
                        task.spec.sources[index].anchor = now.timeIntervalSince1970
                    } else if let pausedAt = old.pausedAt {
                        task.spec.sources[index].anchor =
                            (task.spec.sources[index].anchor ?? now.timeIntervalSince1970)
                            + now.timeIntervalSince(pausedAt)
                    }
                }
                task.state = TaskRuntimeState()
            }
        }
        if ["resume", "restart", "refresh"].contains(operation) {
            attach(id)
            if operation == "refresh" {
                due[id] = .distantPast
                tick()
            }
        }
        store.checkpointRuntime()
    }
    /// Invalidate a pending refresh before user input or an execution revision.
    func inputsChanged(_ id: UUID) { if receipts[id] != nil { attach(id) } }
    func verify(_ id: UUID) async throws {
        guard let task = store.runtimeTask(id), let initial = receipts[id] else {
            throw AppError.message("This continuing task has no active runtime.")
        }
        let interval = task.spec.refresh?.intervalSeconds ?? 1
        let deadline = Date().addingTimeInterval(min(10, interval * 2 + 3))
        while Date() < deadline {
            try Task.checkCancellation()
            guard let receipt = receipts[id], receipt.generation == initial.generation else {
                throw CancellationError()
            }
            if interval > 3, receipt.prepared, due[id] != nil, store.runtimeTask(id)?.state.phase == .running { return }
            // Long intervals verify preparation; short intervals must execute twice.
            if receipt.samples >= (interval > 3 ? 1 : 2), let updated = receipt.updated,
                Date().timeIntervalSince(updated) < max(2, interval + 1), store.runtimeTask(id)?.state.phase == .running
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppError.message(
            "The ongoing data source did not produce fresh scheduled samples. Repair runtime before finishing.")
    }
}
