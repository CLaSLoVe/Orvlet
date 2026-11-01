import WebKit
import AppKit
import AVFoundation

@MainActor
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    var lastState: [String:Any] = [:]
    var loading = false
    private var installedAdRules: WKContentRuleList?
    private var protectionRevision = 0
    private var disposed = false
    unowned let model: PetModel
    let webView: WKWebView
    static var script: String {
        guard let url = Bundle.main.url(forResource: "browser", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    init(model: PetModel, id: UUID = UUID()) {
        self.id = id
        self.model = model
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source:AdBlocker.helper(enabled:model.settings.blockAds),injectionTime:.atDocumentStart,forMainFrameOnly:true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        super.init()
        config.userContentController.add(self, name: "orvlet")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
    }
    func dispose() {
        disposed = true; protectionRevision += 1
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName:"orvlet")
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.loadHTMLString("",baseURL:nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !model.externalBrowser, let data = message.body as? [String: Any] else { return }
        updateState(data)
    }
    func updateState(_ data: [String: Any]) {
        lastState = data
        guard model.browser === self else { model.updateBackgroundTask(id, data:data); return }
        if let url = data["url"] as? String, !model.webURL.isEmpty, url != model.webURL {
            model.hasMedia = false; model.isPlaying = false; model.mediaType = ""
            model.surface = .webpage; model.hasCustomSurface = false
        }
        if let next = data["url"] as? String, !model.webURL.isEmpty,
           URL(string:next)?.host != URL(string:model.webURL)?.host { model.endBackgroundListening(clearTaskIntent:true) }
        let oldTitle = model.webTitle
        let wasPlaying = model.isPlaying
        model.webTitle = data["title"] as? String ?? model.webTitle
        model.webURL = data["url"] as? String ?? model.webURL
        model.hasMedia = data["hasMedia"] as? Bool ?? model.hasMedia
        model.isPlaying = data["playing"] as? Bool ?? model.isPlaying
        model.mediaType = data["mediaType"] as? String ?? model.mediaType
        model.progress = data["currentTime"] as? Double ?? model.progress
        model.duration = data["duration"] as? Double ?? model.duration
        model.volume = data["volume"] as? Double ?? model.volume
        if let interaction = data["interaction"] as? String { model.lastInteraction = interaction }
        if model.isPlaying && (!wasPlaying || oldTitle != model.webTitle) {
            model.remember(title: model.webTitle, url: model.webURL, kind: model.mediaType == "video" ? "video" : "audio")
        }
        model.canGoBack = webView.canGoBack; model.canGoForward = webView.canGoForward
        model.saveSession()
        model.upsertWebTask()
        model.updateLiveReadings(id,data:data)
        model.adaptive.changed()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        lastState = [:]
        if let i = model.sideTasks.firstIndex(where: { $0.id == id }) {
            model.sideTasks[i].plan = nil; model.sideTasks[i].liveValues = nil
            model.sideTasks[i].hasMedia = false
            if model.sideTasks[i].listening != true { model.sideTasks[i].mediaPrimary = nil }
            model.sideTasks[i].playing = false; model.sideTasks[i].generated = false
        }
        guard model.browser === self else { return }
        model.hasMedia = false; model.isPlaying = false; model.mediaType = ""
        model.surface = .webpage; model.hasCustomSurface = false
        model.webLoading = true; model.webError = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        guard model.browser === self else { return }
        model.webLoading = false
        model.webURL = webView.url?.absoluteString ?? ""
        model.webTitle = webView.title ?? ""
        model.remember(title: model.webTitle, url: model.webURL, kind: "web")
        model.canGoBack = webView.canGoBack; model.canGoForward = webView.canGoForward
        model.saveSession()
        model.adaptive.changed()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        guard model.browser === self else { return }
        model.webLoading = false
        if (error as NSError).code != NSURLErrorCancelled { model.webError = "Could not load this page. Check the address or connection." }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if model.browser === self { model.webLoading = false }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["https", "http"].contains(url.scheme ?? "") { webView.load(URLRequest(url: url)) }
        return nil
    }
    func configureAdBlocking() async {
        guard !disposed else { return }
        protectionRevision += 1
        let revision = protectionRevision
        let controller = webView.configuration.userContentController
        // Reinstall only this browser's two bundled scripts for subsequent navigations.
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source:Self.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        controller.addUserScript(WKUserScript(source:AdBlocker.helper(enabled:model.settings.blockAds),injectionTime:.atDocumentStart,forMainFrameOnly:true))
        if !model.settings.blockAds {
            model.adBlockingError = nil
            if let installedAdRules { controller.remove(installedAdRules); self.installedAdRules = nil }
            _ = try? await webView.evaluateJavaScript("window.__orvletAds?.setEnabled(false)")
            return
        }
        do {
            let rules = try await AdBlocker.ruleList()
            guard revision == protectionRevision, model.settings.blockAds else { return }
            if installedAdRules == nil { controller.add(rules); installedAdRules = rules }
            model.adBlockingError = nil
            _ = try? await webView.evaluateJavaScript("window.__orvletAds?.setEnabled(true)")
        } catch {
            guard revision == protectionRevision, model.settings.blockAds, !disposed else { return }
            model.adBlockingError = "Ad blocking could not start. Pages remain available; try reopening Orvlet."
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        guard ["http", "https", "about", "blob"].contains(scheme) else { decisionHandler(.cancel); return }
        // Install compiled rules before the first request, including restored pages.
        if model.settings.blockAds && installedAdRules == nil {
            Task { await configureAdBlocking(); decisionHandler(disposed ? .cancel : .allow) }
        } else { decisionHandler(.allow) }
    }
    func bindReadings(_ bindings: [CardReading]) async throws {
        let data = try JSONEncoder().encode(bindings)
        let json = String(data:data,encoding:.utf8)!
        let state = try await webView.evaluateJavaScript("window.__orvlet.bindReadings(\(json))") as? [String:Any] ?? [:]
        if !state.isEmpty { updateState(state) }
    }
    func observe() async throws -> [String: Any] {
        if webView.url == nil { return ["url": "", "elements": [], "text": "No page is open."] }
        _ = try await webView.evaluateJavaScript(Self.script)
        return try await webView.evaluateJavaScript("window.__orvlet.observe()") as? [String: Any] ?? [:]
    }
    func action(_ input: [String: Any]) async throws -> [String: Any] {
        if input["action"] as? String == "navigate" {
            guard let raw = input["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else { throw AgentError.message("Invalid web address.") }
            model.saveSession(force:true)
            model.cancelRestoration()
            await webView.setAllMediaPlaybackSuspended(false)
            webView.load(URLRequest(url: url, cachePolicy:.useProtocolCachePolicy))
            model.webURL = raw
            return try await settledObservation(navigation: true)
        }
        if let operation = input["action"] as? String, ["back", "forward", "reload"].contains(operation) {
            model.cancelRestoration()
            await webView.setAllMediaPlaybackSuspended(false)
            switch operation {
            case "back": webView.goBack()
            case "forward": webView.goForward()
            default: webView.reload()
            }
            return try await settledObservation(navigation: true)
        }
        if input["action"] as? String == "observe" { return try await observe() }
        _ = try await webView.evaluateJavaScript(Self.script)
        let result = try await webView.callAsyncJavaScript("try { return await window.__orvlet.act(input); } catch (error) { return {orvletActionError: String(error.message || error)}; }", arguments: ["input": input], in: nil, contentWorld: .page)
        if let state = result as? [String: Any] {
            if let reason = state["orvletActionError"] as? String { throw AgentError.message(reason) }
            updateState(state); return state
        }
        return ["ok": true]
    }
    // Return evidence with each operation instead of making the agent spend a round observing again.
    func settledObservation(navigation: Bool = false) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(navigation ? 10 : 3)
        var latest: [String: Any] = [:]
        var previous = ""
        var stable = 0
        repeat {
            try await Task.sleep(for: .milliseconds(250))
            if let current = try? await observe() {
                latest = current
                let items = current["elements"] as? [[String: Any]] ?? []
                let fingerprint = (current["url"] as? String ?? "") + items.prefix(12).compactMap { $0["label"] as? String }.joined(separator: "|")
                stable = fingerprint == previous ? stable + 1 : 0
                previous = fingerprint
                if !loading && !items.isEmpty && stable >= 1 { break }
            }
        } while Date() < deadline
        try Task.checkCancellation()
        latest["loading"] = loading
        latest["ok"] = true
        updateState(latest)
        if model.browser === self { model.lastObservation = latest }
        return latest
    }
    func clearResourceCache() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes:[WKWebsiteDataTypeDiskCache,WKWebsiteDataTypeMemoryCache],modifiedSince:.distantPast)
    }
    func screenshot() async throws -> String {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1000
        let image = try await webView.takeSnapshot(configuration: config)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { throw AgentError.message("Unable to capture the page.") }
        return jpeg.base64EncodedString()
    }
}
