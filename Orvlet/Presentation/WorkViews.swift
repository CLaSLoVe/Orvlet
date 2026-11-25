import Foundation

@MainActor
extension AppModel {
    func workSurface(_ artifact: WorkArtifact) throws -> TaskSurface {
        let design = work.design(artifact.id)
        if let native = artifact.native {
            return TaskSurface(title:artifact.title,markup:design?.markup ?? native.presentation,fields:[],actions:artifact.definition.actions,state:native.state)
        }
        if var spec = artifact.definition.apiData {
            spec.card = design?.card
            return try spec.surface(title: artifact.title, state: artifact.values, proposed: design?.markup)
        }
        let markup: CardMarkup
        if let saved = design?.markup { markup = saved }
        else {
            let rows = artifact.values.keys.sorted().prefix(6).map { TaskForm.Output(key: $0, label: $0) }
            guard let first = rows.first else { throw AppError.message("This result has no displayable values yet.") }
            markup = try TaskForm(inputs: [], outputs: rows, buttons: [], compactSubject: artifact.title, compactKey: first.key).markup()
        }
        return TaskSurface(title: artifact.title, markup: markup, fields: artifact.definition.fields,
                           actions: artifact.definition.actions, state: artifact.values,
                           runtime: artifact.definition.runtime, preset: design?.preset)
    }

    func surfaceForView(_ view: WorkView) throws -> TaskSurface {
        guard let selected = work.artifact(view.selected) else { throw AppError.message("This result is unavailable.") }
        if view.layout == .together {
            var state: [String: String] = [:]
            var rows: [TaskForm.Output] = []
            for (index, id) in view.artifacts.enumerated() {
                guard let artifact = work.artifact(id) else { continue }
                let surface = try workSurface(artifact)
                let key = work.design(id)?.card?.primaryKey
                    ?? CardMarkup.bindingKeys(in: surface.markup.compactHTML).sorted().first(where: { artifact.values[$0] != nil })
                guard let key, let value = artifact.values[key] else { throw AppError.message("Choose a result with a primary reading.") }
                let spec = surface.apiData
                let unit = spec?.displayRows.first(where: { $0.key == key }).flatMap { row in
                    row.unitKey.flatMap { artifact.values[$0] } ?? row.unit
                } ?? ""
                let field = "reading" + String(index)
                state[field] = value + (unit.isEmpty || value.hasSuffix(unit) ? "" : " " + unit)
                rows.append(.init(key: field, label: artifact.title))
            }
            guard let first = rows.first else { throw AppError.message("No results to display.") }
            let form = TaskForm(inputs: [], outputs: rows, buttons: [], compactSubject: first.label, compactKey: first.key)
            var markup = try form.markup()
            if let height = view.height { markup.height = height }
            return TaskSurface(title: view.title, markup: markup, fields: [], actions: [], state: state)
        }
        var surface = try workSurface(selected)
        if let markup = view.markup { surface.markup = markup }
        if view.layout == .select {
            let labels = Dictionary(uniqueKeysWithValues: view.artifacts.compactMap { id in work.artifact(id).map { (id.uuidString, $0.title) } })
            let picker = TaskForm(inputs: [.init(key: "workSelection", label: settings.preferredInterfaceLanguage.caseInsensitiveCompare("English") == .orderedSame ? "Item" : userText("对象", "Item"), kind: "select",
                optionLabels: labels, options: view.artifacts.map(\.uuidString))],
                outputs: [.init(key: "selectionLabel", label: "")], buttons: [], compactKey: "selectionLabel")
            let control = try picker.markup().html
            if let start = control.range(of: "<div class='calm-fields'>"), let end = control.range(of: "</div>", range: start.upperBound..<control.endIndex) {
                let fields = String(control[start.lowerBound..<end.upperBound])
                    .replacingOccurrences(of: "data-field='workSelection'", with: "data-field='workSelection' data-change='selectWorkResult'")
                if !surface.markup.html.contains("data-field='workSelection'") && !surface.markup.html.contains("data-field=\"workSelection\"") {
                    surface.markup.html = fields + surface.markup.html
                }
            }
            surface.fields.append("workSelection")
            surface.state["workSelection"] = selected.id.uuidString
            surface.actions.append(.init(id: "selectWorkResult", kind: .view, operation: "select"))
        }
        if let draft = view.draftInputs {
            if let spec = surface.apiData {
                for key in spec.keys where key != spec.card?.displayNameKey && !surface.fields.contains(key) { surface.state[key] = "—" }
            }
            surface.state.merge(draft) { _, new in new }
            surface.state["resultStatus"] = view.inputIssue ?? userText("正在更新…", "Updating…")
        }
        if let height = view.height { surface.markup.height = height }
        return surface
    }

    /// Projection only: no cancelling jobs, adopting a browser, or restarting runtime.
    func projectWorkView(_ id: UUID) throws {
        guard let view = work.view(id), let artifact = work.artifact(view.selected) else { return }
        if view.closed == true {
            // The compatibility executor may still need its native resource;
            // it is not a Tasks entry and must never become visible on refresh.
            if artifact.native?.id == id, let index = sideTasks.firstIndex(where: { $0.id == id }) {
                sideTasks[index].hidden = true
            } else { sideTasks.removeAll { $0.id == id } }
            return
        }
        if var native = artifact.native, view.layout == .single {
            native.id = id
            native.hidden = view.hidden
            native.artifactIDs = view.artifacts
            native.markup = view.markup ?? work.design(artifact.id)?.markup
            if let height = view.height {
                native.intrinsicCardHeight = height
                if native.markup != nil { native.markup?.height = height }
            }
            if let index = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[index] = native }
            else { sideTasks.append(native) }
            return
        }
        let surface = try surfaceForView(view).validated()
        var task = sideTasks.first { $0.id == id } ?? SideTask(id: id, kind: .workspace, title: view.title)
        task.kind = .workspace
        task.title = view.layout == .single ? artifact.title : view.title
        task.taskSurface = surface
        task.artifactIDs = view.artifacts
        if task.intent == nil { task.intent = artifact.goalID.flatMap { work.snapshot.goals[$0]?.request } }
        task.markup = surface.markup
        task.liveValues = surface.state
        task.status = artifact.status
        task.dataIssue = artifact.issue
        if view.inputIssue != nil { task.status = "Input needed"; task.dataIssue = nil }
        task.dataUpdatedAt = artifact.checked
        task.workFile = artifact.file
        task.sourceURL = artifact.source
        task.runtimeState = artifact.runtimeState
        task.hidden = view.hidden
        task.generated = true
        task.interfaceIssue = nil
        if let i = sideTasks.firstIndex(where: { $0.id == id }) { sideTasks[i] = task }
        else { sideTasks.append(task) }
    }
    func projectWorkResult(_ id: UUID) {
        for view in work.snapshot.views.values where view.artifacts.contains(id) {
            do {
                try projectWorkView(view.id)
                resolveTaskIssue(view.id, source: .interface)
            }
            catch {
                if let i = sideTasks.firstIndex(where: { $0.id == view.id }) {
                    sideTasks[i].interfaceIssue = userText("结果已保存，界面需要更新。", "Result saved; view needs updating.")
                }
                reportTaskIssue(view.id, source: .interface, detail: error.localizedDescription)
            }
        }
    }

    @discardableResult
    func presentWork(_ ids: [UUID], layout: WorkView.Layout, title: String, destination: UUID? = nil) throws -> [UUID] {
        guard !ids.isEmpty, ids.count <= 6, Set(ids).count == ids.count,
            ids.allSatisfy({ work.artifact($0) != nil }) else { throw AppError.message("Select one to six retained results.") }
        // Grouping one result must preserve its controls, not turn a working
        // tool into a passive summary of itself.
        let layout: WorkView.Layout = ids.count == 1 ? .single : layout
        let groups = layout == .single ? ids.map { [$0] } : [ids]
        var views: [WorkView] = []
        for (index, group) in groups.enumerated() {
            let existing = work.snapshot.views.values.first { $0.layout == layout && $0.artifacts == group }
            let id = (index == 0 ? destination : nil) ?? existing?.id ?? UUID()
            let artifact = work.artifact(group[0])!
            let view = WorkView(id: id, artifacts: group, selected: existing?.selected ?? group[0], layout: layout,
                title: layout == .single ? artifact.title : title, markup: existing?.markup, height:existing?.height)
            if !(layout == .single && artifact.native != nil) {
                _ = try surfaceForView(view).validated() // Validate all views before publishing any.
            }
            views.append(view)
        }
        for view in views { try work.putView(view); try projectWorkView(view.id) }
        if let placeholder = requestCardID, !views.contains(where: { $0.id == placeholder }) {
            sideTasks.removeAll { $0.id == placeholder && $0.kind == .result }
        }
        if let id = views.first?.id {
            adoptRequestTask(.workspace(id))
            selectedTaskID = selectedTaskID ?? id
        }
        RequestRun.current?.markPresented(ids)
        RequestRun.current?.publishedViewIDs.formUnion(views.map(\.id))
        persistSideTasks()
        reconcileTasks()
        onShow?()
        return views.map(\.id)
    }

    /// Both a rendered control and an agent request invoke this exact operation.
    @discardableResult
    func performWorkAction(viewID: UUID, action: String, fields: [String: String]) -> Task<Void, Never>? {
        guard var view = work.view(viewID), let artifact = work.artifact(view.selected) else { return nil }
        if action == "selectWorkResult" {
            guard let selected = fields["workSelection"].flatMap(UUID.init(uuidString:)), view.artifacts.contains(selected) else { return nil }
            view.selected = selected
            view.draftInputs = nil
            view.inputIssue = nil
            try? work.putView(view)
            try? projectWorkView(viewID)
            persistSideTasks()
            return nil
        }
        let input = (view.draftInputs ?? [:]).merging(fields) { _, new in new }.filter { $0.key != "workSelection" }
        if let spec = artifact.definition.apiData, !input.isEmpty {
            let proposed = (spec.inputs ?? [:]).merging(input) { _, new in new }
            let invalid = spec.inputControls.first { control in
                let value = proposed[control.key] ?? ""
                return value.isEmpty || (control.kind == "select" && !control.accepts(value))
                    || (control.kind == "number" && Double(value)?.isFinite != true)
            }
            view.draftInputs = input
            view.inputIssue = invalid.map { userText("请输入", "Enter ") + $0.label }
            try? work.putView(view)
            try? projectWorkView(viewID)
            if invalid != nil {
                workJobTokens[artifact.id] = nil
                workJobs.removeValue(forKey:artifact.id)?.cancel()
                return nil
            }
        }
        if action == "configureClock", artifact.definition.runtime != nil {
            configureClock(viewID, fields: input)
            return nil
        }
        return performWorkOperation(artifact.id, action: action, fields: input)
    }

    @discardableResult
    func performWorkOperation(_ id: UUID, action: String, fields: [String: String]) -> Task<Void, Never>? {
        guard let original = work.artifact(id),
            let operation = original.definition.actions.first(where: { $0.id == action }),
            Set(fields.keys).isSubset(of: Set(original.definition.fields)),
            fields.values.allSatisfy({ $0.utf8.count <= 8000 }) else { return nil }
        if let native = original.native {
            if !sideTasks.contains(where: { $0.id == native.id }) {
                var resource = native; resource.hidden = true; sideTasks.append(resource)
            }
            if native.kind == .timer {
                timerAction(native.id,action:operation.operation ?? action)
                return Task { }
            }
            if native.isMediaTask {
                controlMedia(native.id,operation:operation.operation ?? action)
            }
            return nil // Media verification still uses the owned player's receipt.
        }
        if operation.kind == .resource, operation.operation == "stop" {
            workJobTokens[id] = nil
            workJobs.removeValue(forKey:id)?.cancel()
            if original.definition.runtime != nil {
                taskRuntime.control(id, operation: "stop")
            } else if work.update(id,expecting:original.revision,{ $0.status = "Stopped" }) {
                projectWorkResult(id)
                persistSideTasks()
            }
            return Task { }
        }
        if operation.kind == .openRecord, let raw = operation.operation, let url = try? PublicDataClient.url(raw) {
            openHandoff(url, taskID: work.snapshot.views.values.first { $0.artifacts.contains(id) }?.id ?? id)
            return nil
        }
        if operation.kind == .agent {
            startCommand((operation.prompt ?? "Continue") + "\nResult context: " + JSONText.encode(original.values.merging(fields) { _, new in new }))
            return nil
        }
        if operation.kind == .runtime {
            if operation.operation == "configureClock" { configureClock(id, fields: fields) }
            else { taskRuntime.control(id, operation: operation.operation ?? "toggle") }
            return Task { }
        }
        workJobs.removeValue(forKey: id)?.cancel()
        guard work.update(id, expecting: original.revision, { $0.status = "Updating…"; $0.issue = nil }), let pending = work.artifact(id) else { return nil }
        projectWorkResult(id)
        let token = UUID()
        workJobTokens[id] = token
        let job = Task { [weak self] in
            guard let self else { return }
            defer {
                if workJobTokens[id] == token {
                    workJobTokens[id] = nil
                    workJobs[id] = nil
                    scheduleDataRefresh()
                }
            }
            do {
                var definition = pending.definition
                let values: [String: String]
                var evidence = pending.evidence
                var checked = Date()
                if var spec = definition.apiData {
                    spec.card = work.design(id)?.card
                    spec = spec.updatingInputs(fields)
                    if operation.operation == "swap", let roles = spec.currencyFields {
                        let from = spec.inputs?[roles.from]
                        let to = spec.inputs?[roles.to]
                        spec.inputs?[roles.from] = to
                        spec.inputs?[roles.to] = from
                    }
                    guard spec.inputControls.allSatisfy({ control in
                        guard let value = spec.inputs?[control.key], !value.isEmpty else { return false }
                        return control.kind == "select" ? control.accepts(value) : control.kind != "number" || Double(value)?.isFinite == true
                    }) else { throw AppError.message("Check the entered values.") }
                    let cached = operation.operation == "update" && apiData.canReuse(spec, state: pending.values, fetchedAt: pending.checked)
                    if cached {
                        values = try await apiData.calculate(spec,state:pending.values)
                        checked = pending.checked
                    }
                    else {
                        let reading = try await apiData.acquire(spec) { sample in
                            checked = sample.checked
                            evidence = try? JSONSerialization.data(withJSONObject:sample.response,options:.fragmentsAllowed)
                        }
                        values = reading.state
                    }
                    spec.card = nil
                    definition.apiData = spec
                } else if let code = operation.code, operation.kind == .code {
                    let input = pending.values.filter { definition.fields.contains($0.key) }.merging(fields) { _, new in new }
                    let updates = try TaskValues.decode(try await taskCode.run(code: code, input: input, state: pending.values, declaredInputs: definition.fields))
                    values = pending.values.merging(input) { _, new in new }.merging(updates) { _, new in new }
                } else { throw AppError.message("This operation is unavailable.") }
                try Task.checkCancellation()
                if work.update(id, expecting: pending.revision, { $0.values = values; $0.definition = definition; $0.evidence = evidence; $0.source = try? definition.apiData?.requestURL().absoluteString; $0.status = "Ready"; $0.checked = checked; $0.issue = nil }) {
                    projectWorkResult(id)
                    resolveTaskIssue(id, source: .data)
                }
            } catch is CancellationError {} catch {
                if work.update(id, expecting: pending.revision, { $0.status = "Update unavailable"; $0.issue = error.localizedDescription }) {
                    projectWorkResult(id)
                    reportTaskIssue(id, source: .data, detail: error.localizedDescription)
                }
            }
            persistSideTasks()
        }
        workJobs[id] = job
        return job
    }
}
