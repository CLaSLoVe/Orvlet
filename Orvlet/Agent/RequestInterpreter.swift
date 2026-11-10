import Foundation

@MainActor
extension AgentController {
    func understand(
        _ text: String, clarification: String?, key: String?, globalRouting: Bool = false, allowFast: Bool = true
    ) async throws
        -> RequestIntent
    {
        let request = Task { @MainActor in
            try await self.interpret(
                text, clarification: clarification, key: key, globalRouting: globalRouting, allowFast: allowFast)
        }
        interpretationTask = request
        defer { interpretationTask = nil }
        return try await withTaskCancellationHandler(
            operation: { try await request.value }, onCancel: { request.cancel() })
    }

    private func interpret(_ text: String, clarification: String?, key: String?, globalRouting: Bool, allowFast: Bool)
        async throws -> RequestIntent
    {
        let explicit = globalRouting ? nil : model.activeRequest?.submittedTaskID
        var prepared = preparedRequest
        preparedRequest = nil
        if prepared?.usable(text: text, explicit: explicit, model: model) != true { prepared = nil }
        if !allowFast { prepared = nil }
        if prepared == nil, allowFast {
            prepared = await model.prepareFastRequest(
                text, explicit: explicit, excluding: globalRouting ? nil : model.requestCardID)
        }
        try Task.checkCancellation()
        let triage = model.settings.useFast ? prepared?.triage : nil
        thinkingBudget = triage?.budget ?? .standard
        // Carry the same capability through global routing and execution, including
        // prepared interpretations that return before another model call.
        requestCapability = triage?.capability ?? .general
        let availableTasks = JevRequestTriage.candidates(
            model, explicit: nil, excluding: globalRouting ? nil : model.requestCardID)
        if clarification == nil,
            let intent = prepared?.intent
                ?? (triage?.resolvesRouting(hasCandidates: !availableTasks.isEmpty) == true
                    ? triage?.directIntent() : nil)
        {
            return try intent.validated(for: text)
        }
        #if DEBUG
            if let interpretationOverride { return try await interpretationOverride(text) }
            // Tests that exercise browser execution can inject their own decision loop
            // without contacting a provider. Native tests inject an interpretation too.
            if completionOverride != nil { return RequestIntent(kind: .information) }
        #endif
        let resolvedKey: String
        if let key { resolvedKey = key } else { resolvedKey = try await model.loadModelKey(for: requestConnection) }
        let endpoint = requestEndpoint ?? model.settings.main
        let routingAdvice = triage
        let capability = requestCapability
        let owner = globalRouting ? nil : model.activeRequest?.submittedTaskID
        let routeKnown = owner != nil || routingAdvice?.resolvesRouting(hasCandidates: !availableTasks.isEmpty) == true
        let resolved = owner ?? (routeKnown ? routingAdvice?.target : nil)
        let targetTask = resolved.flatMap { id in
            (model.sideTasks + model.archivedTaskHistory).first { $0.id == id }
        }
        let methods =
            (capability.tools.contains("reuse_saved_ui") || targetTask?.taskSurface != nil
                || availableTasks.contains { $0.id == routingAdvice?.target && $0.taskSurface != nil })
            ? model.interfaceMemory.planningCatalogue(preferredID: targetTask?.interfaceRecipeID ?? targetTask?.id) : []
        let routingTasks =
            routeKnown
            ? []
            : model.routingContext(
                explicit: nil, excluding: globalRouting ? nil : model.requestCardID)
        let taskIDs =
            routingTasks.filter { $0["availability"] as? String == "available" }.compactMap { $0["id"] as? String }
        let archivedIDs = routingTasks.filter { $0["availability"] as? String != "available" }
            .compactMap { $0["id"] as? String }
        let prompt =
            AgentPrompts.interpretation(resolvedTask: routeKnown) + "\n" + AgentPrompts.planning
            + "\nOther capabilities (full schema available during execution): "
            + JSONText.encode(RequestPlanning.discovery(capability))

        var reuseSchema = (RequestPlanning.reuseTool["function"] as! [String: Any])["parameters"] as! [String: Any]
        reuseSchema["type"] = ["object", "null"]
        var reuseProperties = reuseSchema["properties"] as! [String: [String: Any]]
        reuseProperties["id"]?["enum"] = methods.compactMap { $0["id"] as? String }
        reuseSchema["properties"] = reuseProperties
        reuseSchema["description"] =
            "Select a catalogue method with fresh inputs when it covers the request. Null only when no method fits, inputs need clarification, or the user changes the method. Changed input values alone are reuse."
        if methods.isEmpty { reuseSchema = ["type": "null"] }
        let schema = RequestPlanning.compactSchema(
            ToolSchema.function(
                "interpret_request", "Describe the human's intended outcome and missing details.",
                [
                    "kind": ["type": "string", "enum": ["general", "information", "calendar", "timer"]],
                    "mediaSetting": [
                        "type": "string", "enum": ["none", "loop", "unloop"],
                        "description":
                            "Current-track looping on/off. This changes a setting, not playback position or source.",
                    ],
                    "requiresFreshData": [
                        "type": "boolean",
                        "description":
                            "True for current external facts such as rates, prices, weather or availability. False for playback and local clocks/calculations.",
                    ],
                    "taskAction": ["type": "string", "enum": ["perform", "cancel", "complete"]],
                    "summary": [
                        "type": ["string", "null"],
                        "description":
                            "One brief English UI status sentence describing the intended action. No hidden reasoning or success claims.",
                    ],
                    "missingFields": [
                        "type": "array",
                        "items": [
                            "type": "string",
                            "enum": ["title", "date", "start", "end", "timeZone", "calendar", "dateConflict"],
                        ],
                    ],
                    "continuesClarification": ["type": "boolean"],
                    "needsBrowserContext": [
                        "type": "boolean",
                        "description":
                            "Read an already resolved task's existing page. False for finding or opening a new source.",
                    ],
                    "playbackIntent": [
                        "type": ["string", "null"], "enum": ["none", "play", "pause", NSNull()],
                        "description": "Media playback only. Local task controls use control_task.",
                    ],
                    "targetTaskID": [
                        "type": ["string", "null"],
                        "description":
                            "Choose a compatible existing task under the ownership rules, using its continuationTargetID unless another instance is identified. Null for a different function, separately retained outcome, or no supported match. Changed content alone keeps the task; technical compatibility alone does not establish ownership.",
                        "enum": taskIDs.map { $0 as Any } + [NSNull()],
                    ],
                    "restoreTaskID": [
                        "type": ["string", "null"],
                        "description":
                            "Only for an explicit request to reopen/restore a particular archived task. A matching old title is NOT a restoration request. Normally null. Mutually exclusive with targetTaskID; ordinary new content belongs to an available activity.",
                        "enum": archivedIDs.map { $0 as Any } + [NSNull()],
                    ],
                    "requirements": ["type": "array", "items": OutcomeRequirement.schema],
                    "initialURL": ["type": ["string", "null"]],
                    "reuse": reuseSchema,
                    "goals": [
                        "type": "array", "minItems": 1, "maxItems": 6, "items": ["type": "string"],
                        "description":
                            "All independent user-requested outcomes, not implementation steps. A simple task has one goal. Host verified effects complete goals; discovery is not an extra goal.",
                    ],
                    "steps": RequestStep.schema(actions: RequestPlanning.actions(capability)),
                    "stepsComplete": [
                        "type": "boolean",
                        "description":
                            "True only if these actions fulfill the ENTIRE request without needing their results for further decisions. False for partial plans or discovery.",
                    ],
                    "contextDetail": ["type": "string", "enum": ["state", "page", "definition"]],
                    "answer": [
                        "type": "string",
                        "description":
                            "Direct answer only for information requests needing no fresh external facts or task changes.",
                    ],
                    "route": [
                        "type": "string", "enum": ["auto", "local", "web", "api"],
                        "description":
                            "local: computation/host time; api: structured external facts; web: requested webpage/media interaction; auto: unclear. A clarification does not lock the eventual route.",
                    ],
                    "updateIntervalSeconds": [
                        "type": ["number", "null"],
                        "description":
                            "Explicit periodic update interval for a local scheduled computation; null if none.",
                    ],
                    "behavior": [
                        "type": "string", "enum": ["snapshot", "live", "advancing", "interactive"],
                        "description":
                            "snapshot: one fresh result; interactive: editable inputs; live: explicitly requested ongoing updates; advancing: continuous clock/progress. Current/latest data alone is snapshot.",
                    ],
                    "timeZones": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Requested clock zones as IANA IDs; local clock uses the user timezone.",
                    ],
                    "clarificationQuestion": [
                        "type": ["string", "null"],
                        "description":
                            "Ask only when missing user information prevents a useful action. Source discovery and internal card/task creation are implementation choices, not missing user information.",
                    ],
                    "presentationOnly": [
                        "type": "boolean",
                        "description":
                            "Only layout, typography, size or color changes. False for any change to facts, source, location, task logic or playback.",
                    ],
                    "timerSeconds": [
                        "type": ["number", "null"],
                        "description": "Explicitly requested countdown duration in seconds, otherwise null",
                    ],
                    "timerEvidence": [
                        "type": ["string", "null"],
                        "description": "Exact quote of the requested countdown duration, otherwise null",
                    ],
                ],
                required: [
                    "kind", "route", "behavior", "taskAction", "requiresFreshData", "targetTaskID", "requirements",
                    "reuse",
                    "goals", "steps", "stepsComplete",
                ]), capability: capability, resolved: routeKnown, hasMethods: !methods.isEmpty)
        var turns: [[String: Any]] = [["role": "system", "content": prompt]]
        if let clarification {
            turns.append(["role": "user", "content": "Previous request awaiting clarification: " + clarification])
        }
        turns.append([
            "role": "user",
            "content": "Request context: "
                + JSONText.encode([
                    "routeResolved": routeKnown, "resolvedTaskID": resolved?.uuidString ?? "",
                    "suggestedTaskID": routeKnown ? "" : routingAdvice?.target?.uuidString ?? "",
                    "instanceAdvice": routingAdvice?.additionalInstance == true ? "additional" : "unspecified",
                    "tasks": routingTasks.filter { $0["availability"] as? String == "available" },
                    "history": routingTasks.filter { $0["availability"] as? String != "available" }.map { task in
                        task.filter { ["id", "title", "activity", "intent"].contains($0.key) }
                    },
                    "methods": methods,
                    "time": ISO8601DateFormatter().string(from: Date()), "timeZone": TimeZone.current.identifier,
                ]),
        ])
        if let targetTask {
            let conversation = model.taskInterpretationContext(targetTask.id, excluding: text)
            if !conversation.isEmpty {
                turns.append([
                    "role": "user", "content": "Recent task conversation: " + JSONText.encode(conversation),
                ])
            }
            turns.append([
                "role": "user",
                "content": "Task state: " + JSONText.encode(AgentContext.task(targetTask)),
            ])
        }
        turns.append(["role": "user", "content": "Latest human request: " + text])
        let intent = try await RequestIntent.interpret(
            text, messages: turns, schema: schema,
            contextualize: { candidate in
                var intent = candidate
                if intent.route == .auto { intent.route = capability.defaultRoute }
                if routeKnown {
                    intent.targetTaskID = resolved?.uuidString
                    intent.restoreTaskID = nil
                } else if let archive = intent.restoreTaskID {
                    guard intent.targetTaskID == nil, archivedIDs.contains(archive) else {
                        throw ToolArgumentError(
                            path: "$.restoreTaskID",
                            issue: "choose either an available task or an archived restoration, never both")
                    }
                    // Both destinations use the same ownership/execution path after validation.
                    intent.targetTaskID = archive
                    intent.restoreTaskID = nil
                }
                if intent.clarificationQuestion != nil { return try intent.validated(for: text) }
                intent = intent.resolvingControlDomain(
                    (model.sideTasks + model.archivedTaskHistory).first {
                        $0.id.uuidString == intent.targetTaskID
                    })
                let hasExistingPage = (model.sideTasks + model.archivedTaskHistory).contains {
                    $0.id.uuidString == intent.targetTaskID && $0.kind == .web
                }
                if intent.needsBrowserContext && !hasExistingPage {
                    throw ToolArgumentError(
                        path: "$.needsBrowserContext",
                        issue:
                            "there is no resolved existing page; use false for a self-contained request and discover its source during execution"
                    )
                }
                if let reuse = intent.reuse {
                    guard methods.contains(where: { $0["id"] as? String == reuse.id }) else {
                        throw ToolArgumentError(path: "$.reuse.id", issue: "method is outside the current catalogue")
                    }
                    let recipe = try model.interfaceMemory.recipe(reuse.id)
                    let methodRoute: RequestIntent.Route = recipe.surface?.apiData == nil ? .local : .api
                    guard intent.route == .auto || intent.route == methodRoute else {
                        throw ToolArgumentError(
                            path: "$.reuse.id",
                            issue:
                                "method does not support the requested execution route; select a compatible method or use null"
                        )
                    }
                    let keys = Set(recipe.surface.flatMap(SavedMethod.controls)?.map(\.key) ?? [])
                    guard Set(reuse.state.keys) == keys else {
                        throw ToolArgumentError(
                            path: "$.reuse.state",
                            issue:
                                "supply exactly the selected method's required inputs, or use null when it cannot fulfill the request"
                        )
                    }
                    let data = try JSONEncoder().encode(reuse)
                    let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    try ToolContract.validate("reuse_saved_ui", input)
                    intent.route = methodRoute
                    intent.requiresFreshData = intent.requiresFreshData || recipe.surface?.apiData != nil
                    intent.initialURL = nil
                    intent.needsBrowserContext = false
                    intent.steps = [RequestStep(tool: "reuse_saved_ui", arguments: JSONText.encode(input))]
                    intent.stepsComplete = true
                    intent.answer = nil
                }
                return intent
            },
            complete: { messages, tools, requiredTool in
                try await ModelClient.complete(
                    endpoint: endpoint, key: resolvedKey, messages: messages, tools: tools, reasoning: false,
                    requiredTool: requiredTool, budget: thinkingBudget)
            })
        Diagnostics.record(
            "request_plan",
            [
                "requestID": model.activeRequest?.id.uuidString ?? "",
                "taskID": intent.targetTaskID ?? "", "route": intent.route.rawValue,
                "behavior": intent.behavior.rawValue,
                "routeKnown": routeKnown, "methodCount": methods.count,
                "reused": intent.steps.contains { $0.tool == "reuse_saved_ui" },
            ])
        return try intent.validated(for: text)
    }
    func decide(_ turns: [[String: Any]], key: String) async throws -> [String: Any] {
        #if DEBUG
            if let completionOverride { return try await completionOverride(turns) }
        #endif
        let effective = requestIntent
        var context = AgentContext.compact(turns)
        if context.first?["role"] as? String == "system" {
            context[0]["content"] = AgentPrompts.execution(
                startPolicy: model.activeRequest?.startPolicy ?? model.settings.taskStartPolicy, intent: effective)
        }
        if executionLedger.hasGoals {
            context.append([
                "role": "user",
                "content": "Request outcome ledger (host verified): "
                    + JSONText.encode(
                        executionLedger.goals.enumerated().map { index, goal in
                            ["goal": index, "outcome": goal, "verified": executionLedger.fulfilled[index] != nil]
                                as [String: Any]
                        })
                    + ". Fulfil only outstanding goals; assign each action its goal index. An uncertain effect needs observation, not replay.",
            ])
        }
        let tools = offeredTools(for: effective)
        Diagnostics.record(
            "decision_context",
            [
                "promptBytes": (context.first?["content"] as? String ?? "").utf8.count,
                "toolBytes": JSONText.encode(tools).utf8.count, "toolCount": tools.count,
                "messageBytes": JSONText.encode(context).utf8.count,
                "route": effective.route.rawValue,
            ])
        return try await ModelClient.complete(
            endpoint: requestEndpoint ?? model.settings.main, key: key, messages: context, tools: tools,
            reasoning: thinkingBudget == .normal || thinkingBudget == .high, budget: thinkingBudget)
    }
    /// Load only the selected route. The dispatcher enforces the same boundary.
    func offeredTools(for intent: RequestIntent) -> [[String: Any]] {
        let names: Set<String>?
        if intent.route == .api {
            names = ["query_api", "inspect_api", "reuse_saved_ui", "finish"]
        } else if intent.route == .web {
            names = [
                "find_music", "navigate", "observe", "act", "control_media", "reuse_ui", "compose_ui", "reuse_saved_ui",
                "screenshot",
                "history", "finish", "visibility", "query_api", "inspect_api",
            ]
        } else if intent.kind == .information, !intent.requiresFreshData, !intent.needsBrowserContext,
            intent.route == .auto
        {
            names = ["finish"]
        } else {
            names = nil
        }
        return AgentToolRegistry.definitions.filter { tool in
            guard let name = (tool["function"] as? [String: Any])?["name"] as? String,
                !unavailableTools.contains(name), names?.contains(name) ?? true, intent.allows(name)
            else { return false }
            if !capabilityExploration, requestCapability != .general, requestCapability != .answer,
                !requestCapability.tools.union(["finish"]).contains(name)
            {
                return false
            }
            if model.requestPageID == nil,
                ["observe", "act", "control_media", "reuse_ui", "compose_ui", "screenshot"].contains(name)
            {
                return false
            }
            if name == "reuse_saved_ui", intent.route == .web, model.requestPageID == nil { return false }
            if name == "run_code", intent.route == .local, intent.behavior == .interactive, !exploratoryCodeAvailable {
                return false
            }
            if name == "present_ui", model.requestPageID != nil { return false }
            if name == "screenshot", !(requestEndpoint ?? model.settings.main).vision { return false }
            return true
        }.map { original in
            var tool = original
            if intent.goals.count > 1, var function = tool["function"] as? [String: Any],
                var parameters = function["parameters"] as? [String: Any],
                var properties = parameters["properties"] as? [String: Any]
            {
                properties["goal"] = [
                    "type": "integer", "description": "Zero-based requested goal this action fulfills.",
                ]
                parameters["properties"] = properties
                function["parameters"] = parameters
                tool["function"] = function
            }
            if intent.route == .api,
                (tool["function"] as? [String: Any])?["name"] as? String == "reuse_saved_ui"
            {
                return RequestPlanning.reuseTool
            }
            var scoped = SurfacePlan.scopeTool(tool, observation: model.lastObservation)
            if intent.route == .api, var function = scoped["function"] as? [String: Any],
                function["name"] as? String == "query_api",
                var parameters = function["parameters"] as? [String: Any],
                var properties = parameters["properties"] as? [String: Any]
            {
                properties.removeValue(forKey: "markup")  // Host layout already satisfies ordinary editable data tools.
                parameters["properties"] = properties
                function["parameters"] = parameters
                scoped["function"] = function
            }
            return scoped
        }
    }

}
