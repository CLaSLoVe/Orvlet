import WebKit

/// One presentation session per source, shared by the task and handoff browsers.
@MainActor
final class WindowPlayer: NSObject, WKScriptMessageHandler {
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "window-player", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
    static let observer = """
        if (window === top) document.addEventListener('orvlet-window-player-changed', () => {
          const active = document.documentElement.hasAttribute('data-orvlet-player-active');
          if (window.webkit?.messageHandlers?.orvletWindowPlayer) {
            window.webkit.messageHandlers.orvletWindowPlayer.postMessage(active);
          } else {
            window.__orvletWindowPlayerChanged?.(String(active));
          }
        });
        """
    private static let subframePlaybackObserver = """
        if (window !== top) {
          const id = crypto.getRandomValues(new Uint32Array(4)).join('-');
          let active = false;
          const report = playing => {
            if (active === playing) return;
            active = playing;
            window.webkit.messageHandlers.orvletWindowPlayer.postMessage({frame: id, playing});
          };
          const update = () => report(Array.from(document.querySelectorAll('video,audio')).some(m => !m.paused && !m.ended));
          for (const name of ['playing', 'pause', 'ended', 'emptied']) document.addEventListener(name, update, true);
          window.addEventListener('pagehide', () => report(false));
        }
        """
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: observer, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: subframePlaybackObserver, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private weak var model: AppModel?
    private var playingFrames: [String: WKFrameInfo] = [:]
    weak var web: WKWebView?
    weak var page: SystemBrowserPage?
    init(model: AppModel) { self.model = model }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web else { return }
        if message.frameInfo.isMainFrame, let active = message.body as? Bool {
            changed(active)
        } else if !message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
                  let id = data["frame"] as? String, let playing = data["playing"] as? Bool {
            playingFrames[id] = playing ? message.frameInfo : nil
        }
    }

    func changed(_ active: Bool) {
        guard let model else { return }
        if active {
            guard model.visibleWindowPlayer === self else { exit(); return }
            model.activeWindowPlayer = self
        } else if model.activeWindowPlayer === self {
            model.activeWindowPlayer = nil
        }
    }

    var address: URL? { page?.currentURL ?? web?.url }

    enum MediaState: Int { case none, primaryPlayer, playing }
    static let mediaProbe = """
        (() => {
          const media = Array.from(document.querySelectorAll('video,audio'));
          if (media.some(m => !m.paused && !m.ended)) return 2;
          if (window !== top) return 0;
          const type = document.querySelector('meta[property="og:type"]')?.content?.toLowerCase() || '';
          if (/^(video|music)([.]|$)/.test(type) || document.contentType.startsWith('audio/') || document.contentType.startsWith('video/')) return 1;
          if (type === 'article') return 0;
          const primary = media.some(m => {
            if (!(m.currentSrc || m.srcObject) || m.closest('article,aside,nav')) return false;
            if (navigator.mediaSession?.metadata?.title) return true;
            if (m.checkVisibility?.({checkOpacity: true, checkVisibilityCSS: true}) === false) return false;
            const box = m.getBoundingClientRect();
            const width = Math.max(0, Math.min(innerWidth, box.right) - Math.max(0, box.left));
            const height = Math.max(0, Math.min(innerHeight, box.bottom) - Math.max(0, box.top));
            if (!width || !height) return false;
            if (m.controls && m.matches('main > :only-child, body > :only-child')) return true;
            return m.tagName === 'VIDEO' && width * height >= innerWidth * innerHeight / 4;
          });
          return primary ? 1 : 0;
        })()
        """
    func mediaState() async -> MediaState {
        if let page { return await page.mediaState() }
        guard let web else { return .none }
        let value = try? await web.callAsyncJavaScript("return " + Self.mediaProbe, arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
        let state = MediaState(rawValue: value ?? 0) ?? .none
        guard state != .playing else { return state }
        for (id, frame) in playingFrames {
            let result = try? await web.callAsyncJavaScript("return " + Self.mediaProbe, arguments: [:], in: frame, contentWorld: .defaultClient) as? Int
            if result == MediaState.playing.rawValue { return .playing }
            if playingFrames[id] === frame { playingFrames[id] = nil }
        }
        return state
    }

    func exit() {
        changed(false)
        let fallback = "window.__orvletExitWindowPlayer?.()"
        if let page {
            let script = page.host.native ? "document.fullscreenElement && document.exitFullscreen()" : fallback
            Task { _ = try? await page.evaluate(script) }
        } else { web?.evaluateJavaScript(fallback, completionHandler: nil) }
    }
}
