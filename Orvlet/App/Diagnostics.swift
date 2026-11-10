import Foundation

@MainActor
enum Diagnostics {
    static var file: URL?
    static var started = Date()
    static var storage = UserDefaults.standard
    #if DEBUG
        static var benchmarkEvents: [[String: Any]]? = nil
    #endif
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
            if benchmarkEvents != nil,
                ["api", "round", "tool", "tool_error", "intent_invalid", "decision_context", "ui_spec"].contains(event)
            {
                var entry = fields.filter {
                    [
                        "seconds", "model", "usage", "tools", "name", "category", "reason", "promptBytes", "toolBytes",
                        "toolCount", "route", "form", "fields",
                    ].contains($0.key)
                }
                entry["event"] = event
                benchmarkEvents?.append(entry)
            }
        #endif
        if file == nil {
            // Bounded support metadata only: no messages, source URLs, model
            // responses, generated code, field values or credentials.
            let allowed: Set<String> = [
                "behavior", "fieldPath", "requestID", "taskID", "stage", "seconds", "name", "tools", "attempt", "kind",
                "format", "failed",
                "cancelled", "type", "category", "argumentKeys", "contentLength", "paused", "origin", "held",
                "waitingForInterface", "restoringPlayback", "revision", "playing", "currentTime", "promptBytes",
                "toolBytes", "toolCount", "route",
                "routeKnown", "methodCount", "candidateCount", "reused", "reasonCode", "budget", "capability",
                "directControl", "cardReuse", "messageBytes", "inputBytes", "responseBytes",
                "inputTokens", "outputTokens", "totalTokens", "model", "host", "modelCallID",
                "reasoningRequested", "reasoningPolicy", "reasoningCharacters", "reasoningTokens",
                "goal", "verified", "complete",
                "visible", "imageLoaded", "frame", "screenFrame",
            ]
            var entry = fields.filter { allowed.contains($0.key) }
            entry["event"] = event
            entry["date"] = ISO8601DateFormatter().string(from: Date())
            var entries = storage.array(forKey: "diagnostics.v1") as? [[String: Any]] ?? []
            entries.append(entry)
            storage.set(Array(entries.suffix(600)), forKey: "diagnostics.v1")
            return
        }
        guard let file else { return }
        var entry = fields
        entry["event"] = event
        entry["elapsed"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
            let handle = try? FileHandle(forWritingTo: file)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
    static func category(_ error: Error) -> String {
        if error is ToolArgumentError || error is DecodingError { return "schema" }
        if error is ModelAccessError { return "credentials" }
        if error is URLError { return "network" }
        let text = error.localizedDescription.lowercased()
        if text.contains("runtime") || text.contains("scheduled") || text.contains("continuing") { return "runtime" }
        if text.contains("bind") || text.contains("field") || text.contains("markup") { return "interface" }
        if text.contains("source") || text.contains("verified") || text.contains("playback") { return "verification" }
        if text.contains("calculation") || text.contains("code") || text.contains("handler") { return "calculation" }
        return "execution"
    }
    static func supportSummary() -> String {
        JSONText.encode([
            "version": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "events": storage.array(forKey: "diagnostics.v1") ?? [],
        ])
    }
    static func begin(_ path: String) {
        file = URL(fileURLWithPath: path)
        started = Date()
        try? Data().write(to: file!, options: .atomic)
    }
}
