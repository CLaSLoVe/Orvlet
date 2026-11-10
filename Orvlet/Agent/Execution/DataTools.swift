import Foundation
import WebKit

@MainActor
extension AgentController {
    func executeDataTool(_ name: String, _ input: [String: Any], revision: Int) async throws -> [String: Any] {
        switch name {
        case "inspect_api":
            guard let url = input["url"] as? String else { throw AppError.message("Provide a public JSON API URL.") }
            let json = try await PublicDataClient().fetch(url)
            guard try JSONSerialization.data(withJSONObject: json).count <= 32768 else {
                throw AppError.message(
                    "This API response is too large to inspect. Narrow the query or use documented fields with query_api."
                )
            }
            return ["source": url, "retrievedAt": ISO8601DateFormatter().string(from: Date()), "data": json]
        case "query_api":
            guard nativeRequestActive, ![.live, .advancing].contains(requestIntent.behavior),
                let title = input["title"] as? String, !title.isEmpty,
                let object = input["source"] as? [String: Any]
            else {
                throw AppError.message(
                    "Use query_api for a snapshot with a title and source recipe. Continuous monitoring requires a scheduled source."
                )
            }
            var spec: APIDataSpec
            do {
                spec = try JSONDecoder().decode(APIDataSpec.self, from: JSONSerialization.data(withJSONObject: object))
                    .validated()
            } catch {
                // No transport or side effect has run: repair a recipe contract, not an external failure.
                throw ToolArgumentError.decoding(error) ?? (error as? ToolArgumentError)
                    ?? ToolArgumentError(path: "$.source", issue: error.localizedDescription)
            }
            if Diagnostics.file != nil { Diagnostics.record("api_recipe", ["source": object]) }
            let retainedSurface = model.sideTasks.first(where: {
                $0.id == activeTaskID && $0.taskSurface?.apiData != nil
            })?.taskSurface
            if retainedSurface?.apiData?.customLayout == true { spec.customLayout = true }
            let reading = try await model.apiData.acquire(spec)
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
            let retained = retainedSurface?.markup
            let surface = try spec.surface(title: title, state: state, proposed: markup ?? retained)
            try Task.checkCancellation()
            guard revision == steeringRevision else { return ["superseded": true] }
            try model.commitTaskSurface(surface, id: activeTaskID, ticket: interfaceTicket)
            if let i = model.sideTasks.firstIndex(where: { $0.id == activeTaskID }) {
                model.sideTasks[i].dataUpdatedAt = Date()
                model.sideTasks[i].dataIssue = nil
                model.sideTasks[i].interfaceIssue = nil
                model.sideTasks[i].plan = nil
                model.sideTasks[i].sourceURL = try? spec.requestURL().absoluteString
            }
            model.persistSideTasks()
            freshSourceLoaded = true
            taskSurfaceReady = true
            let primary = spec.card?.primaryKey ?? spec.outputs?.last?.key ?? spec.fields.last!.key
            let output = spec.outputs?.first { $0.key == primary }
            let field = spec.fields.first { $0.key == primary }
            let unit =
                (spec.card?.unitKey ?? output?.unitKey).flatMap { state[$0] } ?? output?.unit ?? field?.unit ?? ""
            let label = spec.card?.kind == .weather ? (output?.label ?? field?.label ?? "Temperature") + " " : ""
            let date = state["sourceDate"] ?? ""
            verifyEffect(
                title + ": " + label + (state[primary] ?? "") + (unit.isEmpty ? "" : " " + unit)
                    + (date.isEmpty ? "" : ". " + date) + ".")

            return ["verified": true, "task_id": activeTaskID.uuidString, "state": state]
        default: throw AppError.message("Unsupported data tool.")
        }
    }

}
