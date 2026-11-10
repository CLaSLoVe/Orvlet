import SwiftUI

struct RequestFeedback: Identifiable {
    enum Kind { case success, needsInput, authorization, failure, information, attention }
    let id = UUID()
    let text: String
    let kind: Kind
    var replyPrefix: String?
    var taskID: UUID?
    var title: String {
        switch kind {
        case .success: return "Done"
        case .needsInput: return "A detail is missing"
        case .authorization: return "Model access"
        case .failure: return "Needs attention"
        case .information: return "Orvlet"
        case .attention: return "Time is up"
        }
    }
    var icon: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .needsInput: return "questionmark.circle"
        case .authorization: return "key"
        case .failure: return "exclamationmark.circle"
        case .information: return "bubble.left"
        case .attention: return "timer"
        }
    }
}

extension AppModel {
    var feedbackSize: NSSize {
        let height = (feedback?.text ?? "").boundingRect(
            with: NSSize(width: 272, height: 1000), options: .usesLineFragmentOrigin,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).height
        return NSSize(width: 300, height: ceil(min(60, max(16, height))) + 86)
    }
    /// One quiet receipt on the existing shell. Full text stays in conversation;
    /// arriving results never focus the composer or interrupt playback.
    func deliverReply(_ text: String, kind: RequestFeedback.Kind = .success, taskID: UUID? = nil) {
        let owner = taskID ?? activeRequest?.owner?.id ?? activeRequest?.placeholderID ?? UUID()
        appendMessage(
            text, isUser: false, taskID: owner,
            requestID: taskID == nil || taskID == activeRequest?.owner?.id ? activeRequest?.id : nil)
        if let index = sideTasks.firstIndex(where: { $0.id == owner && $0.kind == .result }) {
            sideTasks[index].detail = text
            sideTasks[index].status =
                kind == .failure
                ? "Task failed"
                : kind == .needsInput ? "Input needed" : kind == .authorization ? "Waiting for model" : "Ready"
        }
        hasUnreadReply = !commandPanelVisible || conversationTaskID != owner
        guard !commandPanelVisible || conversationTaskID != owner else { return }
        feedbackTask?.cancel()
        // A ready interactive task is already its own receipt. Reserve larger
        // notices for answers, calendar outcomes, errors and required input.
        if kind == .success,
            sideTasks.contains(where: {
                $0.id == owner
                    && (($0.kind == .web && ($0.generated || ($0.isMediaTask && $0.playing))) || $0.kind == .timer
                        || ($0.kind == .workspace && $0.status == "Ready"))
            })
        {
            dismissFeedback()
            return
        }
        let receipt = RequestFeedback(
            text: text, kind: kind, replyPrefix: kind == .needsInput ? agent.clarificationPrefix : nil, taskID: owner)
        feedback = receipt
        feedbackWakesStack = true
        if !taskShelfVisible { onResize?(windowSize) }
        onShow?()
        refreshStackAttention()
        // Problems remain available until read or dismissed, without blinking or sound.
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                while let self, self.pointerInside || self.menuTracking {
                    try await Task.sleep(for: .seconds(1))
                }
                guard let self, self.feedback?.id == receipt.id else { return }
                if kind == .success || kind == .information {
                    self.dismissFeedback()
                } else {
                    self.feedbackWakesStack = false
                    self.refreshStackAttention()
                }
            } catch {}
        }
    }
    func dismissFeedback() {
        guard feedback != nil else { return }
        feedbackTask?.cancel()
        feedbackTask = nil
        feedback = nil
        feedbackWakesStack = false
        if !taskShelfVisible { reconcileTasks() }
        refreshStackAttention()
    }
}

struct RequestFeedbackView: View {
    @ObservedObject var model: AppModel
    let feedback: RequestFeedback
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: feedback.icon).foregroundStyle(model.accent)
                Text(feedback.title).fontWeight(.semibold)
                Spacer(minLength: 0)
                Button {
                    model.dismissFeedback()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Dismiss notification").accessibilityLabel("Dismiss notification")
            }
            Text(feedback.text).font(.system(size: 12)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(feedback.text)
            Spacer(minLength: 0)
            Button(
                feedback.kind == .authorization
                    ? "Open Settings…" : feedback.kind == .needsInput ? "Reply…" : "Chat"
            ) {
                if feedback.kind == .authorization {
                    model.onSettings?()
                    return
                }
                if model.command.isEmpty, let prefix = feedback.replyPrefix { model.command = prefix }
                if let id = feedback.taskID { model.openTaskConversation(id) } else { model.openTaskHistory() }
            }
            .buttonStyle(.plain).foregroundStyle(model.accent).font(.system(size: 11, weight: .medium))
        }
        .font(.system(size: 12)).padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.3) }
        .background { WindowDragArea() }
    }
}
