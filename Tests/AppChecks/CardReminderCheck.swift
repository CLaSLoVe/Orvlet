#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum CardReminderCheck {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            try StateMachineCheck.require(condition, label, &checks)
        }
        let suite = "orvlet-generated-reminders-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.persistHistory = false
        model.settings.autoAdapt = false
        model.settings.alarmSound = .slowRise
        model.settings.messageSound = .keys
        let focus = BackgroundFocusCheck()
        let delegate = AppDelegate(model: model)
        let wasAppHidden = NSApp.isHidden
        let screen = NSRect(x: -18000, y: -18000, width: 1600, height: 950)
        let shell = ShellPanel(contentRect: NSRect(origin: screen.origin, size: model.compactSize),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        delegate.panel = shell
        model.onRemindersChanged = { [weak delegate] in delegate?.presentReminders(in: screen) }
        var sounds: [(ReminderSound, ReminderIntensity)] = []
        model.reminderSoundPlaybackCheck = { sounds.append(($0, $1)) }
        defer {
            model.stopReminderRepeats()
            model.onRemindersChanged = nil
            delegate.reminderPanel?.orderOut(nil)
            shell.orderOut(nil)
            if !wasAppHidden && NSApp.isHidden { NSApp.unhideWithoutActivation() }
            model.taskClock?.invalidate()
            model.taskRuntime.stopAll()
            defaults.removePersistentDomain(forName: suite)
        }

        let owner = UUID()
        let json = #"""
        {"title":"Parcel 42","state":{"phase":"In transit"},"fields":[],"actions":[],
         "markup":{"html":"<strong data-bind='phase'></strong>","compactHTML":"<span data-bind='phase'></span>","css":"","height":170,
                   "reminder":{"key":"phase","condition":"equals","value":"Delivered","message":"Your parcel is ready for collection.",
                               "intensity":"strong","delivery":"whileCondition"}}}
        """#
        let surface = try JSONDecoder().decode(TaskSurface.self, from: Data(json.utf8))
        try model.commitTaskSurface(surface, id: owner, ticket: nil)
        guard let artifactID = model.work.view(owner)?.selected else { throw AppError.message("Missing generated view") }
        model.dismissTask(owner)
        model.hide()
        NSApp.hide(nil)
        try check(model.reminders.isEmpty && sounds.isEmpty, "Mounting or hiding a generated card is silent")

        func transition(to value: String) throws {
            guard let artifact = model.work.artifact(artifactID),
                  model.work.update(artifactID, expecting: artifact.revision, { $0.values["phase"] = value }) else {
                throw AppError.message("Failed to update the generated card fixture")
            }
            model.projectWorkResult(artifactID)
        }
        try transition(to: "Delivered")
        try await Task.sleep(for: .milliseconds(150))
        guard let first = model.reminders.first, let panel = delegate.reminderPanel else {
            throw AppError.message("A hidden generated card did not present its notification")
        }
        try check(first.owner == owner && first.intensity == .strong && first.persistence == .persistent
                  && first.message == "Your parcel is ready for collection."
                  && panel.isVisible && !panel.isKeyWindow && !panel.canHide && panel.level > .normal && screen.contains(panel.frame)
                  && panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary])
                  && !shell.isVisible && model.work.view(owner)?.hidden == true,
                  "A hidden, unmounted generated card presents its own foreground notification")
        try check(sounds.count == 1 && sounds.first?.0 == .slowRise && sounds.first?.1 == .strong,
                  "The foreground reminder selects the configured sound at its requested intensity")
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-reminder-strong.png")
        try transition(to: "Delivered")
        model.projectWorkResult(artifactID)
        try check(model.reminders.count == 1 && sounds.count == 1, "An unchanged result and repeated render do not replay its reminder")
        for _ in 0..<60 where sounds.count == 1 { try await Task.sleep(for: .milliseconds(100)) }
        try check(sounds.count == 2 && sounds.last?.0 == .slowRise && sounds.last?.1 == .strong
                  && model.displayedReminders.first?.id == first.id && panel.isVisible,
                  "The hidden card's pending condition sounds again with the same receipt and selected tone")
        model.settings.alarmSound = .silent
        model.settings.messageSound = .silent
        model.notifyFromGeneratedCard(owner, message: "Tracking history updated", intensity: .gentle, persistence: .brief)
        try check(model.reminders.count == 2 && sounds.count == 2, "A gentle silent reminder can arrive alongside a persistent one")
        let urgent = model.notifyFromGeneratedCard(owner, message: "Collection closes shortly", intensity: .strong)
        try check(urgent != nil && model.displayedReminders.first?.id == urgent && model.displayedReminders.count == 3,
                  "A strong brief reminder appears immediately while a gentler notice is onscreen")
        for _ in 0..<150 where model.reminders.count > 1 { try await Task.sleep(for: .milliseconds(100)) }
        try check(model.reminders.count == 1 && model.reminders.first?.id == first.id && panel.isVisible && sounds.count == 2,
                  "Muting stops audible repeats while the persistent card stays visible beyond the brief timeout")
        model.dismissReminder(first.id)
        try await Task.sleep(for: .milliseconds(200))
        try check(model.reminders.isEmpty && !panel.isVisible, "Dismissing the last reminder clears the foreground panel")
        try transition(to: "In transit")
        try transition(to: "Delivered")
        try await Task.sleep(for: .milliseconds(80))
        try check(model.reminders.count == 1 && sounds.count == 2, "A new crossing rearms the rule even with sound disabled")
        model.settings.alarmSound = .slowRise
        model.settings.messageSound = .keys
        try transition(to: "In transit")
        try await Task.sleep(for: .milliseconds(100))
        try check(model.reminders.isEmpty && !panel.isVisible, "Resolving the underlying condition withdraws its persistent notification")
        model.closeTask(owner)
        try transition(to: "Delivered")
        try await Task.sleep(for: .milliseconds(80))
        try check(model.reminders.isEmpty && model.work.view(owner)?.closed == true, "Closing a generated view retires its alerts")
        if !wasAppHidden && NSApp.isHidden { NSApp.unhideWithoutActivation() }

        let actionOwner = UUID()
        var tool = TaskSurface(title: "Export", markup: CardMarkup(
            html: "<strong data-bind='phase'></strong><button data-action='finish'>Finish</button>",
            compactHTML: "<span data-bind='phase'></span>", css: ""), fields: [], actions: [], state: ["phase": "Waiting"])
        tool.actions = [.init(id: "finish", kind: .code, code:
            "return {state:{phase:'Complete'},reminder:{message:'Export finished',intensity:'strong',delivery:'brief'}};")]
        try model.commitTaskSurface(tool, id: actionOwner, ticket: nil)
        guard let action = model.performWorkAction(viewID: actionOwner, action: "finish", fields: [:]) else {
            throw AppError.message("Missing generated action")
        }
        await action.value
        try check(model.reminders.count == 1 && model.reminders.first?.owner == actionOwner
                  && model.reminders.first?.intensity == .strong && model.reminders.first?.persistence == .brief
                  && model.reminders.first?.message == "Export finished",
                  "A generated handler can request its own notification after its state update commits")
        var rejectedCondition = false
        do {
            _ = try GeneratedReminder.fromAction([
                "state": ["phase": "Complete"],
                "reminder": ["message": "Export finished", "delivery": "whileCondition"]
            ])
        } catch { rejectedCondition = true }
        try check(rejectedCondition, "A one-off action must supply an observable rule to request condition-based delivery")
        try await Task.sleep(for: .milliseconds(3400))
        try check(sounds.count == 3 && sounds.last?.0 == .keys && sounds.last?.1 == .strong && model.reminders.count == 1,
                  "A strong brief event sounds only at arrival and clearing the previous condition stops its cadence")
        model.dismissTask(actionOwner)
        if let notice = model.reminders.first { model.openReminder(notice) }
        try check(model.selectedTaskID == actionOwner && !model.collapsed && model.work.view(actionOwner)?.hidden == false,
                  "Opening a generated reminder reveals its own card on demand")
        let issueOwner = try model.startTimer(seconds: 400, title: "Tea")
        model.settings.messageSound = .pop
        let unreadBeforeIssue = model.unreadReplyIDs
        model.reportTaskIssue(issueOwner, source: .data, detail: "Retrying a background refresh")
        model.resolveTaskIssue(issueOwner, source: .data)
        try await Task.sleep(for: .milliseconds(150))
        try check(model.reminders.isEmpty && model.capsuleAttention[issueOwner] == nil
                  && sounds.count == 3 && model.unreadReplyIDs == unreadBeforeIssue,
                  "A recovered background error leaves no foreground alert, glow, unread badge or sound")
        let saved = try JSONEncoder().encode(model.settings)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: saved)
        var legacy = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        try check(roundTrip.alarmSound == .slowRise && roundTrip.messageSound == .pop, "Alarm and message choices persist independently")
        legacy["alarmSound"] = "alarm"
        legacy["messageSound"] = "bamboo"
        let upgraded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(upgraded.alarmSound == .slowRise && upgraded.messageSound == .bamboo,
                  "The previous Alarm selection upgrades to Slow Rise and preserves Bamboo")
        legacy.removeValue(forKey: "alarmSound")
        legacy.removeValue(forKey: "messageSound")
        for value in ["automatic", "chime", "silent", "tink"] {
            legacy["reminderSound"] = value
            let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
            let explicit = ReminderSound(rawValue: value)
            try check(migrated.alarmSound == (value == "silent" ? .silent : .slowRise) && migrated.messageSound == (explicit ?? .bamboo),
                      "The shared \(value) preference migrates to both sound choices")
        }
        for sound in ReminderSound.allCases where sound != .silent {
            guard let url = sound.url, let cue = NSSound(contentsOf: url, byReference: true) else {
                throw AppError.message("The native sound player could not load " + sound.title)
            }
            try check(cue.duration > 0, "The native sound player loads " + sound.title)
        }
        model.settings.alarmSound = .slowRise

        let settingsPanel = NSPanel(contentRect: NSRect(x: screen.minX, y: screen.minY, width: 520, height: 710),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { settingsPanel.orderOut(nil) }
        settingsPanel.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: 0))
        settingsPanel.orderBack(nil)
        try await Task.sleep(for: .milliseconds(220))
        func popup(_ id: String, in view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton, button.identifier?.rawValue == id { return button }
            for child in view.subviews {
                if let found = popup(id, in: child) { return found }
            }
            return nil
        }
        guard let content = settingsPanel.contentView,
              let alarms = popup("sound-persistent", in: content),
              let messages = popup("sound-brief", in: content) else {
            throw AppError.message("Missing sound choices in Settings")
        }
        let alarmFrame = alarms.convert(alarms.bounds, to: content)
        let messageFrame = messages.convert(messages.bounds, to: content)
        try check(alarmFrame.width > 100 && alarmFrame.minX == messageFrame.minX && alarmFrame.maxX == messageFrame.maxX,
                  "The two native sound selectors have matching left and right edges")
        for (button, tone) in [(alarms, ReminderSound.ripples), (messages, .input)] {
            guard let menu = button.menu, let item = button.item(withTitle: tone.title),
                  button.isEnabled, item.isEnabled, item.target != nil, item.action != nil else {
                throw AppError.message("Disabled sound option: " + tone.title)
            }
            menu.performActionForItem(at: menu.index(of: item))
            try await Task.sleep(for: .milliseconds(120))
            try check(button.titleOfSelectedItem == tone.title && sounds.last?.0 == tone,
                      "Choosing " + tone.title + " from its native menu updates the selection and previews it")
        }
        let changed = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(model.settings))
        try check(changed.alarmSound == .ripples && changed.messageSound == .input,
                  "Both choices from the Settings menus survive saving and loading together")
        try await SideScreenCheck.snapshot(settingsPanel, path: "/tmp/orvlet-reminder-settings.png")
        // Hit the two replay controls in the 520 × 710 Settings viewport captured above.
        for (y, tone) in [(340, ReminderSound.ripples), (306, .input)] {
            let point = NSPoint(x: 440, y: y)
            for _ in 0..<2 {
                let count = sounds.count
                guard let content = settingsPanel.contentView,
                      let hit = content.hitTest(content.convert(point, from: nil)) else {
                    throw AppError.message("Missing Settings preview for " + tone.title)
                }
                if let button = hit as? NSButton {
                    button.performClick(nil)
                } else {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: settingsPanel.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        settingsPanel.sendEvent(event)
                    }
                }
                try await Task.sleep(for: .milliseconds(120))
                try check(sounds.count == count + 1 && sounds.last?.0 == tone, "Clicking the Settings preview replays " + tone.title)
            }
        }
        try check(!focus.tookFocus && !settingsPanel.isKeyWindow,
                  "Presenting and dismissing an Orvlet reminder keeps the current app's focus")
        model.deliverReply("The export failed. Choose a writable folder.", kind: .failure, taskID: actionOwner)
        model.deliverReply("How long should the tea steep?", kind: .needsInput, taskID: issueOwner)
        guard let question = model.reminders.first(where: { $0.owner == issueOwner && $0.needsInput }) else {
            throw AppError.message("A clarification did not reach the foreground panel")
        }
        model.beginAmbientRequest("Refresh the card", taskID: issueOwner)
        try check(model.displayedReminders.contains { $0.id == question.id },
                  "Starting a non-conversation action on the same task leaves its unanswered question visible")
        model.settings.main = Endpoint()
        model.settings.useFast = false
        model.openTaskConversation(issueOwner)
        model.command = "pause"
        model.sendCommand()
        try check(model.reminders.contains { $0.id == question.id },
                  "Using a timer control from the conversation leaves its clarification pending")
        model.command = "Two minutes"
        model.sendCommand()
        try check(!model.reminders.contains { $0.id == question.id },
                  "Submitting a user reply on the question's conversation clears the question")
        checks += try await timerTool(in: screen)
        checks += try await countdownAcknowledgement(in: screen)
        try check(model.displayedReminders.contains { $0.owner == actionOwner && $0.destination == .conversation }
            && panel.isVisible, "A terminal failure awaiting user action remains visible beyond the brief timeout")
        try check(!focus.tookFocus,
                  "Countdown delivery, restoration and acknowledgement preserve the active desktop app")
        return checks
    }

    static func timerTool(in screen: NSRect) async throws -> [String] {
        var checks: [String] = []
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = TimeZone(identifier: "America/New_York")!
        func stamp(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            clock.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        let teaTime = stamp(11, 4, 15, 30)
        try StateMachineCheck.require(
            TimerCard.nextClockTime(teaTime, after: stamp(11, 4, 9, 0), calendar: clock) == teaTime
                && TimerCard.nextClockTime(teaTime, after: teaTime, calendar: clock) == stamp(11, 5, 15, 30),
            "Clock-time countdowns use today's future time and roll an elapsed time over to tomorrow", &checks)
        try StateMachineCheck.require(
            TimerCard.nextClockTime(stamp(3, 7, 2, 30), after: stamp(3, 7, 20, 0), calendar: clock) == stamp(3, 8, 3, 30),
            "A skipped spring-forward hour advances to the next valid matching minute", &checks)
        let suite = "orvlet-unified-timer-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults)
        model.isLiveTest = true
        model.settings.appearance = .light
        model.settings.reduceMotion = true
        model.settings.alarmSound = .silent
        let tea = try model.startTimer(seconds: 180, title: "Tea")
        let toast = try model.startTimer(seconds: 180, title: "Toast")
        model.openTimerTool()
        let laundry = try model.startTimerFromTool(seconds: 900, title: "Laundry")
        model.timerAction(laundry, action: "toggle")
        let panel = NSPanel(contentRect: NSRect(origin: screen.origin, size: NSSize(width: 328, height: 312)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer {
            panel.orderOut(nil)
            model.stopReminderRepeats()
            model.taskClock?.invalidate()
            defaults.removePersistentDomain(forName: suite)
        }
        try StateMachineCheck.require(!model.collapsed && model.orderedTasks.map(\.id) == [tea]
            && model.ambientTasks.map(\.id) == [tea] && Set(model.timerEntries.map(\.id)) == [tea, toast, laundry],
            "Two equal running countdowns and one paused countdown share one Timer in Tasks and the capsule", &checks)
        panel.contentView = NSHostingView(rootView: TimerCard(model: model).background(Color.white))
        panel.orderBack(nil)
        try await Task.sleep(for: .milliseconds(250))
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-unified-timer.png")
        for i in model.sideTasks.indices where [tea, toast].contains(model.sideTasks[i].id) {
            model.sideTasks[i].deadline = .now.addingTimeInterval(-1)
        }
        model.tickTasks()
        try StateMachineCheck.require(model.orderedTasks.map(\.id) == [tea] && Set(model.reminders.map(\.owner)) == [tea, toast],
            "Overlapping alarms retain their original names and acknowledgement owners inside one tool", &checks)
        model.acknowledgeTimerFromTool(tea)
        try StateMachineCheck.require(model.reminders.map(\.owner) == [toast] && model.timerEntries.filter(\.finished).count == 2,
            "Acknowledging Tea leaves Toast ringing and keeps both finished entries available", &checks)
        model.persistSideTasks()
        let restored = AppModel(defaults: defaults)
        restored.isLiveTest = true
        restored.loadSideTasks()
        defer { restored.taskClock?.invalidate(); restored.stopReminderRepeats() }
        try StateMachineCheck.require(restored.orderedTasks.map(\.id) == [tea] && restored.timerEntries.count == 3
            && restored.reminders.map(\.owner) == [toast], "Restoring Timer preserves its entries and pending alarm", &checks)
        restored.closeTaskTool(tea)
        restored.tickTasks()
        try StateMachineCheck.require(restored.timerTool == nil && restored.reminders.isEmpty,
            "Deleting the Timer tool removes its entries and ends its outstanding alarm", &checks)
        restored.openTimerTool()
        try StateMachineCheck.require(restored.timerEntries.isEmpty && restored.timerTool != nil && !restored.collapsed,
            "Add Timer opens a clean editor before any countdown is armed", &checks)
        let editor = NSHostingView(rootView: TimerCard(model: restored).background(Color.white))
        panel.contentView = editor
        try await Task.sleep(for: .milliseconds(250))
        // Centers of the second preset and Start in the empty 328-point editor, measured from its top left.
        for (x, y): (CGFloat, CGFloat) in [(87, 96), (275, 59)] {
            let local = NSPoint(x: x, y: editor.isFlipped ? y : editor.bounds.height - y)
            let point = editor.convert(local, to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
                panel.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try StateMachineCheck.require(restored.timerEntries.map(\.duration) == [900] &&
            restored.timerEntries.first?.deadline != nil && restored.orderedTasks.count == 1 && !restored.collapsed,
            "Clicking 15 min and Start arms a 900-second countdown inside the same Timer", &checks)
        let aliasSuite = "orvlet-linked-timer-" + UUID().uuidString
        let aliasDefaults = UserDefaults(suiteName: aliasSuite)!
        let linked = AppModel(defaults: aliasDefaults)
        linked.isLiveTest = true
        linked.settings.alarmSound = .silent
        defer { linked.stopReminderRepeats(); aliasDefaults.removePersistentDomain(forName: aliasSuite) }
        checks += try await WorkSeparationCheck.timerViews(linked)
        return checks
    }

    private static func countdownAcknowledgement(in screen: NSRect) async throws -> [String] {
        let suite = "orvlet-countdown-receipts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [String] = []
        var soundTimes: [ContinuousClock.Instant] = []
        var soundCount: Int { soundTimes.count }
        func session() -> AppModel {
            let model = AppModel(defaults: defaults)
            model.settings.main = Endpoint()
            model.settings.useFast = false
            model.settings.autoAdapt = false
            model.settings.alarmSound = .tink
            model.reminderSoundPlaybackCheck = { _, _ in soundTimes.append(.now) }
            return model
        }
        let model = session()
        let delegate = AppDelegate(model: model)
        model.onRemindersChanged = { [weak delegate] in delegate?.presentReminders(in: screen) }
        defer {
            model.taskClock?.invalidate()
            delegate.reminderPanel?.orderOut(nil)
        }
        let tea = try model.startTimer(seconds: 1, title: "Steep the tea")
        let bread = try model.startTimer(seconds: 1, title: "Check the bread")
        model.dismissTask(tea)
        model.hide()
        try await Task.sleep(for: .milliseconds(1200))
        model.tickTasks()
        try await Task.sleep(for: .milliseconds(10300))
        model.tickTasks()
        guard let panel = delegate.reminderPanel, panel.isVisible, screen.contains(panel.frame),
              Set(model.displayedReminders.map(\.owner)) == [tea, bread],
              let teaAlarm = model.displayedReminders.first(where: { $0.owner == tea }),
              let breadAlarm = model.displayedReminders.first(where: { $0.owner == bread })
        else { throw AppError.message("Both elapsed countdowns must remain on the foreground panel after ten seconds without acknowledgement") }
        for _ in 0..<30 where soundCount < 4 { try await Task.sleep(for: .milliseconds(100)) }
        try StateMachineCheck.require(!panel.isKeyWindow && model.visibleTasks.contains { $0.id == bread }
            && !model.visibleTasks.contains { $0.id == tea } && soundCount == 4
            && soundTimes[2] - soundTimes[1] >= .seconds(4) && soundTimes[3] - soundTimes[2] >= .seconds(4),
            "Two elapsed timers keep their own visible receipts and share one repeating audible cadence", &checks)
        try await SideScreenCheck.snapshot(panel, path: "/tmp/orvlet-countdown-awaiting-ack.png")
        model.dismissReminder(teaAlarm.id)
        try StateMachineCheck.require(model.displayedReminders.map(\.id) == [breadAlarm.id] && panel.isVisible,
            "Acknowledging one elapsed timer leaves the other in the foreground", &checks)
        model.taskClock?.invalidate()
        model.stopReminderRepeats()
        let beforeRestore = soundCount
        let resumed = session()
        let resumedDelegate = AppDelegate(model: resumed)
        resumed.onRemindersChanged = { [weak resumedDelegate] in resumedDelegate?.presentReminders(in: screen) }
        defer {
            resumed.taskClock?.invalidate()
            resumedDelegate.reminderPanel?.orderOut(nil)
        }
        resumed.loadSideTasks()
        resumed.tickTasks()
        try StateMachineCheck.require(resumed.displayedReminders.map(\.id) == [breadAlarm.id]
            && resumedDelegate.reminderPanel?.isVisible == true && soundCount == beforeRestore,
            "Relaunch restores only the unacknowledged alarm without a second arrival sound", &checks)
        for _ in 0..<75 where soundCount == beforeRestore { try await Task.sleep(for: .milliseconds(100)) }
        try StateMachineCheck.require(soundCount == beforeRestore + 1 && resumed.displayedReminders.map(\.id) == [breadAlarm.id],
            "The restored alarm resumes its audible cadence without creating another receipt", &checks)
        guard let resumedPanel = resumedDelegate.reminderPanel else { throw AppError.message("Missing restored timer panel") }
        try await Task.sleep(for: .milliseconds(150))
        let point = NSPoint(x: resumedPanel.contentLayoutRect.maxX - 22, y: resumedPanel.contentLayoutRect.midY)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: resumedPanel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            resumedPanel.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        let reopened = session()
        defer { reopened.taskClock?.invalidate() }
        reopened.loadSideTasks()
        reopened.tickTasks()
        try StateMachineCheck.require(reopened.reminders.isEmpty && resumedDelegate.reminderPanel?.isVisible == false
            && resumed.collapsed && !resumed.commandPanelVisible
            && soundCount == beforeRestore + 1, "Clicking the rendered acknowledgement clears the alarm across a second launch", &checks)
        let afterAcknowledgement = soundCount
        let stopped = try reopened.startTimer(seconds: 1, title: "Stopped before ringing")
        reopened.timerAction(stopped, action: "stop")
        let dueWhileClosed = try reopened.startTimer(seconds: 1, title: "While away")
        reopened.taskClock?.invalidate()
        try await Task.sleep(for: .milliseconds(5400))
        try StateMachineCheck.require(soundCount == afterAcknowledgement, "The acknowledged alarm remains quiet through its next interval", &checks)
        let late = session()
        defer { late.taskClock?.invalidate() }
        late.onRemindersChanged = {}
        late.loadSideTasks()
        late.tickTasks()
        late.tickTasks()
        try StateMachineCheck.require(late.reminders.map(\.owner) == [dueWhileClosed] && soundCount == afterAcknowledgement + 1,
            "A countdown that elapsed while closed alerts once on return and a manually stopped timer stays quiet", &checks)
        if let alarm = late.reminders.first { late.dismissReminder(alarm.id) }
        let eventDelegate = AppDelegate(model: late)
        late.onRemindersChanged = { [weak eventDelegate] in eventDelegate?.presentReminders(in: screen) }
        defer { eventDelegate.reminderPanel?.orderOut(nil) }
        let export = UUID()
        let kiln = UUID()
        let card = TaskSurface(title: "Kiln batch 27", markup: CardMarkup(html: "<strong data-bind='phase'></strong>",
            compactHTML: "<span data-bind='phase'></span>", css: ""), fields: [], actions: [], state: ["phase": "Firing"])
        try late.commitTaskSurface(card, id: kiln, ticket: nil)
        guard let artifactID = late.work.view(kiln)?.selected else { throw AppError.message("Missing kiln batch") }
        let result = try await late.agent.execute("present_results", [
            "results": [artifactID.uuidString], "layout": "separate", "title": "Kiln batch 27",
            "reminder": ["key": "phase", "condition": "equals", "value": "Fired", "message": "Inspect batch 27.",
                         "intensity": "gentle", "delivery": "untilAcknowledged"]
        ])
        guard (result["views"] as? [String]) == [kiln.uuidString] else { throw AppError.message("Missing generated reminder view") }
        late.dismissTask(kiln)
        func kilnPhase(_ value: String) throws {
            guard let item = late.work.artifact(artifactID),
                  late.work.update(artifactID, expecting: item.revision, { $0.values["phase"] = value })
            else { throw AppError.message("Could not update the kiln reading") }
            late.projectWorkResult(artifactID)
        }
        try kilnPhase("Fired")
        try kilnPhase("Cooling")
        late.projectWorkResult(artifactID)
        for _ in 0..<100 where late.reminders.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        guard let inspection = late.displayedReminders.first(where: { $0.owner == kiln }),
              let eventPanel = eventDelegate.reminderPanel, eventPanel.isVisible, screen.contains(eventPanel.frame) else {
            throw AppError.message("An unacknowledged event vanished when its source moved on")
        }
        try StateMachineCheck.require(late.reminders.count == 1 && inspection.message == "Inspect batch 27."
            && inspection.intensity == .gentle && inspection.persistence == .persistent
            && late.work.view(kiln)?.hidden == true && soundCount == afterAcknowledgement + 2,
            "A generated event stays pending without an extra arrival sound when its hidden card advances", &checks)
        try await SideScreenCheck.snapshot(eventPanel, path: "/tmp/orvlet-kiln-event.png")
        late.deliverReply("Choose a writable folder.", kind: .failure, taskID: export)
        late.deliverReply("Which format?", kind: .needsInput, taskID: export)
        guard let failure = late.reminders.first(where: { $0.destination == .conversation }),
              let question = late.reminders.first(where: { $0.needsInput }) else {
            throw AppError.message("Failed to post a durable task reminder")
        }
        let beforeMessageRestore = soundCount
        late.stopReminderRepeats()
        let restored = session()
        defer { restored.taskClock?.invalidate() }
        restored.loadSideTasks()
        try StateMachineCheck.require(Set(restored.displayedReminders.map(\.id)) == [failure.id, question.id, inspection.id]
            && soundCount == beforeMessageRestore, "A failure, a question and a completed kiln batch survive relaunch without an extra arrival sound", &checks)
        restored.dismissReminder(failure.id)
        try StateMachineCheck.require(restored.clearChatMessages(taskID: export)
            && restored.displayedReminders.map(\.id) == [inspection.id],
            "Clearing the answered task's chat retires its remaining question and preserves the other card's reminder", &checks)
        restored.stopReminderRepeats()
        let afterClearing = session()
        defer { afterClearing.taskClock?.invalidate() }
        afterClearing.loadSideTasks()
        try StateMachineCheck.require(afterClearing.displayedReminders.map(\.id) == [inspection.id] && soundCount == beforeMessageRestore,
            "Dismissed and cleared conversation reminders stay retired after relaunch", &checks)
        afterClearing.dismissReminder(inspection.id)
        let acknowledged = session()
        defer { acknowledged.taskClock?.invalidate() }
        acknowledged.loadSideTasks()
        try StateMachineCheck.require(acknowledged.reminders.isEmpty && soundCount == beforeMessageRestore,
            "Acknowledging the generated event retires it across launches independently of the source reading", &checks)
        return checks
    }
}
#endif
