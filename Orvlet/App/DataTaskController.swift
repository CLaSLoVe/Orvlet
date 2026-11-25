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
            guard old.preset != nil || legacy,
                let updated = try? spec.surface(title: old.title, state: sideTasks[i].state, request: sideTasks[i].intent ?? "")
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
    /// A single deadline follows retained tasks independently of window focus and visibility.
    func scheduleDataRefresh() {
        dataRefreshTimer?.invalidate()
        dataRefreshTimer = nil
        let now = Date()
        let ids = Set(sideTasks.map(\.id)).union(work.snapshot.artifacts.keys)
        dataRefreshAttempts = dataRefreshAttempts.filter { ids.contains($0.key) }
        let workDeadlines = work.snapshot.artifacts.values.compactMap { artifact -> Date? in
            guard let interval = artifact.definition.apiData?.refreshSeconds, workJobs[artifact.id] == nil,
                artifact.status != "Stopped" else { return nil }
            return max(artifact.checked, dataRefreshAttempts[artifact.id] ?? .distantPast).addingTimeInterval(interval)
        }
        guard let next = (sideTasks.compactMap({ nextDataRefresh($0, now: now) }) + workDeadlines).min() else { return }
        let timer = Timer(timeInterval: max(0.1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDueData() }
        }
        dataRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func nextDataRefresh(_ task: SideTask, now: Date) -> Date? {
        guard work.view(task.id) == nil else { return nil }
        guard let interval = task.taskSurface?.apiData?.refreshSeconds, task.terminalLabel == nil,
            task.status != "Input needed", taskActionJobs[task.id] == nil else { return nil }
        let last = max(task.dataUpdatedAt ?? task.created, dataRefreshAttempts[task.id] ?? .distantPast)
        let due = last.addingTimeInterval(interval)
        return busy && ownsRequest(task.id) ? max(due, now.addingTimeInterval(2)) : due
    }

    private func refreshDueData() {
        let now = Date()
        for artifact in work.snapshot.artifacts.values {
            guard let interval = artifact.definition.apiData?.refreshSeconds, workJobs[artifact.id] == nil,
                artifact.status != "Stopped", max(artifact.checked, dataRefreshAttempts[artifact.id] ?? .distantPast).addingTimeInterval(interval) <= now,
                let action = artifact.definition.actions.first(where: { $0.operation == "refresh" }) else { continue }
            dataRefreshAttempts[artifact.id] = now
            performWorkOperation(artifact.id, action: action.id, fields: [:])
        }
        for task in sideTasks {
            if let due = nextDataRefresh(task, now: now), due <= now {
                refreshAPIData(task.id, scheduled: true)
            }
        }
        scheduleDataRefresh()
    }

    @discardableResult
    func performDataAction(_ id: UUID, action: TaskSurfaceAction, fields: [String: String], requestID: UUID? = nil) -> Task<Void, Never>? {
        guard let surface = sideTasks.first(where: { $0.id == id })?.taskSurface, let spec = surface.apiData,
            action.kind == .remote, let operation = action.operation,
            ["update", "refresh", "swap"].contains(operation),
            Set(fields.keys).isSubset(of: Set(surface.fields)), fields.values.allSatisfy({ $0.utf8.count <= 8000 })
        else { return nil }
        var inputs = fields
        if operation == "swap" {
            guard spec.supportsCurrencySwap, let roles = spec.currencyFields else { return nil }
            let current = (spec.inputs ?? [:]).merging(fields) { _, new in new }
            inputs[roles.from] = current[roles.to]
            inputs[roles.to] = current[roles.from]
        }
        return refreshAPIData(id, fields: inputs, force: operation != "update", requestID: requestID)
    }

    @discardableResult
    func refreshAPIData(_ id: UUID, fields: [String: String] = [:], force: Bool = true, scheduled: Bool = false,
                        requestID: UUID? = nil) -> Task<Void, Never>? {
        if let view = work.view(id), let artifact = work.artifact(view.selected),
            let operation = artifact.definition.actions.first(where: { $0.operation == (force ? "refresh" : "update") }) {
            if let requestID, activeRequest?.id != requestID { return nil }
            return performWorkAction(viewID: id, action: operation.id, fields: fields)
        }
        guard let task = sideTasks.first(where: { $0.id == id }), var spec = task.taskSurface?.apiData else { return nil }
        if let requestID {
            guard activeRequest?.id == requestID, activeRequest?.owner?.id == id else { return nil }
        } else if busy && ownsRequest(id) { return nil }
        guard Set(fields.keys).isSubset(of: Set((spec.inputs ?? [:]).keys)) else { return nil }
        spec = spec.updatingInputs(fields)
        dataRefreshAttempts[id] = Date()
        // Only a successful read/calculation updates the verified snapshot. The editable
        // live values can contain an invalid draft or belong to a superseded refresh.
        let previous = task.taskSurface?.state ?? task.liveValues ?? [:]
        let inputs = spec.inputs ?? [:]
        taskActionJobs.removeValue(forKey: id)?.cancel()
        let ticket = beginTaskRevision(id, .execution)
        guard let index = sideTasks.firstIndex(where: { $0.id == id }) else { return nil }
        sideTasks[index].taskSurface?.apiData = spec
        let changed = inputs.contains { previous[$0.key] != $0.value }
        var display = previous
        if changed {
            // Keep the last verified identity recognizable while new values are
            // pending. Commit the new identity and its result together below.
            for key in spec.keys where key != spec.card?.displayNameKey { display[key] = "—" }
            for key in ["sourceDate", "sourceDateDisplay", "sourceChecked", "weatherSampleTime"] { display[key] = "" }
        }
        sideTasks[index].liveValues = display.merging(inputs) { _, new in new }
        let invalid = spec.inputControls.first { control in
            let value = inputs[control.key] ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (control.kind == "number" && !(Double(value)?.isFinite ?? false))
                || (control.kind == "select" && !control.accepts(value))
        }
        if let invalid {
            for output in spec.outputs ?? [] { sideTasks[index].liveValues?[output.key] = "—" }
            sideTasks[index].liveValues?["resultStatus"] = "Enter " + invalid.label.lowercased()
            sideTasks[index].dataIssue = nil
            sideTasks[index].status = "Input needed"
            taskRevisions.finish(ticket)
            persistSideTasks()
            return nil
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
                    scheduleDataRefresh()
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
                if let subject = spec.choiceSubject(values), subject != spec.choiceSubject(previous) {
                    let label = spec.displayRows.first(where: { $0.key == spec.card?.primaryKey })?.label
                    let title = [subject, label].compactMap { $0 }.joined(separator: " · ")
                    sideTasks[i].title = title
                    sideTasks[i].taskSurface?.title = title
                }
                sideTasks[i].liveValues = values
                sideTasks[i].taskSurface?.state = values
                if !cached {
                    sideTasks[i].dataUpdatedAt = Date()
                    Diagnostics.record("api_data_refresh", ["taskID": id.uuidString, "origin": scheduled ? "scheduled" : "interaction", "verified": true])
                }
                sideTasks[i].dataIssue = nil
                sideTasks[i].status = "Ready"
                resolveTaskIssue(id, source: .data)
                persistSideTasks()
            } catch is CancellationError {} catch {
                guard accepts(ticket), let i = sideTasks.firstIndex(where: { $0.id == id }) else { return }
                reportTaskIssue(id, source: .data, detail: error.localizedDescription)
                if cached {
                    for output in spec.outputs ?? [] { sideTasks[i].liveValues?[output.key] = "—" }
                    sideTasks[i].liveValues?["resultStatus"] = "Check the entered values."
                    sideTasks[i].dataIssue = nil
                    sideTasks[i].status = "Input needed"
                } else {
                    sideTasks[i].liveValues?["resultStatus"] = changed ? "Update unavailable" : "Previous result"
                    sideTasks[i].dataIssue = changed ? "Couldn’t verify the new inputs." : "Couldn’t update the source. Showing the last checked result."
                    sideTasks[i].status = "Update unavailable"
                }
                persistSideTasks()
            }
        }
        return taskActionJobs[id]
    }
}
