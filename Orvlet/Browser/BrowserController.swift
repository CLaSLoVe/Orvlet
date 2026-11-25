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
    private(set) var sourceAccessIssue: String?
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
                        if let systemPage {
                            let hostRevision = systemPage.host.revision
                            do { try await systemPage.updateGate() }
                            catch {
                                if !disposed, !systemPage.host.closing, systemPage.host.revision == hostRevision {
                                    systemBrowserFailed(error.localizedDescription)
                                    if systemPage.host.native { systemPage.disconnectNativePage() }
                                    else { systemPage.host.stop() }
                                }
                            }
                        }
                        else { _ = try? await webView.evaluateJavaScript(
                            "window.__orvletPlayback?.setHeld(\(playbackSuspended ? "true" : "false")); true") }
                        if playbackSuspended { await pauseMedia() }
                        if revision == policyRevision { appliedPlaybackRevision = revision }
                    } while !disposed && appliedPlaybackRevision != policyRevision
                }
            }
            await playbackPolicyTask?.value
        }
    }
    private var navigationCommitted = false
    private var activeNavigation: WKNavigation?
    private var committedNavigation: WKNavigation?
    private(set) var navigationGeneration = 0
    private let adBlocker = AdBlocker()
    private(set) var disposed = false
    unowned let model: AppModel
    let windowPlayer: WindowPlayer
    let webView: WKWebView
    private(set) var systemPage: SystemBrowserPage?
    private var systemFailure: String?
    var currentURL: URL? { systemPage == nil ? webView.url : (lastState["url"] as? String).flatMap(URL.init(string:)) }
    func evaluate(_ script: String) async throws -> Any? {
        if let systemPage { try await systemPage.ready(); return try await systemPage.evaluate(script) }
        return try await webView.evaluateJavaScript(script)
    }
    func pauseMedia() async {
        if let systemPage { _ = try? await systemPage.evaluate("document.querySelectorAll('audio,video').forEach(m=>m.pause()); true") }
        else { await webView.pauseAllMediaPlayback() }
    }
    func systemBrowserFailed(_ reason: String) {
        guard !disposed else { return }
        loading = false
        sourceAccessIssue = reason
        systemFailure = reason
        lastState["playing"] = false
        if model.browser === self { model.webLoading = false; model.webError = reason; model.isPlaying = false }
        if let i = model.sideTasks.firstIndex(where: { $0.id == id }) {
            model.sideTasks[i].playing = false
            model.sideTasks[i].dataIssue = reason
        }
        model.reportTaskIssue(id, source: .browser, detail: reason)
    }
    func systemBrowserPlaybackGesture() {
        guard !disposed, model.showingWeb, model.browser === self || model.handoffSource?.systemBrowser === self else { return }
        setUserPlaybackPaused(false, origin: "source_gesture")
        setRestorationHeld(false)
        if model.browser === self { model.markPlaybackTask(id) }
        Task { [weak self] in await self?.applyPlaybackPolicy() }
    }
    static var script: String {
        guard let url = Bundle.main.url(forResource: "browser", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    init(model: AppModel, id: UUID = UUID()) {
        self.id = id
        self.model = model
        windowPlayer = WindowPlayer(model: model)
        let config = WKWebViewConfiguration.orvletSiteBrowser()
        if model.settings.browserEngine == .builtIn && !model.usesNativeBrowser { if #available(macOS 15.4, *) { model.extensions.configure(config) } }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.playbackGate(held: true), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(Self.playbackIntentScript)
        config.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        AdBlocker.installHelper(in: config.userContentController, enabled: model.settings.blockAds)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        super.init()
        if model.usesNativeBrowser { systemPage = SystemBrowserPage(host: model.nativeBrowserHost, owner: self) }
        else if model.settings.browserEngine == .systemBrowser { systemPage = SystemBrowserPage(host: model.systemBrowserHost, owner: self) }
        else if #available(macOS 15.4, *) { model.extensions.register(webView) }
        windowPlayer.web = webView
        windowPlayer.page = systemPage
        config.userContentController.add(windowPlayer, contentWorld: .defaultClient, name: "orvletWindowPlayer")
        model.playbackCoordinator.register(self)
        config.userContentController.add(self, name: "orvlet")
        config.userContentController.add(self, contentWorld: .defaultClient, name: "orvletPlayback")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true
        windowPlayer.changed(false)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orvletWindowPlayer", contentWorld: .defaultClient)
        systemPage?.stop()
        loading = false
        navigationGeneration += 1
        activeNavigation = nil
        committedNavigation = nil
        playbackPolicyTask?.cancel()
        if systemPage == nil { if #available(macOS 15.4, *) { model.extensions.unregister(webView) } }
        model.playbackCoordinator.remove(self)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orvlet")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "orvletPlayback", contentWorld: .defaultClient)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "orvletPlayback" {
            guard !disposed, model.browser === self, model.webExpanded, !model.collapsed,
                model.handoffSource == nil else { return }
            let navigation = navigationGeneration
            // This handler exists only in the isolated world. A trusted gesture
            // plus a media play request, not an arbitrary page click, reaches it.
            setUserPlaybackPaused(false, origin: "source_gesture")
            setRestorationHeld(false)
            model.markPlaybackTask(id)
            Task { [weak self] in
                guard let self, !disposed, navigationGeneration == navigation else { return }
                await applyPlaybackPolicy()
            }
            return
        }
        guard !disposed, !model.externalBrowser, message.frameInfo.isMainFrame,
            !loading || navigationCommitted,
            let data = message.body as? [String: Any],
            data["url"] as? String == webView.url?.absoluteString else { return }
        updateState(data)
    }
    func updateState(_ data: [String: Any]) {
        // Click/scroll acknowledgements are not page snapshots. Keep the last
        // verified media state until the page sends a complete observation.
        guard !disposed, data["url"] is String else { return }
        if systemPage != nil, !loading, let failure = systemFailure,
            let url = (data["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") {
            if let i = model.sideTasks.firstIndex(where: { $0.id == id }), model.sideTasks[i].dataIssue == failure {
                model.sideTasks[i].dataIssue = nil
            }
            systemFailure = nil
            sourceAccessIssue = nil
            model.resolveTaskIssue(id, source: .browser)
            if model.browser === self { model.webError = nil }
        }
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
        activeNavigation = navigation
        sourceAccessIssue = nil
        model.musicErrors[id] = nil
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
        guard !disposed, navigation === activeNavigation else { return }
        windowPlayer.changed(false)
        navigationCommitted = true
        committedNavigation = navigation
        if #available(macOS 15.4, *) { model.extensions.changed(webView) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
            response.statusCode >= 400 {
            sourceAccessIssue = [401,403,412,429].contains(response.statusCode)
                ? "The source blocked access. Open the page to continue."
                : "The source could not load this content."
            model.musicErrors[id] = sourceAccessIssue
            model.reportTaskIssue(id, source: .browser,
                detail: "HTTP \(response.statusCode). " + (sourceAccessIssue ?? "The page could not load."))
            Diagnostics.record("source_access_failed",["taskID":id.uuidString,"status":response.statusCode])
        }
        decisionHandler(.allow)
    }
    static func contentReady(_ observation: [String: Any]) -> Bool {
        let ready = observation["documentReady"] as? String ?? ""
        return ["interactive", "complete"].contains(ready)
            && (!(observation["text"] as? String ?? "").isEmpty
                || !(observation["elements"] as? [[String: Any]] ?? []).isEmpty)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !disposed, navigation === activeNavigation else { return }
        loading = false
        if #available(macOS 15.4, *) { model.extensions.changed(webView) }
        guard model.browser === self else { return }
        model.webLoading = false
        model.webURL = webView.url?.absoluteString ?? ""
        if sourceAccessIssue == nil { model.resolveTaskIssue(id, source: .browser) }
        model.webTitle = webView.title ?? ""
        model.remember(title: model.webTitle, url: model.webURL, kind: "web")
        model.canGoBack = webView.canGoBack
        model.canGoForward = webView.canGoForward
        model.saveSession()
        model.adaptive.changed()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !disposed, navigation === activeNavigation else { return }
        loading = false
        if model.browser === self { model.webLoading = false }
        if (error as NSError).code != NSURLErrorCancelled {
            if model.browser === self { model.webError = "Could not load this page. Check the address or connection." }
            model.reportTaskIssue(id, source: .browser, detail: error.localizedDescription)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !disposed, navigation === activeNavigation else { return }
        loading = false
        if model.browser === self { model.webLoading = false }
        if (error as NSError).code != NSURLErrorCancelled {
            model.reportTaskIssue(id, source: .browser, detail: error.localizedDescription)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !disposed else { return }
        navigationGeneration += 1
        activeNavigation = nil
        committedNavigation = nil
        navigationCommitted = false
        loading = false
        lastState = [:]
        appliedPlaybackRevision = nil
        model.reportTaskIssue(id, source: .browser, detail: "The page process stopped responding. Reload the page to continue.")
        if let i = model.sideTasks.firstIndex(where: { $0.id == id }) {
            model.sideTasks[i].playing = false
            model.sideTasks[i].status = "Open page to continue"
        }
        if model.browser === self {
            model.webLoading = false
            model.isPlaying = false
            model.webError = "The page stopped responding. Reload it to continue."
        }
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
          const pending=new Map();
          const play=HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play=function(...args){
            if(!held){if(navigator.userActivation?.isActive)document.dispatchEvent(new Event('orvlet-request-playback'));return play.apply(this,args);}
            if(!navigator.userActivation?.isActive)return Promise.resolve();
            if(pending.has(this)){document.dispatchEvent(new Event('orvlet-request-playback'));return pending.get(this).promise;}
            const media=this;let resolve,reject;
            const promise=new Promise((yes,no)=>{resolve=yes;reject=no});
            const request={promise,resolve,reject,args};pending.set(media,request);
            document.dispatchEvent(new Event('orvlet-request-playback'));
            setTimeout(()=>{if(pending.get(media)===request){pending.delete(media);reject(new DOMException('Playback handoff was not accepted','NotAllowedError'))}},5000);
            return promise;
          };
          document.addEventListener('play',e=>{
            if(!(e.target instanceof HTMLMediaElement))return;
            if(held){e.target.pause();if(navigator.userActivation?.isActive)e.target.play().catch(()=>{});}
            else if(navigator.userActivation?.isActive)document.dispatchEvent(new Event('orvlet-request-playback'));
          },true);
          const setHeld=value=>{held=!!value;if(held)document.querySelectorAll('audio,video').forEach(m=>m.pause());else{const queued=[...pending];pending.clear();for(const [media,r] of queued)Promise.resolve(play.apply(media,r.args)).then(r.resolve,r.reject)}for(let i=0;i<frames.length;i++)frames[i].postMessage({orvletPlaybackHold:held},'*')};
          window.addEventListener('message',e=>{if(window!==parent && e.source===parent && typeof e.data?.orvletPlaybackHold==='boolean')setHeld(e.data.orvletPlaybackHold)});
          window.__orvletPlayback={setHeld};
        })();
        """
    }
    static var playbackIntentScript: WKUserScript {
        WKUserScript(source: """
        (()=>{
          let gesture=-Infinity;
          for(const type of ['pointerdown','pointerup','click','keydown'])document.addEventListener(type,e=>{
            if(e.isTrusted && !e.repeat && !(e.target instanceof Element && e.target.closest('input,textarea,[contenteditable=true]')))
              gesture=performance.now();
          },true);
          document.addEventListener('orvlet-request-playback',()=>{
            if(navigator.userActivation?.isActive && performance.now()-gesture<1200){
              gesture=-Infinity;
              window.webkit.messageHandlers.orvletPlayback.postMessage({play:true});
            }
          },true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
    }
    private func installUserScripts() {
        guard systemPage == nil else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        WindowPlayer.install(in: controller)
        controller.addUserScript(
            WKUserScript(
                source: Self.playbackGate(held: playbackSuspended), injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        controller.addUserScript(Self.playbackIntentScript)
        controller.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        AdBlocker.installHelper(in: controller, enabled: model.settings.blockAds)
    }
    func configureAdBlocking() async {
        guard !disposed, systemPage == nil else { return }
        installUserScripts()
        await adBlocker.update(webView, model: model)
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
        Task {
            if #available(macOS 15.4, *) { await model.extensions.ready() }
            if model.settings.blockAds && !adBlocker.hasRules {
                await adBlocker.applyRules(to: webView, model: model)
            }
            decisionHandler(disposed ? .cancel : .allow)
        }
    }
    func bindReadings(_ bindings: [CardReading]) async throws {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(bindings)
        let json = String(data: data, encoding: .utf8)!
        let generation = navigationGeneration
        let state =
            try await evaluate("window.__orvlet.bindReadings(\(json))") as? [String: Any] ?? [:]
        try Task.checkCancellation()
        guard !disposed, generation == navigationGeneration else { throw CancellationError() }
        if !state.isEmpty { updateState(state) }
    }
    func observe(query: String? = nil) async throws -> [String: Any] {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if currentURL == nil && systemPage == nil { return ["url": "", "elements": [], "text": "No page is open."] }
        let generation = navigationGeneration
        _ = try await evaluate(Self.script)
        try Task.checkCancellation()
        guard !disposed, generation == navigationGeneration else { throw CancellationError() }
        let result = try await evaluate("window.__orvlet.observe(" + (query.map(JSONText.encode) ?? "undefined") + ")") as? [String: Any] ?? [:]
        try Task.checkCancellation()
        guard !disposed, generation == navigationGeneration else { throw CancellationError() }
        return result
    }

    /// A host-owned data projection supplies its own readiness condition. No full
    /// page observation or unrelated layout stability is needed to read that data.
    /// The committed navigation identity prevents accepting the previous document.
    func navigateReading<Value>(
        to url: String, script: String, timeout: TimeInterval = 10,
        accept: (Any?) throws -> Value?
    ) async throws -> Value {
        let start = Date()
        if systemPage != nil {
            _ = try await action(["action": "navigate", "url": url])
            let generation = navigationGeneration
            while Date().timeIntervalSince(start) < timeout {
                try Task.checkCancellation()
                guard !disposed, generation == navigationGeneration else { throw CancellationError() }
                if let accepted = try accept(try await evaluate(script)) { return accepted }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw PageReadUnavailable()
        }
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
            if !restoringPlayback { model.cancelRestoration() }
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
        activeNavigation = navigation
        if model.browser === self { model.webURL = raw }
        return navigation
    }
    func action(_ input: [String: Any]) async throws -> [String: Any] {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if input["action"] as? String == "navigate" {
            guard let raw = input["url"] as? String else { throw AppError.message("Invalid web address.") }
            if let systemPage {
                navigationGeneration += 1
                let generation = navigationGeneration
                loading = true
                sourceAccessIssue = nil
                if model.browser === self { if !restoringPlayback { model.cancelRestoration() }; model.webLoading = true; model.webError = nil }
                defer { if generation == navigationGeneration { loading = false; if model.browser === self { model.webLoading = false } } }
                do {
                    if model.playbackCoordinator.owner == nil && !userPausedPlayback && !restoringPlayback && !waitingForInterface {
                        try await model.playbackCoordinator.acquire(self)
                    }
                    await applyPlaybackPolicy()
                    ToolExecutionScope.current?.effectStarted = true
                    try await systemPage.navigate(raw)
                    guard !disposed, generation == navigationGeneration else { throw CancellationError() }
                    loading = false
                    let result = try await settledObservation(navigation: true)
                    guard !disposed, generation == navigationGeneration else { throw CancellationError() }
                    return result
                } catch is CancellationError { throw CancellationError() }
                catch { if generation == navigationGeneration { systemBrowserFailed(error.localizedDescription) }; throw error }
            }
            let started = try await beginNavigation(raw)
            return try await settledObservation(navigation: true, expectedNavigation: started)
        }
        if let operation = input["action"] as? String, ["back", "forward", "reload"].contains(operation) {
            if model.browser === self { model.cancelRestoration() }
            await applyPlaybackPolicy()
            guard !disposed else { throw CancellationError() }
            try Task.checkCancellation()
            ToolExecutionScope.current?.effectStarted = true
            if let systemPage {
                if operation == "reload", !systemPage.host.isRunning || systemPage.client?.closed == true,
                    let url = currentURL, ["http", "https"].contains(url.scheme ?? "") {
                    return try await action(["action": "navigate", "url": url.absoluteString])
                }
                navigationGeneration += 1
                let generation = navigationGeneration
                loading = true
                defer { if generation == navigationGeneration { loading = false } }
                try await systemPage.history(operation, fresh: input["fresh"] as? Bool == true)
                guard generation == navigationGeneration, !disposed else { throw CancellationError() }
                loading = false
                return try await settledObservation(navigation: true)
            }
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
        _ = try await evaluate(Self.script)
        if model.browser === self { ToolExecutionScope.current?.effectStarted = true }
        let result: Any?
        if let systemPage {
            result = try await systemPage.evaluate("(async()=>{try{return await window.__orvlet.act(" + JSONText.encode(input) + ")}catch(e){return {orvletActionError:String(e.message||e)}}})()", userGesture: input["action"] as? String == "media")
        } else {
            result = try await webView.callAsyncJavaScript(
                "try { return await window.__orvlet.act(input); } catch (error) { return {orvletActionError: String(error.message || error)}; }",
                arguments: ["input": input], in: nil, contentWorld: .page)
        }
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
    func settledObservation(navigation: Bool = false, expectedNavigation: WKNavigation? = nil) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(navigation ? 10 : 3)
        var latest: [String: Any] = [:]
        var previous = ""
        var stable = 0
        var ready = false
        repeat {
            try await Task.sleep(for: .milliseconds(250))
            guard !disposed else { throw CancellationError() }
            if let expectedNavigation, activeNavigation !== expectedNavigation { throw CancellationError() }
            if let current = try? await observe() {
                if let expectedNavigation, activeNavigation !== expectedNavigation { throw CancellationError() }
                latest = current
                let items = current["elements"] as? [[String: Any]] ?? []
                let fingerprint =
                    (current["url"] as? String ?? "")
                    + items.prefix(12).compactMap { $0["label"] as? String }.joined(separator: "|")
                stable = fingerprint == previous ? stable + 1 : 0
                previous = fingerprint
                if (!loading || (navigationCommitted && Self.contentReady(current))) && stable >= 1 { ready = true; break }
            }
        } while Date() < deadline
        try Task.checkCancellation()
        guard ready, !latest.isEmpty else { throw PageReadUnavailable() }
        latest["loading"] = loading
        latest["ok"] = true
        updateState(latest)
        if model.browser === self { model.lastObservation = latest }
        return latest
    }
    func clearResourceCache() async {
        if let systemPage { _ = try? await systemPage.client?.call("Network.clearBrowserCache"); return }
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
    }
    func screenshot() async throws -> String {
        if let systemPage { return try await systemPage.screenshot() }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1000
        let image = try await webView.takeSnapshot(configuration: config)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { throw AppError.message("Unable to capture the page.") }
        return jpeg.base64EncodedString()
    }
}
