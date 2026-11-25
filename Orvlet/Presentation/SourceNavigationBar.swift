import Combine
import SwiftUI
import WebKit

struct SourceNavigationBar: View {
    @Environment(\.openURL) private var openExternalURL
    @ObservedObject var model: AppModel
    @State private var address: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var error: String?
    @State private var focused = false

    private var browser: BrowserController? { model.visibleSourceBrowser }
    private var web: WKWebView? { model.visibleHandoff?.webView ?? browser?.webView }
    private var currentAddress: URL? {
        if let page = browser?.systemPage { return page.currentURL }
        return web?.url
    }
    private var addressChanges: AnyPublisher<URL?, Never> {
        if let page = browser?.systemPage { return page.$currentURL.eraseToAnyPublisher() }
        if let web { return web.publisher(for: \.url).eraseToAnyPublisher() }
        return Just(nil).eraseToAnyPublisher()
    }
    private var historyChanges: AnyPublisher<(Bool, Bool), Never> {
        if let page = browser?.systemPage {
            return page.$historyItems.map { ($0.back != nil, $0.forward != nil) }.eraseToAnyPublisher()
        }
        if let web {
            return web.publisher(for: \.canGoBack).combineLatest(web.publisher(for: \.canGoForward)).eraseToAnyPublisher()
        }
        return Just((false, false)).eraseToAnyPublisher()
    }
    var body: some View {
        HStack(spacing: 4) {
            Button { navigate("back") } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .disabled(!canGoBack).help("Back")
            Button { navigate("forward") } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                .disabled(!canGoForward).help("Forward")
            Button { navigate("reload") } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                .help("Reload")
            if browser?.systemPage == nil, let web {
                if #available(macOS 15.4, *) { BrowserExtensionMenu(host: model.extensions, web: web) }
            }
            WebAddressField(address: AppModel.externalPageURL(address)?.absoluteString ?? "",
                            focusRequest: model.addressFocusRequest, editing: { editing in
                focused = editing
                model.editingWebAddress = editing
            }, submit: submit)
                .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 19)
                .background(.primary.opacity(focused ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 5))
            Button {
                guard let url = AppModel.externalPageURL(currentAddress), let source = model.visibleWindowPlayer else { return }
                openExternalURL(url) { accepted in
                    if accepted { Task { await model.didOpenExternally(url, source: source) } }
                    else { error = "The default browser could not open this address." }
                }
            } label: {
                Image(systemName: "arrow.up.right.square").frame(width: 24, height: 22)
            }
            .buttonStyle(WindowDragButtonStyle(allowsWindowDrag: false))
            .disabled(AppModel.externalPageURL(address) == nil)
            .help("Open in default browser").accessibilityLabel("Open in default browser")
            .accessibilityIdentifier("open-page-externally")
        }
        .font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 22)
        .onReceive(addressChanges.removeDuplicates()) { address = $0 }
        .onReceive(historyChanges.removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })) { history in
            canGoBack = history.0
            canGoForward = history.1
        }
        .onDisappear { if focused { model.editingWebAddress = false } }
        .alert("Web address", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func submit(_ draft: String) -> Bool {
        guard let url = AppModel.addressURL(draft) else { error = "Enter a valid web address."; return false }
        navigate("navigate", to: url)
        return true
    }

    private func navigate(_ action: String, to url: URL? = nil) {
        if let browser {
            var input: [String: Any] = ["action": action]
            if let url { input["url"] = url.absoluteString }
            let previous = currentAddress
            Task {
                do {
                    _ = try await browser.action(input)
                    if let url { model.didEnterWebAddress(url, replacing: previous, taskID: browser.id) }
                }
                catch is CancellationError {}
                catch { self.error = error.localizedDescription }
            }
        } else if let web {
            if let url { web.load(URLRequest(url: url)) }
            else if action == "back" { web.goBack() }
            else if action == "forward" { web.goForward() }
            else { web.reload() }
        }
    }
}

private struct WebAddressField: NSViewRepresentable {
    let address: String
    let focusRequest: Int
    let editing: (Bool) -> Void
    let submit: (String) -> Bool

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.lastRequest = focusRequest
        field.placeholderString = "Enter web address"
        field.setAccessibilityLabel("Web address")
        field.setAccessibilityIdentifier("source-address")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 10)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = field
        field.target = field
        field.action = #selector(Field.openAddress(_:))
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.onEditing = editing
        field.onSubmit = submit
        if field.currentEditor() == nil, field.stringValue != address { field.stringValue = address }
        if field.lastRequest != focusRequest {
            field.lastRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.makeFirstResponder(field) else { return }
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Field: NSTextField, NSTextFieldDelegate {
        var lastRequest = 0
        var onEditing: ((Bool) -> Void)?
        var onSubmit: ((String) -> Bool)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onEditing?(true) }
            return accepted
        }
        @objc func openAddress(_ sender: NSTextField) {
            if onSubmit?(sender.stringValue) == true { window?.makeFirstResponder(nil) }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            onEditing?(false)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            window?.makeFirstResponder(nil)
            return true
        }
    }
}
