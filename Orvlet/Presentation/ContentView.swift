import SwiftUI
import WebKit

struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WebViewport { WebViewport(webView: webView) }
    func updateNSView(_ view: WebViewport, context: Context) { view.needsLayout = true }
}

final class WebViewport: NSView {
    let webView: WKWebView
    override var isFlipped: Bool { true }
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        webView.autoresizingMask = []
        addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard webView.superview === self, bounds.width > 1, bounds.height > 1 else { return }
        webView.frame = bounds
    }
}
