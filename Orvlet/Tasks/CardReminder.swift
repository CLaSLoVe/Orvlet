import Foundation

enum ReminderDelivery: String, Codable, CaseIterable {
    case brief, untilAcknowledged, whileCondition

    var persistence: ReminderPersistence { self == .brief ? .brief : .persistent }

    static let authoringGuidance = """
        Use the host reminder API. Choose delivery from the user's intended outcome:
        • A requested deadline, signal, or handoff that needs confirmation → untilAcknowledged. The host brings the card forward and repeats the user's Alarm sound until acknowledged, even if the source moves on.
        • An outstanding condition that calls for someone to act → whileCondition on its saved value. Use the alarm while action is useful; withdraw it when the condition clears, including when another person handles it.
        • Ordinary news the user wants to hear once → brief. The host plays the user's Message sound once.
        • Passive status, an automatic retry, or an error that repaired itself → omit reminder. For failures, alert only when recovery leaves work for the person.
        Intensity controls urgency and repeat cadence. Delivery selects the sound category.
        """
}

/// Generated handlers describe an outcome. Orvlet owns its window, sound and dismissal.
struct GeneratedReminder: Codable, Equatable {
    let message: String
    var intensity: ReminderIntensity? = nil
    var persistence: ReminderPersistence? = nil
    var delivery: ReminderDelivery? = nil

    func validate(condition: CardReminderRule.Condition? = nil) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.count <= 240 else {
            throw AppError.message("A reminder needs a message between 1 and 240 characters.")
        }
        guard delivery == nil || persistence == nil else {
            throw AppError.message("Set delivery and omit the legacy persistence field.")
        }
        if delivery == .whileCondition, condition == nil || condition == .changed {
            throw AppError.message("whileCondition needs an equals, atLeast, or atMost rule on a saved value. For a one-time event, use untilAcknowledged or brief.")
        }
    }

    static func fromAction(_ result: [String: Any]) throws -> Self? {
        // Flat legacy outputs may have an ordinary scalar field called reminder.
        guard result["state"] is [String: Any], let object = result["reminder"], !(object is NSNull) else { return nil }
        guard object is [String: Any] else { throw AppError.message("Return a reminder object beside state.") }
        let reminder = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        try reminder.validate()
        return reminder
    }
}

struct CardReminderRule: Codable, Equatable {
    enum Condition: String, Codable { case equals, atLeast, atMost, changed }
    var key: String
    let condition: Condition
    var value: String? = nil
    let message: String
    var intensity: ReminderIntensity? = nil
    var persistence: ReminderPersistence? = nil
    var delivery: ReminderDelivery? = nil

    var reminder: GeneratedReminder { .init(message: message, intensity: intensity, persistence: persistence, delivery: delivery) }

    func validate(available: Set<String>) throws {
        try reminder.validate(condition: condition)
        guard available.contains(key) else {
            throw AppError.message("Choose a reminder key among the card's saved values: " + available.sorted().joined(separator: ", "))
        }
        switch condition {
        case .changed: break
        case .equals:
            guard let value, value.count <= 240 else { throw AppError.message("Supply the state value to match.") }
        case .atLeast, .atMost:
            guard let value, Double(value)?.isFinite == true else { throw AppError.message("Use a finite numeric reminder threshold.") }
        }
    }

    func matches(_ raw: String) -> Bool? {
        switch condition {
        case .changed: return true
        case .equals: return raw == value
        case .atLeast, .atMost:
            guard let x = Double(raw), x.isFinite, let value, let threshold = Double(value) else { return nil }
            return condition == .atLeast ? x >= threshold : x <= threshold
        }
    }

    /// Host countdowns stop at exactly zero. Other readings may happen to contain the same text.
    fileprivate func signalsCompletion(atZero zero: String) -> Bool {
        switch condition {
        case .equals: return value == zero
        case .atMost: return zero == "0" && value.flatMap(Double.init) == 0
        case .atLeast, .changed: return false
        }
    }

    var signalsNativeTimerCompletion: Bool {
        key == "remainingSeconds" && signalsCompletion(atZero: "0")
            || key == "remaining" && signalsCompletion(atZero: "00:00")
    }

    static func decode(_ object: Any?) throws -> Self? {
        guard let object, !(object is NSNull) else { return nil }
        guard let fields = object as? [String: Any] else { throw AppError.message("A reminder rule must be an object.") }
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    static let schema = schema(forKeyDescription: "The saved value to observe.")

    static func schema(forKeyDescription keyDescription: String) -> [String: Any] { [
        "type": "object",
        "description": "Raise a hidden or visible card on a saved value's transition. The initial value establishes a baseline. Use changed only for discrete events. " + ReminderDelivery.authoringGuidance,
        "properties": [
            "key": ["type": "string", "description": keyDescription],
            "condition": ["type": "string", "enum": ["equals", "atLeast", "atMost", "changed"]],
            "value": ["type": "string", "description": "Comparison value; omit for changed."],
            "message": ["type": "string", "minLength": 1, "maxLength": 240],
            "intensity": ["type": "string", "enum": ["gentle", "standard", "strong"]],
            "delivery": ["type": "string", "enum": ReminderDelivery.allCases.map(\.rawValue)]
        ], "required": ["key", "condition", "message", "delivery"]
    ] }

    fileprivate func resolvedDelivery(atDeadline: Bool) -> ReminderDelivery {
        if atDeadline { return .untilAcknowledged }
        if let delivery { return delivery }
        return persistence == .persistent ? .whileCondition : .brief
    }
}

extension SideTask {
    var cardReminderRule: CardReminderRule? { taskSurface?.reminder ?? markup?.reminder ?? plan?.markup?.reminder }
    var nativeTimerAlarmRule: CardReminderRule? {
        guard kind == .timer, let rule = cardReminderRule, rule.signalsNativeTimerCompletion else { return nil }
        return rule
    }
}

struct SavedReminderCondition: Codable {
    let rule: CardReminderRule
    let selected: UUID?
    let changedValue: String?
}

struct CardReminderObservation {
    var rule: CardReminderRule
    var selected: UUID?
    var value: String
    var eventID: UUID?
    var revision = UUID()

    mutating func reconnect(_ saved: SavedReminderCondition, eventID: UUID) -> Bool {
        guard rule == saved.rule, selected == saved.selected, rule.matches(value) == true,
              self.eventID == nil || self.eventID == eventID,
              rule.condition != .changed || value == saved.changedValue else { return false }
        self.eventID = eventID
        revision = UUID()
        return true
    }
}

extension AppModel {
    func deliverCardReminder(_ reminder: GeneratedReminder, to owner: UUID) {
        let delivery = reminder.delivery ?? (reminder.persistence == .persistent ? .untilAcknowledged : .brief)
        notifyFromGeneratedCard(owner, message: reminder.message, intensity: reminder.intensity ?? .standard,
                                persistence: delivery.persistence)
    }

    /// A rendered web view may be absent. Follow the committed task data, including hidden views.
    func observeCardReminders() {
        var owners = Set<UUID>()
        for card in sideTasks {
            guard let rule = card.cardReminderRule else { continue }
            let view = work.view(card.id)
            guard view?.closed != true else { continue }
            owners.insert(card.id)
            let artifact = view.flatMap { work.artifact($0.selected) }
            // A decorated native timer already delivers the alarm for this crossing.
            let native = artifact?.native ?? (card.kind == .timer ? card : nil)
            let nativeDeadline = view?.layout != .together && native?.kind == .timer && rule.signalsNativeTimerCompletion
            if nativeDeadline, let native, work.view(native.id)?.closed != true {
                clearCardReminderObservation(card.id)
                continue
            }
            // A pending input draft is a preview; only saved results can cross a threshold.
            let committed = view?.layout == .together || artifact?.native != nil ? nil : artifact?.values[rule.key]
            guard view?.draftInputs == nil || (cardReminderValues[card.id] == nil && committed != nil) else { continue }
            let raw = committed ?? card.state[rule.key]
            guard let raw, let matches = rule.matches(raw) else { continue }
            guard var observed = cardReminderValues[card.id], observed.rule == rule, observed.selected == view?.selected else {
                clearCardReminderObservation(card.id)
                cardReminderValues[card.id] = .init(rule: rule, selected: view?.selected, value: raw)
                continue
            }
            guard raw != observed.value else { continue }
            let crossed = matches && (rule.condition == .changed || rule.matches(observed.value) == false)
            observed.value = raw
            if !matches || crossed {
                if let event = observed.eventID { Task { @MainActor [weak self] in self?.dismissReminder(event) } }
                observed.eventID = nil
                observed.revision = UUID()
            }
            cardReminderValues[card.id] = observed
            guard crossed else { continue }
            let ticket = observed.revision
            let owner = card.id
            let deadline = card.taskSurface?.runtime?.sources.first { $0.kind == .deadline && $0.key == rule.key }
            let atDeadline = nativeDeadline || deadline.map {
                rule.signalsCompletion(atZero: $0.format == .seconds ? "0" : "00:00:00")
            } == true
            let delivery = rule.resolvedDelivery(atDeadline: atDeadline)
            let requiresCurrentValue = delivery == .whileCondition || (delivery == .brief && rule.delivery == nil)
            let condition = delivery == .whileCondition
                ? SavedReminderCondition(rule: rule, selected: view?.selected, changedValue: rule.condition == .changed ? raw : nil) : nil
            Task { @MainActor [weak self] in
                guard let self, !requiresCurrentValue || cardReminderValues[owner]?.revision == ticket else { return }
                let event = notifyFromGeneratedCard(owner, message: rule.message, intensity: rule.intensity ?? .standard,
                                                    persistence: delivery.persistence,
                                                    condition: condition)
                // A relaunch must see the sample that led to the saved receipt.
                if delivery != .brief, event != nil { work.save() }
                if condition != nil, cardReminderValues[owner]?.revision == ticket {
                    cardReminderValues[owner]?.eventID = event
                }
            }
        }
        for owner in Set(cardReminderValues.keys).subtracting(owners) { clearCardReminderObservation(owner) }
    }

    private func clearCardReminderObservation(_ owner: UUID) {
        if let event = cardReminderValues.removeValue(forKey: owner)?.eventID {
            Task { @MainActor [weak self] in self?.dismissReminder(event) }
        }
    }
}
