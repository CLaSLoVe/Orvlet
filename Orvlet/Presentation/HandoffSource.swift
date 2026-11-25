import Combine
import SwiftUI
import WebKit

/// A source opened by the person, inside the side screen. This view has no agent script bridge.
@MainActor
final class HandoffSource: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private let adBlocker = AdBlocker()
    private unowned let model: AppModel
    let windowPlayer: WindowPlayer
    let taskID: UUID
    let destination: URL
    let document: String?
    let webView: WKWebView?
    let systemBrowser: BrowserController?
    let isBrowserManager: Bool
    @Published var failed = false

    init(taskID: UUID, destination: URL, model: AppModel, browserManager: Bool = false) throws {
        self.model = model
        windowPlayer = WindowPlayer(model: model)
        self.taskID = taskID
        self.destination = destination
        self.isBrowserManager = browserManager
        if browserManager, destination.absoluteString != "chrome://extensions/",
            !(model.usesNativeBrowser && model.nativeExtensions.owns(destination)) {
            throw AppError.message("Unknown browser settings page.")
        }
        if destination.isFileURL {
            document = try String(contentsOf: destination, encoding: .utf8)
            webView = nil
            systemBrowser = nil
        } else if model.settings.browserEngine == .systemBrowser || model.usesNativeBrowser {
            if !browserManager { _ = try PublicDataClient.url(destination.absoluteString) }
            document = nil
            webView = nil
            systemBrowser = BrowserController(model: model)
        } else {
            _ = try PublicDataClient.url(destination.absoluteString)
            document = nil
            systemBrowser = nil
            let config = WKWebViewConfiguration.orvletSiteBrowser()
            if #available(macOS 15.4, *) { model.extensions.configure(config) }
            config.mediaTypesRequiringUserActionForPlayback = .all
            AdBlocker.installHelper(in: config.userContentController, enabled: model.settings.blockAds)
            webView = WKWebView(frame: .zero, configuration: config)
        }
        super.init()
        if let systemBrowser {
            systemBrowser.setUserPlaybackPaused(true, origin: "source_open")
            Task { [weak self] in
                do { try await self?.loadSystemPage() }
                catch { self?.failed = true }
            }
        }
        if let webView {
            if #available(macOS 15.4, *) { model.extensions.register(webView) }
            windowPlayer.web = webView
            webView.configuration.userContentController.add(windowPlayer, contentWorld: .defaultClient, name: "orvletWindowPlayer")
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = true
            webView.load(URLRequest(url: destination))
        }
    }

    func loadSystemPage() async throws {
        guard let systemBrowser else { return }
        failed = false
        if isBrowserManager, let page = systemBrowser.systemPage {
            try await page.ready()
            _ = try await page.client?.call("Page.navigate", ["url": destination.absoluteString])
        } else { _ = try await systemBrowser.action(["action": "navigate", "url": destination.absoluteString]) }
    }

    func close() {
        windowPlayer.changed(false)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "orvletWindowPlayer", contentWorld: .defaultClient)
        systemBrowser?.dispose()
        webView?.stopLoading()
        if let webView { if #available(macOS 15.4, *) { model.extensions.unregister(webView) } }
    }
    func configureAdBlocking() async {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        WindowPlayer.install(in: controller)
        AdBlocker.installHelper(in: controller, enabled: model.settings.blockAds)
        await adBlocker.update(webView, model: model)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, ["http", "https", "about", "blob"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { webView.load(action.request) }
            return
        }
        Task {
            if #available(macOS 15.4, *) { await model.extensions.ready() }
            if model.settings.blockAds && !adBlocker.hasRules { await adBlocker.applyRules(to: webView, model: model) }
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { windowPlayer.changed(false) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failed = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }
}

struct HandoffSourceView: View {
    @ObservedObject var source: HandoffSource
    var body: some View {
        if let text = source.document {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } else if let page = source.systemBrowser?.systemPage {
            if source.failed {
                Button("Retry loading page") { Task { do { try await source.loadSystemPage() } catch { source.failed = true } } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { BrowserPageSurface(page: page, visible: true) }
        } else if let web = source.webView {
            if source.failed {
                Button("Retry loading page") { web.load(URLRequest(url: source.destination)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebSurface(webView: web)
            }
        }
    }
}
