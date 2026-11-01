import SwiftUI
import WebKit

/// The model owns the structure; the host owns execution, typography and lifecycle.
struct CardMarkup: Codable, Equatable {
    var html: String
    var compactHTML: String = ""
    var css: String
    var height: Double = 170
    enum CodingKeys: String, CodingKey { case html, compactHTML, css, height }
    init(html: String, compactHTML: String = "", css: String, height: Double = 170) {
        self.html = html; self.compactHTML = compactHTML; self.css = css; self.height = height
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        html = try c.decode(String.self,forKey:.html)
        compactHTML = try c.decodeIfPresent(String.self,forKey:.compactHTML) ?? ""
        css = try c.decodeIfPresent(String.self,forKey:.css) ?? ""
        height = try c.decodeIfPresent(Double.self,forKey:.height) ?? 170
    }
    func validated() throws -> CardMarkup {
        guard !html.isEmpty, html.utf8.count < 24000,
              compactHTML.utf8.count < 8000, css.utf8.count < 12000, height.isFinite else {
            throw AgentError.message("Keep the generated interaction card small.")
        }
        let combined = (html + compactHTML + css).lowercased()
        // Runtime sanitization and CSP are independent defenses. No model-authored scripts.
        guard !["<script", "<iframe", "<object", "<embed", "<svg", "<math", "javascript:", "@import", "url(", "expression(", "<link", "<meta", "<img", "<style"].contains(where: combined.contains) else {
            throw AgentError.message("Cards support HTML and local CSS only, without scripts or external resources.")
        }
        var value = self; value.height = min(320, max(100, height)); return value
    }
    func validateActions(_ allowed: Set<String>) throws {
        let source = html + compactHTML
        let regex = try NSRegularExpression(pattern:#"data-(?:action|field)\s*=\s*["']([^"']+)["']"#,options:.caseInsensitive)
        for match in regex.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
            guard let range = Range(match.range(at:1),in:source), allowed.contains(String(source[range])) else {
                throw AgentError.message("Every generated control must reference a registered action ID.")
            }
        }
        let buttons = try NSRegularExpression(pattern:#"<button\b[^>]*>"#,options:.caseInsensitive)
        for match in buttons.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
            guard let range = Range(match.range,in:source), source[range].range(of:#"data-action\s*=\s*["'][^"']+["']"#,options:[.regularExpression,.caseInsensitive]) != nil else {
                throw AgentError.message("Every button, including compact buttons, needs data-action with a registered ID. Use plain text for noninteractive labels.")
            }
        }
        if source.range(of:#"\son[a-z]+\s*="# , options:[.regularExpression,.caseInsensitive]) != nil {
            throw AgentError.message("Use data-action instead of JavaScript event attributes.")
        }
    }
    static let prompt = """
    Generate a genuinely task-specific HTML/CSS card, not a fixed toolbar template. Return markup: {html, css, height}. html is the interaction fragment (100–320px tall, 300px wide). The host provides instant native media/timer controls. For other webpage tasks also return compactHTML: a read-only 82×28px glimpse of the task’s most useful live value. This is not a fixed mode: generate structure appropriate to the actual intent. Use shared CSS scoped to separate compact/expanded classes. Keep compactHTML free of buttons and inputs. Design hierarchy and grouping appropriate to the task. Use flex/grid, text, buttons, small badges; no headings about the app, dashboards, decorative subtitles, progress bars for music, or endless animation. Use English for all UI labels unless the human explicitly requests another language. Inherit the system font and primary text color. --accent and --muted are text colors; --soft and --line are translucent backgrounds/borders ONLY, never text colors. Use at most three actions; avoid menus of every website feature. No JS, event attributes, external assets, URLs, SVG, iframe, style tags or remote CSS. Tags allowed: div, span, p, strong, em, small, section, header, footer, h1,h2,h3, button, input, label, ul,ol,li,br,hr. Every interactive button must have data-action="an allowed action id". Inputs use data-field="an action id"; the action receives that value. Native host handles actual execution. Use data-bind="title", "status", "remaining", "detail" or "toggleLabel" for changing facts. Never invent facts. All visible factual text must be grounded in supplied state; dynamic facts should use data-bind. Do not place overlays over controls. Use modest spacing and comfortable click targets. Keep layout stable while state updates; no animation or transitions. This is a side-screen tool, designed to be understood at a glance.
    \(CalmVisualStyle.generationGuidance)
    """
}
struct BoundCardAction: Codable {
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
    var appearance: AppAppearance = .system
    var accent = "#a49bdf"
    let action: (String, String?) -> Void
    var interaction: (Bool) -> Void = { _ in }
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
        c.action = action; c.interaction = interaction; c.allowed = allowedActions
        let fragment = compact ? markup.compactHTML : markup.html
        let signature = fragment + markup.css
        c.state = state.merging(["appearance": appearance.rawValue, "accent": accent, "compact":compact ? "true" : "false"]) { _, new in new }
        if signature != c.signature {
            c.signature = signature; c.loaded = false
            view.loadHTMLString(Self.document(fragment: fragment, css: markup.css), baseURL: nil)
        } else { c.pushState() }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.interaction(false)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "card")
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var signature = ""
        var state: [String:String] = [:]
        var lastState = ""
        var allowed: Set<String> = []
        var loaded = false
        var dragOrigin: NSPoint?
        var dragStart: NSPoint?
        var action: (String, String?) -> Void = { _, _ in }
        var interaction: (Bool) -> Void = { _ in }
        func pushState() {
            guard loaded, let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8), json != lastState else { return }
            lastState = json
            view?.evaluateJavaScript("window.updateCard(\(json))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true; lastState = ""; pushState()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" && navigationAction.navigationType == .other ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String:Any] else { return }
            if let phase = body["drag"] as? String {
                guard let window = view?.window, window.isVisible else { return }
                if phase == "end" { dragOrigin = nil; dragStart = nil; return }
                guard let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite else { return }
                if phase == "start" { dragOrigin = window.frame.origin; dragStart = NSPoint(x:x,y:y) }
                else if phase == "move", let origin = dragOrigin, let start = dragStart {
                    window.setFrameOrigin(NSPoint(x:origin.x+x-start.x,y:origin.y-y+start.y))
                }
                return
            }
            if let focus = body["focus"] as? Bool { interaction(focus); return }
            guard let id = body["action"] as? String, allowed.contains(id) else { return }
            action(id, (body["value"] as? String).map { String($0.prefix(2000)) })
        }
    }
    static func document(fragment: String, css: String) -> String {
        let nonce = UUID().uuidString
        let payload = AgentController.json(["html":fragment,"css":css,"hostCSS":CalmVisualStyle.css]).replacingOccurrences(of: "<", with: "\\u003c")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root{color-scheme:light dark;--accent:#a49bdf;--muted:#88858e;--line:#8882;--soft:#8881}
        *{box-sizing:border-box}html,body{margin:0;background:transparent;font:12px -apple-system,BlinkMacSystemFont,sans-serif;color:light-dark(#292832,#eeedf3);overflow:hidden;height:100%}body{padding:6px 8px}h1,h2,h3,p{margin:0}h1{font-size:24px}h2{font-size:16px}h3{font-size:13px}small{color:var(--muted);font-size:10px}button,input{font:inherit;color:inherit}button{border:1px solid var(--line);background:var(--soft);border-radius:9px;padding:6px 9px;cursor:pointer;min-height:28px}button:hover{background:color-mix(in srgb,var(--accent) 22%,transparent)}button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:1px}input{background:var(--soft);border:1px solid var(--line);border-radius:7px;padding:6px;max-width:100%}#surface{overflow:auto;height:100%;max-height:100%}button:disabled{opacity:.45}*{animation:none!important;transition:none!important}
        html[data-compact="true"] body{padding:0;font-size:11px}html[data-compact="true"] #surface{overflow:hidden}html[data-compact="true"] h1,html[data-compact="true"] h2{font-size:14px}
        </style></head><body><main id="surface"></main><script nonce="\(nonce)">
        const payload=\(payload);
        const permitted=new Set('DIV SPAN P STRONG EM SMALL SECTION HEADER FOOTER H1 H2 H3 BUTTON INPUT LABEL UL OL LI BR HR'.split(' '));
        const attributes=new Set(['class','style','title','aria-label','role','data-action','data-field','data-bind','placeholder','type','value','min','max','step']);
        const safeCSS=s=>!/[\\\\@]|url\\s*\\(|expression\\s*\\(|image-set\\s*\\(|position\\s*:\\s*(fixed|absolute)/i.test(s);
        const template=document.createElement('template');template.innerHTML=payload.html;
        function clean(node){
          if(node.nodeType===3)return document.createTextNode(node.textContent);
          if(node.nodeType!==1||!permitted.has(node.tagName))return document.createTextNode('');
          const el=document.createElement(node.tagName.toLowerCase());
          for(const a of node.attributes)if(attributes.has(a.name)&& (a.name!=='style'||safeCSS(a.value)))el.setAttribute(a.name,a.value);
          if(el.tagName==='BUTTON')el.type='button';
          if(el.tagName==='INPUT'&&!['text','number','range'].includes(el.type))el.type='text';
          for(const ch of node.childNodes)el.appendChild(clean(ch));return el;
        }
        for(const ch of template.content.childNodes)document.querySelector('#surface').appendChild(clean(ch));
        if(safeCSS(payload.css)){const style=document.createElement('style');style.textContent=payload.css.replace(/(^|[;{])\\s*color\\s*:\\s*var\\(--(?:soft|line)\\)/gi,'$1color:inherit');document.head.appendChild(style)}
        const hostStyle=document.createElement("style");hostStyle.textContent=payload.hostCSS;document.head.appendChild(hostStyle);
        window.updateCard=s=>{window.isCompact=s.compact==='true';document.documentElement.dataset.compact=String(window.isCompact);for(const el of document.querySelectorAll('[data-bind]'))if(Object.hasOwn(s,el.dataset.bind))el.textContent=s[el.dataset.bind];document.documentElement.style.colorScheme=s.appearance==='system'?'light dark':s.appearance;document.documentElement.style.setProperty('--accent',s.accent||'#a49bdf');};
        document.addEventListener('click',e=>{const b=e.target.closest('[data-action]');if(!b){if(window.isCompact&&e.target.tagName!=='INPUT')window.webkit.messageHandlers.card.postMessage({action:'expand'});return;}const field=[...document.querySelectorAll('[data-field]')].find(n=>n.dataset.field===b.dataset.action);window.webkit.messageHandlers.card.postMessage({action:b.dataset.action,value:field?.value||null})});
        let drag=null;
        document.addEventListener('mousedown',e=>{if(e.button!==0||e.altKey||e.target.closest('button,input,[data-action],[data-field]'))return;const surface=document.querySelector('#surface');if(surface.scrollHeight>surface.clientHeight&&e.clientX>=surface.getBoundingClientRect().right-12)return;drag={x:e.screenX,y:e.screenY,moved:false};window.webkit.messageHandlers.card.postMessage({drag:'start',x:e.screenX,y:e.screenY})});
        document.addEventListener('mousemove',e=>{if(!drag)return;if(!drag.moved&&Math.hypot(e.screenX-drag.x,e.screenY-drag.y)<5)return;drag.moved=true;window.getSelection()?.removeAllRanges();window.webkit.messageHandlers.card.postMessage({drag:'move',x:e.screenX,y:e.screenY})});
        document.addEventListener('mouseup',()=>{if(!drag)return;drag=null;window.webkit.messageHandlers.card.postMessage({drag:'end'})});
        document.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.dataset.field)window.webkit.messageHandlers.card.postMessage({action:e.target.dataset.field,value:e.target.value})});
        document.addEventListener('focusin',e=>{if(e.target.tagName==='INPUT')window.webkit.messageHandlers.card.postMessage({focus:true})});
        document.addEventListener('focusout',e=>{if(e.target.tagName==='INPUT')window.webkit.messageHandlers.card.postMessage({focus:false})});
        </script></body></html>
        """
    }
}
