import Foundation

/// An optional behavior for a scalar that the person records repeatedly.
struct ActionJournalSpec: Codable, Equatable {
    enum Scope: String, Codable { case day, allTime }
    var valueKey: String
    var scope: Scope
    var recentLabel: String?
    var undoLabel: String?

    static let schema: [String: Any] = [
        "type": "object",
        "description": "Use for recording a cumulative numeric quantity. The host records real local times, shows recent changes and provides Undo. Use day for a total that resets each local calendar day, allTime for a running total.",
        "properties": [
            "valueKey": ["type": "string", "description": "The single changing numeric output without a unit suffix. Other outputs must be static; fields can hold user-selected amounts."],
            "scope": ["type": "string", "enum": ["day", "allTime"]],
            "recentLabel": ["type": "string", "description": "Localized short heading for recent entries."],
            "undoLabel": ["type": "string", "description": "Localized short label for undoing the latest entry."]
        ], "required": ["valueKey", "scope"]
    ]

    /// Only the recorded quantity is reversible. Inputs remain the user's current choices.
    func validatePatch(_ patch: [String: String], base: [String: String]) throws {
        guard patch.allSatisfy({ $0.key == valueKey || base[$0.key] == $0.value }),
              (patch[valueKey] ?? base[valueKey]).flatMap(Double.init)?.isFinite == true else {
            throw ToolArgumentError(path: "$.journal.valueKey", issue: "A scalar journal action can change only its numeric output. Keep other readings static or use a different representation for coupled results.")
        }
    }

    func validate(_ surface: TaskSurface) throws {
        guard let value = surface.state[valueKey], Double(value)?.isFinite == true,
              valueKey != "journalRecent", !surface.fields.contains("journalRecent"), !surface.fields.contains(valueKey), surface.markup.bindingKeys.contains(valueKey),
              surface.runtime == nil, surface.apiData == nil,
              surface.actions.contains(where: { $0.kind == .code }),
              surface.actions.allSatisfy({ $0.kind == .code || $0.kind == .view || ($0.kind == .resource && $0.id == "undoJournal") }),
              !surface.actions.contains(where: { $0.id == "undoJournal" && $0.kind != .resource }),
              [recentLabel, undoLabel].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.count <= 60 })
        else {
            throw ToolArgumentError(path: "$.journal", issue: "Bind a finite numeric output changed by a local action. Keep units separate from its value. Undo is provided by the host.")
        }
    }
}

struct JournalHistory: Codable {
    struct Entry: Codable {
        let at: Date
        let before: String
        let after: String
    }
    var day: Date
    var entries: [Entry] = []
}

extension WorkArtifact {
    @discardableResult
    mutating func rollJournal(to now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let spec = definition.journal else { return false }
        guard let history = journalHistory else {
            journalHistory = JournalHistory(day: now)
            return true
        }
        guard spec.scope == .day, !calendar.isDate(history.day, inSameDayAs: now) else { return false }
        values[spec.valueKey] = "0"
        journalHistory = JournalHistory(day: now)
        return true
    }

    mutating func recordJournal(from previous: String, at date: Date) {
        guard let spec = definition.journal, let value = values[spec.valueKey],
              let before = Double(previous), let after = Double(value),
              before.isFinite, after.isFinite, before != after else { return }
        if journalHistory == nil { journalHistory = JournalHistory(day: date) }
        journalHistory?.entries.insert(.init(at: date, before: previous, after: value), at: 0)
        if (journalHistory?.entries.count ?? 0) > 12 { journalHistory?.entries.removeLast() }
    }

    @discardableResult
    mutating func undoJournal(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let rolled = rollJournal(to: date, calendar: calendar)
        guard let spec = definition.journal, let entry = journalHistory?.entries.first,
              values[spec.valueKey] == entry.after else { return rolled }
        values[spec.valueKey] = entry.before
        journalHistory?.entries.removeFirst()
        return true
    }
}

extension CardMarkup {
    /// Keep host-projected controls and records out of saved/reused card designs.
    var excludingJournal: CardMarkup {
        guard let start = html.range(of: "<section class='calm-journal'><header><small class='calm-label'>"),
              let end = html.range(of: "</section>", range: start.upperBound..<html.endIndex) else { return self }
        var result = self
        result.html.removeSubrange(start.lowerBound..<end.upperBound)
        return result
    }
}

extension TaskSurface {
    var excludingJournalPresentation: TaskSurface {
        guard journal != nil else { return self }
        var result = self
        result.markup = markup.excludingJournal
        result.actions.removeAll { $0.kind == .resource && $0.id == "undoJournal" }
        result.state.removeValue(forKey: "journalRecent")
        return result
    }

    mutating func presentJournal(_ artifact: WorkArtifact, language: String) {
        guard let spec = artifact.definition.journal else { return }
        let locale = CardMarkup.localeIdentifier(for: language) ?? "en"
        let chinese = locale.hasPrefix("zh")
        let traditional = Locale(identifier: locale).language.script?.identifier == "Hant"
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        if !markup.html.contains("class='calm-journal'") {
            let recent = escape(spec.recentLabel ?? (chinese ? (traditional ? "最近紀錄" : "最近记录") : "Recent entries"))
            let undo = escape(spec.undoLabel ?? (chinese ? (traditional ? "撤銷上一次" : "撤销上一次") : "Undo last"))
            markup.html += "<section class='calm-journal'><header><small class='calm-label'>" + recent +
                "</small><button class='calm-secondary' data-action='undoJournal'>" + undo +
                "</button></header><ol class='calm-list'></ol></section>"
        }
        if !actions.contains(where: { $0.id == "undoJournal" }) {
            actions.append(.init(id: "undoJournal", kind: .resource, operation: "undoJournal"))
        }
        // Only the three visible records cross the web-view boundary.
        let entries = (artifact.journalHistory?.entries ?? []).prefix(3).compactMap { entry -> [String: Double]? in
            guard let old = Double(entry.before), let new = Double(entry.after), (new - old).isFinite else { return nil }
            return ["time": entry.at.timeIntervalSince1970 * 1000, "change": new - old]
        }
        state["journalRecent"] = JSONText.encode(entries)
    }
}

@MainActor
extension AppModel {
    @discardableResult
    func rollDailyJournal(_ id: UUID, now: Date = Date()) -> Bool {
        guard var item = work.artifact(id), item.rollJournal(to: now) else { return false }
        return work.update(id, expecting: item.revision) { $0 = item }
    }

    func refreshDailyJournals() {
        for artifact in work.snapshot.artifacts.values where artifact.definition.journal?.scope == .day {
            if rollDailyJournal(artifact.id) { projectWorkResult(artifact.id) }
        }
    }
}
