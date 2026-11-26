import SwiftUI

struct TimerCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var amount = "5"
    @State private var unit = Unit.minutes
    @State private var clockTime = Date.now.addingTimeInterval(300)
    @State private var name = ""
    @State private var startError: String?

    private enum Unit: String, CaseIterable {
        case seconds, minutes, hours, days
        case clock = "At time"

        var multiplier: Double? {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 3600
            case .days: 86400
            case .clock: nil
            }
        }
    }

    private var tint: Color { CalmVisualStyle.tint(model.accent, scheme: scheme) }
    private var seconds: Double? {
        guard let multiplier = unit.multiplier else {
            let now = Date.now
            return Self.nextClockTime(clockTime, after: now).map { max(1, $0.timeIntervalSince(now)) }
        }
        let input = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = Locale.current.decimalSeparator ?? "."
        guard let value = Double(input.replacingOccurrences(of: decimal, with: ".")) else { return nil }
        let seconds = value * multiplier
        return (1...604800).contains(seconds) ? seconds : nil
    }

    static func nextClockTime(_ clockTime: Date, after now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        var components = calendar.dateComponents([.hour, .minute], from: clockTime)
        components.second = 0
        return [Calendar.RepeatedTimePolicy.first, .last].compactMap {
            calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTimePreservingSmallerComponents,
                              repeatedTimePolicy: $0)
        }.min()
    }

    private static func isCurrent(_ entry: SideTask) -> Bool {
        !entry.finished || entry.pendingTimerReminderID != nil
    }

    static func contentHeight(_ entries: [SideTask], historyExpanded: Bool) -> CGFloat {
        let active = entries.filter { Self.isCurrent($0) }.count
        let history = entries.count - active
        return 122 + (active == 0 ? 0 : 13 + CGFloat(min(active, 3)) * 44)
            + (history == 0 ? 0 : 33)
            + (historyExpanded ? CGFloat(min(history, 3)) * 34 : 0)
    }

    var body: some View {
        let entries = model.timerEntries
        let current = entries.filter { Self.isCurrent($0) }.sorted {
            if ($0.pendingTimerReminderID != nil) != ($1.pendingTimerReminderID != nil) {
                return $0.pendingTimerReminderID != nil
            }
            return ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
        let past = entries.filter { !Self.isCurrent($0) }.sorted {
            ($0.completedAt ?? $0.created) > ($1.completedAt ?? $1.created)
        }

        VStack(alignment: .leading, spacing: 0) {
            if !current.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(current) { entry in currentRow(entry) }
                    }
                }
                .frame(height: CGFloat(min(current.count, 3)) * 44)
                .windowDragControl()
                Divider().frame(height: 13)
            }
            editor
            if !past.isEmpty {
                Button {
                    model.timerHistoryExpanded.toggle()
                    model.onResize?(model.windowSize)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("History")
                        Text(past.count, format: .number).foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: model.timerHistoryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 25).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 8).windowDragControl()
                .accessibilityIdentifier("timer-history")
                .accessibilityValue(model.timerHistoryExpanded ? "Expanded" : "Collapsed")
                if model.timerHistoryExpanded {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(past) { entry in historyRow(entry) }
                        }
                    }
                    .frame(height: CGFloat(min(past.count, 3)) * 34)
                    .windowDragControl()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .windowDraggableSurface()
        .accessibilityIdentifier("timer-card")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(height: 22)
                .onSubmit(start).windowDragControl()
                .accessibilityLabel("Timer name").accessibilityIdentifier("timer-name")
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    if unit == .clock {
                        DatePicker("End time", selection: $clockTime, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.field).controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("End time").accessibilityIdentifier("timer-clock-time")
                    } else {
                        TextField("0", text: $amount)
                            .textFieldStyle(.plain).font(.system(size: 23, weight: .medium, design: .rounded))
                            .monospacedDigit().onSubmit(start)
                            .accessibilityLabel("Duration").accessibilityIdentifier("timer-duration")
                    }
                    Picker("Unit", selection: $unit) {
                        ForEach(Unit.allCases, id: \.self) { option in Text(option.rawValue).tag(option) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    .accessibilityLabel("Duration unit or clock time").accessibilityIdentifier("timer-unit")
                }
                .padding(.horizontal, 10).frame(height: 39)
                .background(model.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .windowDragControl()
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 13).frame(height: 39)
                        .background(model.accent.opacity(0.19), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(seconds == nil).windowDragControl()
                .accessibilityLabel("Start timer").accessibilityIdentifier("timer-start")
            }
            if let issue = startError ?? (unit != .clock && seconds == nil && !amount.isEmpty ? "Choose 1 second to 7 days." : nil) {
                Text(issue).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(height: 25)
            } else if unit == .clock {
                TimelineView(.everyMinute) { context in
                    if let target = Self.nextClockTime(clockTime, after: context.date) {
                        let day = Calendar.autoupdatingCurrent.isDate(context.date, inSameDayAs: target) ? "Today" : "Tomorrow"
                        Text(day + ", " + target.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 25)
                            .accessibilityIdentifier("timer-clock-target")
                    }
                }
            } else {
                HStack(spacing: 5) {
                    ForEach([5, 15, 25, 60], id: \.self) { minutes in
                        Button {
                            amount = minutes == 60 ? "1" : String(minutes)
                            unit = minutes == 60 ? .hours : .minutes
                        } label: {
                            Text(minutes == 60 ? "1 hr" : "\(minutes) min")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(seconds == Double(minutes * 60) ? tint : Color.secondary)
                                .padding(.horizontal, 7).frame(height: 23)
                                .background(
                                    model.accent.opacity(seconds == Double(minutes * 60) ? 0.12 : 0.04),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain).windowDragControl()
                        .accessibilityLabel("Set duration to \(minutes) minutes")
                        .accessibilityIdentifier("timer-preset-\(minutes)")
                    }
                }.frame(height: 25)
            }
        }
        .onChange(of: amount) { _, _ in startError = nil }
        .onChange(of: unit) { _, _ in startError = nil }
    }

    private func currentRow(_ entry: SideTask) -> some View {
        let ringing = entry.pendingTimerReminderID != nil
        let paused = entry.deadline == nil
        return HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.timerSubject).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Group {
                    if ringing { Text("Time is up") }
                    else if let end = entry.deadline { Text("Ends \(end, style: .time)") }
                    else { Text("Paused") }
                }
                .font(.system(size: 10)).foregroundStyle(ringing ? tint : .secondary)
            }
            Spacer(minLength: 2)
            if ringing {
                Button {
                    model.acknowledgeTimerFromTool(entry.id)
                } label: {
                    Label("Got it", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(model.accent.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel("Acknowledge " + entry.timerSubject)
                .accessibilityIdentifier("timer-acknowledge-" + entry.id.uuidString)
            } else {
                Text(Self.clock(entry.remaining))
                    .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(paused ? .secondary : .primary)
                rowAction(paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill", entry: entry) {
                    model.timerAction(entry.id, action: "toggle")
                }
                .accessibilityIdentifier("timer-toggle-" + entry.id.uuidString)
            }
        }
        .frame(height: 44).contentShape(Rectangle())
        .contextMenu {
            Button("Restart") { model.timerAction(entry.id, action: "restart") }
            if !ringing {
                Button("Add a minute") { model.timerAction(entry.id, action: "addMinute") }
                    .disabled(entry.remaining + 60 > 604800)
                Button("Stop") { model.timerAction(entry.id, action: "stop") }
            }
        }
    }

    private func historyRow(_ entry: SideTask) -> some View {
        HStack(spacing: 8) {
            Text(entry.timerSubject).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 4)
            if let end = entry.completedAt {
                Text(end.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(entry.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            rowAction("Restart", symbol: "arrow.counterclockwise", entry: entry) {
                model.timerAction(entry.id, action: "restart")
            }
            .accessibilityIdentifier("timer-restart-" + entry.id.uuidString)
        }.frame(height: 34)
    }

    private func rowAction(_ title: String, symbol: String, entry: SideTask, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(model.accent.opacity(0.10), in: Circle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title + " " + entry.timerSubject)
    }

    private func start() {
        guard let seconds else { return }
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty, unit == .clock {
            title = "Timer at " + Date.now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
        }
        do {
            try model.startTimerFromTool(seconds: seconds, title: title)
            name = ""
            startError = nil
        } catch {
            startError = error.localizedDescription
        }
    }

    private static func clock(_ remaining: Double) -> String {
        let seconds = Int(ceil(remaining))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
