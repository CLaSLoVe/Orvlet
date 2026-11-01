#if DEBUG
import AppKit

/// Uses the configured model, with a simulated calendar executor: never writes to Apple Calendar.
@MainActor
enum CalendarCheck {
    static func run(_ model: PetModel) async {
        model.isLiveTest = true; model.persistHistory = false
        model.settings.autoAdapt = false; model.settings.allowAgents = false
        Diagnostics.begin("/tmp/orvlet-calendar-live.jsonl")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-calendar-dry-run-" + UUID().uuidString)
        model.calendarService.journalDirectory = root
        defer { try? FileManager.default.removeItem(at:root) }
        var written: [String:Any]?
        var commands: [String] = []
        model.calendarService.runnerOverride = { args in
            commands.append(args[0])
            switch args[0] {
            case "list": return "[{\"name\":\"工作\",\"writable\":true}]"
            case "find": return AgentController.json(written.map { [$0] } ?? [])
            case "create":
                written = ["status":"created","calendar":args[1],"uid":"dry-run-only","title":args[2],"start":args[3],"end":args[4],"location":args[5],"notes":args[6],"url":args[7],"allDay":args[8] == "true"]
                return AgentController.json(written!)
            case "read":
                guard let written else { throw AgentError.message("No simulated event exists") }
                return AgentController.json(written)
            default: throw AgentError.message("Unexpected calendar operation")
            }
        }
        let notice = """
        You are cordially invited to attend a face-to-face seminar entitled "Reliable Interactive Systems", with details below:
        Speaker: Dr. Alex Example (Example Research Institute)
        Date: 5 November 2026 (Thursday)
        Time: 2:00 pm - 3:00 pm
        Venue: Room 101
        """
        let started = Date()
        do {
            let reply = try await model.agent.run(notice)
            let expected = try CalendarService.prepare(CalendarDraft(title:"expected",start:"2026-11-05T14:00:00",end:"2026-11-05T15:00:00",timeZone:"Asia/Hong_Kong"),calendar:"工作")
            Diagnostics.record("parsed_event",["parsed":written ?? [:],"commands":commands,"realCalendarWrites":0])
            guard let event = written, event["start"] as? String == expected.start,
                  event["end"] as? String == expected.end, event["location"] as? String == "Room 101",
                  (event["title"] as? String ?? "").contains("Reliable Interactive Systems"),
                  (event["notes"] as? String ?? "").contains("Alex Example"),
                  !(event["notes"] as? String ?? "").contains("End time assumed"),
                  commands.filter({ $0 == "create" }).count == 1, commands.last == "read", model.webURL.isEmpty else {
                throw AgentError.message("Parsed event or native-tool sequence did not match the notice.")
            }
            Diagnostics.record("calendar_dry_run_passed",["seconds":Date().timeIntervalSince(started),"parsed":event,"commands":commands,"reply":reply,"realCalendarWrites":0])
            let second = try await model.agent.run(notice)
            guard commands.filter({ $0 == "create" }).count == 1 else { throw AgentError.message("Repeated notice created a duplicate") }
            Diagnostics.record("calendar_repeat_passed",["commands":commands,"reply":second,"realCalendarWrites":0])
            exit(0)
        } catch {
            Diagnostics.record("failed",["reason":error.localizedDescription,"commands":commands,"realCalendarWrites":0])
            exit(1)
        }
    }
}
#endif
