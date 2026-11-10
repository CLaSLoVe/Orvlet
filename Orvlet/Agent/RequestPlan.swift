import Foundation

/// Discovery is small. Construction schemas are loaded only by the executor.
@MainActor
enum RequestPlanning {
    /// Inline only bounded schemas. Larger construction tools remain discoverable,
    /// and use the same executor after their full schema is loaded.
    static func actions(_ capability: RequestCapability) -> [[String: Any]] {
        guard capability != .general else { return [] }
        return AgentToolRegistry.definitions.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                let name = function["name"] as? String, capability.planningTools.contains(name), name != "reuse_saved_ui",
                let parameters = function["parameters"] as? [String: Any],
                JSONText.encode(parameters).utf8.count + (function["description"] as? String ?? "").utf8.count <= 3500
            else { return nil }
            return function
        }
    }

    static func discovery(_ capability: RequestCapability) -> [[String: Any]] {
        let inline = Set(actions(capability).compactMap { $0["name"] as? String })
        return AgentToolRegistry.definitions.compactMap { tool in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String,
                capability.planningTools.contains(name), !inline.contains(name), name != "reuse_saved_ui"
            else { return nil }
            return ["name": name, "description": String((function["description"] as? String ?? "").prefix(160))]
        }
    }

    static func compactSchema(_ schema: [String: Any], capability: RequestCapability, resolved: Bool, hasMethods: Bool)
        -> [String: Any]
    {
        var schema = schema
        var function = schema["function"] as! [String: Any]
        var parameters = function["parameters"] as! [String: Any]
        var properties = parameters["properties"] as! [String: [String: Any]]
        var remove: Set<String> = ["summary"]
        if resolved { remove.formUnion(["targetTaskID", "restoreTaskID"]) }
        if !hasMethods { remove.insert("reuse") }
        if capability != .general {
            let tools = capability.tools
            if !tools.contains("calendar_create") { remove.formUnion(["missingFields", "continuesClarification"]) }
            if !tools.contains("timer_start") { remove.formUnion(["timerSeconds", "timerEvidence"]) }
            if !tools.contains("control_media") { remove.formUnion(["playbackIntent", "mediaSetting"]) }
            if !tools.contains("present_ui") && !tools.contains("control_task") {
                remove.formUnion(["timeZones", "updateIntervalSeconds"])
            }
            if capability != .answer { remove.insert("answer") }
        }
        for key in remove { properties.removeValue(forKey: key) }
        parameters["properties"] = properties
        parameters["required"] = (parameters["required"] as? [String] ?? []).filter {
            !remove.contains($0)
        }
        function["parameters"] = parameters
        schema["function"] = function
        return schema
    }
    static var reuseTool: [String: Any] {
        ToolSchema.function(
            "reuse_saved_ui", "Execute a saved method with fresh inputs; its receipt completes the request.",
            [
                "id": ["type": "string"],
                "state": ["type": "object", "additionalProperties": ["type": "string"]],
                "outcomeEvidence": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "requirement": ["type": "integer"], "fieldKey": ["type": "string"],
                        ], "required": ["requirement", "fieldKey"],
                    ],
                ],
            ], required: ["id", "state"])
    }
}

/// The first model response carries executable work as well as its checked intent.
/// Both planned and subsequent actions pass through the same dispatcher.
struct RequestStep: Codable {
    enum CodingKeys: String, CodingKey { case tool, arguments, goal }
    let tool: String
    let arguments: String
    var goal: Int? = nil

    init(tool: String, arguments: String, goal: Int? = nil) {
        self.tool = tool
        self.arguments = arguments
        self.goal = goal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(String.self, forKey: .tool)
        goal = try c.decodeIfPresent(Int.self, forKey: .goal)
        // Legacy persisted/internal plans can still be read. The live schema accepts objects only.
        if let legacy = try? c.decode(String.self, forKey: .arguments) {
            arguments = legacy
        } else {
            let object = try c.decode([String: PlanJSON].self, forKey: .arguments)
            arguments = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool)
        try c.encodeIfPresent(goal, forKey: .goal)
        try c.encode(JSONDecoder().decode([String: PlanJSON].self, from: Data(arguments.utf8)), forKey: .arguments)
    }

    func input() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw AppError.message("An action needs a JSON object of arguments.")
        }
        return value
    }

    var call: [String: Any] {
        [
            "id": "plan_" + UUID().uuidString, "type": "function",
            "function": ["name": tool, "arguments": arguments],
        ]
    }

    @MainActor static func schema(actions: [[String: Any]]) -> [String: Any] {
        let variants: [[String: Any]] = actions.map { function in
            [
                "type": "object", "description": function["description"] ?? "",
                "properties": [
                    "tool": ["type": "string", "enum": [function["name"]!]],
                    "goal": ["type": "integer", "minimum": 0, "description": "Index in goals."],
                    "arguments": function["parameters"]!,
                ], "required": ["tool", "arguments", "goal"], "additionalProperties": false,
            ]
        }
        let items: [String: Any] =
            variants.isEmpty
            ? ["type": "object", "additionalProperties": false] : ["anyOf": variants]
        return [
            "type": "array",
            "description":
                "Start known work NOW. Include the first executable action with object arguments when its inputs are supplied. A discovery tool performs its own search: do not wait for its results to plan invoking it. Empty only for an answer, clarification, saved-method reuse, or when no supplied action can start without new evidence. Never invent page IDs or external results.",
            "items": items,
            "maxItems": variants.isEmpty ? 0 : 4,
        ]
    }
}

/// Lossless JSON tree at the planning boundary; serialization is owned by the host.
private indirect enum PlanJSON: Codable {
    case object([String: PlanJSON])
    case array([PlanJSON])
    case string(String)
    case number(Decimal)
    case boolean(Bool)
    case null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .boolean(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Decimal.self) {
            self = .number(v)
        } else if let v = try? c.decode([PlanJSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: PlanJSON].self))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// Jev chooses a small capability catalogue, not a second execution pipeline.
enum RequestCapability: String, CaseIterable {
    case control, music, timer, calendar, data, workspace, browser, answer, general

    var defaultRoute: RequestIntent.Route {
        switch self {
        case .data: return .api
        case .workspace: return .local
        case .music, .browser: return .web
        default: return .auto
        }
    }

    var tools: Set<String> {
        switch self {
        case .control: return ["control_media", "control_task", "observe"]
        case .music: return ["find_music", "control_media", "observe"]
        case .timer: return ["timer_start", "control_task"]
        case .calendar: return ["calendar_create", "calendar_clarify"]
        case .data: return ["query_api", "inspect_api", "reuse_saved_ui"]
        case .workspace: return ["present_ui", "run_code", "reuse_saved_ui", "control_task"]
        case .browser: return ["navigate", "observe", "act", "control_media"]
        case .answer: return []
        case .general:
            return Set(AgentToolName.allCases.map(\.rawValue)).subtracting([
                "finish", "screenshot", "restore", "visibility", "compose_ui", "reuse_ui",
            ])
        }
    }

    /// Intent-producing actions for the first plan. Executor support tools are
    /// available after results, or when triage explicitly selects their capability.
    /// This is capability metadata, not a second execution path or a text classifier.
    var planningTools: Set<String> {
        switch self {
        case .control: return ["control_media", "control_task"]
        case .music: return ["find_music"]
        case .timer: return ["timer_start"]
        case .calendar: return ["calendar_create", "calendar_clarify"]
        case .data: return ["query_api", "inspect_api", "reuse_saved_ui"]
        case .workspace: return ["present_ui", "run_code", "reuse_saved_ui"]
        case .browser: return ["navigate", "observe", "act"]
        case .answer: return []
        case .general: return tools
        }
    }

    static let criteria: [String: String] = [
        "control":
            "Operate an existing task using its controls, including changing form input values, pause, resume, next, volume, repeat, refresh or restart. Preserve its method, source and layout.",
        "music": "Find, replace or queue music, including a named song, genre or mood.",
        "timer": "Start or control a countdown with a requested duration.",
        "calendar": "Create a calendar event or clarify its details.",
        "data": "Look up structured external facts or calculate from fresh public API data.",
        "workspace":
            "Create or change the behavior or design of a local tool, calculation, clock, form or task interface. Existing input/control changes belong to control.",
        "browser": "Browse or operate a website or video, including unfamiliar webpage tasks.",
        "answer": "Answer or explain without external lookup or changing any task.",
        "general": "Mixed, ambiguous or other requests needing a wider capability catalogue.",
    ]
}
