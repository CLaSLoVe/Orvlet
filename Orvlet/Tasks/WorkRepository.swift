import Foundation

/// Durable work has no dependency on a window, a card ID or rendered markup.
struct WorkGoal: Codable, Identifiable {
    enum Status: String, Codable { case running, completed, partial, waiting, stopped }
    let id: UUID
    var request: String
    var status: Status = .running
    var results: [UUID] = []
}

struct WorkAttempt: Codable, Identifiable {
    let id: UUID
    let goalID: UUID
    var started = Date()
    var finished: Date?
    var operations: [String] = []
}

/// Executable operations survive changing, hiding or replacing a view.
struct WorkDefinition: Codable {
    var fields: [String] = []
    var actions: [TaskSurfaceAction] = []
    var apiData: APIDataSpec?
    var runtime: TaskRuntimeSpec?
    var journal: ActionJournalSpec?
}

struct WorkArtifact: Codable, Identifiable {
    let id: UUID
    var goalID: UUID?
    var title: String
    var values: [String: String]
    var definition: WorkDefinition
    var source: String?
    var evidence: Data?
    var file: WorkFile?
    var revision = 1
    var checked = Date()
    var status = "Ready"
    var issue: String?
    var journalHistory: JournalHistory?
    var runtimeState: TaskRuntimeState?
    // Compatibility resource adapter for native timers, calendar and owned pages.
    // The resource ID survives closing or replacing any of its views.
    var native: SideTask?
}

/// A suggested rendering is separate from the executable definition and result.
struct WorkDesign: Codable {
    var markup: CardMarkup?
    var card: DataCardPreset?
    var preset: String?
}

struct WorkView: Codable, Identifiable {
    enum Layout: String, Codable { case single, together, select }
    let id: UUID
    var artifacts: [UUID]
    var selected: UUID
    var layout: Layout
    var title: String
    var markup: CardMarkup?
    var hidden = false
    // Absent in older archives. A closed view is not a hidden shelf entry.
    // Retain its identity so resource updates cannot recreate it implicitly.
    var closed: Bool?
    var height: Double?
    var draftInputs: [String:String]?
    var inputIssue: String?
    var reminder: CardReminderRule?
}

/// Main-actor commits are atomic. View edits never advance result revisions.
@MainActor
final class WorkRepository {
    struct Snapshot: Codable {
        var goals: [UUID: WorkGoal] = [:]
        var attempts: [UUID: WorkAttempt] = [:]
        var artifacts: [UUID: WorkArtifact] = [:]
        var designs: [UUID: WorkDesign] = [:]
        var views: [UUID: WorkView] = [:]
    }
    private(set) var snapshot = Snapshot()
    private let defaults: UserDefaults
    init(defaults: UserDefaults, recoverInterrupted: Bool = false) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "work.v1"), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
            guard recoverInterrupted else { return }
            // An in-flight operation belongs to the previous process. Preserve its
            // evidence, but never advertise that it is still executing after restart.
            for id in snapshot.goals.keys where snapshot.goals[id]?.status == .running {
                snapshot.goals[id]?.status = .partial
            }
            for id in snapshot.attempts.keys where snapshot.attempts[id]?.finished == nil {
                snapshot.attempts[id]?.finished = Date()
            }
            for id in snapshot.artifacts.keys where snapshot.artifacts[id]?.status == "Updating…" {
                snapshot.artifacts[id]?.status = "Update unavailable"
                snapshot.artifacts[id]?.issue = "The update was interrupted. Refresh to try again."
            }
            save()
        }
    }
    func save() {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: "work.v1") }
    }
    func begin(goalID: UUID, runID: UUID, request: String) {
        if snapshot.goals[goalID] == nil { snapshot.goals[goalID] = WorkGoal(id: goalID, request: request) }
        snapshot.attempts[runID] = WorkAttempt(id: runID, goalID: goalID)
        save()
    }
    func record(runID: UUID, operation: String) {
        snapshot.attempts[runID]?.operations.append(operation)
    }
    func finish(goalID: UUID, runID: UUID, status: WorkGoal.Status) {
        snapshot.attempts[runID]?.finished = Date()
        snapshot.goals[goalID]?.status = status
        save()
    }
    @discardableResult
    func retain(title: String, values: [String: String], definition: WorkDefinition, design: WorkDesign,
                goalID: UUID?, replacing id: UUID? = nil, source: String? = nil, evidence: Data? = nil, file: WorkFile? = nil) -> UUID {
        let id = id ?? UUID()
        let prior = snapshot.artifacts[id]
        var artifact = WorkArtifact(id: id, goalID: goalID ?? prior?.goalID, title: title, values: values,
                                    definition: definition, source: source, evidence: evidence, file: file)
        artifact.revision = (prior?.revision ?? 0) + 1
        artifact.runtimeState = prior?.runtimeState
        if let spec = definition.journal {
            if let prior, let previousSpec = prior.definition.journal, previousSpec.valueKey == spec.valueKey,
                previousSpec.scope == spec.scope {
                artifact.journalHistory = prior.journalHistory
                artifact.values[spec.valueKey] = prior.values[spec.valueKey]
            }
            artifact.rollJournal(to: Date())
        }
        snapshot.artifacts[id] = artifact
        snapshot.designs[id] = design
        if let goalID, snapshot.goals[goalID]?.results.contains(id) == false { snapshot.goals[goalID]?.results.append(id) }
        save()
        return id
    }
    func link(_ id: UUID, to goalID: UUID) {
        guard snapshot.artifacts[id] != nil, snapshot.goals[goalID] != nil,
            snapshot.goals[goalID]?.results.contains(id) == false else { return }
        snapshot.goals[goalID]?.results.append(id)
    }
    func artifact(_ id: UUID) -> WorkArtifact? { snapshot.artifacts[id] }
    func view(_ id: UUID) -> WorkView? { snapshot.views[id] }
    func hasOpenView(for artifact: UUID) -> Bool {
        snapshot.views.values.contains { $0.closed != true && $0.artifacts.contains(artifact) }
    }
    func design(_ id: UUID) -> WorkDesign? { snapshot.designs[id] }
    func putView(_ view: WorkView) throws {
        guard !view.artifacts.isEmpty, view.artifacts.allSatisfy({ snapshot.artifacts[$0] != nil }),
            view.artifacts.contains(view.selected), Set(view.artifacts).count == view.artifacts.count else {
            throw AppError.message("Choose retained results for this view.")
        }
        snapshot.views[view.id] = view
        save()
    }
    func hideView(_ id: UUID) { snapshot.views[id]?.hidden = true; save() }
    func showView(_ id: UUID) {
        snapshot.views[id]?.hidden = false
        snapshot.views[id]?.closed = nil
        save()
    }
    func closeView(_ id: UUID) {
        snapshot.views[id]?.hidden = true
        snapshot.views[id]?.closed = true
        save()
    }
    func removeView(_ id: UUID) { snapshot.views[id] = nil; save() }
    /// A late operation cannot overwrite a newer definition or user operation.
    @discardableResult
    func update(_ id: UUID, expecting revision: Int, persist: Bool = true, advanceRevision: Bool = true, _ mutate: (inout WorkArtifact) -> Void) -> Bool {
        guard var artifact = snapshot.artifacts[id], artifact.revision == revision else { return false }
        mutate(&artifact)
        if advanceRevision { artifact.revision += 1 }
        snapshot.artifacts[id] = artifact
        for viewID in snapshot.views.keys {
            guard let view = snapshot.views[viewID], view.selected == id, let draft = view.draftInputs,
                draft.allSatisfy({ artifact.values[$0.key] == $0.value }) else { continue }
            snapshot.views[viewID]?.draftInputs = nil
            snapshot.views[viewID]?.inputIssue = nil
        }
        if persist { save() }
        return true
    }
    func matching(_ spec: APIDataSpec, values: [String: String]) -> UUID? {
        guard let identity = spec.readingIdentity(values) else { return nil }
        return snapshot.artifacts.values.first {
            guard var source = $0.definition.apiData else { return false }
            source.card = snapshot.designs[$0.id]?.card
            return source.readingIdentity($0.values) == identity
        }?.id
    }
    func syncNative(_ task: SideTask, goalID: UUID?) -> UUID {
        let existing = snapshot.artifacts.values.first { $0.native?.id == task.id }
        let id = existing?.id ?? UUID()
        var resource = task
        resource.artifactIDs = nil
        resource.hidden = false
        resource.markup = nil
        resource.plan?.markup = nil
        var artifact = existing ?? WorkArtifact(id:id,goalID:goalID,title:task.title,values:task.state,definition:WorkDefinition())
        artifact.title = task.title
        artifact.values = task.state
        artifact.native = resource
        artifact.source = task.sourceURL
        artifact.status = task.status
        artifact.definition.actions = task.allowedActions.subtracting(["expand","dismiss","source","calendar"]).sorted().map {
            TaskSurfaceAction(id:$0,kind:.resource,operation:$0)
        }
        snapshot.artifacts[id] = artifact
        // A page can publish its designed card after its first (plain page) observation.
        // Keep that design before stripping markup from the resource snapshot.
        if task.kind == .web, let markup = task.plan?.markup {
            snapshot.designs[id] = WorkDesign(markup: markup)
        } else if task.kind == .web, let existing, existing.source != task.sourceURL {
            snapshot.designs[id] = WorkDesign()
        } else if snapshot.designs[id] == nil {
            snapshot.designs[id] = WorkDesign(markup: task.markup ?? task.plan?.markup)
        }
        if var view = snapshot.views[task.id] {
            view.hidden = view.closed == true || task.hidden
            snapshot.views[task.id] = view
        }
        else { snapshot.views[task.id] = WorkView(id:task.id,artifacts:[id],selected:id,layout:.single,title:task.title,hidden:task.hidden) }
        if let goalID, snapshot.goals[goalID]?.results.contains(id) == false { snapshot.goals[goalID]?.results.append(id) }
        return id
    }
}

extension WorkDefinition {
    init(surface: TaskSurface) {
        fields = surface.fields
        actions = surface.actions
        apiData = surface.apiData
        apiData?.card = nil
        apiData?.customLayout = nil
        runtime = surface.runtime
        journal = surface.journal
    }
}

@MainActor
extension AppModel {
    /// Import a legacy surface once. Thereafter it is a materialized view of work.
    func migrateWorkSurface(_ task: SideTask) {
        guard work.view(task.id) == nil, let surface = task.taskSurface else { return }
        let artifact = work.retain(title: task.title, values: task.liveValues ?? surface.state,
            definition: WorkDefinition(surface: surface),
            design: WorkDesign(markup: surface.markup, card: surface.apiData?.card, preset: surface.preset),
            goalID: nil, source: task.sourceURL, file: task.workFile)
        try? work.putView(WorkView(id: task.id, artifacts: [artifact], selected: artifact,
                                  layout: .single, title: task.title, markup: surface.markup, hidden: task.hidden))
    }

    func retainWorkResult(title: String, values: [String: String], spec: APIDataSpec, replacing destination: UUID? = nil, sample: APIDataService.Sample? = nil) -> UUID {
        var definition = spec
        definition.card = nil
        definition.customLayout = nil
        let existing = destination ?? (RequestRun.current?.forceNewTask == true ? nil : work.matching(spec, values: values))
        let id = work.retain(title: title, values: values,
            definition: WorkDefinition(fields: spec.inputControls.map(\.key), actions: spec.workActions, apiData: definition),
            design: WorkDesign(card: spec.card), goalID: RequestRun.current?.goalID,
            replacing: existing, source: try? spec.requestURL().absoluteString, evidence: sample.flatMap { try? JSONSerialization.data(withJSONObject:$0.response,options:.fragmentsAllowed) })
        RequestRun.current?.retainResult(id, needsView:true)
        return id
    }
}

// Executable operations do not depend on a rendering being available.
extension APIDataSpec {
    var workActions: [TaskSurfaceAction] {
        var actions = [TaskSurfaceAction(id:"refreshData",kind:.remote,operation:"refresh"),
                       TaskSurfaceAction(id:"updateData",kind:.remote,operation:"update")]
        if supportsCurrencySwap { actions.append(.init(id:"swapCurrencies",kind:.remote,operation:"swap")) }
        if refreshSeconds != nil { actions.append(.init(id:"stopUpdates",kind:.resource,operation:"stop")) }
        return actions
    }
}
