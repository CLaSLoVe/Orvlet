import SwiftUI
import WebKit

/// The model owns the structure; the host owns execution, typography and lifecycle.
struct CardMarkup: Codable, Equatable {
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "html": ["type": "string"],
                "compactHTML": [
                    "type": "string",
                    "description": "Required read-only compact glance, bound to live state; not a duplicate full panel",
                ],
                "css": ["type": "string"], "height": ["type": "number"],
            ], "required": ["html"],
        ]
    }
    var html: String
    var compactHTML: String = ""
    var css: String
    var height: Double = 170
    var bindingKeys: Set<String> { Self.bindingKeys(in: html + compactHTML) }
    static func bindingKeys(in source: String) -> Set<String> {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"data-bind\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        else { return [] }
        return Set(
            regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                Range($0.range(at: 1), in: source).map { String(source[$0]) }
            })
    }
    func hasSameDesign(as other: CardMarkup) -> Bool {
        html == other.html && compactHTML == other.compactHTML && css == other.css
    }
    func validateBindings(available: Set<String>, requiredLive: Set<String> = []) throws {
        guard bindingKeys.isSubset(of: available) else {
            throw AppError.message(
                "Unknown live fields: " + bindingKeys.subtracting(available).sorted().joined(separator: ", "))
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
    enum CodingKeys: String, CodingKey { case html, compactHTML, css, height }
    init(html: String, compactHTML: String = "", css: String, height: Double = 170) {
        self.html = html
        self.compactHTML = compactHTML
        self.css = css
        self.height = height
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        html = try c.decode(String.self, forKey: .html)
        compactHTML = try c.decodeIfPresent(String.self, forKey: .compactHTML) ?? ""
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
        Generate a genuinely task-specific HTML/CSS card, not a fixed toolbar template. Return markup: {html, css, height}. html is the interaction fragment (100–320px tall, 300px wide). The host provides instant native media/timer controls. For other webpage tasks also return compactHTML: a read-only 82×28px glimpse of the task’s most useful live value. This is not a fixed mode: generate structure appropriate to the actual intent. Use shared CSS scoped to separate compact/expanded classes. Keep compactHTML free of buttons and inputs. Design hierarchy and grouping appropriate to the task. Use flex/grid, text, buttons, small badges; no headings about the app, dashboards, decorative subtitles, progress bars for music, or endless animation. Use English for all UI labels unless the human explicitly requests another language. Inherit the system font and primary text color. --accent and --muted are text colors; --soft and --line are translucent backgrounds/borders ONLY, never text colors. Use at most three actions; avoid menus of every website feature. No JS, event attributes, external assets, URLs, SVG, iframe, style tags or remote CSS. Tags allowed: div, span, p, strong, em, small, section, header, footer, h1,h2,h3, button, input, textarea, select, option, label, ul,ol,li,br,hr. Every interactive button must have data-action="an allowed action id". Inputs use data-field="a declared field key" for local forms, or the corresponding binding action ID for webpage controls; registered actions receive their values. Native host handles actual execution. Use supplied state keys, including host runtime source keys, with data-bind for changing facts. title/status/detail are host keys; remaining/toggleLabel are for native tasks. Never invent facts. All visible factual text must be grounded in supplied state; dynamic facts should use data-bind. For media cards, title and status MUST use data-bind="title" and data-bind="status". Sound buttons should use media operation toggleMute with data-bind="muteLabel", never a webpage button name that changes after muting. Playback buttons should bind the media toggle operation: the host supplies their live Play/Pause icon and label. Never write a literal song name, artist, duration or Playing/Paused into the markup; omit unsupported metadata or bind a verified reading. Use one title, one muted status, and a clean control row, no nested button panels. Do not place overlays over controls. Use modest spacing and comfortable click targets. Keep layout stable while state updates; the host supplies restrained interaction transitions; do not author your own animations. This is a side-screen tool, designed to be understood at a glance.
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
            ], "required": ["id", "binding"],
        ]
    }
    var id: String
    var binding: PageBinding
    var submit: PageBinding?
    var revealSource: Bool? = nil
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
        let signature = fragment + markup.css
        c.state = state.merging([
            "appearance": appearance.rawValue, "accent": accent, "compact": compact ? "true" : "false",
            "formMode": collectFields ? "true" : "false", "measureContent": c.measuresHeight ? "true" : "false",
            "mediaActions": JSONText.encode(mediaActions), "reduceMotion": reduceMotion ? "true" : "false",
        ]) { _, new in new }
        if signature != c.signature {
            c.signature = signature
            c.loaded = false
            view.loadHTMLString(Self.document(fragment: fragment, css: markup.css), baseURL: nil)
        } else {
            c.pushState()
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.interaction(false)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "card")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var signature = ""
        var state: [String: String] = [:]
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
                    dragOrigin = nil
                    dragStart = nil
                    return
                }
                guard let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite else { return }
                if phase == "start" {
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
    static func document(fragment: String, css: String) -> String {
        let nonce = UUID().uuidString
        let payload = JSONText.encode(["html": fragment, "css": css, "hostCSS": CalmVisualStyle.css])
            .replacingOccurrences(of: "<", with: "\\u003c")
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
            <style>
            :root{color-scheme:light dark;--accent:#a49bdf;--muted:#88858e;--line:#8882;--soft:#8881}
            *{box-sizing:border-box}html,body{margin:0;background:transparent;font:12px -apple-system,BlinkMacSystemFont,sans-serif;color:light-dark(#292832,#eeedf3);overflow:hidden;height:100%}body{padding:6px 8px}h1,h2,h3,p{margin:0}h1{font-size:24px}h2{font-size:16px}h3{font-size:13px}small{color:var(--muted);font-size:10px}button,input{font:inherit;color:inherit}button{border:1px solid var(--line);background:var(--soft);border-radius:9px;padding:6px 9px;cursor:pointer;min-height:28px}button:hover{background:color-mix(in srgb,var(--accent) 22%,transparent)}button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:1px}input{background:var(--soft);border:1px solid var(--line);border-radius:7px;padding:6px;max-width:100%}#surface{overflow:auto;height:100%;max-height:100%}button:disabled{opacity:.45}*{animation:none!important}:is(button,input,textarea,select){transition:background-color .14s ease,border-color .14s ease!important}html[data-reduce-motion=true] *{transition:none!important}
            html[data-compact="true"] body{padding:0;font-size:11px}html[data-compact="true"] #surface{overflow:hidden}html[data-compact="true"] h1,html[data-compact="true"] h2{font-size:14px}
            </style></head><body><main id="surface"></main><script nonce="\(nonce)">
            const payload=\(payload);
            const permitted=new Set('DIV SPAN P STRONG EM SMALL SECTION HEADER FOOTER H1 H2 H3 BUTTON INPUT TEXTAREA SELECT OPTION LABEL UL OL LI BR HR'.split(' '));
            const attributes=new Set(['class','style','title','aria-label','role','data-action','data-field','data-input','data-change','data-bind','placeholder','type','value','min','max','step','rows','required','selected','checked']);
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
            if(safeCSS(payload.css)){
              const style=document.createElement('style');style.textContent=payload.css;document.head.appendChild(style);
              const harmonizeRules=rules=>{for(const rule of rules){if(rule.style)harmonize(rule.style);if(rule.cssRules)harmonizeRules(rule.cssRules)}};
              if(style.sheet)harmonizeRules(style.sheet.cssRules);
            }
            const hostStyle=document.createElement("style");hostStyle.textContent=payload.hostCSS;document.head.appendChild(hostStyle);
            window.updateCard=s=>{document.documentElement.dataset.reduceMotion=s.reduceMotion||'false';window.measureContent=s.measureContent==='true';window.formMode=s.formMode==='true';if(window.formMode)for(const el of document.querySelectorAll('[data-field]'))if(Object.hasOwn(s,el.dataset.field)&&document.activeElement!==el&&!el.dataset.dirty){if(el.type==='checkbox')el.checked=s[el.dataset.field]==='true'||s[el.dataset.field]==='1';else el.value=s[el.dataset.field]};window.isCompact=s.compact==='true';document.documentElement.dataset.compact=String(window.isCompact);for(const el of document.querySelectorAll('[data-bind]'))el.textContent=Object.hasOwn(s,el.dataset.bind)?s[el.dataset.bind]:'—';const playing=s.mediaPlaying==='true';for(const [id,op] of Object.entries(JSON.parse(s.mediaActions||'{}'))){if(!['toggle','play','pause','mute','unmute','toggleMute'].includes(op))continue;for(const b of document.querySelectorAll('button[data-action]')){if(b.dataset.action!==id)continue;if(['mute','unmute','toggleMute'].includes(op)){const muted=s.mediaMuted==='true',label=op==='unmute'||(op==='toggleMute'&&muted)?'Unmute':'Mute';b.textContent=label;b.setAttribute('aria-label',label);b.title=label;b.disabled=op==='mute'?muted:op==='unmute'?!muted:false;continue}const pause=op==='pause'||(op==='toggle'&&playing),label=pause?'Pause':'Play';b.classList.add('calm-transport');b.dataset.playing=String(pause);b.setAttribute('aria-label',label);b.title=label;b.disabled=op==='pause'?!playing:op==='play'?playing:false;b.replaceChildren();const icon=document.createElement('span');icon.className='calm-transport-icon';icon.setAttribute('aria-hidden','true');const text=document.createElement('span');text.textContent=label;b.append(icon,text)}}document.documentElement.style.colorScheme=s.appearance==='system'?'light dark':s.appearance;document.documentElement.style.setProperty('--accent',s.accent||'#a49bdf');reportHeight();requestAnimationFrame(reportHeight);};
            let lastHeight=0;
            function reportHeight(){if(!window.measureContent||window.isCompact||document.querySelector('#surface').clientWidth===0)return;const surface=document.querySelector('#surface'),top=surface.getBoundingClientRect().top,style=getComputedStyle(document.body);const height=Math.ceil(Math.max(0,...[...surface.children].map(n=>n.getBoundingClientRect().bottom-top+(parseFloat(getComputedStyle(n).marginBottom)||0)))+parseFloat(style.paddingTop)+parseFloat(style.paddingBottom));if(Math.abs(height-lastHeight)>1){lastHeight=height;window.webkit.messageHandlers.card.postMessage({height})}}
            const sizeObserver=new ResizeObserver(reportHeight);sizeObserver.observe(document.querySelector('#surface'));for(const child of document.querySelector('#surface').children)sizeObserver.observe(child);
            function submitAction(id,automatic=false){const fields=[...document.querySelectorAll('[data-field]')];if(!automatic&&window.formMode&&fields.some(n=>!n.reportValidity()))return;const value=window.formMode?JSON.stringify(Object.fromEntries(fields.map(n=>[n.dataset.field,n.type==='checkbox'?String(n.checked):n.value]))):fields.find(n=>n.dataset.field===id)?.value||null;for(const field of fields)delete field.dataset.dirty;window.webkit.messageHandlers.card.postMessage({action:id,value})}
            let inputTimer;document.addEventListener('input',e=>{if(e.target.dataset.field)e.target.dataset.dirty='true';if(e.target.dataset.input&&!e.isComposing){clearTimeout(inputTimer);const id=e.target.dataset.input;inputTimer=setTimeout(()=>submitAction(id,true),220)}});document.addEventListener('change',e=>{if(e.target.dataset.change){clearTimeout(inputTimer);submitAction(e.target.dataset.change,true)}});
            document.addEventListener('click',e=>{const b=e.target.closest('[data-action]');if(!b){if(window.isCompact&&!['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({action:'expand'});return;}submitAction(b.dataset.action)});
            let drag=null;
            document.addEventListener('mousedown',e=>{if(e.button!==0||e.altKey||e.target.closest('button,input,textarea,select,[data-action],[data-field]'))return;const surface=document.querySelector('#surface');if(surface.scrollHeight>surface.clientHeight&&e.clientX>=surface.getBoundingClientRect().right-12)return;drag={x:e.screenX,y:e.screenY,moved:false};window.webkit.messageHandlers.card.postMessage({drag:'start',x:e.screenX,y:e.screenY})});
            document.addEventListener('mousemove',e=>{if(!drag)return;if(!drag.moved&&Math.hypot(e.screenX-drag.x,e.screenY-drag.y)<5)return;drag.moved=true;window.getSelection()?.removeAllRanges();window.webkit.messageHandlers.card.postMessage({drag:'move',x:e.screenX,y:e.screenY})});
            document.addEventListener('mouseup',()=>{if(!drag)return;drag=null;window.webkit.messageHandlers.card.postMessage({drag:'end'})});
            document.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.tagName==='INPUT'&&e.target.dataset.field){const id=window.formMode?(e.target.dataset.input||e.target.dataset.change||document.querySelector('button[data-action]')?.dataset.action):e.target.dataset.field;if(id){e.preventDefault();clearTimeout(inputTimer);submitAction(id)}}});
            document.addEventListener('focusin',e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({focus:true})});
            document.addEventListener('focusout',e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))window.webkit.messageHandlers.card.postMessage({focus:false})});
            </script></body></html>
            """
    }
}
