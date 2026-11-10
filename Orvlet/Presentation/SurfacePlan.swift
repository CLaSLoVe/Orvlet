import Foundation
import SwiftUI

// Legacy native components remain readable for migration; new surfaces use generated HTML/CSS.
enum ComponentKind: String, Codable { case media, transport, slider, buttons, list, input, web, text }
struct PageBinding: Codable {
    static let mediaOperations = [
        "play", "pause", "toggle", "seek", "volume", "mute", "unmute", "toggleMute", "next", "previous", "loop",
        "unloop",
    ]
    static var operationSchema: [String: Any] {
        [
            "type": "string", "enum": mediaOperations + ["down", "up", "press", "move", "click"],
            "description":
                "Required for media: choose play/pause/toggle/seek/volume/mute/unmute/toggleMute/next/previous. Keyboard uses down/up/press; pointer uses down/up/move/click.",
        ]
    }
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["click", "type", "select", "submit", "media", "key"]],
                "id": [
                    "type": "string", "description": "Exact observed DOM element ID, only for element interactions",
                ],
                "role": ["type": "string"], "name": ["type": "string"],
                "operation": operationSchema,
                "text": ["type": "string"], "key": ["type": "string"], "value": ["type": "number"],
            ], "required": ["action"],
        ]
    }
    var action: String
    var id: String?
    var role: String?
    var name: String?
    var operation: String?
    var text: String?
    var key: String?
    var value: Double?
    var x: Double?
    var y: Double?
    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
struct SurfaceAction: Codable, Identifiable {
    var label: String
    var icon: String?
    var binding: PageBinding
    var id: String { label + (binding.name ?? binding.operation ?? binding.action) }
}
struct SurfaceComponent: Codable, Identifiable {
    var kind: ComponentKind
    var label: String?
    var actions: [SurfaceAction]?
    var binding: PageBinding?
    var submit: PageBinding?
    var valueSource: String?
    var id: String { kind.rawValue + (label ?? "") + (binding?.name ?? "") }
}
struct CardReading: Codable {
    var key: String
    var selector: String
}
struct SurfacePlan: Codable {
    static func scopeTool(_ tool: [String: Any], observation: [String: Any]) -> [String: Any] {
        var result = tool
        guard var function = result["function"] as? [String: Any],
            ["compose_ui", "reuse_saved_ui"].contains(function["name"] as? String ?? ""),
            var parameters = function["parameters"] as? [String: Any],
            var properties = parameters["properties"] as? [String: Any]
        else { return tool }
        let selectors = (observation["readables"] as? [[String: Any]] ?? []).compactMap { $0["selector"] as? String }
        // Long page selectors already occur in the observation. Do not duplicate them in every tool schema.
        let selectorSchema: [String: Any] =
            !selectors.isEmpty && JSONText.encode(selectors).utf8.count <= 2048
            ? ["type": "string", "enum": selectors]
            : [
                "type": "string",
                "description": "Exact selector from the observed readables; the host verifies the binding.",
            ]
        properties["readings"] = [
            "type": "array", "maxItems": selectors.isEmpty ? 0 : 8,
            "items": [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                        "description": "Unique custom state key; never title, status, detail or a reserved host key",
                    ],
                    "selector": selectorSchema,
                ], "required": ["key", "selector"],
            ],
        ]
        if observation["hasMedia"] as? Bool == true, observation["mediaPrimary"] as? Bool != false,
            var markup = properties["markup"] as? [String: Any], var fields = markup["properties"] as? [String: Any]
        {
            fields["html"] = [
                "type": "string",
                "description":
                    "Expanded HTML. Bind the live title with data-bind='title'. Represent playback with data-bind='toggleLabel' on its transport button or data-bind='status' on a status label; no duplicate label is needed. Never freeze track facts or playback text.",
            ]
            markup["properties"] = fields
            properties["markup"] = markup
        }
        parameters["properties"] = properties
        function["parameters"] = parameters
        result["function"] = function
        return result
    }
    var components: [SurfaceComponent]
    var width: Double
    var height: Double
    var title: String?
    var markup: CardMarkup? = nil
    var actions: [BoundCardAction]? = nil
    var readings: [CardReading]? = nil
    var interfaceRecipeID: UUID? = nil
    var hasMediaControls: Bool {
        (actions ?? []).contains { $0.binding.action == "media" }
            || components.contains { $0.kind == .media || $0.kind == .transport }
    }
    /// Only content-independent transport layouts may cross a track URL change.
    /// Information cards retain exact source identity, including query parameters.
    var reusableTransport: Bool {
        guard hasMediaControls, (readings ?? []).isEmpty,
            bindings.allSatisfy({ $0.action == "media" }),
            components.allSatisfy({ [.media, .transport, .slider].contains($0.kind) })
        else { return false }
        guard let markup else { return true }
        guard markup.css.range(of: #"(?i)(?:^|[;{])\s*content\s*:"#, options: .regularExpression) == nil,
            (markup.html + markup.compactHTML).range(
                of: #"(?i)\b(?:title|alt|placeholder|aria-label)\s*="#, options: .regularExpression) == nil
        else { return false }
        let allowed = Set([
            "play", "pause", "mute", "unmute", "next", "previous", "volume", "source", "open", "player", "now",
            "playing",
        ])
        for fragment in [markup.html, markup.compactHTML] {
            // Bound nodes are replaced by fresh host state, including their text.
            let unbound = fragment.replacingOccurrences(
                of: #"(?is)<([a-z][a-z0-9]*)\b[^>]*\bdata-bind\s*=\s*["'][^"']+["'][^>]*>.*?</\1\s*>"#, with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            let words = unbound.lowercased().split { !$0.isLetter }.map(String.init)
            if !Set(words).isSubset(of: allowed) { return false }
        }
        return true
    }
    var needsVisual: Bool { components.contains { $0.kind == .web } }
    static let empty = SurfacePlan(components: [], width: 300, height: 260)
    static let webpage = SurfacePlan(components: [SurfaceComponent(kind: .web)], width: 340, height: 240)
    func compacted() -> SurfacePlan {
        var copy = self
        if let markup {
            copy.width = 320
            copy.height = markup.height + 38
            return copy
        }
        // Dimensions are a desktop footprint, not a web app canvas size.
        copy.width = min(max(width, 250), needsVisual ? 400 : 320)
        let controls = components.reduce(0.0) { total, c in
            total
                + (c.kind == .media
                    ? 38
                    : c.kind == .transport
                        ? 30
                        : c.kind == .slider
                            ? 23
                            : c.kind == .input
                                ? 32
                                : c.kind == .buttons
                                    ? 32
                                    : c.kind == .list
                                        ? min(126, Double(c.actions?.count ?? 0) * 30) : c.kind == .text ? 20 : 0)
        }
        if components.isEmpty { return copy }
        copy.height = min(
            needsVisual ? 420 : 320, 42 + controls + Double(max(0, components.count - 1)) * 5 + (needsVisual ? 185 : 0))
        return copy
    }
    var size: NSSize { NSSize(width: width, height: height) }
    var bindings: [PageBinding] {
        components.flatMap { c in (c.actions ?? []).map(\.binding) + [c.binding, c.submit].compactMap { $0 } }
            + (actions ?? []).flatMap { [$0.binding, $0.submit].compactMap { $0 } }
    }
    func validatedAction(_ action: BoundCardAction, observation: [String: Any]) throws -> BoundCardAction {
        var checked = action
        // Semantic bindings survive changing webpage button names.
        if markup?.actionsBound(to: "toggleLabel").contains(action.id) == true {
            checked.binding = PageBinding(action: "media", operation: "toggle")
        } else if markup?.actionsBound(to: "muteLabel").contains(action.id) == true {
            checked.binding = PageBinding(action: "media", operation: "toggleMute")
        }
        checked.binding = try checked.binding.validated(observation: observation)
        if let submit = checked.submit { checked.submit = try submit.validated(observation: observation) }
        return checked
    }
    static func sourceFallback(readings: [CardReading], primary: String, observation: [String: Any]) throws
        -> SurfacePlan
    {
        guard readings.contains(where: { $0.key == primary }), !readings.isEmpty, readings.count <= 8,
            readings.allSatisfy({ $0.key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,30}$", options: .regularExpression) != nil }
            )
        else { throw AppError.message("Use valid observed result keys.") }
        let rows = readings.map { "<div data-bind='" + $0.key + "'></div>" }.joined()
        let markup = CardMarkup(
            html: "<section class='source-result'>" + rows + "</section>",
            compactHTML: "<strong data-bind='" + primary + "'></strong>",
            css: ".source-result{display:grid;gap:8px;font-variant-numeric:tabular-nums}")
        return try SurfacePlan(
            components: [], width: 320, height: 180, title: observation["title"] as? String, markup: markup,
            actions: [], readings: readings
        ).validated(observation: observation)
    }
    func validated(observation: [String: Any]) throws -> SurfacePlan {
        guard !components.isEmpty || markup != nil, components.count <= 9, width.isFinite, height.isFinite else {
            throw AppError.message("Incomplete interface plan.")
        }
        func bind(_ binding: PageBinding) throws -> PageBinding { try binding.validated(observation: observation) }
        var plan = self
        if let readings {
            let observed = observation["readables"] as? [[String: Any]] ?? []
            var keys = Set<String>()
            guard readings.count <= 8 else { throw AppError.message("Keep live readings small.") }
            for reading in readings {
                guard reading.key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,30}$", options: .regularExpression) != nil,
                    ![
                        "title", "detail", "status", "remaining", "toggleLabel", "mediaPlaying", "mediaMuted",
                        "muteLabel", "mediaActions", "appearance", "accent", "compact",
                    ].contains(reading.key),
                    keys.insert(reading.key).inserted
                else {
                    throw AppError.message(
                        "Invalid or duplicate reading key '\(reading.key)'. Use a unique custom key, not a reserved host field such as title or status."
                    )
                }
                guard observed.contains(where: { $0["selector"] as? String == reading.selector }) else {
                    throw AppError.message(
                        "Selector '\(reading.selector)' was not observed. Copy one of the exact selectors from observation.readables; do not guess an ID or alter the selector."
                    )
                }
            }
        }
        if let markup {
            plan.markup = try markup.validated()
            let available = Set(
                ["title", "status", "toggleLabel", "mediaPlaying", "mediaMuted", "muteLabel"]
                    + (readings ?? []).map(\.key))
            try markup.validateBindings(available: available, requiredLive: Set((readings ?? []).map(\.key)))
            if !hasMediaControls, !(readings ?? []).isEmpty,
                markup.compactHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AppError.message(
                    "Include compactHTML for this live information card. Bind its main live reading; the compact view must not fall back to a page title or frozen text."
                )
            }
            if !hasMediaControls, (actions ?? []).isEmpty, (readings ?? []).isEmpty,
                !(observation["readables"] as? [[String: Any]] ?? []).isEmpty
            {
                throw AppError.message(
                    "A read-only webpage card needs live readings. Choose selectors from observation.readables, declare readings:[{key,selector}], and bind those keys in both html and compactHTML. title is only the page title and status is only the site name; detail is unavailable. Do not paste captured values into HTML."
                )
            }
            if hasMediaControls {
                let keys = CardMarkup.bindingKeys(in: markup.html)
                guard keys.contains("title") else {
                    throw AppError.message(
                        "Bind the live track title with data-bind='title'; do not bake a song name into HTML.")
                }
                guard !keys.isDisjoint(with: ["status", "toggleLabel"]) else {
                    throw AppError.message(
                        "Bind playback with data-bind='toggleLabel' on the transport button, or data-bind='status' on a label. One live indicator is sufficient."
                    )
                }
            }
        }
        if let actions {
            guard markup != nil, actions.count <= 12 else { throw AppError.message("Too many card actions.") }
            var ids = Set<String>()
            plan.actions = try actions.map { action in
                guard action.id.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,39}$", options: .regularExpression) != nil,
                    !["expand", "source", "dismiss"].contains(action.id), ids.insert(action.id).inserted
                else {
                    throw AppError.message("Use unique short action IDs.")
                }
                return try validatedAction(action, observation: observation)
            }
        }
        if let markup = plan.markup {
            try markup.validateActions(Set((plan.actions ?? []).map(\.id)).union(["expand", "source", "dismiss"]))
        }
        plan.width = min(max(width, 250), 400)
        let hasWeb = needsVisual
        plan.height = min(max(height, hasWeb ? 220 : 120), 420)
        var used = Set<String>()
        for i in plan.components.indices {
            var c = plan.components[i]
            guard used.insert(c.id).inserted else { throw AppError.message("Duplicate components.") }
            guard (c.actions?.count ?? 0) <= 20 else { throw AppError.message("Too many controls.") }
            if [.transport, .buttons, .list].contains(c.kind), c.actions?.isEmpty != false {
                throw AppError.message("Action component has no binding.")
            }
            if [.input, .slider].contains(c.kind), c.binding == nil {
                throw AppError.message("Input component has no binding.")
            }
            if c.kind == .slider, !["mediaTime", "volume"].contains(c.valueSource ?? "") {
                throw AppError.message("Slider needs a live value source.")
            }
            if c.kind == .text, let label = c.label {
                let evidence = [observation["title"] as? String, observation["text"] as? String].compactMap { $0 }
                    .joined(separator: "\n")
                if !evidence.localizedCaseInsensitiveContains(label) {
                    c.label = observation["title"] as? String ?? ""
                }
            }
            if let actions = c.actions {
                c.actions = try actions.map {
                    var a = $0
                    a.binding = try bind(a.binding)
                    return a
                }
            }
            if let b = c.binding { c.binding = try bind(b) }
            if let b = c.submit { c.submit = try bind(b) }
            plan.components[i] = c
        }
        let estimatedHeights = plan.components.map { c -> Double in
            switch c.kind {
            case .web: 200
            case .media: 65
            case .transport: 42
            case .slider: c.valueSource == "mediaTime" ? 30 : 20
            case .buttons: (c.actions?.count ?? 0) > 3 ? 82 : 42
            case .list: min(155, Double(c.actions?.count ?? 0) * 43)
            case .input: 42
            case .text: 30
            }
        }
        let requiredHeight = 80 + estimatedHeights.reduce(0, +) + Double(max(0, plan.components.count - 1)) * 10
        guard requiredHeight <= 680 else { throw AppError.message("Simplify the interface: too many controls.") }
        plan.height = max(plan.height, requiredHeight)
        return plan.compacted()
    }
}

extension SurfacePlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markup = try c.decodeIfPresent(CardMarkup.self, forKey: .markup)
        // Legacy native templates remain readable; HTML generation needs no empty template array.
        components = try c.decodeIfPresent([SurfaceComponent].self, forKey: .components) ?? []
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 320
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? ((markup?.height ?? 170) + 38)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        actions = try c.decodeIfPresent([BoundCardAction].self, forKey: .actions)
        readings = try c.decodeIfPresent([CardReading].self, forKey: .readings)
        interfaceRecipeID = try c.decodeIfPresent(UUID.self, forKey: .interfaceRecipeID)
    }
}

extension PageBinding {
    func validated(observation: [String: Any]) throws -> PageBinding {
        let elements = observation["elements"] as? [[String: Any]] ?? []
        let allowed = Set(["click", "type", "select", "submit", "scroll", "media", "pip", "key", "pointer"])
        let mediaOperations = Set([
            "play", "pause", "toggle", "next", "previous", "seek", "volume", "mute", "unmute", "toggleMute", "loop",
            "unloop",
        ])
        var b = self
        guard allowed.contains(b.action) else { throw AppError.message("Unsupported interface action.") }
        if b.action == "media" {
            guard observation["hasMedia"] as? Bool == true, observation["mediaPrimary"] as? Bool != false,
                mediaOperations.contains(b.operation ?? "")
            else { throw AppError.message("This page does not have that media capability.") }
        }
        if let id = b.id {
            guard let element = elements.first(where: { $0["id"] as? String == id }),
                let name = element["label"] as? String, !name.isEmpty
            else { throw AppError.message("Control needs a reusable page locator.") }
            b.role = element["role"] as? String
            b.name = name
            b.id = nil
        }
        if ["click", "type", "select", "submit"].contains(b.action) {
            guard let name = b.name, !name.isEmpty, b.role != nil else {
                throw AppError.message("Control is not bound to a page element.")
            }
            let matches = elements.filter { $0["label"] as? String == name && $0["role"] as? String == b.role }
            guard matches.count == 1 else { throw AppError.message("Page control is ambiguous. Inspect it again.") }
            if b.action == "type", matches[0]["editable"] as? Bool != true,
                !["input", "textarea", "textbox", "searchbox"].contains(b.role ?? "")
            {
                throw AppError.message(
                    "This observed control is not a text field. For a search link/button, bind click with revealSource:true, or inspect the actual editable input first."
                )
            }
            if b.action == "select", !["select", "combobox", "listbox"].contains(b.role ?? "") {
                throw AppError.message("Selection needs an observed select control.")
            }
        }
        // Coordinate actions are useful live, but unsafe to retain across layout changes.
        guard b.x == nil && b.y == nil else {
            throw AppError.message("Coordinate actions cannot be saved as reusable controls.")
        }
        return b
    }
}
