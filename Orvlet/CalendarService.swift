import Foundation

struct CalendarDraft: Codable {
    var title: String
    var start: String
    var end: String?
    var timeZone: String?
    var calendar: String?
    var category: String?
    var kind: String?
    var location: String?
    var notes: String?
    var url: String?
    var allDay: Bool?
}
struct PreparedCalendarEvent: Codable {
    var calendar: String
    var title: String
    var start: String
    var end: String
    var location: String
    var notes: String
    var url: String
    var allDay: Bool
    var assumedEnd: Bool
    var sourceTimeZone: String
    var arguments: [String] { ["create",calendar,title,start,end,location,notes,url,allDay ? "true":"false"] }
}

@MainActor
final class CalendarService {
    #if DEBUG
    var runnerOverride: (([String]) async throws -> String)?
    #endif
    var journalDirectory: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("Orvlet/CalendarRequests",isDirectory:true)
    static func hasCalendarIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["translate", "translation", "summarize", "summarise", "example only", "for reference", "do not add", "don't add", "do not create", "翻译", "仅供参考", "不要添加", "不要创建", "只是例子"].contains(where:lower.contains) { return false }
        return ["calendar", "schedule", "seminar", "appointment", "meeting", "cordially invited", "日程", "日历", "讲座", "会议", "预约"].contains(where:lower.contains)
    }
    static func prepare(_ draft: CalendarDraft, calendar: String, hostTimeZone: TimeZone = .current) throws -> PreparedCalendarEvent {
        guard !draft.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, draft.title.count <= 1000,
              (draft.notes?.count ?? 0) <= 16000, (draft.location?.count ?? 0) <= 2000 else { throw AgentError.message("Calendar details are missing or too long.") }
        guard let zone = TimeZone(identifier:draft.timeZone ?? "Asia/Hong_Kong") else { throw AgentError.message("Unknown event time zone. Ask the user to clarify it.") }
        let allDay = draft.allDay ?? false
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = allDay ? hostTimeZone : zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; formatter.isLenient = false
        func parse(_ raw: String) throws -> Date {
            guard raw.count == 19, let date = formatter.date(from:raw), formatter.string(from:date) == raw else { throw AgentError.message("A valid date and start time are required. Ask for missing or conflicting details.") }
            return date
        }
        let start = try parse(draft.start)
        let end: Date
        var assumed = false
        if let explicit = draft.end, !explicit.isEmpty { end = try parse(explicit) }
        else if allDay {
            var calendar = Calendar(identifier:.gregorian); calendar.timeZone = hostTimeZone
            end = calendar.date(byAdding:.day,value:1,to:start)!
        } else if ["seminar","lecture","meeting"].contains(draft.kind ?? "") { end = start.addingTimeInterval(3600); assumed = true }
        else { throw AgentError.message("The end time is missing. Ask the user instead of guessing a duration.") }
        guard end > start else { throw AgentError.message("Event end must be after its start.") }
        if allDay && (!draft.start.hasSuffix("T00:00:00") || !(draft.end ?? "T00:00:00").hasSuffix("T00:00:00")) { throw AgentError.message("All-day events must use midnight date boundaries.") }
        let link = draft.url ?? ""
        guard link.isEmpty || SessionStore.validURL(link) else { throw AgentError.message("Calendar links must be HTTP or HTTPS.") }
        var notes = draft.notes ?? ""
        notes += "\nTime zone: \(zone.identifier)."
        if assumed { notes += "\nEnd time assumed: one hour after the start." }
        formatter.timeZone = hostTimeZone
        return PreparedCalendarEvent(calendar:calendar,title:draft.title,start:formatter.string(from:start),end:formatter.string(from:end),location:draft.location ?? "",notes:notes,url:link,allDay:allDay,assumedEnd:assumed,sourceTimeZone:zone.identifier)
    }
    static func normalizedTitle(_ value: String) -> String {
        value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }
    static func confirmation(_ event: [String:Any]) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let start = formatter.date(from:event["start"] as? String ?? "")
        let end = formatter.date(from:event["end"] as? String ?? "")
        formatter.timeZone = TimeZone(identifier:event["sourceTimeZone"] as? String ?? "Asia/Hong_Kong")
        formatter.dateFormat = event["allDay"] as? Bool == true ? "MMM d" : "MMM d, HH:mm"
        var time = start.map { formatter.string(from:$0) } ?? ""
        if event["allDay"] as? Bool != true, let end {
            formatter.dateFormat = "HH:mm"; time += "–" + formatter.string(from:end)
        }
        let prefix = event["status"] as? String == "exists" ? "Already in" : "Added to"
        let location = event["location"] as? String ?? ""
        var reply = "\(prefix) \(event["calendar"] as? String ?? "Calendar"): \(event["title"] as? String ?? "Event") · \(time)"
        if !location.isEmpty { reply += " · " + location }
        if event["assumedEnd"] as? Bool == true { reply += ". End time assumed: one hour." }
        return reply
    }
    func run(_ arguments: [String]) async throws -> String {
        #if DEBUG
        if let runnerOverride { return try await runnerOverride(arguments) }
        #endif
        guard let script = Bundle.main.url(forResource:"calendar-event",withExtension:"scpt") ?? Bundle.main.url(forResource:"calendar-event",withExtension:"applescript") else { throw AgentError.message("Calendar action is missing from this build.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                do { continuation.resume(returning:try Self.runScriptSync(script:script,arguments:arguments)) }
                catch { continuation.resume(throwing:error) }
            }
        }
    }
    nonisolated private static func runScriptSync(script: URL, arguments: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
            process.arguments = [script.path] + arguments
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orvlet-calendar-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:directory) }
            let outputURL = directory.appendingPathComponent("result"), errorURL = directory.appendingPathComponent("error")
            FileManager.default.createFile(atPath:outputURL.path,contents:nil,attributes:[.posixPermissions:0o600])
            FileManager.default.createFile(atPath:errorURL.path,contents:nil,attributes:[.posixPermissions:0o600])
            let output = try FileHandle(forWritingTo:outputURL), errors = try FileHandle(forWritingTo:errorURL)
            defer { try? output.close(); try? errors.close() }
            process.standardOutput = output; process.standardError = errors
            let ended = DispatchSemaphore(value:0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            guard ended.wait(timeout:.now()+60) == .success else {
                process.terminate()
                throw AgentError.message("Calendar did not confirm in time. The event may have been created; check Calendar before retrying.")
            }
            let text = String(decoding:try Data(contentsOf:outputURL),as:UTF8.self)
            let error = String(decoding:try Data(contentsOf:errorURL),as:UTF8.self)
            guard process.terminationStatus == 0 else {
                if error.contains("-1743") || error.contains("not authorized") || error.contains("不允许") {
                    throw AgentError.message("Allow Orvlet to control Calendar in System Settings → Privacy & Security → Automation, then retry.")
                }
                throw AgentError.message("Calendar action failed: " + String(error.prefix(600)))
            }
            return text.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func create(_ draft: CalendarDraft, shouldProceed: () -> Bool = { true }) async throws -> [String:Any] {
        let calendarData = Data(try await run(["list"]).utf8)
        guard let calendars = try JSONSerialization.jsonObject(with:calendarData) as? [[String:Any]] else { throw AgentError.message("Calendar list could not be read.") }
        let writable = calendars.filter { $0["writable"] as? Bool == true }.compactMap { $0["name"] as? String }
        let name: String
        if let requested = draft.calendar, !requested.isEmpty {
            guard writable.contains(requested) else { throw AgentError.message("Requested calendar is not writable. Choose from: " + writable.joined(separator:", ")) }
            name = requested
        } else {
            let preferred = draft.category == "personal" ? ["安排","Personal","Home"] : ["工作","Work"]
            guard let selected = preferred.first(where:writable.contains) ?? writable.first else { throw AgentError.message("No writable calendar exists. Choose a calendar in Apple Calendar first.") }
            name = selected
        }
        let event = try Self.prepare(draft,calendar:name)
        let found = try JSONSerialization.jsonObject(with:Data(try await run(["find",name,event.start]).utf8)) as? [[String:Any]] ?? []
        if let duplicate = found.first(where:{ Self.normalizedTitle($0["title"] as? String ?? "") == Self.normalizedTitle(event.title) }), let uid = duplicate["uid"] as? String {
            return try await confirmed(name,uid:uid,status:"exists",event:event)
        }
        if let possible = found.first(where:{ row in
            let a = Self.normalizedTitle(row["title"] as? String ?? ""), b = Self.normalizedTitle(event.title)
            return (min(a.count,b.count) > 16 && (a.contains(b) || b.contains(a))) || (!event.location.isEmpty && row["location"] as? String == event.location && row["end"] as? String == event.end)
        }) { return ["status":"possible_duplicate", "event":possible, "message":"A similar event already exists. Ask whether this is the same event; nothing was added."] }
        try Task.checkCancellation()
        guard shouldProceed() else { throw AgentError.message("New user instructions superseded this calendar write. Nothing was added.") }
        try FileManager.default.createDirectory(at:journalDirectory,withIntermediateDirectories:true)
        let files = (try? FileManager.default.contentsOfDirectory(at:journalDirectory,includingPropertiesForKeys:nil)) ?? []
        for file in files where file.pathExtension == "pending" {
            if let data = try? Data(contentsOf:file), let previous = try? JSONDecoder().decode(PreparedCalendarEvent.self,from:data),
               previous.calendar == event.calendar && previous.start == event.start && Self.normalizedTitle(previous.title) == Self.normalizedTitle(event.title) {
                throw AgentError.message("A previous attempt is unconfirmed. No duplicate was created. Check Calendar before retrying; request saved at " + file.path)
            }
        }
        let journal = journalDirectory.appendingPathComponent(UUID().uuidString + ".pending")
        try JSONEncoder().encode(event).write(to:journal,options:.atomic)
        let result = try JSONSerialization.jsonObject(with:Data(try await run(event.arguments).utf8)) as? [String:Any] ?? [:]
        guard let uid = result["uid"] as? String else { throw AgentError.message("Calendar did not return an event ID. Check Calendar before retrying.") }
        let verified = try await confirmed(name,uid:uid,status:result["status"] as? String ?? "created",event:event)
        try JSONSerialization.data(withJSONObject:verified,options:.prettyPrinted).write(to:journal.appendingPathExtension("confirmed.json"),options:.atomic)
        try FileManager.default.removeItem(at:journal)
        return verified
    }
    private func confirmed(_ name: String, uid: String, status: String, event: PreparedCalendarEvent) async throws -> [String:Any] {
        let data = Data(try await run(["read",name,uid]).utf8)
        guard var read = try JSONSerialization.jsonObject(with:data) as? [String:Any], read["uid"] as? String == uid,
              read["start"] as? String == event.start else { throw AgentError.message("Calendar read-back did not match. Check the event before retrying.") }
        if status == "created" {
            guard read["title"] as? String == event.title, read["end"] as? String == event.end,
                  read["location"] as? String == event.location, read["notes"] as? String == event.notes,
                  read["allDay"] as? Bool == event.allDay, read["url"] as? String == event.url else {
                throw AgentError.message("Calendar read-back differs from the requested details. Check the saved event before retrying.")
            }
        }
        read["status"] = status; read["verified"] = true; read["assumedEnd"] = event.assumedEnd
        read["sourceTimeZone"] = event.sourceTimeZone; read["hostTimeZone"] = TimeZone.current.identifier
        return read
    }
}
