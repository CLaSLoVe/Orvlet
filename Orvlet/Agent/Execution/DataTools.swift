import Foundation
import WebKit

@MainActor
extension AgentController {
    var comparisonCandidates: [SideTask] {
        guard let plan = requestIntent.placement, plan.layout == .together else { return [] }
        return model.visibleTasks.filter { task in
            task.id != activeTaskID && task.terminalLabel == nil && task.kind != .result
                && (RequestRun.current?.initialCandidates.contains(task.id) ?? true)
                && (plan.context.isEmpty || plan.context.contains(task.id))
        }
    }

    private func requireAvailableSource(_ url: String) throws {
        if recovery.sourceUnavailable(url) {
            throw AppError.message("This data endpoint already failed in this request. Keep the verified alternative response and use another source recipe; loading a saved method does not make this endpoint available.")
        }
    }

    private static func dataRecipe(_ object: [String: Any], language: String) throws -> (spec: APIDataSpec, omitted: Int) {
        var source = object
        let raw = source.removeValue(forKey: "visuals")
        let decoder = JSONDecoder()
        var spec = try decoder.decode(APIDataSpec.self, from: JSONSerialization.data(withJSONObject: source))
        spec.interfaceLanguage = language
        let proposal = CardVisual.decodeProposals(raw)
        spec.visuals = raw == nil ? nil : proposal.blocks
        spec = try spec.validated()
        return (spec, proposal.count - (spec.visuals?.count ?? 0))
    }

    func executeDataTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "inspect_results": return inspectResults(input)
        case "present_results": return try presentResults(input)
        case "operate_result": return try await operateResult(input)
        case "build_data_tool":
            guard let reference = input["source"] as? String, let sample = observations.sample(reference) else {
                throw ToolArgumentError(path:"$.source",issue:"inspect the source first and use its observation handle")
            }
            sourceEvidence = sample
            let spec = try DataToolPlan.compile(input, sample:sample)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String:Any]
            do {
                return try await executeDataTool("query_api", ["title":input["title"] ?? "", "source":object], revision:revision)
            } catch let issue as ToolArgumentError where issue.path == "$.source.calculation" {
                let regex = try NSRegularExpression(pattern:#"results\[([0-9]+)\]\.expression"#)
                let match = regex.firstMatch(in:issue.issue, range:NSRange(issue.issue.startIndex...,in:issue.issue))
                let path = match.flatMap { Range($0.range,in:issue.issue) }.map { "$." + issue.issue[$0] } ?? "$.results"
                throw ToolArgumentError(path:path,issue:issue.issue)
            }
        case "inspect_api":
            guard let url = input["url"] as? String else { throw AppError.message("Provide a public JSON API URL.") }
            try requireAvailableSource(url)
            let sample = try await model.apiData.sample(url: url, previous: sourceEvidence)
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            if requestedDelivery != .answer, !RequestedDelivery.hasAnswerCue(currentRequest),
                requestIntent.placement?.layout == .answer || requestIntent.placement == nil,
                model.activeRequest?.owner == nil {
                requestedDelivery = .card
            }
            recovery.sourceSucceeded()
            sourceEvidence = sample
            var result: [String: Any] = ["observation": observations.retain(sample), "source": url,
                "retrievedAt": ISO8601DateFormatter().string(from: sample.checked), "data": sample.preview]
            result["next"] = "Use build_data_tool for an editable or derived result. Declare parameters and result expressions once; the host builds controls, state and both views."
            if observations.hasSeveralSources {
                result["otherObservations"] = "Earlier observations remain available. Their count does not prescribe the interface: a parameterized tool may select one object at a time; a combined calculation must bind all contributing measurements."
            }
            return result
        case "show_readings":
            guard let title = input["title"] as? String, let rows = input["rows"] as? [[String: String]],
                (2...6).contains(rows.count) else { throw ToolArgumentError(path: "$.rows", issue: "supply two to six named readings") }
            var state: [String: String] = [:]
            var outputs: [TaskForm.Output] = []
            var actions: [TaskSurfaceAction] = []
            func appendRow(key: String, label: String, page: String?) {
                var row = TaskForm.Output(key: key, label: String(label.prefix(80)))
                if let page, let url = try? PublicDataClient.url(page) {
                    let id = "open" + key
                    actions.append(.init(id: id, kind: .openRecord, operation: url.absoluteString))
                    row.sourceAction = id
                }
                outputs.append(row)
            }
            var selected = Set<UUID>()
            for (index, row) in rows.enumerated() {
                let key = "reading" + String(index)
                if let handle = row["card"] {
                    guard let task = comparisonCandidates.first(where: { $0.id.uuidString == handle }),
                        selected.insert(task.id).inserted, task.dataIssue == nil,
                        let spec = task.taskSurface?.apiData, let card = spec.card,
                        let primary = spec.displayRows.first(where: { $0.key == card.primaryKey }),
                        let value = task.state[primary.key], !value.isEmpty else {
                        throw ToolArgumentError(path: "$.rows", issue: "select distinct available reading cards or inspect the requested sources")
                    }
                    let unit = (card.unitKey ?? primary.unitKey).flatMap { task.state[$0] } ?? primary.unit ?? ""
                    state[key] = value + (unit.isEmpty || value.hasSuffix(unit) ? "" : " " + unit)
                    let subject = card.displayNameKey.flatMap { task.state[$0] } ?? card.subject ?? task.title
                    appendRow(key: key, label: subject, page: spec.recordPagePointer == nil ? nil : task.state["recordPageURL"])
                    continue
                }
                guard let subject = row["subject"], let observation = row["observation"],
                    let identity = row["identityPointer"], let expected = row["expectedIdentity"], !expected.isEmpty,
                    let pointer = row["valuePointer"], pointer != identity else {
                    throw ToolArgumentError(path: "$.rows", issue: "bind the identity and reading separately")
                }
                func read(_ pointer: String) throws -> String {
                    let values = try observations.inputs(["bindings": [["name": "v", "observation": observation, "pointer": pointer]]])
                    guard let raw = values["v"], let value = APIDataSpec.scalar(raw), !value.isEmpty else {
                        throw ToolArgumentError(path: "$.rows", issue: "use a reported scalar from the observed record")
                    }
                    return value
                }
                guard try read(identity).caseInsensitiveCompare(expected) == .orderedSame else {
                    throw ToolArgumentError(path: "$.rows", issue: "source record does not match the requested subject")
                }
                let unit = try row["unitPointer"].map(read) ?? row["unit"] ?? ""
                state[key] = try read(pointer) + (unit.isEmpty ? "" : " " + unit)
                appendRow(key: key, label: subject, page: row["recordPagePointer"].flatMap { try? read($0) })
            }
            // Use source order for both lines so each value stays with its label.
            // When the pair cannot fit, show one labeled reading; all rows remain in the card.
            let first = outputs[0]
            var subject = first.label
            var primary = first.key
            if outputs.count == 2 {
                let labels = outputs.map(\.label).joined(separator: " / ")
                let readings = outputs.compactMap { state[$0.key] }.joined(separator: " / ")
                if (labels as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width <= 80,
                    (readings as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width <= 80 {
                    subject = labels
                    primary = "glance"
                    state[primary] = readings
                }
            }
            let form = TaskForm(inputs: [], outputs: outputs, buttons: [], compactSubject: String(subject.prefix(40)), compactKey: primary)
            let surface = TaskSurface(title: title, markup: try form.markup(), fields: [], actions: actions, state: state)
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            try model.commitTaskSurface(surface, id: activeTaskID, ticket: interfaceTicket)
            freshSourceLoaded = true
            taskSurfaceReady = true
            verifyEffect(title)
            return ["verified": true, "state": state]
        case "read_value":
            guard input["valuePointer"] as? String != input["identityPointer"] as? String else {
                throw ToolArgumentError(path: "$.valuePointer", issue: "bind the requested measurement separately from the source identity")
            }
            guard let url = input["url"] as? String, let subject = input["subject"] as? String,
                let label = input["valueLabel"] as? String, let pointer = input["valuePointer"] as? String,
                let identity = input["identityPointer"] as? String, let expected = input["expectedIdentity"] as? String,
                !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ToolArgumentError(path: "$.expectedIdentity", issue: "provide the identity expected from the requested source record") }
            var value = ["key": "reading", "label": label, "pointer": pointer]
            value["unit"] = input["unit"] as? String
            var fields = [value, ["key": "entity", "label": subject, "pointer": identity]]
            var card: [String: Any] = ["kind": "reading", "primaryKey": "reading", "subject": subject, "detailKeys": []]
            if let name = input["displayNamePointer"] as? String, !name.isEmpty,
                name != pointer, name != identity, name != input["unitPointer"] as? String {
                fields.append(["key": "displayName", "label": subject, "pointer": name])
                card["displayNameKey"] = "displayName"
                card.removeValue(forKey: "subject")
            }
            if let unit = input["unitPointer"] as? String {
                fields.append(["key": "readingUnit", "label": label, "pointer": unit])
                card["unitKey"] = "readingUnit"
            }
            var expectations = ["entity": expected]
            for (i, extra) in (input["qualifiers"] as? [[String: String]] ?? []).enumerated() {
                guard let pointer = extra["pointer"], let expected = extra["expected"] else { continue }
                let key = "qualifier" + String(i)
                fields.append(["key": key, "label": expected, "pointer": pointer])
                expectations[key] = expected
            }
            var source: [String: Any] = ["url": url, "fields": fields, "card": card, "expectations": expectations]
            for key in ["recordPagePointer", "updatedAtPointer", "updatedAtFormat", "refreshSeconds"] { source[key] = input[key] }
            // read_value declares the identity roles explicitly. Bind a verified
            // identity/qualifier even when another name is an equally valid alias.
            let proofs = requestIntent.requirements.enumerated().compactMap { index, requirement -> [String: Any]? in
                guard let field = fields.first(where: { field in
                    guard let key = field["key"], let identity = expectations[key] else { return false }
                    return requirement.anyOf.contains { OutcomeEvidence.matches(identity, expected: $0) }
                }), let key = field["key"] else { return nil }
                return ["requirement": index, "fieldKey": key]
            }
            return try await executeDataTool("query_api", ["title": subject, "source": source, "outcomeEvidence": proofs], revision: revision)
        case "query_api":
            guard nativeRequestActive, requestIntent.behavior != .advancing,
                let title = input["title"] as? String, !title.isEmpty,
                let object = input["source"] as? [String: Any]
            else {
                throw AppError.message(
                    "Supply a title and source recipe for a data reading."
                )
            }
            var spec: APIDataSpec
            let omitted: Int
            do {
                (spec, omitted) = try Self.dataRecipe(object, language: model.settings.preferredInterfaceLanguage)
            } catch {
                // No transport or side effect has run: repair a recipe contract, not an external failure.
                if let decoding = ToolArgumentError.decoding(error) {
                    throw ToolArgumentError(path: "$.source" + decoding.path.dropFirst(), issue: decoding.issue)
                }
                throw (error as? ToolArgumentError) ?? ToolArgumentError(path: "$.source", issue: error.localizedDescription)
            }
            if requestIntent.behavior == .live && spec.refreshSeconds == nil {
                spec.refreshSeconds = requestIntent.updateIntervalSeconds ?? 60
                spec = try spec.validated()
            }
            if Diagnostics.file != nil { Diagnostics.record("api_recipe", ["source": object]) }
            let retainedSurface = model.sideTasks.first(where: {
                $0.id == activeTaskID && $0.taskSurface?.apiData != nil
            })?.taskSurface
            if retainedSurface?.apiData?.customLayout == true { spec.customLayout = true }
            try requireAvailableSource(try spec.requestURL().absoluteString)
            let reading = try await model.apiData.acquire(spec, previous: sourceEvidence) { self.sourceEvidence = $0 }
            recovery.sourceSucceeded()
            let state = reading.state
            let proofs = input["outcomeEvidence"] as? [[String: Any]] ?? []
            for (index, requirement) in requestIntent.requirements.enumerated() {
                let inputControls = spec.inputControls.filter { control in
                    if let key = requirement.inputKey { return control.key == key }
                    return [control.key, control.label].contains {
                        $0.caseInsensitiveCompare(requirement.label) == .orderedSame
                    }
                }
                if inputControls.count == 1, let key = inputControls.first?.key, let value = spec.inputs?[key],
                    requirement.anyOf.contains(where: { OutcomeEvidence.matches(value, expected: $0) }),
                    !spec.url.contains("{" + key + "}") || (spec.expectations ?? [:]).values.contains("{" + key + "}")
                {
                    // Locally supplied parameters are checked against bound inputs.
                    // Source-affecting inputs additionally need the response identity
                    // assertion already checked by APIDataService.read.
                    continue
                }
                // Proof concerns actual extracted source fields, not an LLM's
                // fragile ordinal mapping. Redundant echoes of the same actual value are not ambiguity.
                // A map may report an identity as an object member name instead of
                // repeating it as a scalar. Verify it in the actual response along a
                // successfully extracted field path, never in a URL or generated label.
                if let sample = sourceEvidence {
                    let keys = spec.fields.flatMap { field -> [String] in
                        guard let pointer = try? spec.expandedPointer(field.pointer) else { return [] }
                        return APIDataSpec.reportedKeys(pointer, in: sample.response)
                    }
                    if keys.contains(where: { key in requirement.anyOf.contains { OutcomeEvidence.matches(key, expected:$0) } }) {
                        continue
                    }
                }
                let matches = spec.fields.filter { field in
                    state[field.key].map { value in
                        requirement.anyOf.contains { OutcomeEvidence.matches(value, expected: $0) }
                    } ?? false
                }
                let declared = proofs.first { $0["requirement"] as? Int == index }?["fieldKey"] as? String
                let matchingValues = Set(
                    matches.compactMap { field in
                        state[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines).folding(
                            options: [.caseInsensitive, .diacriticInsensitive],
                            locale: Locale(identifier: "en_US_POSIX"))
                    })
                guard matches.contains(where: { $0.key == declared }) || matchingValues.count == 1 else {
                    if let repair = reading.bindingError(
                        label: requirement.label,
                        excluding: spec.fields.map(\.pointer),
                        matching: { value in
                            requirement.anyOf.contains { OutcomeEvidence.matches(value, expected: $0) }
                        })
                    {
                        throw repair
                    }
                    let observed = spec.fields.map { $0.key + "=" + String((state[$0.key] ?? "").prefix(120)) }.joined(
                        separator: ", ")
                    throw AppError.message(
                        "Source identity mismatch for " + requirement.label + ". Expected one of "
                            + JSONText.encode(requirement.anyOf) + "; actual source fields: " + observed
                            + ". Bind a matching source field; do not rebuild the interface or substitute generated labels."
                    )
                }
            }
            let markup = (input["markup"] as? [String: Any]).flatMap {
                try? JSONDecoder().decode(CardMarkup.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            let retained = retainedSurface?.apiData?.customLayout == true && retainedSurface?.markup.matchesLanguage(model.settings.preferredInterfaceLanguage) == true ? retainedSurface?.markup : nil
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            retainedSnapshot = nil
            retainedReading = spec.readingSummary(title: title, state: state)
            // The result commits before rendering. A failed view cannot erase it,
            // and later source operations never overwrite a sibling result.
            if let run = RequestRun.current {
                let replacement = resolvedResultView.flatMap { model.work.view($0)?.selected }
                    .flatMap { model.work.artifact($0)?.native == nil ? $0 : nil }
                let id = model.retainWorkResult(title: title, values: state, spec: spec, replacing: replacement, sample: sourceEvidence)
                freshSourceLoaded = true
                return ["verified":true, "result":id.uuidString, "title":title, "values":state,
                    "retainedResults":run.resultIDs.map { result in
                        ["id":result.uuidString, "title":model.work.artifact(result)?.title ?? ""]
                    }, "next":"Continue the goal if needed. Use present_results to select separate, together or select views; no new execution is required."]
            }
            let surface: TaskSurface
            do {
                let candidate = try spec.surface(title: title, state: state, proposed: markup ?? retained, request: currentRequest)
                if let layout = candidate.apiData?.card, layout.kind == .reading {
                    let labels = spec.displayRows.filter { $0.key != layout.primaryKey }.map(\.label)
                    try candidate.markup.validateMeasuredResult(primary: layout.primaryKey, subjects: [candidate.title] + labels, state: candidate.state, fieldPath: "$.source.card.primaryKey")
                }
                try candidate.markup.validateLanguage(model.settings.preferredInterfaceLanguage, path: markup == nil ? "$.source" : "$.markup")
                #if DEBUG
                if model.isLiveTest && CommandLine.arguments.contains("--reject-reading-layout") {
                    throw ToolArgumentError(path: "$.markup", issue: "Injected presentation failure after verification")
                }
                #endif
                surface = candidate
            } catch {
                guard retained == nil else { throw error }
                var plain = spec
                plain.visuals = nil
                plain.customLayout = nil
                // Keep the verified source, input contract, schedule and values in the same transaction.
                surface = try plain.surface(title: title, state: state, request: currentRequest)
                Diagnostics.record("verified_reading_fallback", ["taskID": activeTaskID.uuidString])
            }
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            // Commit on the main actor after verification. Concurrent or retried
            // reads of the same record and metric can reveal the first finished card.
            if model.activeRequest?.owner == nil, requestShape != .dependent, requestIntent.placement?.layout != .together,
                requestedDelivery != .answer, let record = spec.readingIdentity(state),
                let i = model.sideTasks.firstIndex(where: { task in
                    task.id != activeTaskID && task.terminalLabel == nil
                        && task.taskSurface?.apiData?.readingIdentity(task.state) == record
                }) {
                let id = model.sideTasks[i].id
                model.sideTasks[i].hidden = false
                model.adoptRequestTask(.workspace(id))
                freshSourceLoaded = true
                taskSurfaceReady = true
                verifyEffect(spec.readingSummary(title: model.sideTasks[i].title, state: state))
                return ["verified": true, "task_id": id.uuidString, "retained": true]
            }
            retainedSnapshot = surface
            let previousRecord = retainedSurface.flatMap { old in old.apiData?.readingIdentity(old.state) }
            try model.commitTaskSurface(surface, id: activeTaskID, ticket: interfaceTicket)
            if let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID }) {
                if let previousRecord, let current = spec.readingIdentity(state), previousRecord != current {
                    // The conversation keeps its history; shelf matching describes
                    // the result that now occupies this card after replacement.
                    let metric = spec.displayRows.first { $0.key == spec.card?.primaryKey }?.label
                    model.sideTasks[i].intent = [title, metric].compactMap { $0 }.joined(separator: " · ")
                }
                model.sideTasks[i].dataUpdatedAt = sourceEvidence?.checked ?? Date()
                model.sideTasks[i].dataIssue = nil
                model.sideTasks[i].interfaceIssue = nil
                model.sideTasks[i].plan = nil
                model.sideTasks[i].sourceURL = try? spec.requestURL().absoluteString
            }
            RequestRun.current?.assignment?.methods.remember(spec)
            model.persistSideTasks()
            freshSourceLoaded = true
            taskSurfaceReady = true
            var summary = (surface.apiData ?? spec).readingSummary(title: title, state: surface.state)
            if omitted > 0 {
                Diagnostics.record("api_visuals_omitted", ["count": omitted])
                summary += "\n" + model.userText("读数已核实。部分图表的定义与数据列不匹配，已略过。", "Reading verified. Some visuals could not be matched to the data and were omitted.")
            }
            verifyEffect(summary)
            return ["verified": true, "task_id": activeTaskID.uuidString, "state": AgentContext.displayState(state, source: spec)]
        default: throw AppError.message("Unsupported data tool.")
        }
    }

}

extension APIDataSpec {
    /// Semantic keys come from source bindings rather than generated labels.
    func readingIdentity(_ state: [String: String]) -> [String]? {
        guard (controls ?? []).isEmpty, (visuals ?? []).isEmpty, let url = try? requestURL() else { return nil }
        if let pointer = primarySourcePointer {
            return [url.absoluteString, pointer, (outputs ?? []).first?.unit ?? "",
                (outputs ?? []).first?.unitKey.flatMap { state[$0] } ?? ""]
        }
        guard calculation == nil, let key = card?.primaryKey,
            let primary = fields.first(where: { $0.key == key && $0.itemPointer == nil }),
            let expectations, !expectations.isEmpty else { return nil }
        var result = [url.absoluteString, primary.pointer, primary.unit ?? "",
                      card?.unitKey.flatMap { state[$0] } ?? ""]
        var identity: [String] = []
        for key in expectations.keys {
            guard let pointer = fields.first(where: { $0.key == key })?.pointer, let value = state[key] else { return nil }
            identity.append(pointer + "=" + value)
        }
        result.append(contentsOf: identity.sorted())
        return result
    }
}
