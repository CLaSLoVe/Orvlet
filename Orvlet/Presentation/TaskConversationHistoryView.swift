import SwiftUI

/// History is a task index; only a resolved task can show conversation messages.
struct TaskConversationHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var deleting: UUID?
    @State private var showEarlierSteps = false
    var body: some View {
        Group {
            if let id = model.conversationTaskID {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            model.openTaskHistory()
                        } label: {
                            Image(systemName: "chevron.left").frame(width: 24, height: 26)
                        }
                        .help("All task history").accessibilityLabel("All task history")
                        Text(model.conversationTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            _ = model.restoreHistoryTask(id)
                        } label: {
                            Image(systemName: "arrow.up.forward.square").frame(width: 26, height: 26)
                        }
                        .help("Open task card").accessibilityLabel("Open task card")
                    }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 5)
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if model.visibleConversation.isEmpty {
                                    Text("No messages for this task yet.").foregroundStyle(.secondary).font(
                                        .system(size: 12)
                                    ).padding(.vertical, 12)
                                }
                                ForEach(model.visibleConversation) { message in
                                    Text(message.text).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                                        .padding(.horizontal, 10).padding(.vertical, 8)
                                        .background(
                                            message.isUser ? model.accent.opacity(0.09) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10)
                                        )
                                        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                                        .id(message.id)
                                }
                                if !model.conversationProgress.isEmpty || model.conversationActivity != nil {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if model.conversationProgress.count > 3 {
                                            DisclosureGroup("Earlier steps", isExpanded: $showEarlierSteps) {
                                                ForEach(Array(model.conversationProgress.dropLast(3).enumerated()), id: \.offset) { _, step in
                                                    Text(step.replacingOccurrences(of: " · ", with: ", ")).textSelection(.enabled).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        ForEach(Array(model.conversationProgress.suffix(3).enumerated()), id: \.offset) { index, step in
                                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                                Image(systemName: step.contains(" · ") ? "exclamationmark.circle" : "circle.fill")
                                                    .font(.system(size: step.contains(" · ") ? 10 : 4))
                                                Text(step.replacingOccurrences(of: " · ", with: ", ")).textSelection(.enabled)
                                            }
                                            .foregroundStyle(index == min(2, model.conversationProgress.count - 1) ? .primary : .secondary)
                                        }
                                        if let draft = model.runOwning(id)?.streamText, !draft.isEmpty {
                                            Text(draft).font(.system(size: 12)).textSelection(.enabled)
                                        } else if model.conversationProgress.isEmpty, let activity = model.conversationActivity {
                                            Text(activity.label)
                                        }
                                    }
                                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 10).overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 1).fill(model.accent.opacity(0.5)).frame(width: 2)
                                    }
                                    .accessibilityElement(children: .contain).id("request-activity")
                                }

                            }.padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .onChange(of: model.conversationActivity) { _, state in
                            if state != nil { reader.scrollTo("request-activity", anchor: .bottom) }
                        }
                        .onAppear {
                            if model.conversationActivity != nil {
                                reader.scrollTo("request-activity", anchor: .bottom)
                            } else if let last = model.visibleConversation.last {
                                reader.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: model.visibleConversation.last?.id) { _, id in
                            if let id { reader.scrollTo(id, anchor: .bottom) }
                        }
                    }.id(id)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if model.taskHistoryItems.isEmpty {
                            Text("Your tasks and their conversations will appear here.").font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(20)
                        }
                        ForEach(model.taskHistoryItems) { item in
                            Button {
                                model.openTaskConversation(item.id)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
                                        .frame(width: 18).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Spacer(minLength: 8)
                                            Text(item.state).font(.system(size: 9)).foregroundStyle(.tertiary)
                                        }
                                        Text(item.preview).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }.padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Conversation: " + item.title)
                                .contextMenu {
                                    Button("Delete task and history…", role: .destructive) { deleting = item.id }
                                }
                        }
                    }.padding(8)
                }
            }
        }
        .alert(
            "Delete this task and its history?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting { model.deleteTaskHistory(id) }
                deleting = nil
            }
        } message: {
            Text(
                "The card will close and its saved conversation and task state will be removed. Website data and created calendar events are kept."
            )
        }
    }
}
