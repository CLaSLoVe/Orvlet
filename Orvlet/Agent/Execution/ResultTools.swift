import Foundation

@MainActor
enum ResultTools {
    static let inspectSchema = ToolSchema.function("inspect_results",
        "Find retained work, including results with no visible card. Returns result IDs, verified values and registered operations. This does not fetch, run or display anything.",
        ["query":["type":"string","description":"Optional subject or purpose to find."]], required:[])

    static let operationSchema = ToolSchema.function("operate_result",
        "Invoke an operation registered on a retained result. This works whether or not a card is visible. Use only the listed operation ID and changed inputs; the host keeps other inputs and updates every referencing view.",
        ["result":["type":"string"], "action":["type":"string"],
         "fields":["type":"object","additionalProperties":["type":"string"]],
         "complete":["type":"boolean"]], required:["result","action"])
    static let schema = ToolSchema.function("present_results",
        "Arrange retained results without fetching or executing them again. Choose separate for independently kept results, together for a joint reading, select for one tool that switches among results. Existing views are preserved. Presentation does not partition the work goal. A source may produce results before any view exists.",
        ["results": ["type":"array", "minItems":1, "maxItems":6, "items":["type":"string"], "description":"Result IDs returned by tools or listed in retainedResults."],
         "layout": ["type":"string", "enum":["separate","together","select"]],
         "reminder": CardReminderRule.schema,
         "title": ["type":"string", "maxLength":80],
         "complete": ["type":"boolean"]], required:["results","layout","title"])
}

@MainActor
extension AgentController {
    /// The interpreted destination survives borrowing a browser resource.
    var resolvedResultView: UUID? {
        if let placement = requestIntent.placement, !placement.layout.usesExistingCard { return nil }
        return requestIntent.targetTaskID.flatMap(UUID.init(uuidString:)) ?? model.activeRequest?.submittedTaskID
    }
    func presentationDestination() -> UUID? {
        guard let id = resolvedResultView else { return nil }
        if let view = model.work.view(id), model.work.artifact(view.selected)?.native != nil { return nil }
        return id
    }
    func finishWorkPresentation(keeping published: Set<UUID>) {
        var hidden = Set<UUID>()
        if let id = resolvedResultView, let view = model.work.view(id),
            model.work.artifact(view.selected)?.native != nil { hidden.insert(id) }
        if let run = RequestRun.current, let page = run.context?.browserResourceID,
            !run.initialResources.contains(page),
            let resource = model.sideTasks.first(where:{ $0.id == page }), !resource.isMediaTask {
            hidden.insert(page)
        }
        // Hide auxiliary views only after successful publication. Their resources
        // and source evidence remain available; pre-existing pages are untouched.
        for id in hidden.subtracting(published) {
            model.work.hideView(id)
            if let i = model.sideTasks.firstIndex(where:{ $0.id == id }) { model.sideTasks[i].hidden = true }
        }
        model.persistSideTasks()
    }
    func inspectResults(_ input: [String:Any]) -> [String:Any] {
        let query = (input["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let results = model.work.snapshot.artifacts.values.filter { artifact in
            query.isEmpty || artifact.title.localizedCaseInsensitiveContains(query)
                || artifact.goalID.flatMap { model.work.snapshot.goals[$0]?.request }?.localizedCaseInsensitiveContains(query) == true
        }.sorted { $0.checked > $1.checked }.prefix(12)
        return ["results":results.map { artifact -> [String:Any] in
            ["id":artifact.id.uuidString,"title":artifact.title,"checked":ISO8601DateFormatter().string(from:artifact.checked),
             "values":artifact.values.filter { $0.value.utf8.count <= 1000 },"inputs":artifact.definition.fields,
             "actions":artifact.definition.actions.map { ["id":$0.id,"kind":$0.kind.rawValue,"operation":$0.operation ?? ""] },
             "views":model.work.snapshot.views.values.filter { $0.artifacts.contains(artifact.id) }.map { ["id":$0.id.uuidString,"hidden":$0.hidden,"closed":$0.closed == true] }]
        }]
    }

    func operateResult(_ input: [String:Any]) async throws -> [String:Any] {
        guard let raw = input["result"] as? String, let id = UUID(uuidString: raw),
            let action = input["action"] as? String, let artifact = model.work.artifact(id),
            let operation = artifact.definition.actions.first(where: { $0.id == action }) else {
            throw ToolArgumentError(path:"$.action",issue:"use an available result operation")
        }
        let fields = input["fields"] as? [String:String] ?? [:]
        guard Set(fields.keys).isSubset(of:Set(artifact.definition.fields)), fields.values.allSatisfy({ $0.utf8.count <= 8000 }) else {
            throw ToolArgumentError(path:"$.fields",issue:"use the operation's declared inputs")
        }
        if let job = model.performWorkOperation(id, action:action, fields:fields) {
            await withTaskCancellationHandler(operation:{ await job.value },onCancel:{ job.cancel() })
        } else if operation.kind == .agent || operation.kind == .openRecord {
            return ["accepted":true,"result":raw,"status":"Handed off"]
        } else if artifact.native?.isMediaTask == true {
            let expected = (operation.operation ?? action) == "toggle" ? !(artifact.native?.playing ?? false)
                : (operation.operation ?? action) == "play"
            for _ in 0..<40 {
                if model.work.artifact(id)?.native?.playing == expected { break }
                try await Task.sleep(for:.milliseconds(150))
            }
            guard model.work.artifact(id)?.native?.playing == expected else { throw AppError.message("Playback change has not been confirmed.") }
        } else { throw ToolArgumentError(path:"$.action",issue:"operation could not be started") }
        try Task.checkCancellation()
        guard let updated = model.work.artifact(id), updated.issue == nil,
            updated.native != nil || updated.definition.runtime != nil || updated.status == "Ready" || (operation.operation == "stop" && updated.status == "Stopped") else {
            throw AppError.message("The operation could not be verified; the earlier result remains saved.")
        }
        if operation.kind == .runtime, !fields.allSatisfy({ updated.values[$0.key] == $0.value }) {
            throw ToolArgumentError(path:"$.fields",issue:"runtime inputs were not accepted; use the registered choices")
        }
        if operation.kind == .remote { freshSourceLoaded = true }
        RequestRun.current?.retainResult(id,needsView:false)
        verifyEffect(updated.title)
        return ["verified":true,"result":raw,"values":updated.values]
    }
    func presentResults(_ input: [String:Any]) throws -> [String:Any] {
        guard let raw = input["results"] as? [String], let layout = input["layout"] as? String,
            let title = input["title"] as? String else { throw AppError.message("Select retained results and a layout.") }
        let ids = raw.compactMap(UUID.init(uuidString:))
        let available = Set(model.work.snapshot.artifacts.keys)
        guard ids.count == raw.count, Set(ids).isSubset(of: available) else {
            throw ToolArgumentError(path:"$.results", issue:"use saved result IDs returned by acquisition or inspect_results")
        }
        let target = presentationDestination()
        let rule = try CardReminderRule.decode(input["reminder"])
        let viewIDs = try model.presentWork(ids, layout: layout == "separate" ? .single : layout == "select" ? .select : .together,
            title: title, destination: target, reminder: rule)
        finishWorkPresentation(keeping:Set(viewIDs))
        taskSurfaceReady = true
        if let id = viewIDs.first { activeTaskID = id }
        verifyEffect(title)
        return ["verified":true,"views":viewIDs.map(\.uuidString),"results":raw]
    }
}
