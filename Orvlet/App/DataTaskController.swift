import Foundation

@MainActor
extension AppModel {
    /// Upgrade only a recognized host template. Bespoke and deliberately edited designs keep ownership.
    func upgradeStandardCard(_ id: UUID) {
        guard let i = sideTasks.firstIndex(where: { $0.id == id }), var old = sideTasks[i].taskSurface,
            taskActionJobs[id] == nil, !(busy && ownsRequest(id))
        else { return }
        if let spec = old.apiData, spec.customLayout != true {
            let legacy = old.markup.css == APIDataSpec.genericDataCSS && old.markup.html.contains("class='data-result'")
            guard old.preset != nil || legacy, spec.resolvedCard != nil,
                let updated = try? spec.surface(title: old.title, state: sideTasks[i].state)
            else { return }
            guard !old.markup.hasSameDesign(as: updated.markup) else { return }
            old = updated
        } else if old.preset == "clock", old.runtime != nil {
            let updated = old.withClockControls
            guard !old.markup.hasSameDesign(as: updated.markup) else { return }
            old = updated
        } else {
            return
        }
        let needsFreshFields = old.apiData?.fields.contains { sideTasks[i].liveValues?[$0.key] == nil } == true
        sideTasks[i].liveValues = old.state.merging(sideTasks[i].liveValues ?? [:]) { _, live in live }
        sideTasks[i].taskSurface = old
        sideTasks[i].markup = old.markup
        sideTasks[i].title = old.title
        interfaceMemory.remember(sideTasks[i], purpose: sideTasks[i].intent ?? sideTasks[i].title)
        persistSideTasks()
        if needsFreshFields { refreshAPIData(id, force: true) }
    }
    func refreshAPIData(_ id: UUID, fields: [String: String] = [:], force: Bool = true) {
        guard let task = sideTasks.first(where: { $0.id == id }), var spec = task.taskSurface?.apiData else { return }
        if busy && ownsRequest(id) { return }
        guard Set(fields.keys).isSubset(of: Set((spec.inputs ?? [:]).keys)) else { return }
        if spec.isWttrWeather {
            if let day = fields["weatherDay"], day != spec.inputs?["weatherDay"], let key = spec.weatherDateKey {
                spec.expectations?[key] = nil
            }
            if let place = fields["weatherLocation"], place != spec.inputs?["weatherLocation"] {
                // A deliberate location edit supersedes the original request's geographic constraints.
                // Display the returned nearest city instead of relabelling old readings with the typed name.
                for field in spec.fields where field.pointer.contains("/nearest_area/") {
                    spec.expectations?[field.key] = nil
                }
            }
        }
        spec.inputs = (spec.inputs ?? [:]).merging(fields) { _, new in new }
        let previous = task.liveValues ?? task.taskSurface?.state ?? [:]
        let inputs = spec.inputs ?? [:]
        taskActionJobs.removeValue(forKey: id)?.cancel()
        let ticket = beginTaskRevision(id, .execution)
        guard let index = sideTasks.firstIndex(where: { $0.id == id }) else { return }
        sideTasks[index].taskSurface?.apiData = spec
        sideTasks[index].liveValues = previous.merging(inputs) { _, new in new }
        let invalid = spec.inputControls.first { control in
            let value = inputs[control.key] ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (control.kind == "number" && !(Double(value)?.isFinite ?? false))
                || (control.kind == "select" && !(control.options ?? []).contains(value))
        }
        if let invalid {
            for output in spec.outputs ?? [] { sideTasks[index].liveValues?[output.key] = "—" }
            sideTasks[index].liveValues?["resultStatus"] = "Enter " + invalid.label.lowercased()
            sideTasks[index].taskSurface?.state = sideTasks[index].liveValues ?? [:]
            sideTasks[index].dataIssue = nil
            sideTasks[index].status = "Input needed"
            taskRevisions.finish(ticket)
            persistSideTasks()
            return
        }
        let cached = !force && apiData.canReuse(spec, state: previous, fetchedAt: task.dataUpdatedAt)
        sideTasks[index].status = cached ? "Calculating…" : "Updating…"
        sideTasks[index].liveValues?["resultStatus"] = cached ? "" : "Updating…"
        taskActionJobs[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if accepts(ticket) {
                    taskActionJobs[id] = nil
                    taskRevisions.finish(ticket)
                }
            }
            do {
                var values: [String: String]
                if cached {
                    values = try await apiData.calculate(spec, state: previous)
                } else {
                    values = try await apiData.read(spec)
                }
                values["resultStatus"] = ""
                try Task.checkCancellation()
                guard accepts(ticket), let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
                sideTasks[i].liveValues = values
                sideTasks[i].taskSurface?.state = values
                if !cached { sideTasks[i].dataUpdatedAt = Date() }
                sideTasks[i].dataIssue = nil
                sideTasks[i].status = "Ready"
                persistSideTasks()
            } catch is CancellationError {} catch {
                guard accepts(ticket), let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
                if cached {
                    for output in spec.outputs ?? [] { sideTasks[i].liveValues?[output.key] = "—" }
                    sideTasks[i].liveValues?["resultStatus"] = "Check the entered values."
                    sideTasks[i].dataIssue = nil
                    sideTasks[i].status = "Input needed"
                } else {
                    sideTasks[i].liveValues?["resultStatus"] = "Previous result"
                    sideTasks[i].dataIssue = "Couldn’t update the source. Showing the last checked result."
                    sideTasks[i].status = "Update unavailable"
                }
                sideTasks[i].taskSurface?.state = sideTasks[i].liveValues ?? [:]
                persistSideTasks()
            }
        }
    }
}
