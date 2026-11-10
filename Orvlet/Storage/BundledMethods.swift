import Foundation

/// Declarative execution recipes share exactly the user-method selection and
/// verification path. No request keywords, old outputs or model prompts live here.
@MainActor
enum BundledMethods {
    private struct Definition: Decodable {
        let id: UUID
        let purpose: String
        let source: APIDataSpec
    }
    static let recipes: [InterfaceRecipe] = {
        guard let url = Bundle.main.url(forResource: "methods", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let definitions = try? JSONDecoder().decode([Definition].self, from: data)
        else { return [] }
        return definitions.compactMap { definition in
            do {
                let source = try definition.source.validated()
                let keys =
                    source.fields.map(\.key) + (source.outputs ?? []).map(\.key) + [
                        "sourceDate", "sourceHost", "resultStatus",
                    ]
                let empty = Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, "") })
                var surface = try source.surface(title: definition.purpose, state: empty)
                surface.state = [:]
                return InterfaceRecipe(
                    id: definition.id, purpose: definition.purpose, kind: .workspace,
                    markup: surface.markup, surface: surface, stateKeys: [])
            } catch {
                Diagnostics.record("bundled_method_invalid", ["category": Diagnostics.category(error)])
                return nil
            }
        }
    }()
}
