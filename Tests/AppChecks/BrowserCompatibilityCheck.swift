#if DEBUG
import WebKit

@MainActor
enum BrowserCompatibilityCheck {
    private static func inspect(_ view: WKWebView, accepts: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let script = """
            (() => {
                const links = [...document.querySelectorAll('a[href*="/video/BV"]')];
                const match = links.find(a => (a.innerText + (a.title || '') + (a.querySelector('img')?.alt || '')).includes('伯虎说'));
                return {url:location.href, ua:navigator.userAgent, title:document.title,
                    legacy:document.body?.innerText.includes('浏览器版本过低') || false,
                    match:match?.href || '', links:links.length, video:!!document.querySelector('video'),
                    heading:document.querySelector('h1')?.innerText || ''};
            })()
            """
        var state: [String: Any] = [:]
        for _ in 0..<120 {
            state = try await view.evaluateJavaScript(script) as? [String: Any] ?? [:]
            if state["legacy"] as? Bool == true || accepts(state) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        print(JSONText.encode(state))
        guard state["legacy"] as? Bool == false, accepts(state) else { throw AppError.message("The requested page content did not render.") }
        return state
    }

    static func run(_ model: AppModel) async throws {
        var search = URLComponents(string: "https://search.bilibili.com/all")!
        search.queryItems = [URLQueryItem(name: "keyword", value: "伯虎说 DJ")]
        let browser = model.browser
        browser.setUserPlaybackPaused(true, origin: "compatibility_check")
        if CommandLine.arguments.contains("--stock-webkit-agent") {
            let stock = WKWebView(frame: .zero)
            browser.webView.customUserAgent = try await stock.evaluateJavaScript("navigator.userAgent") as? String
        }
        _ = try await browser.action(["action": "navigate", "url": search.url!.absoluteString])
        let results = try await inspect(browser.webView) { ($0["match"] as? String)?.isEmpty == false }
        guard let raw = results["match"] as? String, let url = URL(string: raw),
            url.host == "www.bilibili.com", url.pathComponents.contains("video") else { throw AppError.message("Missing matching video link") }

        // Open a currently listed result in both production browsing surfaces.
        func isRequestedVideo(_ state: [String: Any]) -> Bool {
            (state["heading"] as? String)?.contains("伯虎说") == true && state["video"] as? Bool == true
        }
        _ = try await browser.action(["action": "navigate", "url": url.absoluteString])
        _ = try await inspect(browser.webView, accepts: isRequestedVideo)
        let original = try HandoffSource(taskID: UUID(), destination: url, model: model)
        guard let page = original.webView else { throw AppError.message("Missing in-app handoff") }
        _ = try await inspect(page, accepts: isRequestedVideo)
    }
}
#endif
