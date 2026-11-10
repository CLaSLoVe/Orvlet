import Carbon
import Foundation

/// Fixed Calendar Apple Events originate from Orvlet's signed process. A shell
/// child cannot reliably use the app's scripting access-group entitlement.
nonisolated enum CalendarNativeTransport {
    static func code(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func object(
        _ kind: OSType, form: OSType, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor = .null()
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw AppError.message("Invalid Calendar object")
        }
        return result
    }
    static func all(_ kind: OSType, in container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        guard
            let ordinal = NSAppleEventDescriptor(
                descriptorType: DescType(typeAbsoluteOrdinal),
                data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data)
        else { throw AppError.message("Invalid Calendar ordinal") }
        return try object(kind, form: OSType(formAbsolutePosition), key: ordinal, container: container)
    }
    static func property(_ key: OSType, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try object(
            OSType(typeProperty), form: OSType(formPropertyID), key: NSAppleEventDescriptor(typeCode: key),
            container: container)
    }
    static func request(_ id: OSType, parameters: [AEKeyword: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: id,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        for (key, value) in parameters { event.setParam(value, forKeyword: key) }
        return event
    }
    static func send(_ event: NSAppleEventDescriptor, allowPrompt: Bool = false) throws -> NSAppleEventDescriptor {
        let flags =
            allowPrompt ? kAEWaitReply | kAECanInteract : kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent
        let options = NSAppleEventDescriptor.SendOptions(rawValue: UInt(flags))
        let reply = try event.sendEvent(options: options, timeout: 15)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            throw AppError.message("Calendar returned no result")
        }
        return value
    }
    static func get(_ object: NSAppleEventDescriptor, allowPrompt: Bool = false) throws -> NSAppleEventDescriptor {
        try send(
            request(OSType(kAEGetData), parameters: [AEKeyword(keyDirectObject): object]), allowPrompt: allowPrompt)
    }
    static func list(allowPrompt: Bool = false) throws -> String {
        let calendars = try get(all(code("wres")), allowPrompt: allowPrompt)
        guard calendars.descriptorType == DescType(typeAEList) else {
            throw AppError.message("Calendar list could not be read")
        }
        var result: [[String: Any]] = []
        for index in 0..<calendars.numberOfItems {
            guard let calendar = calendars.atIndex(index + 1) else { continue }
            let name = try get(property(code("pnam"), of: calendar)).stringValue ?? ""
            let writable = try get(property(code("wr05"), of: calendar)).booleanValue
            result.append(["name": name, "writable": writable])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }
    static func formatter() -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        value.isLenient = false
        return value
    }
    static func date(_ value: String) throws -> Date {
        let formatter = formatter()
        guard value.count == 19, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw AppError.message("Invalid Calendar date")
        }
        return date
    }
    static func calendar(_ name: String) throws -> NSAppleEventDescriptor {
        try object(code("wres"), form: OSType(formName), key: NSAppleEventDescriptor(string: name))
    }
    static func matchingEvents(in calendar: NSAppleEventDescriptor, start: Date) throws -> NSAppleEventDescriptor {
        guard let examined = NSAppleEventDescriptor(descriptorType: DescType(typeObjectBeingExamined), data: Data())
        else { throw AppError.message("Invalid Calendar comparison") }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(
            NSAppleEventDescriptor(enumCode: OSType(kAEEquals)), forKeyword: AEKeyword(keyAECompOperator))
        comparison.setDescriptor(try property(code("wr1s"), of: examined), forKeyword: AEKeyword(keyAEObject1))
        comparison.setDescriptor(NSAppleEventDescriptor(date: start), forKeyword: AEKeyword(keyAEObject2))
        guard let test = comparison.coerce(toDescriptorType: DescType(typeCompDescriptor)) else {
            throw AppError.message("Invalid Calendar comparison")
        }
        return try object(code("wrev"), form: OSType(formTest), key: test, container: calendar)
    }
    static func details(_ event: NSAppleEventDescriptor, calendar: String, status: String) throws -> [String: Any] {
        func field(_ code: String) throws -> NSAppleEventDescriptor { try get(property(Self.code(code), of: event)) }
        guard let start = try field("wr1s").dateValue, let end = try field("wr5s").dateValue,
            let uid = try field("ID  ").stringValue, !uid.isEmpty
        else { throw AppError.message("Calendar returned incomplete event details") }
        return [
            "calendar": calendar, "status": status, "uid": uid, "title": try field("wr11").stringValue ?? "",
            "start": formatter().string(from: start), "end": formatter().string(from: end),
            "location": try field("wr14").stringValue ?? "", "notes": try field("wr12").stringValue ?? "",
            "url": try field("wr16").stringValue ?? "", "allDay": try field("wrad").booleanValue,
        ]
    }
    static func find(_ name: String, start: Date) throws -> [[String: Any]] {
        let matches = try get(matchingEvents(in: calendar(name), start: start))
        guard matches.descriptorType == DescType(typeAEList), matches.numberOfItems <= 200 else {
            throw AppError.message("Calendar matches could not be verified")
        }
        return try (0..<matches.numberOfItems).map { index in
            guard let event = matches.atIndex(index + 1) else { throw AppError.message("Calendar match is missing") }
            return try details(event, calendar: name, status: "exists")
        }
    }
    static func makeEventRequest(_ arguments: [String]) throws -> NSAppleEventDescriptor {
        guard arguments.count == 9, arguments[0] == "create", !arguments[2].isEmpty,
            ["true", "false"].contains(arguments[8])
        else { throw AppError.message("Invalid Calendar creation request") }
        let start = try date(arguments[3])
        let end = try date(arguments[4])
        guard end > start else { throw AppError.message("Event end must be after start") }
        let properties = NSAppleEventDescriptor.record()
        for (key, index) in [("wr11", 2), ("wr14", 5), ("wr12", 6), ("wr16", 7)] {
            properties.setDescriptor(NSAppleEventDescriptor(string: arguments[index]), forKeyword: code(key))
        }
        properties.setDescriptor(NSAppleEventDescriptor(date: start), forKeyword: code("wr1s"))
        properties.setDescriptor(NSAppleEventDescriptor(date: end), forKeyword: code("wr5s"))
        properties.setDescriptor(NSAppleEventDescriptor(boolean: arguments[8] == "true"), forKeyword: code("wrad"))
        let location = NSAppleEventDescriptor.record()
        location.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(kAEEnd)), forKeyword: AEKeyword(keyAEPosition))
        location.setDescriptor(try all(code("wrev"), in: calendar(arguments[1])), forKeyword: AEKeyword(keyAEObject))
        guard let insertion = location.coerce(toDescriptorType: DescType(typeInsertionLoc)) else {
            throw AppError.message("Invalid Calendar destination")
        }
        return request(
            OSType(kAECreateElement),
            parameters: [
                AEKeyword(keyAEObjectClass): NSAppleEventDescriptor(typeCode: code("wrev")),
                AEKeyword(keyAEInsertHere): insertion, AEKeyword(keyAEPropData): properties,
            ])
    }
    static func run(_ arguments: [String], allowPrompt: Bool = false) throws -> String {
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        if arguments == ["list"] { return try list(allowPrompt: allowPrompt) }
        guard let operation = arguments.first else { throw AppError.message("Missing Calendar operation") }
        if operation == "validate", arguments.count == 2 { return try formatter().string(from: date(arguments[1])) }
        if operation == "find", arguments.count == 3 { return try json(find(arguments[1], start: date(arguments[2]))) }
        if operation == "read", arguments.count == 3 {
            let event = try object(
                code("wrev"), form: OSType(formUniqueID), key: NSAppleEventDescriptor(string: arguments[2]),
                container: calendar(arguments[1]))
            return try json(details(event, calendar: arguments[1], status: "confirmed"))
        }
        guard operation == "create", arguments.count == 9 else {
            throw AppError.message("Unsupported Calendar operation")
        }
        let command = try makeEventRequest(arguments)
        guard try get(property(code("wr05"), of: calendar(arguments[1]))).booleanValue else {
            throw AppError.message("Calendar is not writable")
        }
        if let existing = try find(arguments[1], start: date(arguments[3])).first(where: {
            $0["title"] as? String == arguments[2]
        }) {
            return try json(existing)
        }
        // Exactly one creation send. If it times out, CalendarService retains
        // its pending journal and will not blindly repeat the write.
        let event = try send(command)
        return try json(details(event, calendar: arguments[1], status: "created"))
    }
}
