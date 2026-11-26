import Foundation

/// Retain only a failed, replayable tool definition within the current request revision.
struct FailedStep {
    static let tools: Set<String> = ["present_ui", "query_api", "build_data_tool", "run_code", "compose_ui"]
    let name: String
    let arguments: [String: Any]
    @MainActor init(name: String, arguments: [String: Any]) {
        self.name = name
        self.arguments = ToolContract.normalizedCardArguments(name, arguments)
    }

    static let schema = ToolSchema.function("repair_step",
        "Repair the retained failed tool call. Patch only the affected arguments. Use the exact reported field path as a changes key to replace one value, including a single array item. For example a key named $.actions[0].code replaces only that handler body. Nested object patches also merge. Other arguments and verified work are preserved. Send changes as an object. Set an unexpected key to null to remove it. Example: {\u{22}checks\u{22}:[...]}. The host reruns validation before publishing.",
        ["changes": ["type": ["object", "string"]]], required: ["changes"])

    func repaired(_ input: [String: Any]) throws -> [String: Any] {
        let changes: [String: Any]?
        if let patch = input["changes"] as? [String: Any] { changes = patch }
        else if let encoded = input["changes"] as? String, encoded.utf8.count <= 120_000 {
            changes = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        } else { changes = nil }
        guard let changes, !changes.isEmpty, JSONText.encode(changes).utf8.count <= 120_000 else { throw ToolArgumentError(path: "$.changes", issue: "supply the corrected argument(s) as a JSON object") }
        func merge(_ previous: [String: Any], _ patch: [String: Any]) -> [String: Any] {
            var result = previous
            for (key, value) in patch {
                if value is NSNull { result.removeValue(forKey: key) }
                else if let nested = value as? [String: Any], let old = result[key] as? [String: Any] {
                    result[key] = merge(old, nested)
                } else { result[key] = value }
            }
            return result
        }
        var fields: [String: Any] = [:]
        var paths: [String: Any] = [:]
        for (key, value) in changes {
            if key.hasPrefix("$.") { paths[key] = value }
            else if key.hasPrefix(".") { paths["$" + key] = value }
            else if key.contains(".") || key.contains("[") { paths["$." + key] = value }
            else { fields[key] = value }
        }
        var patched = merge(arguments, fields)
        for path in paths.keys.sorted() {
            guard path.range(of: #"^\$(?:\.[A-Za-z_][A-Za-z0-9_-]*|\[[0-9]{1,4}\])+$"#, options: .regularExpression) != nil else {
                throw ToolArgumentError(path: "$.changes", issue: "use the exact reported field path")
            }
            let keys = path.dropFirst().split { ".[]".contains($0) }.map(String.init)
            let invalid = ToolArgumentError(path: path, issue: "the retained definition has no such parent or array index")
            func replace(_ current: Any, at index: Int) throws -> Any {
                guard index < keys.count else { return paths[path]! }
                let key = keys[index]
                if var object = current as? [String: Any] {
                    guard let old = object[key] ?? (index == keys.count - 1 ? NSNull() : nil) else { throw invalid }
                    let next = try replace(old, at: index + 1)
                    object[key] = next is NSNull ? nil : next
                    return object
                }
                if var array = current as? [Any], let position = Int(key), array.indices.contains(position) {
                    array[position] = try replace(array[position], at: index + 1)
                    return array
                }
                throw invalid
            }
            patched = try replace(patched, at: 0) as! [String: Any]
        }
        return patched
    }
}

/// Acquisition failed before a usable response existed. Keep this distinct from a
/// bad pointer, calculation or layout: those can reuse the response already fetched.
struct SourceReadFailure: LocalizedError {
    let url: String
    let reason: String
    var allowsCorrection = false
    var hostUnavailable = false
    var accessStatus: Int? = nil
    var errorDescription: String? { reason }
    static func route(_ raw: String) -> String {
        guard let url = URLComponents(string: raw) else { return raw }
        return (url.host?.lowercased() ?? "") + url.percentEncodedPath
    }
}

/// Acquisition, definition repair and execution keep separate bounded failure counts.
/// A valid source remains usable while independent definition errors are corrected.
struct RequestRecovery {
    var siteDestination: String?
    private var failures: [String: Int] = [:]
    private var unavailableSources = Set<String>()
    private var unavailableHosts = Set<String>()
    private var recoveredSource = false
    private var alternativePageAttempted = false
    var sourceRecoveryContext: [String: Any]? {
        guard !unavailableSources.isEmpty else { return nil }
        return ["unavailableRoutes": unavailableSources.sorted(), "unavailableHosts": unavailableHosts.sorted()]
    }
    private(set) var definitionFailures = 0
    private(set) var lastDefinitionIssue: String?
    private(set) var repeatedDefinitionField = 0
    private var definitionField: String?
    mutating func definitionFailed(_ reason: String, field: String?) {
        definitionFailures += 1
        repeatedDefinitionField = field == definitionField ? repeatedDefinitionField + 1 : 1
        definitionField = field
        lastDefinitionIssue = reason
    }
    var needsAlternativeSource: Bool { unavailableSources.count == 1 && !recoveredSource && !alternativePageAttempted }
    mutating func sourceFailed(_ failure: SourceReadFailure) {
        unavailableSources.insert(SourceReadFailure.route(failure.url))
        if failure.hostUnavailable, let host = URL(string: failure.url)?.host?.lowercased() { unavailableHosts.insert(host) }
        recoveredSource = false
        switched = true
    }
    mutating func attemptingPage(_ raw: String) {
        if !unavailableSources.isEmpty, !sourceUnavailable(raw) { alternativePageAttempted = true }
    }
    mutating func sourceSucceeded() { recoveredSource = true }
    func sourceUnavailable(_ raw: String) -> Bool {
        unavailableSources.contains(SourceReadFailure.route(raw)) || URL(string: raw)?.host.map { unavailableHosts.contains($0.lowercased()) } == true
    }

    private(set) var total = 0
    private(set) var switched = false
    private(set) var lastTool: String?
    private(set) var needsSourceReading = false
    private var expectedValues = Set<String>()
    private var needsTimedRecipe = false

    func validateSnapshot(_ sourceValues: [String], requirements: [OutcomeRequirement]) throws {
        guard !needsTimedRecipe else {
            throw ToolArgumentError(path: "$.bindings", issue: "the requested recipe needs freshness or recurring updates; verify them with a source recipe")
        }
        try validateIdentity(sourceValues, requirements: requirements)
    }

    func validateIdentity(_ sourceValues: [String], requirements: [OutcomeRequirement]) throws {
        let missing = expectedValues.filter { expected in !sourceValues.contains { $0.caseInsensitiveCompare(expected) == .orderedSame } }
        let unproven = requirements.filter { requirement in
            !sourceValues.contains { text in requirement.anyOf.contains { OutcomeEvidence.matches(text, expected: $0) } }
        }
        guard missing.isEmpty, unproven.isEmpty else {
            throw ToolArgumentError(path: "$.bindings", issue: "bind identity and qualifier fields from the contributing sources as well as measurements: "
                + (missing.sorted() + unproven.map(\.label)).joined(separator: ", "))
        }
    }
    private var rejectedMethod: String?
    var awaitingAlternative: Bool { rejectedMethod != nil }

    mutating func starting(_ tool: String, _ arguments: [String: Any]) {
        guard let rejectedMethod, !["load_tools", "finish"].contains(tool),
            method(tool, arguments) != rejectedMethod else { return }
        self.rejectedMethod = nil
    }
    var requiresVerifiedResult: Bool { lastTool != nil }

    private func method(_ tool: String, _ arguments: [String: Any]) -> String {
        let source = arguments["source"] as? [String: Any] ?? arguments
        let endpoint = (source["url"] as? String).flatMap(URLComponents.init(string:))
        let site = endpoint?.host ?? ""
        let resource = site + (endpoint?.percentEncodedPath ?? "")
        switch tool {
        case "build_data_tool": return tool + "/" + (arguments["source"] as? String ?? resource)
        case "query_api": return tool + "/" + resource + (source["calculation"] is String ? "/calculation" : "/binding")
        case "inspect_api", "read_value", "navigate": return tool + "/" + resource
        case "present_ui": return tool + (arguments["markup"] == nil ? "/components" : "/markup")
        case "finish": return tool + "/" + (arguments["outcome"] as? String ?? "")
        default: return tool
        }
    }

    func exhausted(_ tool: String, _ arguments: [String: Any]) -> Bool {
        if ["query_api", "read_value", "inspect_api"].contains(tool) {
            let source = arguments["source"] as? [String: Any] ?? arguments
            var raw = source["url"] as? String ?? ""
            for (key, value) in source["inputs"] as? [String: String] ?? [:] {
                raw = raw.replacingOccurrences(of: "{" + key + "}", with: value)
            }
            if sourceUnavailable(raw) { return true }
        }
        return rejectedMethod == method(tool, arguments)
    }

    mutating func record(_ tool: String, _ arguments: [String: Any], definitionIssue: Bool = false) -> Int {
        // Independent corrections are progress, not evidence that a healthy source
        // is unavailable. Bound repetitions of the exact invalid definition instead.
        let key = method(tool, arguments) + (definitionIssue ? "/definition/" + JSONText.encode(arguments) : "")
        failures[key, default: 0] += 1
        if !definitionIssue { total += 1; lastDefinitionIssue = nil; definitionField = nil; repeatedDefinitionField = 0 }
        if ["read_value", "query_api", "build_data_tool", "inspect_api"].contains(tool) {
            needsSourceReading = true
            let source = arguments["source"] as? [String: Any] ?? arguments
            needsTimedRecipe = needsTimedRecipe || source["maxAgeSeconds"] is NSNumber || source["refreshSeconds"] is NSNumber
            let expectations = source["expectations"] as? [String: String] ?? [:]
            let inputs = source["inputs"] as? [String: String] ?? [:]
            for var value in expectations.values {
                for (name, parameter) in inputs { value = value.replacingOccurrences(of: "{" + name + "}", with: parameter) }
                expectedValues.insert(value)
            }
            if let expected = source["expectedIdentity"] as? String { expectedValues.insert(expected) }
            for qualifier in source["qualifiers"] as? [[String: String]] ?? [] {
                if let expected = qualifier["expected"] { expectedValues.insert(expected) }
            }
        }
        if !["finish", "load_tools", "arguments"].contains(tool) { lastTool = tool }
        if failures[key, default: 0] >= 2 && !definitionIssue {
            switched = true
            if ["query_api", "build_data_tool", "read_value", "inspect_api", "compose_ui", "present_ui", "reuse_saved_ui", "navigate"].contains(tool) {
                rejectedMethod = key
            }
        }
        return failures[key, default: 0]
    }
}

extension AgentController {
    func recover(_ error: Error, tool: String, arguments: [String: Any]) throws -> String {
        let acquisition = (error as? SourceReadFailure).flatMap { $0.allowsCorrection ? nil : $0 }
        var earlierDenial = false
        if let acquisition {
            if let status = acquisition.accessStatus {
                earlierDenial = model.siteMemory.hint(url: acquisition.url, profile: nil) != nil
                let owner = model.activeRequest?.owner?.id ?? model.requestCardID ?? activeTaskID
                model.siteMemory.recordAPI(url: acquisition.url, status: status, taskID: owner)
            }
            recovery.sourceFailed(acquisition)
        }
        let definitionIssue = error is ToolArgumentError || error is DecodingError
        let attempt = recovery.record(tool, arguments, definitionIssue: definitionIssue)
        if definitionIssue { recovery.definitionFailed(error.localizedDescription, field: (error as? ToolArgumentError)?.path) }
        if recovery.total >= 8 || recovery.definitionFailures >= 8 || definitionIssue && attempt >= 3 { throw RecoveryLimit(tool: recovery.lastTool ?? tool) }
        if definitionIssue {
            model.activity = model.userText("正在修正这一步的定义…", "Correcting this step…")
            return "Correct the reported definition field with repair_step when available. This is not a failed source: keep the acquired response, its identity and the same task. Do not switch providers or rebuild the tool solely because separate definition fields need correction."
        }
        if attempt == 1 && acquisition == nil {
            model.activity = model.userText("正在重新核对这一步…", "Checking this step again…")
            return failedStep == nil ? "Correct the step or use another method. Preserve verified work." :
                "Use repair_step for a targeted correction, or choose a simpler method."
        }
        failedStep = nil
        model.activity = model.userText("正在换一种方法…", "Trying another approach…")
        if acquisition != nil {
            // A source outage does not invalidate the API renderer or recipe tools.
            // Keep them available so a new response can go straight onto the card.
            loadedToolFamilies.formUnion(["data", "reading", "source_lookup"])
            Diagnostics.record("recovery_switch", ["name": tool, "attempt": attempt, "category": "source", "requestID": model.activeRequest?.id.uuidString ?? ""])
            return (earlierDenial ? "This exact public API operation also denied an earlier task. " : "") + "No usable response was acquired. This endpoint is unavailable for the request. Choose another public endpoint/provider or inspect an accessible page in the owned browser. After inspecting an alternative JSON source, use build_data_tool with its observation handle, parameters and result expressions. The host assembles the executable recipe and card. For a direct page reading, use finish(page_ready,source_only:true) with a short title, primaryKey, observed readings and exact readingValues instead of generating markup. Keep the goal, units and requested interactions. Do not ask the human to retry an internal source failure."
        }
        let next: String
        switch tool {
        case "inspect_api", "read_value", "query_api", "build_data_tool":
            loadedToolFamilies.remove("data")
            loadedToolFamilies.formUnion(["reading", "source_lookup"])
            if observations.hasSeveralSources && RequestRun.current?.assignment == nil {
                next = "Keep all contributing sources for a combined result. Use run_code.bindings with actual values and requested source qualifiers, then present_ui. For independent results use separate_cards. Do not publish only the last reading."
            } else {
                next = "Use read_value for directly reported data, a different public source, or navigate and verify the reading on its page. For required calculations load data for a new source or use a verified computation. Preserve identity, freshness and units."
            }
        case "present_ui", "run_code", "reuse_saved_ui":
            loadedToolFamilies.formUnion(["workspace", "custom_layout"])
            next = "Switch between a verified host form, a saved method or a minimal custom interface. Preserve requested interactions and use verified inputs."
        case "compose_ui", "reuse_ui", "navigate", "observe":
            loadedToolFamilies.formUnion(["web", "data"])
            next = "Use another source or binding. For a snapshot, finish(page_ready,source_only:true) with exact observed readings. Preserve all requested behavior."
        default:
            next = "Load another applicable capability, use a different method, or verify the existing effect. Never repeat an uncertain write."
        }
        Diagnostics.record("recovery_switch", ["name": tool, "attempt": attempt, "category": Diagnostics.category(error), "requestID": model.activeRequest?.id.uuidString ?? ""])
        return "This method is exhausted for this request. " + next
    }
}

struct RecoveryLimit: Error {
    let tool: String
}

/// Receipts live only through the attempted definition and its repairs. Editing code, inputs or
/// upstream state gives a different key. Normal user actions always execute the real worker.
@MainActor
final class DefinitionChecks: TaskCodeExecuting {
    let worker: TaskCodeRuntime
    var successes: [String: [String: Any]] = [:]
    init(_ worker: TaskCodeRuntime) { self.worker = worker }
    func run(code: String, input: [String: Any], state: [String: String]) async throws -> [String: Any] {
        try await worker.run(code: code, input: input, state: state)
    }
    func run(code: String, input: [String: Any], state: [String: String], declaredInputs: [String]) async throws -> [String: Any] {
        let signature = JSONText.encode(["code": code, "input": input, "state": state, "fields": declaredInputs.sorted()])
        if let receipt = successes[signature] { return receipt }
        let output = try await worker.run(code: code, input: input, state: state, declaredInputs: declaredInputs)
        if successes.count < 32 { successes[signature] = output }
        return output
    }
}
