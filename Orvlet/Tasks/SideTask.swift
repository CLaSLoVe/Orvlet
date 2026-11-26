import AppKit
import Combine
import SwiftUI
import WebKit

enum SideTaskKind: String, Codable { case web, timer, calendar, result, workspace }
struct CapsuleAction {
    let id: String
    let label: String

    init?(id: String, label: String?) {
        guard let label else { return nil }
        self.id = id
        self.label = label
    }

    static func validate(_ actions: [Self]) throws {
        guard actions.count <= 1 else { throw AppError.message("Choose one frequent action for the capsule.") }
        if let action = actions.first {
            guard (1...3).contains(action.label.count), !action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.message("Use a short, legible compactLabel of 1–3 characters.")
            }
        }
    }
}

extension CapsuleAction {
    /// The shortcut and its six-point gap share a 108-point capsule with the text.
    var textWidth: CGFloat { 102 - buttonWidth }

    var buttonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return min(42, max(24, ceil(textWidth) + 8))
    }
}

struct SideTask: Identifiable, Codable {
    var id = UUID()
    var kind: SideTaskKind
    var title: String
    var terminalLabel: String? = nil
    var detail = ""
    var status = ""
    var sourceURL: String? = nil
    var plan: SurfacePlan? = nil
    var markup: CardMarkup? = nil
    var taskSurface: TaskSurface? = nil
    var artifactIDs: [UUID]? = nil
    var workFile: WorkFile? = nil
    var runtimeState: TaskRuntimeState? = nil
    var resumeOnHistoryRestore: Bool? = nil
    var dataUpdatedAt: Date? = nil
    var dataIssue: String? = nil
    var created = Date()
    var expires: Date? = nil
    var hidden = false
    var deadline: Date? = nil
    var pausedSeconds: Double? = nil
    var duration: Double? = nil
    var timerToolLauncher: Bool? = nil
    var completedAt: Date? = nil
    var pendingTimerReminderID: UUID? = nil
    var finished = false
    var muted: Bool? = nil
    var musicQueue: MusicQueue? = nil
    // nil is a legacy or ordinary web task. Music requests record their session policy here.
    var musicSessionRole: MusicSessionRole? = nil
    var playing = false
    var hasMedia = false
    var mediaPrimary: Bool? = nil
    var listening: Bool? = nil  // Verified task intent survives transient player/ad DOM changes.
    var prefersSource: Bool? = nil  // Watching/browsing may explicitly prefer the source.
    var liveValues: [String: String]? = nil
    var isMediaTask: Bool {
        kind == .web && (listening == true || (mediaPrimary != false && (plan?.hasMediaControls == true)))
    }
    var opensSourceByDefault: Bool {
        kind == .web && (prefersSource ?? (!isMediaTask && plan?.markup == nil && markup == nil))
    }
    mutating func updateMediaRole(primary: Bool?, url: String?) {
        if let url, let previous = sourceURL, previous != url {
            mediaPrimary = nil
            if URL(string: previous)?.host != URL(string: url)?.host {
                listening = false
                prefersSource = nil
            }
        }
        // Primary media is a page capability, not a requirement on generated bindings.
        // Keep the established role across hidden/replaced players on the same page.
        if primary == true { mediaPrimary = true } else if mediaPrimary != true, let primary { mediaPrimary = primary }
    }
    var interfaceIssue: String? = nil
    var intent: String? = nil
    var interfaceRecipeID: UUID? = nil
    var customCompact: Bool? = nil
    var generated = false
    var intrinsicCardHeight: Double? = nil
    var symbol: String {
        switch kind {
        case .web: return isMediaTask ? "music.note" : "globe"
        case .timer: return "timer"
        case .calendar: return "calendar"
        case .workspace: return "square.grid.2x2"
        case .result:
            return ["Task failed", "Needs attention"].contains(status) ? "exclamationmark.circle" : "checkmark.circle"
        }
    }

    var timerNeedsAttention: Bool {
        kind == .timer && (pendingTimerReminderID != nil || (deadline != nil && remaining <= 60))
    }
    var timerSubject: String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration, label.isEmpty || label.caseInsensitiveCompare("Timer") == .orderedSame else { return title }
        let seconds = Int(duration)
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }
    var timerAlarmText: String {
        if let rule = nativeTimerAlarmRule { return rule.message }
        return timerSubject == title ? "Time is up." : timerSubject + ", time is up."
    }
    var expandedDisplayState: [String: String] {
        guard let workFile else { return state }
        return state.merging(["preview": workFile.preview]) { _, preview in preview }
    }
    var remaining: Double { max(0, deadline?.timeIntervalSinceNow ?? pausedSeconds ?? 0) }
    var state: [String: String] {
        let seconds = Int(ceil(remaining))
        var values = [
            "title": title, "detail": detail, "status": status, "runtimeStatus": runtimeState?.phase.rawValue ?? "",
            "mediaPlaying": playing ? "true" : "false",
            "mediaMuted": muted == true ? "true" : "false", "muteLabel": muted == true ? "Unmute" : "Mute",
            "remaining": String(format: "%02d:%02d", seconds / 60, seconds % 60),
            "toggleLabel": kind == .timer
                ? (finished ? "Restart" : deadline == nil ? "Resume" : "Pause") : (playing ? "Pause" : "Play"),
        ].merging(liveValues ?? [:]) { _, reading in reading }
        if kind == .calendar {
            values["eventDuration"] = values["eventDuration"] ?? ""
            values["eventLocal"] = values["eventLocal"] ?? ""
            if values["eventGlance"] == nil {
                values["eventGlance"] = values["eventTime"]?.hasPrefix("All day") == true
                    ? values["eventDate"] : values["eventTime"]
            }
        }
        if kind == .timer, let duration {
            let total = Int(duration)
            values["remainingSeconds"] = String(seconds)
            values["timerSubject"] = timerSubject
            values["timerDuration"] = total % 60 == 0 ? "\(total / 60) minute timer" : "\(total) second timer"
        }
        if let surface = taskSurface, surface.preset == "clock" {
            values.merge(surface.clockOffsets(at: Date())) { _, current in current }
        }
        if let spec = taskSurface?.apiData { values = spec.presentationState(values) }
        return values
    }
    var mediaActions: [String: String] {
        guard isMediaTask else { return [:] }
        var result = ["toggle": "toggle"]
        for action in plan?.actions ?? [] where action.binding.action == "media" {
            if let operation = action.binding.operation { result[action.id] = operation }
        }
        return result
    }
    var capsuleAction: CapsuleAction? {
        if let action = taskSurface?.capsuleAction { return CapsuleAction(id: action.id, label: action.compactLabel) }
        if let action = plan?.actions?.first(where: { $0.compactLabel != nil }) {
            return CapsuleAction(id: action.id, label: action.compactLabel)
        }
        return nil
    }

    var allowedActions: Set<String> {
        var result: Set<String> = ["expand", "dismiss"]
        if kind == .web {
            result.insert("source")
            result.formUnion((plan?.actions ?? []).map(\.id))
            if isMediaTask { result.insert("toggle") }
        }
        if kind == .timer && timerToolLauncher != true { result.formUnion(["toggle", "restart", "stop", "addMinute"]) }
        if kind == .calendar { result.insert("calendar") }
        if kind == .workspace { result.formUnion(taskSurface?.actions.map(\.id) ?? []) }
        return result
    }
    /// Honest instant fallback for local tasks and old saved surfaces, replaced by generated markup when available.
    var presentation: CardMarkup {
        if let markup { return markup }
        if let markup = plan?.markup { return markup }
        if kind == .timer || kind == .calendar {
            var card =
                kind == .timer
                ? BuiltinCards.timer(finished: finished)
                : BuiltinCards.calendar(structured: liveValues?["eventDate"] != nil)
            card.height = intrinsicCardHeight ?? card.height
            return card
        }
        let toggle =
            kind == .timer || isMediaTask
            ? "<button class='calm-primary' data-action='toggle' data-bind='toggleLabel'></button>" : ""
        let primary =
            kind == .timer
            ? "<strong class='calm-value time' data-bind='remaining'></strong>"
            : "<strong class='calm-title' data-bind='title'></strong>"
        let extra =
            kind == .calendar
            ? "<button class='calm-secondary' data-action='calendar'>Open Calendar</button>"
            : kind == .web ? "<button class='calm-secondary' data-action='source'>Open page</button>" : ""
        return CardMarkup(
            html:
                "<section class='calm-surface'><div class='calm-result'>\(primary)<small class='calm-label' data-bind='status'></small><p class='calm-description' data-bind='detail'></p></div><div class='calm-actions'>\(toggle)\(extra)</div></section>",
            compactHTML: "<div class='calm-glance'>\(primary)</div>",
            css:
                ".time{font-size:32px}.calm-description:empty{display:none}.calm-actions:empty{display:none}.calm-description{white-space:pre-line}",
            height: kind == .timer ? 145 : 150)

    }
}
