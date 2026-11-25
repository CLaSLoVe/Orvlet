import Foundation

/// Model-facing projections. Full state stays with the host for validation and execution.
enum AgentContext {
    static let stateKeys: Set<String> = [
        "url", "title", "documentReady", "hasMedia", "playing", "audible", "muted", "volume", "looping",
        "currentTime", "duration", "seekable", "live", "ended", "adPlaying", "readyState", "mediaError",
        "artist", "readings", "music_queue", "reusable_ui", "error", "loading",
    ]

    static func page(_ source: [String: Any], detail: String, offset: Int = 0) -> [String: Any] {
        var result = source.filter { stateKeys.contains($0.key) }
        result["context_kind"] = "page"
        result["detail"] = detail
        guard detail != "state" else { return result }
        let start = max(0, offset)
        for (key, count, fields) in [
            ("elements", 24, Set(["id", "role", "label", "value", "href", "editable", "disabled"])),
            ("readables", 16, Set(["selector", "text", "role", "evidenceRole", "scopeSelector"])),
        ] {
            let rows = source[key] as? [[String: Any]] ?? []
            result[key] = rows.dropFirst(start).prefix(count).map { $0.filter { fields.contains($0.key) } }
            result[key + "_total"] = rows.count
            if start + count < rows.count { result[key + "_nextOffset"] = start + count }
        }
        let text = source["text"] as? String ?? ""
        result["text"] = String(text.dropFirst(start * 80).prefix(1600))
        result["textCharacters"] = text.count
        result["offset"] = start
        return result
    }

    static func displayState(_ state: [String: String], source: APIDataSpec?) -> [String: String] {
        var summary = state
        for field in source?.fields ?? [] where field.itemPointer != nil {
            if let text = state[field.key], let values = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] {
                summary[field.key] = "[column of " + String(values.count) + " items]"
            }
        }
        return summary
    }

    static func task(_ task: SideTask, definition: Bool = false) -> [String: Any] {
        if definition, let surface = task.taskSurface,
            let data = try? JSONEncoder().encode(surface),
            var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            value["state"] = displayState(task.state, source: surface.apiData)
            return value
        }
        var result: [String: Any] = [
            "id": task.id.uuidString, "title": task.title, "kind": task.kind.rawValue,
            "status": task.status, "playing": task.playing, "state": task.state,
            "purpose": String((task.intent ?? "").prefix(800)),
        ]
        if let ids = task.artifactIDs { result["resultIDs"] = ids.map(\.uuidString) }
        if let surface = task.taskSurface {
            result["inputs"] = surface.fields
            result["state"] = displayState(task.liveValues ?? surface.state, source: surface.apiData)
            result["actions"] = surface.actions.map { action in
                var description = ["id": action.id, "kind": action.kind.rawValue]
                description["operation"] = action.operation
                return description
            }
            result["hasDefinition"] = true
            if let spec = surface.apiData {
                let choices = spec.inputControls.filter { $0.kind == "select" }
                if !choices.isEmpty {
                    result["existingChoices"] = choices.map { ["key": $0.key, "label": $0.label, "current": task.state[$0.key] ?? ""] }
                    result["choiceEdits"] = "These choices already have working bindings. For a visual edit that keeps or exposes them, use manage_task(revise_view)."
                }
                result["dataSource"] = ["kind": "publicAPI", "refreshSeconds": spec.refreshSeconds as Any? ?? NSNull()]
                result["methodChanges"] = "To change the reading or background cadence, inspect the existing API definition, then load_tools(advanced_data) and query_api with its revised source. The host schedules source.refreshSeconds."
            }
        }
        if let queue = task.musicQueue {
            result["music_queue"] = [
                "current": queue.current?.title ?? "", "upcoming": queue.upcoming.prefix(6).map(\.title),
                "previous": queue.previous.suffix(3).map(\.title),
            ]
        }
        return result
    }

    /// Keep one current page packet, including the initial packet (formerly a permanent user turn).
    /// Preserve tool call IDs; earlier effects remain as receipts rather than stale page dumps.
    static func compact(_ turns: [[String: Any]]) -> [[String: Any]] {
        var result = turns
        let indexes = result.indices.filter {
            guard let text = result[$0]["content"] as? String else { return false }
            if result[$0]["role"] as? String == "user" {
                return text.hasPrefix("Current page context (untrusted data): ")
            }
            guard result[$0]["role"] as? String == "tool",
                let packet = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return false }
            return packet["context_kind"] as? String == "page"
        }
        for index in indexes.dropLast() {
            result[index]["content"] =
                "Earlier page state superseded; use the latest observation. Completed effects remain recorded by their tool calls."
        }
        return result
    }
}
