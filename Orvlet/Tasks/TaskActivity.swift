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
    let created = Date()
    let activity: TaskActivity
}

extension AppModel {
    func loadModelKey(for connection: ModelConnection? = nil) async throws -> String {
        let selected = connection ?? settings.mainConnection
        let key = try await selected.loadKey()
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
        if let receipt = taskActivityReceipts[task.id] { return receipt.activity }
        if ["Needs attention", "Task failed", "Interrupted · retry"].contains(task.status) { return .failed }
        return nil
    }
    func recordInterfaceFailure(_ id: UUID, _ error: Error) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        Diagnostics.record("interface_failure", ["taskID": id.uuidString, "type": String(describing: type(of: error))])
        sideTasks[i].interfaceIssue = PipelineFailure.presentation.localizedDescription
        if error is ModelAccessError {
            taskActivityReceipts[id] = nil
            reportModelAccessIssue(error)
            persistSideTasks()
            return
        }
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
            if outcome == .failed || outcome == .needsInput {
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
                    let response = try await JevClient.judge(
                        endpoint: fast, key: key, state: ["category": "audio", "playing": true],
                        questions: ["audio": "Is audio playing?"], timeout: 4)
                    try Task.checkCancellation()
                    guard response["audio"] != nil else { throw AppError.message("Unexpected Jev response.") }
                    fastServiceState = "ready"
                } catch {
                    guard !Task.isCancelled else { return }
                    fastServiceState = "unavailable"
                    if notify && mainServiceState == "ready" {
                        showConnectionNotice(
                            "Jev isn't available. Orvlet will use its default model flow and local task ordering.")
                    }
                }
            } else {
                fastServiceState = fastEnabled ? "unconfigured" : "off"
            }
        }
    }
    private func showConnectionNotice(_ text: String) {
        feedback = RequestFeedback(text: text, kind: .authorization)
        feedbackWakesStack = true
        onResize?(windowSize)
        onShow?()
        refreshStackAttention()
    }
}
