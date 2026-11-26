import AppKit
import SwiftUI

enum ReminderIntensity: String, Codable {
    case gentle, standard, strong

    var edgeStrength: Double {
        switch self {
        case .gentle: 0.66
        case .standard: 1
        case .strong: 1.45
        }
    }
}

enum ReminderPersistence: String, Codable { case brief, persistent }

enum ReminderDestination: Equatable, Codable {
    case card, conversation, reply(prefix: String?), settings
}

struct SavedReminder: Codable {
    let destination: ReminderDestination
    let intensity: ReminderIntensity
    var condition: SavedReminderCondition?
}

struct PresentedCardReminder: Identifiable {
    static let briefDuration: TimeInterval = 5
    let attention: CapsuleAttention
    var id: UUID { attention.eventID }
    let owner: UUID
    let title: String
    let symbol: String
    let message: String
    var intensity: ReminderIntensity { attention.intensity }
    let persistence: ReminderPersistence
    let destination: ReminderDestination
    var needsInput: Bool {
        if case .reply = destination { return true }
        return false
    }
    var opensSettings: Bool { destination == .settings }
    var waitsForBriefSlot: Bool { persistence == .brief && intensity != .strong }
}

extension AppModel {
    /// Routine notices take turns. Urgent and persistent notices are visible on arrival.
    var displayedReminders: [PresentedCardReminder] {
        let current = reminders.first(where: \.waitsForBriefSlot)?.id
        let displayed = reminders.reversed().filter { !$0.waitsForBriefSlot || $0.id == current }
        guard let newest = displayed.first(where: { $0.id == latestPresentedReminderID }) else { return displayed }
        return [newest] + displayed.filter { $0.id != newest.id }
    }

    @discardableResult
    func notifyFromGeneratedCard(_ id: UUID, message: String, intensity: ReminderIntensity = .standard,
                                 persistence: ReminderPersistence = .brief, condition: SavedReminderCondition? = nil) -> UUID? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, listedTasks.contains(where: { $0.id == id }) else { return nil }
        let event = appendMessage(text, isUser: false, taskID: id)
        if !commandPanelVisible || conversationTaskID != id { unreadReplyIDs.insert(event) }
        presentCardReminder(id, eventID: event, message: text, intensity: intensity, persistence: persistence,
                            destination: .card, saveForRelaunch: true, condition: condition)
        return event
    }

    func presentCardReminder(_ owner: UUID, eventID: UUID, message: String, intensity: ReminderIntensity = .standard,
                             persistence: ReminderPersistence = .brief, destination: ReminderDestination = .conversation,
                             restoring: Bool = false, saveForRelaunch: Bool = false, condition: SavedReminderCondition? = nil) {
        let nativeAlarm = sideTasks.contains { $0.id == owner && $0.pendingTimerReminderID == eventID }
        guard work.view(owner)?.closed != true || (nativeAlarm && timerAlarmView(for: owner) != nil),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reminders.contains(where: { $0.id == eventID }) else { return }
        let task = sideTasks.first { $0.id == owner }
        let reminder = PresentedCardReminder(attention: CapsuleAttention(eventID: eventID, intensity: intensity),
                                    owner: owner, title: task?.title ?? "Orvlet",
                                    symbol: task?.symbol ?? "bell", message: message,
                                    persistence: persistence, destination: destination)
        let startsNow = !reminder.waitsForBriefSlot || !reminders.contains(where: \.waitsForBriefSlot)
        if saveForRelaunch, persistence == .persistent, let index = messages.lastIndex(where: { $0.id == eventID }) {
            messages[index].pendingReminder = SavedReminder(destination: destination, intensity: intensity, condition: condition)
        }
        reminders.append(reminder)
        if restoring {
            onRemindersChanged?()
        } else if startsNow {
            beginPresenting(reminder)
        }
        if persistence == .persistent { updateReminderRepeats() }
    }

    func restoreMessageReminders() {
        for index in messages.indices {
            let message = messages[index]
            guard let pending = message.pendingReminder, let owner = message.taskID else { continue }
            guard work.view(owner)?.closed != true,
                  pending.condition.map({ cardReminderValues[owner]?.reconnect($0, eventID: message.id) == true }) ?? true else {
                messages[index].pendingReminder = nil
                unreadReplyIDs.remove(message.id)
                continue
            }
            unreadReplyIDs.insert(message.id)
            presentCardReminder(owner, eventID: message.id, message: message.text, intensity: pending.intensity,
                                persistence: .persistent, destination: pending.destination, restoring: true)
        }
    }

    /// A native countdown may outlive its original view when a generated card still shows it.
    func timerAlarmView(for owner: UUID) -> UUID? {
        guard let source = work.view(owner) else { return owner }
        guard source.closed == true else { return owner }
        guard work.artifact(source.selected)?.native?.kind == .timer else { return nil }
        return work.snapshot.views.values.first { $0.closed != true && $0.artifacts.contains(source.selected) }?.id
    }

    func presentTimerAlarm(for task: SideTask, eventID: UUID, restoring: Bool = false) {
        if !commandPanelVisible || conversationTaskID != task.id { unreadReplyIDs.insert(eventID) }
        presentCardReminder(task.id, eventID: eventID, message: task.timerAlarmText,
                            intensity: task.nativeTimerAlarmRule?.intensity ?? .standard, persistence: .persistent,
                            destination: .card, restoring: restoring)
    }

    func clearPendingTimerAlarm(for owner: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == owner }), let event = sideTasks[i].pendingTimerReminderID else { return }
        sideTasks[i].pendingTimerReminderID = nil
        unreadReplyIDs.remove(event)
        removeReminders { $0.id == event }
    }

    private func beginPresenting(_ reminder: PresentedCardReminder) {
        latestPresentedReminderID = reminder.id
        let owner = reminder.owner
        let edge = CapsuleAttention(eventID: reminder.id, intensity: reminder.intensity)
        capsuleAttention[owner] = edge
        refreshStackAttention()
        onRemindersChanged?()
        playReminderSound(intensity: reminder.intensity, eventID: reminder.id, persistence: reminder.persistence)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(CapsuleAttention.duration))
            guard let self, capsuleAttention[owner]?.eventID == reminder.id else { return }
            capsuleAttention[owner] = nil
            refreshStackAttention()
        }
        if reminder.persistence == .brief {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(PresentedCardReminder.briefDuration))
                self?.removeReminders { $0.id == reminder.id }
            }
        }
    }

    func openReminder(_ reminder: PresentedCardReminder) {
        dismissReminder(reminder.id)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        switch reminder.destination {
        case .card:
            let destination = timerAlarmView(for: reminder.owner) ?? reminder.owner
            if !selectTask(destination, expanded: true, preferSource: false) {
                openTaskConversation(reminder.owner)
            }
        case .conversation:
            openTaskConversation(reminder.owner)
        case .reply(let prefix):
            openTaskConversation(reminder.owner)
            if command.isEmpty, let prefix { command = prefix }
        case .settings:
            onSettings?()
        }
    }

    func dismissReminder(_ id: UUID) {
        if let reminder = reminders.first(where: { $0.id == id }),
           let task = sideTasks.first(where: { $0.id == reminder.owner && $0.pendingTimerReminderID == id }) {
            clearPendingTimerAlarm(for: task.id)
            persistSideTasks()
            return
        }
        unreadReplyIDs.remove(id)
        removeReminders { $0.id == id }
    }

    func removeReminders(where remove: (PresentedCardReminder) -> Bool) {
        guard reminders.contains(where: remove) else { return }
        let current = reminders.first(where: \.waitsForBriefSlot)?.id
        let removed = Set(reminders.filter(remove).map(\.id))
        for i in messages.indices where messages[i].pendingReminder != nil && removed.contains(messages[i].id) {
            messages[i].pendingReminder = nil
        }
        reminders.removeAll { removed.contains($0.id) }
        stopReminderSound(events: removed)
        updateReminderRepeats()
        capsuleAttention = capsuleAttention.filter { !removed.contains($0.value.eventID) }
        if let next = reminders.first(where: \.waitsForBriefSlot), next.id != current {
            beginPresenting(next)
        } else {
            onRemindersChanged?()
            refreshStackAttention()
        }
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ReminderList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let items = model.displayedReminders
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 9) {
                            Button {
                                model.openReminder(item)
                            } label: {
                                HStack(spacing: 9) {
                                    CalmGlyph(symbol: item.symbol, accent: model.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                        Text(item.message).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { model.dismissReminder(item.id) } label: {
                                if item.persistence == .persistent {
                                    Text(model.userText("知道了", "Got it"))
                                        .font(.system(size: 11, weight: .medium))
                                        .fixedSize().padding(.horizontal, 9).frame(height: 26)
                                        .background(.primary.opacity(0.055), in: Capsule())
                                        .frame(minHeight: 34).contentShape(Rectangle())
                                } else {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary).frame(width: 22, height: 26)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityLabel(item.persistence == .persistent
                                ? model.userText("确认提醒", "Acknowledge reminder")
                                : model.userText("关闭提醒", "Dismiss reminder"))
                        }
                        .padding(.horizontal, 11).frame(height: 60)
                        .background(CalmVisualStyle.windowFill(model.settings.appearance.scheme ?? systemScheme),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).strokeBorder(model.accent.opacity(0.19), lineWidth: 0.75)
                                if item.persistence == .persistent {
                                    CapsuleAttentionEdge(event: item.attention, reducedMotion: model.motionReduced,
                                                         accent: model.accent, radius: 12, ongoing: true)
                                } else if let edge = model.capsuleAttention[item.owner], edge.eventID == item.id {
                                    CapsuleAttentionEdge(event: edge, reducedMotion: model.motionReduced, accent: model.accent, radius: 12)
                                }
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                        .id(item.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: items.first?.id) { _, first in
                if let first { proxy.scrollTo(first, anchor: .top) }
            }
        }.preferredColorScheme(model.settings.appearance.scheme)
    }
    @Environment(\.colorScheme) private var systemScheme
}

extension AppDelegate {
    func presentReminders(in visibleFrame: NSRect? = nil) {
        let count = model.displayedReminders.count
        guard count > 0 else {
            reminderPanel?.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = visibleFrame ?? screen?.visibleFrame else { return }
        let window: NSPanel
        if let reminderPanel {
            window = reminderPanel
        } else {
            window = ReminderPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = .statusBar
            window.canHide = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isExcludedFromWindowsMenu = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: ReminderList(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            reminderPanel = window
        }
        let safe = area.insetBy(dx: 12, dy: 12)
        let width = min(292, safe.width)
        let height = min(CGFloat(count * 66 - 6), safe.height)
        window.setFrame(NSRect(x: safe.maxX - width, y: safe.maxY - height, width: width, height: height), display: true)
        window.orderFrontRegardless()
    }
}
