import SwiftUI

struct RequestFeedback: Identifiable {
    enum Kind { case success, needsInput, authorization, failure, information }
    let id: UUID
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
        }
    }
    var icon: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .needsInput: return "questionmark.circle"
        case .authorization: return "key"
        case .failure: return "exclamationmark.circle"
        case .information: return "bubble.left"
        }
    }
}

extension AppModel {
    var feedbackSize: NSSize {
        let height = (feedback?.text ?? "").boundingRect(
            with: NSSize(width: 272, height: 1000), options: .usesLineFragmentOrigin,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).height
        return NSSize(width: 300, height: ceil(min(60, max(16, height))) + (feedback?.kind == .information ? 104 : 86))
    }
    /// One quiet receipt on the existing shell. Full text stays in conversation;
    /// arriving results never focus the composer or interrupt playback.
    func deliverReply(_ text: String, kind: RequestFeedback.Kind = .success, taskID: UUID? = nil) {
        let owner = taskID ?? activeRequest?.owner?.id ?? activeRequest?.placeholderID ?? UUID()
        let proof = RequestRun.current?.agent.lastToolVerification
        let verifiedResult = kind == .success && proof?.needsInput == false && proof?.reply == text
        let messageID = appendMessage(
            text, isUser: false, taskID: owner,
            requestID: taskID == nil || taskID == activeRequest?.owner?.id ? activeRequest?.id : nil, verifiedMemoryResult: verifiedResult)
        if let index = sideTasks.firstIndex(where: { $0.id == owner && $0.kind == .result }) {
            sideTasks[index].detail = text
            sideTasks[index].status =
                kind == .failure
                ? "Task failed"
                : kind == .needsInput ? "Input needed" : kind == .authorization ? "Waiting for model" : "Ready"
        }
        if [.needsInput, .failure, .authorization].contains(kind) {
            guard work.view(owner)?.closed != true else { return }
            if !commandPanelVisible || conversationTaskID != owner { unreadReplyIDs.insert(messageID) }
            let destination: ReminderDestination = switch kind {
            case .needsInput: .reply(prefix: agent.clarificationPrefix)
            case .authorization: .settings
            default: .conversation
            }
            presentCardReminder(owner, eventID: messageID, message: text,
                                persistence: .persistent,
                                destination: destination, saveForRelaunch: true)
            // The foreground receipt owns presentation when the window delegate is installed.
            if onRemindersChanged != nil { return }
        }
        guard !commandPanelVisible || conversationTaskID != owner else { return }
        unreadReplyIDs.insert(messageID)
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
            id: messageID, text: text, kind: kind, replyPrefix: kind == .needsInput ? agent.clarificationPrefix : nil, taskID: owner)
        feedback = receipt
        feedbackWakesStack = true
        if !taskShelfVisible { onResize?(windowSize) }
        onShow?()
        refreshStackAttention()
        guard kind == .success else { return }
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                while let self, self.pointerInside || self.menuTracking {
                    try await Task.sleep(for: .seconds(1))
                }
                guard let self, self.feedback?.id == receipt.id else { return }
                self.dismissFeedback()
            } catch {}
        }
    }
    func sendFeedbackReply(_ text: String, to receipt: RequestFeedback) {
        guard receipt.id == feedback?.id, let owner = receipt.taskID,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversationDrafts[owner] = nil
        openTaskConversation(owner)
        command = text
        sendCommand()
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
    @State private var reply = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: feedback.icon).foregroundStyle(model.accent)
                Text(feedback.kind == .information ? (model.messages.last { $0.taskID == feedback.taskID && $0.isUser }?.text ?? feedback.title) : feedback.title)
                    .fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    model.dismissReminder(feedback.id)
                    model.dismissFeedback()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Dismiss notification").accessibilityLabel("Dismiss notification")
            }
            Text(feedback.text).font(.system(size: 12)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(feedback.text)
            Spacer(minLength: 0)
            if feedback.kind == .information {
                HStack(spacing: 6) {
                    TextField(model.userText("继续问…", "Ask a follow-up…"), text: $reply)
                        .textFieldStyle(.plain).onSubmit { model.sendFeedbackReply(reply, to: feedback) }
                        .onAppear { reply = feedback.taskID.flatMap { model.conversationDrafts[$0] } ?? "" }
                        .onChange(of: reply) { _, value in
                            if let id = feedback.taskID { model.conversationDrafts[id] = value }
                        }
                    Button {
                        model.sendFeedbackReply(reply, to: feedback)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                    }.buttonStyle(.plain).foregroundStyle(model.accent)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(model.userText("发送", "Send"))
                }.padding(.horizontal, 9).frame(height: 28)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Button(
                    feedback.kind == .authorization
                        ? "Open Settings…" : feedback.kind == .needsInput ? "Reply…" : "Chat"
                ) {
                    if let reminder = model.reminders.first(where: { $0.id == feedback.id }) {
                        model.openReminder(reminder)
                        model.dismissFeedback()
                        return
                    }
                    if feedback.kind == .authorization {
                        model.onSettings?()
                        return
                    }
                    if model.command.isEmpty, let prefix = feedback.replyPrefix { model.command = prefix }
                    if let id = feedback.taskID { model.openTaskConversation(id) } else { model.openTaskHistory() }
                }
                .buttonStyle(.plain).foregroundStyle(model.accent).font(.system(size: 11, weight: .medium))
            }
        }
        .font(.system(size: 12)).padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.3) }
        .background { WindowDragArea() }
    }
}
