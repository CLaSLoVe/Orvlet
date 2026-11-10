#if DEBUG
    import Foundation

    @MainActor
    enum CalendarOutcomeCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ ok: Bool, _ name: String) throws {
                guard ok else { throw AppError.message(name) }
                checks.append(name)
            }
            let suite = "orvlet-calendar-outcome-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.agent.interpretationOverride = { _ in
                RequestIntent(kind: .calendar, goals: ["Create the requested calendar event"])
            }
            model.isLiveTest = true
            model.persistHistory = false
            model.settings = AppSettings()
            defer { model.taskClock?.invalidate() }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            model.calendarService.journalDirectory = root
            defer { try? FileManager.default.removeItem(at: root) }
            let request = "Add a seminar on 18 February 2027 from 10:00 to 11:00, Hong Kong time, in Example Room."
            let draft: [String: Any] = [
                "title": "Example seminar", "start": "2027-02-18T10:00:00", "end": "2027-02-18T11:00:00",
                "timeZone": "Asia/Hong_Kong", "kind": "seminar", "location": "Example Room",
                "notes": "Synthetic test only",
            ]
            let invented = "Event added to calendar: Example seminar."
            func tool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
                [
                    "id": UUID().uuidString, "type": "function",
                    "function": ["name": name, "arguments": JSONText.encode(arguments)],
                ]
            }
            func response(_ calls: [[String: Any]]) -> [String: Any] { ["role": "assistant", "tool_calls": calls] }
            var calls = 0
            var writes = 0
            var reads = 0
            var saved: [String: Any] = [:]
            model.calendarService.runnerOverride = { args in
                switch args[0] {
                case "list": return "[{\"name\":\"Work\",\"writable\":true}]"
                case "find": return "[]"
                case "create":
                    writes += 1
                    saved = [
                        "uid": "fixture-event", "status": "created", "calendar": args[1], "title": args[2],
                        "start": args[3], "end": args[4], "location": args[5], "notes": args[6], "url": args[7],
                        "allDay": args[8] == "true",
                    ]
                    return JSONText.encode(saved)
                case "read":
                    reads += 1
                    return JSONText.encode(saved)
                default: throw AppError.message("Unexpected fixture command")
                }
            }
            model.agent.completionOverride = { _ in
                calls += 1
                return ["role": "assistant", "content": invented]
            }
            var rejected = false
            do { _ = try await model.agent.run(request) } catch { rejected = true }
            try check(
                rejected && calls == 3 && writes == 0 && !model.sideTasks.contains(where: { $0.kind == .calendar }),
                "A text-only Calendar success is rejected without a write or success card")
            try check(
                !model.messages.contains(where: { !$0.isUser && $0.text == invented }),
                "Fabricated success is not retained as a completed conversation result")

            calls = 0
            model.agent.completionOverride = { _ in
                calls += 1
                if calls == 1 { return response([tool("finish", ["outcome": "answer", "reply": invented])]) }
                return response([tool("calendar_clarify", ["fields": ["date", "start"]])])
            }
            let clarification = try await model.agent.run("Add a seminar to my calendar")
            try check(
                clarification.hasPrefix("What should I use") && clarification.contains("date, start time")
                    && writes == 0,
                "finish(answer) cannot forge a Calendar receipt; missing details use a host-generated question")

            calls = 0
            model.agent.completionOverride = { _ in
                calls += 1
                if calls == 1 { return ["role": "assistant", "content": invented] }
                return response([
                    tool("calendar_create", draft),
                    tool("finish", ["outcome": "answer", "reply": "Overwrite the actual receipt"]),
                    tool("calendar_create", draft),
                ])
            }
            let verified = try await model.agent.run(request)
            try check(
                verified.hasPrefix("Added to Work:") && verified.contains("Example seminar") && writes == 1
                    && reads == 1, "A corrected tool call returns success only after Calendar read-back")
            try check(
                !verified.contains("Overwrite") && model.sideTasks.filter({ $0.kind == .calendar }).count == 1,
                "The confirmed Calendar result is terminal and trailing tools cannot replace it or duplicate the write")

            calls = 0
            model.sideTasks.removeAll()
            model.calendarService.runnerOverride = { _ in
                throw AppError.message("Simulated Automation permission denial")
            }
            model.agent.completionOverride = { _ in
                calls += 1
                if calls == 1 { return response([tool("calendar_create", draft)]) }
                return ["role": "assistant", "content": invented]
            }
            var setupShown = 0
            model.onSetup = { setupShown += 1 }
            let accessReply = try await model.agent.run(request)
            try check(
                !model.sideTasks.contains(where: { $0.kind == .calendar }) && calls == 1
                    && model.agent.replyKind == .needsInput && model.calendarReadiness == .blocked && setupShown == 1
                    && accessReply.contains("Setup") && accessReply.contains("Check Calendar"),
                "A revoked Calendar permission opens setup and preserves the request without failure, retry or a false success"
            )

            calls = 0
            model.calendarService.runnerOverride = { args in
                if args[0] == "list" { return "[{\"name\":\"Work\",\"writable\":true}]" }
                if args[0] == "find" { return "[]" }
                if args[0] == "create" { return "{\"uid\":\"fixture-event\",\"status\":\"created\"}" }
                if args[0] == "read" { return "{\"uid\":\"wrong-event\"}" }
                throw AppError.message("Unexpected fixture command")
            }
            model.agent.completionOverride = { _ in
                calls += 1
                if calls == 1 { return response([tool("calendar_create", draft)]) }
                return ["role": "assistant", "content": invented]
            }
            rejected = false
            do { _ = try await model.agent.run(request) } catch { rejected = true }
            try check(
                rejected && !model.sideTasks.contains(where: { $0.kind == .calendar }),
                "A write without matching read-back never creates a success reply or card")

            model.agent.completionOverride = { _ in ["role": "assistant", "content": "An ordinary answer"] }
            model.agent.interpretationOverride = { _ in RequestIntent(kind: .information) }
            let normal = try await model.agent.run("Explain a simple idea")
            try check(normal == "An ordinary answer", "Ordinary conversation remains available without an action tool")
            let translation = try await model.agent.run("Translate this seminar notice: example only")
            try check(
                translation == "An ordinary answer",
                "Translation and example requests are not forced through Calendar writes")
            return checks
        }
    }
#endif
