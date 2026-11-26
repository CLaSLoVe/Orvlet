import SwiftUI

/// Host-owned work state stays independent of generated content and playback.
enum TaskActivity: Equatable {
    case working(String)
    case queued, succeeded, failed, interfaceFailed, needsInput, stopped, stale
    var label: String {
        switch self {
        case .working(let label): return label
        case .queued: return "Waiting…"
        case .succeeded: return "Done"
        case .needsInput: return "Input needed"
        case .failed: return "Task failed"
        case .interfaceFailed: return "View not updated"
        case .stopped: return "Stopped"
        case .stale: return "Update unavailable"
        }
    }
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

struct TaskActivityReceipt {
    let id = UUID()
    let created: Date
    let activity: TaskActivity
    init(activity: TaskActivity, created: Date = Date()) {
        self.activity = activity
        self.created = created
    }
    var visibleActivity: TaskActivity? {
        activity == .needsInput || Date().timeIntervalSince(created) < 8 ? activity : nil
    }
}

struct CapsuleAttention {
    static let duration: TimeInterval = 1.45
    let eventID: UUID
    var intensity: ReminderIntensity = .standard
    let started = Date()
}

enum TaskIssueSource: String {
    case browser, readings, playback, interface, data, runtime
    var title: String {
        switch self {
        case .browser: "Page connection"
        case .readings: "Page data"
        case .playback: "Playback control"
        case .interface: "View update"
        case .data: "Data update"
        case .runtime: "Task update"
        }
    }
}

extension AppModel {
    /// Keep temporary failures in the task record. The caller promotes a failure
    /// only after recovery has finished and the person has an action to take.
    func reportTaskIssue(_ id: UUID, source: TaskIssueSource, detail: String, requiresAttention: Bool = false) {
        let owners = taskIssueOwners(id)
        for owner in owners {
            let text = source.title + ": " + String(detail.prefix(2000))
            let previous = messages.lastIndex { $0.taskID == owner && ($0.issueResource ?? $0.taskID) == id
                && $0.issueSource == source.rawValue && $0.issueResolved != true }
            let index: Int
            if let previous, messages[previous].text == text {
                guard requiresAttention && messages[previous].issuePromoted != true else { continue }
                index = previous
            } else {
                appendMessage(text, isUser: false, taskID: owner)
                index = messages.index(before: messages.endIndex)
                messages[index].issueSource = source.rawValue
                messages[index].issueResource = id
            }
            if requiresAttention {
                messages[index].issuePromoted = true
                let messageID = messages[index].id
                if !commandPanelVisible || conversationTaskID != owner { unreadReplyIDs.insert(messageID) }
                presentCardReminder(owner, eventID: messageID, message: detail, persistence: .persistent, saveForRelaunch: true)
            }
        }
    }
    func resolveTaskIssue(_ id: UUID, source: TaskIssueSource) {
        let owners = Set(taskIssueOwners(id))
        var resolved = Set<UUID>()
        for i in messages.indices where messages[i].taskID.map(owners.contains) == true
            && (messages[i].issueResource ?? messages[i].taskID) == id
            && messages[i].issueSource == source.rawValue && messages[i].issueResolved != true {
            resolved.insert(messages[i].id)
            messages[i].issueResolved = true
        }
        if !resolved.isEmpty {
            unreadReplyIDs.subtract(resolved)
            removeReminders { resolved.contains($0.id) }
        }
    }
    private func taskIssueOwners(_ id: UUID) -> [UUID] {
        if sideTasks.contains(where: { $0.id == id }) { return [id] }
        return work.snapshot.views.values.filter { $0.artifacts.contains(id) && $0.closed != true }.map(\.id)
    }
    func loadModelKey(for connection: ModelConnection? = nil) async throws -> String {
        let selected = connection ?? settings.mainConnection
        let key = try await selected.loadKey()
        if modelAccessIssue != nil { removeReminders { $0.opensSettings } }
        modelAccessIssue = nil
        if feedback?.kind == .authorization { dismissFeedback() }
        return key
    }
    func reportModelAccessIssue(_ error: Error) {
        let message = error.localizedDescription
        guard modelAccessIssue != message else { return }
        modelAccessIssue = message
        deliverReply(message, kind: .authorization)
    }
    var hasTaskWork: Bool { busy || buildingSurface || !interfaceJobs.isEmpty || !taskActionJobs.isEmpty }
    func taskActivity(_ task: SideTask) -> TaskActivity? {
        if interfaceJobs[task.id] != nil { return .working("Updating view…") }
        if taskActionJobs[task.id] != nil { return .working("Calculating…") }
        if let run = runOwning(task.id) { return .working(run.activity.isEmpty ? "Starting…" : run.activity) }
        if busy && ownsRequest(task.id) {
            return .working(activity.isEmpty ? "Working…" : activity)
        }
        if webLoading && task.id == browser.id
            && !["interactive", "complete"].contains(browser.lastState["documentReady"] as? String ?? "")
        {
            return .working("Opening page…")
        }
        if buildingSurface && task.id == browser.id { return .working("Preparing view…") }
        if queuedTaskRequests.contains(where: { $0.taskID == task.id }) { return .queued }
        if task.dataIssue != nil { return .stale }
        if let activity = taskActivityReceipts[task.id]?.visibleActivity,
            !(activity == .succeeded && task.isMediaTask && task.terminalLabel == nil) {
            return activity
        }
        if ["Needs attention", "Task failed", "Interrupted. Retry", "Interrupted · retry"].contains(task.status) { return .failed }
        return nil
    }
    /// A recovered resource is not a failed task. Keep the failed request in its
    /// conversation, while removing its obsolete overlay from working controls.
    func clearPlaybackFailure(_ id: UUID, playing: Bool) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id && $0.isMediaTask }),
            sideTasks[i].terminalLabel == nil else { return }
        if taskActivityReceipts[id]?.activity == .failed { taskActivityReceipts[id] = nil }
        if ["Needs attention", "Task failed", "Interrupted. Retry", "Interrupted · retry"].contains(sideTasks[i].status) {
            sideTasks[i].status = playing ? "Playing" : "Paused"
        }
    }
    func recordInterfaceFailure(_ id: UUID, _ error: Error, userRequested: Bool = true) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        Diagnostics.record("interface_failure", ["taskID": id.uuidString, "type": String(describing: type(of: error))])
        sideTasks[i].interfaceIssue = PipelineFailure.presentation.localizedDescription
        if error is ModelAccessError {
            taskActivityReceipts[id] = nil
            if userRequested { reportModelAccessIssue(error) }
            persistSideTasks()
            return
        }
        reportTaskIssue(id, source: .interface, detail: error.localizedDescription)
        recordTaskOutcome(id, .interfaceFailed)
        persistSideTasks()
    }
    func recordTaskOutcome(_ id: UUID, _ outcome: TaskActivity) {
        guard sideTasks.contains(where: { $0.id == id }) else { return }
        let receipt = TaskActivityReceipt(activity: outcome)
        taskActivityReceipts[id] = receipt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, taskActivityReceipts[id]?.id == receipt.id else { return }
            if outcome == .needsInput {
                refreshStackAttention()
            } else {
                taskActivityReceipts[id] = nil
            }
        }
    }
}

/// Reuses the existing glyph footprint; essential controls never move or disappear.
struct TaskActivityGlyph: View {
    @ObservedObject var model: AppModel
    let task: SideTask
    var symbol: String? = nil
    var body: some View {
        Group {
            if let activity = model.taskActivity(task) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(model.accent.opacity(0.12))
                    if activity.isWorking && !model.motionReduced {
                        ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
                    } else {
                        Image(
                            systemName: activity.isWorking || activity == .queued
                                ? "hourglass"
                                : activity == .succeeded
                                    ? "checkmark" : activity == .stopped ? "stop.fill" : "exclamationmark"
                        )
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(model.accent)
                    }
                }.frame(width: 20, height: 20)
                    .accessibilityLabel(activity.label).help(
                        activity == .interfaceFailed
                            ? (task.interfaceIssue ?? activity.label)
                            : activity == .stale ? (task.dataIssue ?? activity.label) : activity.label)
            } else {
                CalmGlyph(symbol: symbol ?? task.symbol, accent: model.accent)
            }
        }.animation(CalmMotion.animation(reduced: model.motionReduced), value: model.taskActivity(task))
    }
}

extension AppModel {
    func checkModelConnections(notify: Bool = true) {
        guard !isLiveTest else { return }
        connectionCheckTask?.cancel()
        let connection = settings.mainConnection
        let fast = settings.fast
        let decisionAPI = settings.decisionAPI
        let fastAccount = settings.fastKeyAccount
        let fastEnabled = settings.useFast
        mainServiceState = connection.endpoint.isConfigured ? "checking" : "unconfigured"
        if notify && !connection.endpoint.isConfigured {
            showConnectionNotice(
                "Connect a model in Settings to start new tasks. Existing local controls remain available.")
        }
        connectionCheckTask = Task {
            if connection.endpoint.isConfigured {
                do {
                    let key = try await connection.loadKey()
                    let tool = ToolSchema.function(
                        "connection_check", "Confirm availability", ["ok": ["type": "boolean"]], required: ["ok"])
                    let response = try await ModelClient.complete(
                        endpoint: connection.endpoint, key: key,
                        messages: [["role": "user", "content": "Call connection_check with ok=true."]], tools: [tool],
                        reasoning: false, requiredTool: "connection_check", timeout: 12)
                    try Task.checkCancellation()
                    let raw = try StructuredResponse.arguments(response, named: "connection_check")
                    guard let value = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                        value["ok"] as? Bool == true
                    else { throw AppError.message("The model didn't confirm tool support.") }
                    mainServiceState = "ready"
                    removeReminders { $0.opensSettings }
                    if feedback?.kind == .authorization { dismissFeedback() }
                } catch {
                    guard !Task.isCancelled else { return }
                    mainServiceState = "unavailable"
                    if notify {
                        showConnectionNotice(
                            "The model connection isn't ready. Check Settings or try the connection again. "
                                + error.localizedDescription)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if fastEnabled && fast.isConfigured {
                fastServiceState = "checking"
                do {
                    let key = try await SecretStore.load(fastAccount)
                    let response = try await DecisionClient.judge(
                        endpoint: fast, api: decisionAPI, key: key, state: ["category": "audio", "playing": true],
                        questions: ["audio": "Is audio playing?"], timeout: 4)
                    try Task.checkCancellation()
                    guard response["audio"] != nil else { throw AppError.message("Unexpected decision response.") }
                    fastServiceState = "ready"
                } catch {
                    guard !Task.isCancelled else { return }
                    fastServiceState = "unavailable"
                }
            } else {
                fastServiceState = fastEnabled ? "unconfigured" : "off"
            }
        }
    }
    private func showConnectionNotice(_ text: String) {
        guard !reminders.contains(where: { $0.opensSettings && $0.message == text }) else { return }
        deliverReply(text, kind: .authorization)
    }
}
