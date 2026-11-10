import Foundation

/// A verified or user-edited design, not a cached answer. Instance values are never replayed.
struct InterfaceRecipe: Codable, Identifiable {
    var id: UUID
    var purpose: String
    var kind: SideTaskKind
    var markup: CardMarkup
    var plan: SurfacePlan?
    var surface: TaskSurface?
    var stateKeys: [String]
    var sourceURL: String? = nil
}

@MainActor
final class InterfaceMemory {
    private var userRecipes: [InterfaceRecipe]
    var recipes: [InterfaceRecipe] {
        let ids = Set(userRecipes.map(\.id))
        return userRecipes + BundledMethods.recipes.filter { !ids.contains($0.id) }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        userRecipes =
            defaults.data(forKey: "interfaceRecipes.v1").flatMap {
                try? JSONDecoder().decode([InterfaceRecipe].self, from: $0)
            } ?? []
    }
    func remember(_ task: SideTask, purpose: String) {
        guard task.kind == .web || task.kind == .workspace else { return }
        let id = task.interfaceRecipeID ?? task.id
        var surface = task.taskSurface
        surface?.state = [:]
        surface?.runID = nil
        if var spec = surface?.runtime {
            // Saved appearance must not replay a previous stopwatch start.
            for index in spec.sources.indices where spec.sources[index].kind == .elapsed {
                spec.sources[index].anchor = nil
            }
            spec.refresh?.initialValues = nil
            surface?.runtime = spec
        }
        let previous = recipes.first { $0.id == id }
        let stablePurpose =
            previous.flatMap { prior in
                SavedMethod.signature(prior.surface) == SavedMethod.signature(surface) ? prior.purpose : nil
            } ?? ((surface?.title ?? task.title) + ": " + purpose)
        let recipe = InterfaceRecipe(
            id: id, purpose: String(stablePurpose.prefix(240)), kind: task.kind, markup: task.presentation,
            plan: task.plan, surface: surface,
            stateKeys: Array(
                Set((task.liveValues ?? task.taskSurface?.state ?? [:]).keys).subtracting(
                    Set(surface?.runtime?.sources.map(\.key) ?? []))
            ).sorted(), sourceURL: task.sourceURL)
        userRecipes.removeAll { $0.id == id }
        userRecipes.insert(recipe, at: 0)
        userRecipes = Array(userRecipes.prefix(16))
        if let data = try? JSONEncoder().encode(userRecipes) { defaults.set(data, forKey: "interfaceRecipes.v1") }
    }
    var storedBytes: Int { defaults.data(forKey: "interfaceRecipes.v1")?.count ?? 0 }
    func resetUserRecipes() {
        userRecipes.removeAll()
        defaults.removeObject(forKey: "interfaceRecipes.v1")
    }
    /// Deduplicate methods in model context, never delete saved designs or IDs.
    static func methodGroups(_ recipes: [InterfaceRecipe]) -> [[InterfaceRecipe]] {
        var groups: [[InterfaceRecipe]] = []
        var indexes: [String: Int] = [:]
        for recipe in recipes {
            let key =
                recipe.kind == .workspace && recipe.surface != nil
                ? SavedMethod.signature(recipe.surface) : recipe.id.uuidString
            if let index = indexes[key] {
                groups[index].append(recipe)
            } else {
                indexes[key] = groups.count
                groups.append([recipe])
            }
        }
        return groups
    }

    /// Selection needs input contracts, not HTML, code, old values or every tool schema.
    func planningCatalogue(preferredID: UUID? = nil) -> [[String: Any]] {
        Self.methodGroups(recipes).compactMap { group -> [String: Any]? in
            let recipe = group.first(where: { $0.id == preferredID }) ?? group[0]
            guard recipe.kind == .workspace, let surface = recipe.surface,
                surface.runtime == nil, let controls = SavedMethod.controls(surface), controls.count <= 6,
                surface.apiData != nil || (surface.actions.count == 1 && surface.actions[0].kind == .code)
            else { return nil }
            return [
                "id": recipe.id.uuidString, "purpose": String(recipe.purpose.prefix(240)),
                "route": surface.apiData == nil ? "local" : "api",
                "inputs": controls.map { control -> [String: Any] in
                    var row: [String: Any] = ["key": control.key, "label": control.label, "type": control.kind]
                    if let options = control.options { row["options"] = Array(options.prefix(64)) }
                    return row
                },
                "outputs": surface.apiData?.outputs?.map(\.label) ?? [],
                "sourceFields": surface.apiData?.fields.map { ["key": $0.key, "label": $0.label] } ?? [],
            ]
        }.prefix(8).map { $0 }
    }
    /// Semantic selection is made by the agent, never by title/keyword matching.
    var catalogue: [[String: Any]] {
        recipes.map {
            var entry: [String: Any] = [
                "id": $0.id.uuidString, "purpose": $0.purpose, "kind": $0.kind.rawValue, "state_keys": $0.stateKeys,
                "fields": $0.surface?.fields ?? [],
                "actions": $0.surface?.actions.map(\.id) ?? $0.plan?.actions?.map(\.id) ?? [],
            ]
            if let spec = $0.surface?.apiData {
                entry["api"] =
                    [
                        "input_keys": (spec.inputs ?? [:]).keys.sorted(),
                        "source_fields": spec.fields.map { ["key": $0.key, "label": $0.label] },
                        "source_host": URL(string: spec.url)?.host ?? "",
                        "instruction":
                            "reuse_saved_ui fetches fresh data. Supply every input in state; map requirements with outcomeEvidence.fieldKey. For a different acquisition method use query_api.",
                    ] as [String: Any]
            }
            if $0.surface?.preset == "clock" {
                entry["preset"] = "clock"
                entry["instruction"] =
                    "Supply runtime with the currently requested IANA time zones, and state:{}; the host rebuilds clock labels from those actual sources."
            }
            return entry
        }
    }
    func recipe(_ raw: String) throws -> InterfaceRecipe {
        guard let id = UUID(uuidString: raw), let recipe = recipes.first(where: { $0.id == id }) else {
            throw AppError.message("That saved interface is no longer available.")
        }
        return recipe
    }
    func webPlan(
        _ raw: String, observation: [String: Any], readings: [CardReading]? = nil, actions: [BoundCardAction]? = nil
    ) throws -> SurfacePlan {
        let recipe = try recipe(raw)
        guard recipe.kind == .web, var plan = recipe.plan else {
            throw AppError.message("This saved interface is not a webpage card.")
        }
        if !plan.reusableTransport {
            guard let source = recipe.sourceURL,
                SurfaceCache.pageKey(source) == SurfaceCache.pageKey(observation["url"] as? String ?? "")
            else {
                throw AppError.message(
                    "This saved view belongs to a different source. Recompose from current readings so old labels and facts cannot carry over."
                )
            }
        }
        plan.markup = recipe.markup
        plan.interfaceRecipeID = recipe.id
        if let readings {
            guard Set(readings.map(\.key)) == Set((plan.readings ?? []).map(\.key)) else {
                throw AppError.message("Rebind the saved reading keys without changing the design.")
            }
            plan.readings = readings
        }
        if let actions {
            guard Set(actions.map(\.id)) == Set((plan.actions ?? []).map(\.id)) else {
                throw AppError.message("Rebind the saved action IDs without changing the design.")
            }
            plan.actions = actions
        }
        // Selector/action validation uses today's page, never the saved observation.
        return try plan.validated(observation: observation)
    }
    func taskSurface(_ raw: String, title: String, state: [String: String]) throws -> TaskSurface {
        let recipe = try recipe(raw)
        guard recipe.kind == .workspace, var surface = recipe.surface else {
            throw AppError.message("This saved interface needs a webpage.")
        }
        let required = Set(recipe.stateKeys).subtracting(
            surface.preset == "clock"
                ? Set(["clockZone0", "clockZone1", "clockZone2", "clockHourStyle", "clockLocationLabel"]) : [])
        guard required.isSubset(of: Set(state.keys)) else {
            throw AppError.message(
                "Supply fresh values for every saved state key. Old task results are never reused.")
        }
        surface.title = title
        surface.state = state
        surface.markup = recipe.markup
        surface.runtime?.refresh?.initialValues = nil
        if surface.preset == "clock" { surface = surface.withClockControls }
        return try surface.validated()
    }
}
