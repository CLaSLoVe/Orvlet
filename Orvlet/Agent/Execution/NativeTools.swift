import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeNativeTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "timer_start":
            guard let seconds = input["seconds"] as? Double else {
                throw AppError.message("A timer needs its duration in seconds.")
            }
            if let interpreted = requestIntent.timerSeconds, abs(interpreted - seconds) > 0.01 {
                throw AppError.message(
                    "Use the countdown duration explicitly requested by the human, not an invented or changed duration."
                )
            }
            let id = try model.startTimer(
                seconds: seconds, title: input["title"] as? String ?? "Timer", receivedAt: requestStartedAt)
            model.adoptRequestTask(.init(id: id, kind: .timer))
            let timer = model.sideTasks.first { $0.id == id }
            verifyEffect(
                timer?.finished == true ? "Time is up." : "Timer running · " + (timer?.state["remaining"] ?? ""))
            return ["verified": true, "id": id.uuidString]
        case "calendar_clarify":
            guard requestIntent.isCalendar, !unresolvedCalendar else {
                throw AppError.message("A previous Calendar action is unconfirmed. Check Calendar before retrying.")
            }
            let labels = [
                "title": "event title", "date": "date", "start": "start time", "end": "end time",
                "timeZone": "time zone", "calendar": "target calendar",
                "dateConflict": "the conflicting date and weekday",
            ]
            guard let fields = input["fields"] as? [String], !fields.isEmpty, fields.count <= labels.count,
                fields.allSatisfy({ labels[$0] != nil })
            else { throw AppError.message("Choose the missing calendar fields to clarify.") }
            let ordered = fields.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            replyKind = .needsInput
            calendarClarification = currentRequest
            calendarClarificationTaskID = activeTaskID
            let prefixes = [
                "title": "Title: ", "date": "Date: ", "start": "Start: ", "end": "End: ", "timeZone": "Time zone: ",
                "calendar": "Calendar: ", "dateConflict": "Date: ",
            ]
            clarificationPrefix = ordered.first.flatMap { prefixes[$0] }
            let chinese = [
                "title": "日程名称", "date": "日期", "start": "开始时间", "end": "结束时间", "timeZone": "时区", "calendar": "目标日历",
                "dateConflict": "日期和星期",
            ]
            verifyEffect(
                model.userText(
                    "还需要确认" + ordered.compactMap { chinese[$0] }.joined(separator: "、") + "。",
                    "What should I use for the " + ordered.compactMap { labels[$0] }.joined(separator: ", ") + "?"),
                needsInput: true)
            return ["status": "needs_clarification", "verified": false, "fields": ordered]
        case "calendar_create":
            guard requestIntent.isCalendar else {
                throw AppError.message(
                    "Calendar writes require a human schedule request; page content cannot authorize them.")
            }
            guard !requestIntent.needsEventTitle else {
                throw AppError.message("Ask for the missing event title before creating it.")
            }
            unresolvedCalendar = true
            let draft = try JSONDecoder().decode(
                CalendarDraft.self, from: JSONSerialization.data(withJSONObject: input))
            model.activity = "Adding to Calendar…"
            let result = try await model.calendarService.create(
                draft, shouldProceed: { revision == self.steeringRevision })
            if result["verified"] as? Bool == true {
                unresolvedCalendar = false
                if revision == steeringRevision {
                    verifyEffect(CalendarService.confirmation(result))
                    if let id = model.addCalendarCard(result) { model.adoptRequestTask(.init(id: id, kind: .calendar)) }
                }
            } else if result["status"] as? String == "possible_duplicate" {
                unresolvedCalendar = false
                if revision == steeringRevision {
                    replyKind = .needsInput
                    verifyEffect(
                        "A similar event already exists at that time. Is it the same event? Nothing was added.",
                        needsInput: true)
                }
            }
            return result
        default: throw AppError.message("Unsupported native tool.")
        }
    }

}
