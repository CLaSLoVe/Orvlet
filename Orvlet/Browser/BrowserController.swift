import AVFoundation
import AppKit
import WebKit

struct PageReadUnavailable: LocalizedError {
    var errorDescription: String? { "The requested page data did not become available in time." }
}

@MainActor
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    var lastState: [String: Any] = [:]
    private var retainedMediaSurface: (url: URL, plan: SurfacePlan)?
    func rememberMediaSurface(_ plan: SurfacePlan, url: String) {
        guard plan.markup != nil else { return }
        guard plan.reusableTransport, let source = URL(string: url), source.host != nil else {
            retainedMediaSurface = nil
            return
        }
        retainedMediaSurface = (source, plan)
    }
    func reusableMediaSurface(_ observation: [String: Any]) -> SurfacePlan? {
        guard let retained = retainedMediaSurface, let raw = observation["url"] as? String, let url = URL(string: raw),
            url.scheme == retained.url.scheme, url.host == retained.url.host, url.port == retained.url.port,
            url.path == retained.url.path,
            observation["hasMedia"] as? Bool == true, observation["mediaPrimary"] as? Bool != false,
            observation["adPlaying"] as? Bool != true,
            var checked = try? retained.plan.validated(observation: observation)
        else { return nil }
        checked.title = observation["title"] as? String
        return checked
    }
    var loading = false
    private(set) var userPausedPlayback = false
    private(set) var waitingForInterface = false
    private(set) var restoringPlayback = false
    private var playbackRevision = 0
    private var policyRevision = 0
    var playbackGeneration: Int { playbackRevision }
    private(set) var audioFocusHeld = true
    private var focusRequested = false
    var playbackSuspended: Bool { userPausedPlayback || waitingForInterface || restoringPlayback || audioFocusHeld }
    func setAudioFocusHeld(_ held: Bool) {
        guard audioFocusHeld != held else { return }
        audioFocusHeld = held
        policyRevision += 1
        installUserScripts()
    }
    func setUserPlaybackPaused(_ paused: Bool, origin: String = "direct") {
        Diagnostics.record("playback_intent", ["taskID": id.uuidString, "paused": paused, "origin": origin])
        #if DEBUG
            if model.isLiveTest && origin == "direct" {
                Diagnostics.record("playback_caller", ["stack": Thread.callStackSymbols.prefix(14).map { $0 }])
            }
        #endif
        userPausedPlayback = paused
        if !paused {
            waitingForInterface = false
            focusRequested = true
        } else {
            focusRequested = false
        }
        installUserScripts()
        playbackRevision += 1
        policyRevision += 1
    }
    func waitForInterface() {
        waitingForInterface = true
        playbackRevision += 1
        policyRevision += 1
        installUserScripts()
    }
    func releaseInterface() {
        waitingForInterface = false
        playbackRevision += 1
        policyRevision += 1
        installUserScripts()
    }
    func setRestorationHeld(_ held: Bool) {
        restoringPlayback = held
        playbackRevision += 1
        policyRevision += 1
        installUserScripts()
    }
    private var appliedPlaybackRevision: Int?
    private var playbackPolicyTask: Task<Void, Never>?
    /// One writer owns WebKit's asynchronous playback gate. All callers wait
    /// for the latest intent, so an older suspend cannot land after a new play.
    func applyPlaybackPolicy() async {
        if focusRequested && !userPausedPlayback && !waitingForInterface && !restoringPlayback {
            focusRequested = false
            try? await model.playbackCoordinator.acquire(self)
        }
        await applyPlaybackGate()
    }
    func applyPlaybackGate() async {
        while !disposed && appliedPlaybackRevision != policyRevision {
            if playbackPolicyTask == nil {
                playbackPolicyTask = Task { [weak self] in
                    guard let self else { return }
                    defer { playbackPolicyTask = nil }
                    repeat {
                        let revision = policyRevision
                        Diagnostics.record(
                            "playback_policy",
                            [
                                "taskID": id.uuidString, "held": playbackSuspended, "paused": userPausedPlayback,
                                "waitingForInterface": waitingForInterface, "restoringPlayback": restoringPlayback,
                                "revision": revision,
                            ])
                        _ = try? await webView.evaluateJavaScript(
                            "window.__orvletPlayback?.setHeld(\(playbackSuspended ? "true" : "false")); true")
                        if playbackSuspended { await webView.pauseAllMediaPlayback() }
                        if revision == policyRevision { appliedPlaybackRevision = revision }
                    } while !disposed && appliedPlaybackRevision != policyRevision
                }
            }
            await playbackPolicyTask?.value
        }
    }
    private var navigationCommitted = false
    private var committedNavigation: WKNavigation?
    private(set) var navigationGeneration = 0
    private var installedAdRules: WKContentRuleList?
    private var protectionRevision = 0
    private(set) var disposed = false
    unowned let model: AppModel
    let webView: WKWebView
    static var script: String {
        guard let url = Bundle.main.url(forResource: "browser", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    init(model: AppModel, id: UUID = UUID()) {
        self.id = id
        self.model = model
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.playbackGate(held: true), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(
                source: AdBlocker.helper(enabled: model.settings.blockAds), injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        super.init()
        model.playbackCoordinator.register(self)
        config.userContentController.add(self, name: "orvlet")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
    }
    func dispose() {
        disposed = true
        model.playbackCoordinator.remove(self)
        protectionRevision += 1
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orvlet")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !model.externalBrowser, let data = message.body as? [String: Any] else { return }
        updateState(data)
    }
    func updateState(_ data: [String: Any]) {
        // Click/scroll acknowledgements are not page snapshots. Keep the last
        // verified media state until the page sends a complete observation.
        guard !disposed, data["url"] is String else { return }
        if let playing = data["playing"] as? Bool, playing != (lastState["playing"] as? Bool),
            data["hasMedia"] as? Bool == true
        {
            Diagnostics.record(
                "playback_state",
                [
                    "taskID": id.uuidString, "playing": playing, "currentTime": data["currentTime"] as? Double ?? 0,
                    "held": playbackSuspended,
                ])
        }
        lastState = data
        guard model.browser === self else {
            model.updateBackgroundTask(id, data: data)
            return
        }
        if let url = data["url"] as? String, !model.webURL.isEmpty, url != model.webURL {
            model.hasMedia = false
            model.isPlaying = false
            model.mediaType = ""
            model.surface = reusableMediaSurface(data) ?? .webpage
            model.hasCustomSurface = model.surface.markup != nil
        }
        if let next = data["url"] as? String, !model.webURL.isEmpty,
            URL(string: next)?.host != URL(string: model.webURL)?.host
        {
            model.endBackgroundListening(clearTaskIntent: true)
        }
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
            model.remember(
                title: model.webTitle, url: model.webURL, kind: model.mediaType == "video" ? "video" : "audio")
        }
        model.canGoBack = webView.canGoBack
        model.canGoForward = webView.canGoForward
        model.saveSession()
        model.upsertWebTask()
        model.updateLiveReadings(id, data: data)
        model.receiveMusicState(id, data: data)
        model.adaptive.changed()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !disposed else { return }
        committedNavigation = nil
        navigationGeneration += 1
        Diagnostics.record("source_navigation", ["taskID": id.uuidString, "revision": navigationGeneration])
        if model.browser === self { model.adaptive.invalidate() }
        loading = true
        navigationCommitted = false
        lastState = [:]
        if let i = model.sideTasks.firstIndex(where: { $0.id == id }) {
            model.sideTasks[i].plan = nil
            model.sideTasks[i].liveValues = nil
            model.sideTasks[i].hasMedia = false
            if model.sideTasks[i].listening != true { model.sideTasks[i].mediaPrimary = nil }
            model.sideTasks[i].playing = false
            model.sideTasks[i].generated = false
        }
        guard model.browser === self else { return }
        model.hasMedia = false
        model.isPlaying = false
        model.mediaType = ""
        model.surface = .webpage
        model.hasCustomSurface = false
        model.webLoading = true
        model.webError = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationCommitted = true
        committedNavigation = navigation
    }
    static func contentReady(_ observation: [String: Any]) -> Bool {
        let ready = observation["documentReady"] as? String ?? ""
        return ["interactive", "complete"].contains(ready)
            && (!(observation["text"] as? String ?? "").isEmpty
                || !(observation["elements"] as? [[String: Any]] ?? []).isEmpty)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        guard model.browser === self else { return }
        model.webLoading = false
        model.webURL = webView.url?.absoluteString ?? ""
        model.webTitle = webView.title ?? ""
        model.remember(title: model.webTitle, url: model.webURL, kind: "web")
        model.canGoBack = webView.canGoBack
        model.canGoForward = webView.canGoForward
        model.saveSession()
        model.adaptive.changed()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        guard model.browser === self else { return }
        model.webLoading = false
        if (error as NSError).code != NSURLErrorCancelled {
            model.webError = "Could not load this page. Check the address or connection."
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if model.browser === self { model.webLoading = false }
    }
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
            ["https", "http"].contains(url.scheme ?? "")
        {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
    // A preparation hold prevents autoplay without disabling WebKit's ability to
    // start fresh media after controls are ready. All holds share this document-start
    // gate; native actions additionally require explicit new user playback intent.
    static func playbackGate(held: Bool) -> String {
        """
        (()=>{
          if(window.__orvletPlayback){window.__orvletPlayback.setHeld(\(held));return;}
          let held=\(held);
          const play=HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play=function(...args){return held ? Promise.resolve() : play.apply(this,args)};
          document.addEventListener('play',e=>{if(held && e.target instanceof HTMLMediaElement)e.target.pause()},true);
          const setHeld=value=>{held=!!value;if(held)document.querySelectorAll('audio,video').forEach(m=>m.pause());for(let i=0;i<frames.length;i++)frames[i].postMessage({orvletPlaybackHold:held},'*')};
          window.addEventListener('message',e=>{if(window!==parent && e.source===parent && typeof e.data?.orvletPlaybackHold==='boolean')setHeld(e.data.orvletPlaybackHold)});
          window.__orvletPlayback={setHeld};
        })();
        """
    }
    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(
                source: Self.playbackGate(held: playbackSuspended), injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        controller.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(
            WKUserScript(
                source: AdBlocker.helper(enabled: model.settings.blockAds), injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
    }
    func configureAdBlocking() async {
        guard !disposed else { return }
        protectionRevision += 1
        let revision = protectionRevision
        let controller = webView.configuration.userContentController
        installUserScripts()
        if !model.settings.blockAds {
            model.adBlockingError = nil
            if let installedAdRules {
                controller.remove(installedAdRules)
                self.installedAdRules = nil
            }
            _ = try? await webView.evaluateJavaScript("window.__orvletAds?.setEnabled(false)")
            return
        }
        do {
            let rules = try await AdBlocker.ruleList()
            guard revision == protectionRevision, model.settings.blockAds else { return }
            if installedAdRules == nil {
                controller.add(rules)
                installedAdRules = rules
            }
            model.adBlockingError = nil
            _ = try? await webView.evaluateJavaScript("window.__orvletAds?.setEnabled(true)")
        } catch {
            guard revision == protectionRevision, model.settings.blockAds, !disposed else { return }
            model.adBlockingError = "Ad blocking could not start. Pages remain available; try reopening Orvlet."
        }
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        guard ["http", "https", "about", "blob"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        // Install compiled rules before the first request, including restored pages.
        if model.settings.blockAds && installedAdRules == nil {
            Task {
                await configureAdBlocking()
                decisionHandler(disposed ? .cancel : .allow)
            }
        } else {
            decisionHandler(.allow)
        }
    }
    func bindReadings(_ bindings: [CardReading]) async throws {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(bindings)
        let json = String(data: data, encoding: .utf8)!
        let state =
            try await webView.evaluateJavaScript("window.__orvlet.bindReadings(\(json))") as? [String: Any] ?? [:]
        if !state.isEmpty { updateState(state) }
    }
    func observe() async throws -> [String: Any] {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if webView.url == nil { return ["url": "", "elements": [], "text": "No page is open."] }
        _ = try await webView.evaluateJavaScript(Self.script)
        return try await webView.evaluateJavaScript("window.__orvlet.observe()") as? [String: Any] ?? [:]
    }

    /// A host-owned data projection supplies its own readiness condition. No full
    /// page observation or unrelated layout stability is needed to read that data.
    /// The committed navigation identity prevents accepting the previous document.
    func navigateReading<Value>(
        to url: String, script: String, timeout: TimeInterval = 10,
        accept: (Any?) throws -> Value?
    ) async throws -> Value {
        let start = Date()
        let navigation = try await beginNavigation(url)
        var probes = 0
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            guard !disposed else { throw CancellationError() }
            if committedNavigation === navigation {
                probes += 1
                // The bridge is installed at document end; early/transitional
                // documents are pending, not extraction failures.
                let value = try await webView.evaluateJavaScript(
                    "(() => { if (!window.__orvlet) return null; return (" + script + "); })()")
                try Task.checkCancellation()
                guard !disposed else { throw CancellationError() }
                if committedNavigation === navigation, let accepted = try accept(value) {
                    Diagnostics.record("browser_read", ["seconds": Date().timeIntervalSince(start), "probes": probes])
                    return accepted
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PageReadUnavailable()
    }

    private func beginNavigation(_ raw: String) async throws -> WKNavigation {
        guard !disposed else { throw CancellationError() }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else {
            throw AppError.message("Invalid web address.")
        }
        if model.browser === self {
            model.saveSession(force: true)
            model.cancelRestoration()
        }
        if model.playbackCoordinator.owner == nil && !userPausedPlayback && !restoringPlayback && !waitingForInterface {
            try await model.playbackCoordinator.acquire(self)
        }
        await applyPlaybackPolicy()
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        navigationCommitted = false
        committedNavigation = nil
        if model.browser === self { ToolExecutionScope.current?.effectStarted = true }
        guard let navigation = webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)) else {
            throw AppError.message("The page could not start loading.")
        }
        if model.browser === self { model.webURL = raw }
        return navigation
    }
    func action(_ input: [String: Any]) async throws -> [String: Any] {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if input["action"] as? String == "navigate" {
            guard let raw = input["url"] as? String else { throw AppError.message("Invalid web address.") }
            _ = try await beginNavigation(raw)
            return try await settledObservation(navigation: true)
        }
        if let operation = input["action"] as? String, ["back", "forward", "reload"].contains(operation) {
            if model.browser === self { model.cancelRestoration() }
            await applyPlaybackPolicy()
            guard !disposed else { throw CancellationError() }
            try Task.checkCancellation()
            ToolExecutionScope.current?.effectStarted = true
            switch operation {
            case "back": webView.goBack()
            case "forward": webView.goForward()
            default: if input["fresh"] as? Bool == true { webView.reloadFromOrigin() } else { webView.reload() }
            }
            return try await settledObservation(navigation: true)
        }
        if input["action"] as? String == "observe" { return try await observe() }
        if input["action"] as? String == "media",
            !PageBinding.mediaOperations.contains(input["operation"] as? String ?? "")
        {
            throw AppError.message(
                "Media requires an operation field. Use {action:\"media\",operation:\"play\"} to play. Supported operations: "
                    + PageBinding.mediaOperations.joined(separator: ", ")
                    + ". Do not use name or text for the operation.")
        }
        if input["action"] as? String == "media",
            ["play", "toggle", "next", "previous"].contains(input["operation"] as? String ?? "")
        {
            let startsPlayback = input["operation"] as? String != "toggle" || lastState["playing"] as? Bool != true
            if startsPlayback && userPausedPlayback {
                throw AppError.message("Playback was paused by the user. Only a new user play command may resume it.")
            }
            if startsPlayback && waitingForInterface {
                var state = try await observe()
                state["playbackDeferred"] = true
                return state
            }
            if startsPlayback { try await model.playbackCoordinator.acquire(self) }
        }
        _ = try await webView.evaluateJavaScript(Self.script)
        if model.browser === self { ToolExecutionScope.current?.effectStarted = true }
        let result = try await webView.callAsyncJavaScript(
            "try { return await window.__orvlet.act(input); } catch (error) { return {orvletActionError: String(error.message || error)}; }",
            arguments: ["input": input], in: nil, contentWorld: .page)
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if let state = result as? [String: Any] {
            if let reason = state["orvletActionError"] as? String { throw AppError.message(reason) }
            updateState(state)
            return state
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
            guard !disposed else { throw CancellationError() }
            if let current = try? await observe() {
                latest = current
                let items = current["elements"] as? [[String: Any]] ?? []
                let fingerprint =
                    (current["url"] as? String ?? "")
                    + items.prefix(12).compactMap { $0["label"] as? String }.joined(separator: "|")
                stable = fingerprint == previous ? stable + 1 : 0
                previous = fingerprint
                if (!loading || (navigationCommitted && Self.contentReady(current))) && stable >= 1 { break }
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
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
    }
    func screenshot() async throws -> String {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1000
        let image = try await webView.takeSnapshot(configuration: config)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { throw AppError.message("Unable to capture the page.") }
        return jpeg.base64EncodedString()
    }
}
