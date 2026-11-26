import SwiftUI
import WebKit

/// The model owns the structure; the host owns execution, typography and lifecycle.
struct CardMarkup: Codable, Equatable {
    static let visualBindings = """
        Use semantic HTML tables for exact comparisons. For changing rows use <table><thead><tr><th data-column="key">Header</th>…</tr></thead></table>, one aligned JSON array per column. For a trend use <figure data-series="yKey" data-x="xKey" aria-label="Measurement (unit) over …"></figure>. Bind JSON arrays of observed numbers with ascending numeric or ISO-date x coordinates. For Unix timestamps supply data-x-format="unixSeconds" or "unixMilliseconds". A local calculation can return JSON.stringify(array) as a state value. Label axes/units in the configured interface language. Use these in the expanded markup only as needed.
        """
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "html": ["type": "string", "description": visualBindings],
                "reminder": CardReminderRule.schema,
                "glance": ["type": "object", "description": "Host-rendered named capsule; bind valueKey in the expanded HTML too. Include units in the live reading.",
                    "properties": ["subject": ["type": "string", "minLength": 1, "maxLength": 40], "valueKey": ["type": "string"], "unit": ["type": "string", "maxLength": 12]],
                    "required": ["subject", "valueKey"]],
                "compactHTML": [
                    "type": "string",
                    "description": "Optional custom capsule when glance is omitted. Show the short subject and a bound primary value.",
                ],
                "css": ["type": "string"], "height": ["type": "number"],
            ], "required": ["html"],
        ]
    }
    var reminder: CardReminderRule?
    var html: String
    var compactHTML: String = ""
    var interfaceLanguage: String?
    func matchesLanguage(_ language: String) -> Bool {
        interfaceLanguage?.caseInsensitiveCompare(language) == .orderedSame
    }
    var css: String
    var height: Double = 170
    var bindingKeys: Set<String> { Self.bindingKeys(in: html + compactHTML) }
    static func bindingKeys(in source: String) -> Set<String> {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\bdata-(?:bind|series|x|column)\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        else { return [] }
        return Set(
            regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                Range($0.range(at: 1), in: source).map { String(source[$0]) }
            })
    }
    static func unitSuffix(_ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return "" }
        return "<span class='preset-unit-suffix raw-value-unit'>" + unit.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") + "</span>"
    }

    static func shortGlanceSubject(_ subject: String) -> String {
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        if width(subject) <= 76 { return subject }
        var prefix = ""
        for character in subject {
            let next = prefix + String(character)
            guard width(next + "…") <= 76 else { break }
            prefix = next
        }
        return prefix + "…"
    }

    static func fitsGlance(_ text: String, width: CGFloat = 85) -> Bool {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width <= width
    }

    func validateGlance(state: [String: String], fieldPath: String, runtimeKeys: Set<String> = [], width: CGFloat = 82, unit: String? = nil) throws {
        let keys = Self.bindingKeys(in: compactHTML).subtracting(["title", "status"])
        guard keys.count == 1, let key = keys.first else {
            throw ToolArgumentError(path: fieldPath, issue: "bind one primary value shared with the expanded card")
        }
        if runtimeKeys.contains(key), state[key]?.isEmpty != false { return }
        guard let value = state[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError(path: fieldPath, issue: "the selected value is empty or missing; bind a populated output or initialize it")
        }
        let unitWidth: CGFloat
        if let unit, !unit.isEmpty, compactHTML.contains("raw-value-unit"), Double(value) != nil {
            unitWidth = (unit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 2
        } else {
            unitWidth = 0
        }
        guard Self.fitsGlance(value, width: width - unitWidth) else {
            throw ToolArgumentError(path: fieldPath, issue: "The primary reading in " + key + " would be clipped. Bind a short value with its unit (about 12 characters). Keep explanations and secondary values on the expanded card. Set form.compactKey or markup.glance.valueKey accordingly.")
        }
    }

    /// A named option can identify the winner, but it cannot also serve as the
    /// measurement. Consider only values actually displayed on this card.
    func validateMeasuredResult(primary: String, subjects: [String], state: [String: String], fieldPath: String) throws {
        guard let name = state[primary]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, name.contains(where: \.isLetter) else { return }
        let literal = NSRegularExpression.escapedPattern(for: name)
        // Latin names can border Chinese conjunctions without spaces.
        let pattern = #"(?<![\p{Latin}\p{N}])"# + literal + #"(?![\p{Latin}\p{N}])"#
        guard subjects.contains(where: { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) else { return }
        let details = Self.bindingKeys(in: html).subtracting([primary, "title", "detail", "status", "sourceDate", "sourceDateDisplay", "sourceChecked"])
        let measured = details.filter { key in
            guard let value = state[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return value.range(of: #"^(?:[\p{Sc}]|[A-Z]{1,3}\$)?\s*[+−-]?\d+(?:[.,]\d+)*\s*(?:[%‰°\p{L}]+)?$"#, options: .regularExpression) != nil
        }
        guard measured.count < 2 else {
            throw ToolArgumentError(path: fieldPath, issue: "The capsule repeats an option name while the expanded result has measurements. Show the relevant measured value with its unit and identifiable subject, or a verified difference. Keep the other readings in the expanded card.")
        }
    }

    func validateExpandedPurpose(state: [String: String], subject: String, hasActions: Bool) throws {
        let supporting = Self.bindingKeys(in: html).subtracting(Self.bindingKeys(in: compactHTML))
            .subtracting(["title", "status"])
        if hasActions || !supporting.isEmpty || html.contains("data-series") || html.contains("<table") { return }
        // Only flag clear replicas. Explanations, instructions and static legends can be useful.
        var copy = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for word in [subject, state["title"] ?? ""] where !word.isEmpty {
            copy = copy.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        guard copy.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw ToolArgumentError(path: "$.markup.html", issue: "the expanded view repeats the capsule. Include a verified detail that helps a decision, an actual control or the original work. For a transient answer reply in conversation.")
        }
    }

    /// A host-built static subject belongs to its original instance. Keep live name bindings intact.
    mutating func bindReusedGlanceTitle() {
        let pattern = #"^<div class='calm-glance'><small class='calm-label'>[^<]*</small>"#
        compactHTML = compactHTML.replacingOccurrences(of: pattern,
            with: "<div class='calm-glance'><small class='calm-label' data-bind='title'></small>",
            options: .regularExpression)
    }

    func hasSameDesign(as other: CardMarkup) -> Bool {
        html == other.html && compactHTML == other.compactHTML && css == other.css
    }
    func validateBindings(available: Set<String>, requiredLive: Set<String> = []) throws {
        try reminder?.validate(available: available)
        guard bindingKeys.isSubset(of: available) else {
            throw ToolArgumentError(path: "$.markup", issue: "Unknown live fields: "
                + bindingKeys.subtracting(available).sorted().joined(separator: ", ")
                + ". Every data-bind, data-series, data-x and data-column must reference a declared state key. Available: "
                + available.sorted().joined(separator: ", "))
        }
        try validateLiveReadings(requiredLive)
    }
    func validateLiveReadings(_ keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        guard keys.isSubset(of: bindingKeys),
            !keys.isDisjoint(with: Self.bindingKeys(in: html)),
            !keys.isDisjoint(with: Self.bindingKeys(in: compactHTML))
        else {
            throw AppError.message(
                "Declared live readings must actually appear in data-bind attributes. Bind every declared key somewhere, and bind a useful live value in BOTH html and compactHTML. Never replace these bindings with captured text."
            )
        }
    }
    enum CodingKeys: String, CodingKey { case html, compactHTML, css, height, interfaceLanguage, reminder }
    init(html: String, compactHTML: String = "", css: String, height: Double = 170) {
        self.html = html
        self.compactHTML = compactHTML
        self.css = css
        self.height = height
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reminder = try c.decodeIfPresent(CardReminderRule.self, forKey: .reminder)
        interfaceLanguage = try c.decodeIfPresent(String.self, forKey: .interfaceLanguage)
        html = try c.decode(String.self, forKey: .html)
        compactHTML = try c.decodeIfPresent(String.self, forKey: .compactHTML) ?? ""
        enum GeneratedKey: String, CodingKey { case glance }
        struct Glance: Decodable { let subject: String; let valueKey: String; var unit: String? }
        let generated = try decoder.container(keyedBy: GeneratedKey.self)
        if let glance = try generated.decodeIfPresent(Glance.self, forKey: .glance) {
            let subject = glance.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, subject.count <= 40,
                glance.valueKey.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil,
                Self.bindingKeys(in: html).contains(glance.valueKey) else {
                throw ToolArgumentError(path: "$.markup.glance", issue: "Supply a short object name and a valueKey bound in the expanded HTML.")
            }
            let label = subject.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            compactHTML = "<div class='calm-glance'><small class='calm-label'>" + label
                + "</small><span><strong class='calm-value' data-bind='" + glance.valueKey + "'></strong>" + Self.unitSuffix(glance.unit) + "</span></div>"
        }
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 170
    }
    func validated() throws -> CardMarkup {
        guard !html.isEmpty, html.utf8.count < 24000,
            compactHTML.utf8.count < 8000, css.utf8.count < 12000, height.isFinite
        else {
            throw AppError.message("Keep the generated interaction card small.")
        }
        let combined = (html + compactHTML + css).lowercased()
        // Runtime sanitization and CSP are independent defenses. No model-authored scripts.
        guard
            ![
                "<script", "<iframe", "<object", "<embed", "<svg", "<math", "javascript:", "@import", "url(",
                "expression(", "<link", "<meta", "<img", "<style",
            ].contains(where: combined.contains)
        else {
            throw AppError.message("Cards support HTML and local CSS only, without scripts or external resources.")
        }
        var value = self
        value.height = min(320, max(100, height))
        return value
    }
    func validateActions(_ allowed: Set<String>, fields: Set<String> = []) throws {
        let source = html + compactHTML
        let regex = try NSRegularExpression(
            pattern: #"data-(action|field|input|change)\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let typeRange = Range(match.range(at: 1), in: source),
                let range = Range(match.range(at: 2), in: source),
                (source[typeRange] == "field" ? allowed.union(fields) : allowed).contains(String(source[range]))
            else {
                throw AppError.message("Every generated control must reference a registered action ID.")
            }
        }
        let controls = try NSRegularExpression(pattern: #"<(?:input|select|textarea)\b[^>]*>"#, options: .caseInsensitive)
        for match in controls.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html),
                html[range].range(of: #"\bdata-field\s*=\s*["'][^"']+["']"#, options: [.regularExpression,.caseInsensitive]) != nil else {
                throw ToolArgumentError(path: "$.markup.html", issue: "Bind each editable control to a registered field. If this operation is new, extend the current card’s behavior before presenting it.")
            }
        }
        let buttons = try NSRegularExpression(pattern: #"<button\b[^>]*>"#, options: .caseInsensitive)
        for match in buttons.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source),
                source[range].range(
                    of: #"data-action\s*=\s*["'][^"']+["']"#, options: [.regularExpression, .caseInsensitive]) != nil
            else {
                throw AppError.message(
                    "Every button, including compact buttons, needs data-action with a registered ID. Use plain text for noninteractive labels."
                )
            }
        }
        if source.range(of: #"\son[a-z]+\s*="#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw AppError.message("Use data-action instead of JavaScript event attributes.")
        }
    }
    var boundControlIDs: Set<String> {
        let pattern = #"\bdata-(?:action|input|change)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return Set(regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        })
    }
    func actionsBound(to key: String) -> Set<String> {
        guard let buttons = try? NSRegularExpression(pattern: #"<button\b[^>]*>"#, options: .caseInsensitive) else {
            return []
        }
        var result = Set<String>()
        for match in buttons.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard
                tag.range(
                    of: "data-bind\\s*=\\s*[\"']" + key + "[\"']", options: [.regularExpression, .caseInsensitive])
                    != nil,
                let action = try? NSRegularExpression(
                    pattern: #"data-action\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive),
                let value = action.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                let id = Range(value.range(at: 1), in: tag)
            else { continue }
            result.insert(String(tag[id]))
        }
        return result
    }
    static let prompt = """
        Generate a genuinely task-specific HTML/CSS card, not a fixed toolbar template. Return markup: {html, css, height}. html is the interaction fragment (100–320px tall, 300px wide). The host renders media/timer controls and the optional primary action of other interactive cards. Set compactLabel on one directly usable action. For other webpage tasks also return compactHTML: a read-only 82×28px view showing the recognizable object name above its most useful live value. This is not a fixed mode: generate structure appropriate to the actual intent. Use shared CSS scoped to separate compact/expanded classes. Keep compactHTML free of buttons and inputs. Design hierarchy and grouping appropriate to the task. Use flex/grid, text, buttons, small badges; no headings about the app, dashboards, decorative subtitles, progress bars for music, or endless animation. Inherit the system font and primary text color. --accent and --muted are text colors; --soft and --line are translucent backgrounds/borders ONLY, never text colors. Use at most three actions; avoid menus of every website feature. No JS, event attributes, external assets, URLs, SVG, iframe, style tags or remote CSS. Tags allowed: div, span, p, strong, em, small, section, header, footer, h1,h2,h3, button, input, textarea, select, option, label, ul,ol,li,br,hr,table,caption,thead,tbody,tr,th,td,figure,figcaption. Every interactive button must have data-action="an allowed action id". Inputs use data-field="a declared field key" for local forms, or the corresponding binding action ID for webpage controls; registered actions receive their values. Native host handles actual execution. Use supplied state keys, including host runtime source keys, with data-bind for changing facts. title/status/detail are host keys; remaining/toggleLabel are for native tasks. Never invent facts. All visible factual text must be grounded in supplied state; dynamic facts should use data-bind. For media cards, title and status MUST use data-bind="title" and data-bind="status". Sound buttons should use media operation toggleMute with data-bind="muteLabel", never a webpage button name that changes after muting. Playback buttons should bind the media toggle operation: the host supplies their live Play/Pause icon and label. Never write a literal song name, artist, duration or Playing/Paused into the markup; omit unsupported metadata or bind a verified reading. Use one title, one muted status, and a clean control row, no nested button panels. Do not place overlays over controls. Use modest spacing and comfortable click targets. Keep layout stable while state updates; the host supplies restrained interaction transitions; do not author your own animations. This is a side-screen tool, designed to be understood at a glance.
        \(visualBindings)
        \(ReminderDelivery.authoringGuidance)
        \(CalmVisualStyle.generationGuidance)
        """
}
struct BoundCardAction: Codable {
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "description":
                        "Unique local action ID matching data-action in HTML; not the observed DOM element ID",
                    "pattern": "^[a-zA-Z][a-zA-Z0-9_-]{0,31}$",
                ],
                "binding": PageBinding.schema, "submit": PageBinding.schema, "revealSource": ["type": "boolean"],
                "compactLabel": ["type": "string", "maxLength": 3,
                                 "description": "Offer one immediately usable page click on the capsule with a short label. Keep navigation and inputs on the expanded card."],
            ], "required": ["id", "binding"],
        ]
    }
    var id: String
    var binding: PageBinding
    var submit: PageBinding?
    var revealSource: Bool? = nil
    var compactLabel: String? = nil
    var compactPageURL: String? = nil
}

struct HTMLCardView: NSViewRepresentable {
    let markup: CardMarkup
    let compact: Bool
    let state: [String: String]
    let allowedActions: Set<String>
    var collectFields = false
    var measuresContent = false
    var mediaActions: [String: String] = [:]
    var appearance: AppAppearance = .system
    var accent = "#a49bdf"
    var reduceMotion = false
    var compactHasGlyph = true
    let action: (String, String?) -> Void
    var interaction: (Bool) -> Void = { _ in }
    var contentHeight: (Double) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "card")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        c.action = action
        c.interaction = interaction
        c.allowed = allowedActions
        c.contentHeight = contentHeight
        c.measuresHeight = (measuresContent || collectFields) && !compact
        let fragment = compact ? markup.compactHTML : markup.html
        let signature = fragment + markup.css + "\0" + (markup.interfaceLanguage ?? "")
        c.state = Self.renderState(state, compact: compact, appearance: appearance, accent: accent,
                                   formMode: collectFields, measureContent: c.measuresHeight,
                                   mediaActions: mediaActions, reduceMotion: reduceMotion, compactHasGlyph: compactHasGlyph)
        if signature != c.signature {
            c.signature = signature
            c.loaded = false
            view.loadHTMLString(Self.document(fragment: fragment, css: markup.css, language: markup.interfaceLanguage), baseURL: nil)
        } else {
            c.pushState()
        }
    }
    static func renderState(_ values: [String: String], compact: Bool, appearance: AppAppearance = .system,
                            accent: String = "#a49bdf", formMode: Bool = false, measureContent: Bool = false,
                            mediaActions: [String: String] = [:], reduceMotion: Bool = false, compactHasGlyph: Bool = true) -> [String: [String: String]] {
        ["values": values, "view": ["compact": String(compact), "appearance": appearance.rawValue,
            "accent": accent, "formMode": String(formMode), "measureContent": String(measureContent),
            "mediaActions": JSONText.encode(mediaActions), "reduceMotion": String(reduceMotion), "compactHasGlyph": String(compactHasGlyph)]]
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.interaction(false)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "card")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var signature = ""
        var state: [String: [String: String]] = [:]
        var lastState = ""
        var allowed: Set<String> = []
        var loaded = false
        var dragOrigin: NSPoint?
        var dragStart: NSPoint?
        var action: (String, String?) -> Void = { _, _ in }
        var interaction: (Bool) -> Void = { _ in }
        var contentHeight: (Double) -> Void = { _ in }
        var measuresHeight = false
        func pushState() {
            guard loaded, let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                let json = String(data: data, encoding: .utf8), json != lastState
            else { return }
            lastState = json
            view?.evaluateJavaScript("window.updateCard(\(json))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            lastState = ""
            pushState()
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                navigationAction.request.url?.scheme == "about" && navigationAction.navigationType == .other
                    ? .allow : .cancel)
        }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double, measuresHeight, height.isFinite {
                contentHeight(min(320, max(100, height)))
                return
            }
            if let phase = body["drag"] as? String {
                guard let window = view?.window, window.isVisible else { return }
                if phase == "end" {
                    (window as? ShellPanel)?.moveInteraction(false)
                    dragOrigin = nil
                    dragStart = nil
                    return
                }
                guard let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite else { return }
                if phase == "start" {
                    (window as? ShellPanel)?.moveInteraction(true)
                    dragOrigin = window.frame.origin
                    dragStart = NSPoint(x: x, y: y)
                } else if phase == "move", let origin = dragOrigin, let start = dragStart {
                    window.setFrameOrigin(NSPoint(x: origin.x + x - start.x, y: origin.y - y + start.y))
                }
                return
            }
            if let focus = body["focus"] as? Bool {
                interaction(focus)
                return
            }
            guard let id = body["action"] as? String, allowed.contains(id) else { return }
            guard let value = body["value"] as? String else {
                action(id, nil)
                return
            }
            guard value.utf8.count <= 131072 else { return }
            action(id, value)
        }
    }
    static func document(fragment: String, css: String, language: String? = nil) -> String {
        let nonce = UUID().uuidString
        let locale = language.flatMap { CardMarkup.localeIdentifier(for: $0) } ?? "en"
        let catalogs = fragment.contains("data-catalog") ? Dictionary(uniqueKeysWithValues: ChoiceCatalog.allCases.filter { fragment.contains($0.rawValue) }.map { ($0.rawValue, $0.choices(locale: Locale(identifier: locale))) }) : [:]
        let payload = JSONText.encode(["catalogs": catalogs, "locale": locale, "html": fragment, "css": css, "hostCSS": CalmVisualStyle.css])
            .replacingOccurrences(of: "<", with: "\\u003c")
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
            <style>
            :root{color-scheme:light dark;--accent:#a49bdf;--muted:#88858e;--line:#8882;--soft:#8881}
            *{box-sizing:border-box}html,body{margin:0;background:transparent;font:12px -apple-system,BlinkMacSystemFont,sans-serif;color:light-dark(#292832,#eeedf3);overflow:hidden;height:100%}body{padding:6px 8px}h1,h2,h3,p{margin:0}h1{font-size:24px}h2{font-size:16px}h3{font-size:13px}small{color:var(--muted);font-size:10px}button,input{font:inherit;color:inherit}button{border:1px solid var(--line);background:var(--soft);border-radius:9px;padding:6px 9px;cursor:pointer;min-height:28px}button:hover{background:color-mix(in srgb,var(--accent) 22%,transparent)}button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:1px}input{background:var(--soft);border:1px solid var(--line);border-radius:7px;padding:6px;max-width:100%}#surface{overflow:auto;height:100%;max-height:100%}button:disabled{opacity:.45}*{animation:none!important}:is(button,input,textarea,select){transition:background-color .14s ease,border-color .14s ease!important}html[data-reduce-motion=true] *{transition:none!important}
            html[data-compact="true"] body{padding:0;font-size:11px}html[data-compact="true"] #surface{overflow:hidden}html[data-compact="true"] h1,html[data-compact="true"] h2{font-size:14px}
            select[hidden]{display:none!important}.clock-zone .choice-trigger{grid-area:1/1/2/3}.data-input .choice-trigger{grid-area:2/1/3/3}.choice-trigger{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.choice-dialog{padding:8px;width:min(240px,92vw);max-height:92vh;background:Canvas;color:CanvasText;border:1px solid var(--line);border-radius:10px}.choice-dialog[open]{display:flex;flex-direction:column;gap:6px}.choice-dialog::backdrop{background:#5552}.choice-dialog div{overflow:auto}.choice-dialog input{flex:none;width:100%}.choice-dialog button{display:block;width:100%;text-align:start;background:transparent;border:0}.choice-dialog button:hover,.choice-dialog button:focus-visible{background:var(--soft)}
            </style></head><body><main id="surface"></main><script nonce="\(nonce)">
            const payload=\(payload);
            document.documentElement.lang=payload.locale;
            const permitted=new Set('DIV SPAN P STRONG EM SMALL SECTION HEADER FOOTER H1 H2 H3 BUTTON INPUT TEXTAREA SELECT OPTION LABEL UL OL LI BR HR TABLE CAPTION THEAD TBODY TR TH TD FIGURE FIGCAPTION'.split(' '));
            const attributes=new Set(['class','style','title','aria-label','role','scope','data-catalog','data-column','data-series','data-x','data-x-format','data-action','data-field','data-input','data-change','data-bind','placeholder','type','value','min','max','step','rows','required','selected','checked']);
            const safeCSS=s=>!/[\\\\@]|url\\s*\\(|expression\\s*\\(|image-set\\s*\\(|position\\s*:\\s*(fixed|absolute)/i.test(s);
            \(CalmVisualStyle.harmonizeScript)
            const template=document.createElement('template');template.innerHTML=payload.html;
            function clean(node){
              if(node.nodeType===3)return document.createTextNode(node.textContent);
              if(node.nodeType!==1||!permitted.has(node.tagName))return document.createTextNode('');
              const el=document.createElement(node.tagName.toLowerCase());
              for(const a of node.attributes)if(attributes.has(a.name)&& (a.name!=='style'||safeCSS(a.value)))el.setAttribute(a.name,a.value);
              harmonize(el.style);
              if(el.tagName==='BUTTON')el.type='button';
              if(el.tagName==='INPUT'&&!['text','number','range','checkbox','date','time'].includes(el.type))el.type='text';
              for(const ch of node.childNodes)el.appendChild(clean(ch));return el;
            }
            for(const ch of template.content.childNodes)document.querySelector('#surface').appendChild(clean(ch));
            for (const select of document.querySelectorAll('select[data-field]')) {
                const rows = payload.catalogs[select.dataset.catalog];
                if (Array.isArray(rows)) {
                    const prior = [...select.options];
                    select.replaceChildren();
                    for (const [value,label,aliases] of rows) {
                        const option = new Option(label,value);
                        option.dataset.aliases = aliases;
                        select.add(option);
                    }
                    for (const option of prior) if (![...select.options].some(o=>o.value===option.value)) select.add(option);
                }
                if (select.options.length > 1) installPicker(select);
            }
            function installPicker(select) {
                const trigger = document.createElement('button');
                trigger.type = 'button';
                trigger.className = 'choice-trigger';
                trigger.setAttribute('aria-label',select.getAttribute('aria-label') || select.dataset.field);
                trigger.setAttribute('aria-haspopup','dialog');
                select.hidden = true;
                select.after(trigger);
                select.syncLabel = () => { trigger.textContent = select.selectedOptions[0]?.text || '…'; };
                select.syncLabel();
                trigger.addEventListener('click', event => {
                    event.preventDefault();
                    const dialog = document.createElement('dialog'), search = document.createElement('input'), list = document.createElement('div');
                    dialog.className = 'choice-dialog';
                    dialog.setAttribute('aria-label',trigger.getAttribute('aria-label'));
                    search.type = 'search';
                    search.placeholder = payload.locale.startsWith('zh') ? '搜索' : 'Search';
                    search.setAttribute('aria-label', search.placeholder);
                    function filter() {
                        list.replaceChildren();
                        const query = search.value.trim().toLocaleLowerCase();
                        for (const option of select.options) {
                            const terms = [option.text,option.value,option.dataset.aliases || ''].join(' ').toLocaleLowerCase();
                            if (!terms.includes(query)) continue;
                            const button = document.createElement('button');
                            button.type = 'button'; button.textContent = option.text; button.value = option.value;
                            button.addEventListener('click', () => {
                                select.value = option.value;
                                select.syncLabel();
                                dialog.close();
                                select.dispatchEvent(new Event('input',{bubbles:true}));
                                select.dispatchEvent(new Event('change',{bubbles:true}));
                            });
                            list.append(button);
                        }
                        if (!list.childElementCount) list.textContent = payload.locale.startsWith('zh') ? '没有匹配项' : 'No matches';
                    }
                    search.oninput = filter;
                    search.onkeydown = e => { if (e.key==='ArrowDown') { e.preventDefault(); list.firstElementChild?.focus(); } };
                    dialog.onclose = () => { dialog.remove(); trigger.focus(); };
                    const searchable = select.options.length > 16 || select.hasAttribute('data-catalog');
                    if (searchable) dialog.append(search);
                    dialog.append(list); document.body.append(dialog); filter(); dialog.showModal();
                    if (searchable) search.focus(); else list.querySelector('button')?.focus();
                    dialog.addEventListener('click', e => {
                        if (e.target !== dialog) return;
                        const r = dialog.getBoundingClientRect();
                        if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) dialog.close();
                    });
                });
            }
            const hostGlance = document.querySelector('#surface > .calm-glance .calm-value') !== null;
            let customStyle;
            if(safeCSS(payload.css)){
              const style=document.createElement('style');style.textContent=payload.css;document.head.appendChild(style);customStyle=style;
              const harmonizeRules=rules=>{for(const rule of rules){if(rule.style)harmonize(rule.style);if(rule.cssRules)harmonizeRules(rule.cssRules)}};
              if(style.sheet)harmonizeRules(style.sheet.cssRules);
            }
            const hostStyle=document.createElement("style");hostStyle.textContent=payload.hostCSS;document.head.appendChild(hostStyle);
            \(CardVisuals.script)
            function compactTimestamp(value) {
                // ISO wall time belongs to the source zone. Preserve it when shortening a capsule.
                const match = /^(\\d{4})-(\\d{2}-\\d{2})T(\\d{2}:\\d{2}):\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?$/.exec(value);
                return match ? match[2] + ' ' + match[3] : value;
            }
            // A long secondary reading should not displace the primary result or its controls.
            // Retain the original bound node so a live update respects the user's disclosure state.
            const supportingReadings = Array.from(document.querySelectorAll('.calm-form .form-details > .calm-result')).flatMap(group => {
              const label = group.querySelector(':scope > small.calm-label');
              const body = group.querySelector(':scope > div');
              const value = body?.querySelector('.form-value[data-bind]');
              return label && !label.querySelector('button,a') && body && value ? [{group, label, body, value, disclosure:null}] : [];
            });
            function updateSupportingReadings() {
              for (const reading of supportingReadings) {
                const {group, label, body, value, disclosure} = reading;
                const long = value.textContent.trimEnd().split('\\n').length > 3;
                if (long && !disclosure) {
                  const details = document.createElement('details');
                  details.className = 'supporting-reading';
                  const summary = document.createElement('summary');
                  summary.append(label);
                  details.append(summary, body);
                  group.append(details);
                  details.addEventListener('toggle', reportHeight);
                  reading.disclosure = details;
                } else if (!long && disclosure) {
                  disclosure.replaceWith(label, body);
                  reading.disclosure = null;
                }
              }
            }
            function updateUnitSuffixes(){
              for(const unit of document.querySelectorAll('.preset-unit,.preset-unit-suffix')){
                const value=unit.previousElementSibling?.textContent.trim()||'';
                const suffix=unit.textContent.trim();
                // Formatted readings may put the unit before the number or inside a short status.
                const words=value.toLocaleLowerCase().split(/[^\\p{L}\\p{N}°%]+/u);
                if(unit.classList.contains('raw-value-unit')){
                  unit.hidden=!/^[+−-]?[0-9][0-9.,'\\s]*$/.test(value);
                  continue;
                }
                unit.hidden=!!suffix && (value.endsWith(suffix) || words.includes(suffix.toLocaleLowerCase()) ||
                  (value.startsWith(suffix) && /^[0-9.,+-]/.test(value.slice(suffix.length).trimStart())));
              }
            }
            const journal=document.querySelector('.calm-journal');
            function updateJournal(serialized) {
              if(!journal || journal.dataset.records===serialized)return;
              journal.dataset.records=serialized;
              const list=journal.querySelector('ol'), undo=journal.querySelector('button');
              if(!list || !undo)return;
              let rows=[];
              try { rows=JSON.parse(serialized || '[]') } catch {}
              if(!Array.isArray(rows))rows=[];
              journal.hidden=rows.length===0;
              undo.disabled=journal.hidden;
              list.replaceChildren();
              const number=new Intl.NumberFormat(payload.locale,{signDisplay:'exceptZero',maximumSignificantDigits:12});
              const now=new Date(), unit=document.querySelector('.calm-result .raw-value-unit')?.textContent;
              for(const entry of rows){
                const row=document.createElement('li'), value=document.createElement('strong'), stamp=document.createElement('time');
                const date=new Date(entry.time);
                if(!Number.isFinite(entry.change) || !Number.isFinite(date.getTime()))continue;
                row.className='calm-journal-row';
                value.textContent=number.format(entry.change)+(unit?' '+unit:'');
                const format={hour:'numeric',minute:'2-digit'};
                if(date.toDateString()!==now.toDateString()){format.month='short';format.day='numeric'}
                stamp.dateTime=date.toISOString();
                stamp.textContent=new Intl.DateTimeFormat(payload.locale,format).format(date);
                row.append(value,stamp);list.append(row);
              }
            }
            window.updateCard=({values:s,view})=>{if(customStyle && hostGlance)customStyle.disabled=view.compact==='true';document.documentElement.dataset.reduceMotion=view.reduceMotion||'false';window.measureContent=view.measureContent==='true';window.formMode=view.formMode==='true';if(window.formMode)for(const el of document.querySelectorAll('[data-field]'))if(Object.hasOwn(s,el.dataset.field)&&document.activeElement!==el&&!el.dataset.dirty){if(el.type==='checkbox')el.checked=s[el.dataset.field]==='true'||s[el.dataset.field]==='1';else el.value=s[el.dataset.field];el.syncLabel?.()};document.documentElement.style.setProperty('--glance-inset',view.compactHasGlyph==='false'?'0px':'26px');window.isCompact=view.compact==='true';document.documentElement.dataset.compact=String(window.isCompact);for(const el of document.querySelectorAll('[data-bind]')){el.textContent=Object.hasOwn(s,el.dataset.bind)?(window.isCompact?compactTimestamp(s[el.dataset.bind]):s[el.dataset.bind]):'—';el.dataset.longValue=String(el.textContent.length>48)};updateUnitSuffixes();updateSupportingReadings();updateVisuals(s);updateJournal(s.journalRecent);const playing=s.mediaPlaying==='true';for(const [id,op] of Object.entries(JSON.parse(view.mediaActions||'{}'))){if(!['toggle','play','pause','mute','unmute','toggleMute'].includes(op))continue;for(const b of document.querySelectorAll('button[data-action]')){if(b.dataset.action!==id)continue;if(['mute','unmute','toggleMute'].includes(op)){const muted=s.mediaMuted==='true',label=op==='unmute'||(op==='toggleMute'&&muted)?'Unmute':'Mute';b.textContent=label;b.setAttribute('aria-label',label);b.title=label;b.disabled=op==='mute'?muted:op==='unmute'?!muted:false;continue}const pause=op==='pause'||(op==='toggle'&&playing),label=pause?'Pause':'Play';b.classList.add('calm-transport');b.dataset.playing=String(pause);b.setAttribute('aria-label',label);b.title=label;b.disabled=op==='pause'?!playing:op==='play'?playing:false;b.replaceChildren();const icon=document.createElement('span');icon.className='calm-transport-icon';icon.setAttribute('aria-hidden','true');const text=document.createElement('span');text.textContent=label;b.append(icon,text)}}document.documentElement.style.colorScheme=view.appearance==='system'?'light dark':view.appearance;document.documentElement.style.setProperty('--accent',view.accent||'#a49bdf');reportHeight();requestAnimationFrame(reportHeight);};
            let lastHeight=0;
            function reportHeight(){if(!window.measureContent||window.isCompact||document.querySelector('#surface').clientWidth===0)return;const surface=document.querySelector('#surface'),top=surface.getBoundingClientRect().top,style=getComputedStyle(document.body);const height=Math.ceil(Math.max(0,...[...surface.children].map(n=>n.getBoundingClientRect().bottom-top+(parseFloat(getComputedStyle(n).marginBottom)||0)))+parseFloat(style.paddingTop)+parseFloat(style.paddingBottom));if(Math.abs(height-lastHeight)>1){lastHeight=height;window.webkit.messageHandlers.card.postMessage({height})}}
            const sizeObserver=new ResizeObserver(reportHeight);sizeObserver.observe(document.querySelector('#surface'));for(const child of document.querySelector('#surface').children)sizeObserver.observe(child);
            function submitAction(id,automatic=false){const fields=[...document.querySelectorAll('[data-field]')];if(!automatic&&window.formMode&&fields.some(n=>!n.reportValidity()))return;const value=window.formMode?JSON.stringify(Object.fromEntries(fields.map(n=>[n.dataset.field,n.type==='checkbox'?String(n.checked):n.value]))):fields.find(n=>n.dataset.field===id)?.value||null;for(const field of fields)delete field.dataset.dirty;window.webkit.messageHandlers.card.postMessage({action:id,value})}
            let inputTimer;document.addEventListener('input',e=>{if(e.target.dataset.field)e.target.dataset.dirty='true';if(e.target.dataset.input&&!e.isComposing){clearTimeout(inputTimer);const id=e.target.dataset.input;inputTimer=setTimeout(()=>submitAction(id,true),220)}});document.addEventListener('change',e=>{if(e.target.dataset.change){clearTimeout(inputTimer);submitAction(e.target.dataset.change,true)}});
            document.addEventListener('click',e=>{const b=e.target.closest('[data-action]');if(!b){if(window.isCompact&&!['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({action:'expand'});return;}submitAction(b.dataset.action)});
            let drag=null;
            document.addEventListener('mousedown',e=>{if(e.button!==0||e.altKey||e.target.closest('button,input,textarea,select,summary,[data-action],[data-field]'))return;const surface=document.querySelector('#surface');if(surface.scrollHeight>surface.clientHeight&&e.clientX>=surface.getBoundingClientRect().right-12)return;drag={x:e.screenX,y:e.screenY,moved:false};window.webkit.messageHandlers.card.postMessage({drag:'start',x:e.screenX,y:e.screenY})});
            document.addEventListener('mousemove',e=>{if(!drag)return;if(!drag.moved&&Math.hypot(e.screenX-drag.x,e.screenY-drag.y)<5)return;drag.moved=true;window.getSelection()?.removeAllRanges();window.webkit.messageHandlers.card.postMessage({drag:'move',x:e.screenX,y:e.screenY})});
            document.addEventListener('mouseup',()=>{if(!drag)return;drag=null;window.webkit.messageHandlers.card.postMessage({drag:'end'})});
            document.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.tagName==='INPUT'&&e.target.dataset.field){const id=window.formMode?(e.target.dataset.input||e.target.dataset.change||document.querySelector('button[data-action]')?.dataset.action):e.target.dataset.field;if(id){e.preventDefault();clearTimeout(inputTimer);submitAction(id)}}});
            document.addEventListener('focusin',e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({focus:true})});
            document.addEventListener('focusout',e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({focus:false})});
            </script></body></html>
            """
    }
}
