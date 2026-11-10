import SwiftUI
import WebKit

struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> ScaledWebViewport { ScaledWebViewport(webView: webView) }
    func updateNSView(_ view: ScaledWebViewport, context: Context) { view.needsLayout = true }
}

// Keep a desktop-sized CSS viewport, then scale the native view coordinate system.
// AppKit maps real mouse events through this transform; the agent continues using DOM coordinates.
final class ScaledWebViewport: NSView {
    let webView: WKWebView
    private let canvas = NSView()
    override var isFlipped: Bool { true }
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        canvas.autoresizesSubviews = false
        addSubview(canvas)
        webView.autoresizingMask = []
        canvas.addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let virtualWidth = max(1000, bounds.width)
        let scale = bounds.width / virtualWidth
        let virtualSize = NSSize(width: virtualWidth, height: bounds.height / scale)
        canvas.frame = bounds
        canvas.setBoundsSize(virtualSize)
        webView.frame = NSRect(origin: .zero, size: virtualSize)
    }
}
