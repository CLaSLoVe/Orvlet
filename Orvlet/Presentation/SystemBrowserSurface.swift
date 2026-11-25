import SwiftUI
import AppKit
import Combine

struct SystemBrowserSurface: NSViewRepresentable {
    let page: SystemBrowserPage
    var visible: Bool
    func makeNSView(context: Context) -> SystemBrowserCanvas { SystemBrowserCanvas(page: page) }
    func updateNSView(_ view: SystemBrowserCanvas, context: Context) {
        view.presented = visible
        view.needsDisplay = true
        page.setVisible(visible, size: view.bounds.size)
    }
    static func dismantleNSView(_ view: SystemBrowserCanvas, coordinator: ()) {
        view.page.setVisible(false, size: view.bounds.size)
    }
}

/// A live browser viewport. Cocoa owns focus/IME; Chromium owns the actual DOM and selection.
final class SystemBrowserCanvas: NSView, NSTextInputClient {
    let page: SystemBrowserPage
    var presented = false
    private var marked = NSAttributedString(string: "")
    private var lastPoint = NSPoint.zero
    private var updates: Set<AnyCancellable> = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(page: SystemBrowserPage) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        setAccessibilityLabel("Task browser page")
        // Video frames repaint only this canvas, not the surrounding SwiftUI tree.
        page.$frame.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &updates)
        page.$issue.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &updates)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); page.setVisible(presented, size: bounds.size) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        if let image = page.frame {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let issue = page.issue {
            let text = NSAttributedString(string: issue, attributes: [.font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.windowBackgroundColor])
            text.draw(in: NSRect(x: 12, y: 12, width: max(1, bounds.width - 24), height: 54))
        }
    }
    private func modifiers(_ e: NSEvent) -> Int {
        (e.modifierFlags.contains(.option) ? 1 : 0) | (e.modifierFlags.contains(.control) ? 2 : 0)
            | (e.modifierFlags.contains(.command) ? 4 : 0) | (e.modifierFlags.contains(.shift) ? 8 : 0)
    }
    private var inputScale: NSSize {
        NSSize(width: page.viewportSize.width / max(1, bounds.width),
               height: page.viewportSize.height / max(1, bounds.height))
    }
    private func mouse(_ e: NSEvent, type: String, buttons: Int) {
        guard presented else { return }
        lastPoint = convert(e.locationInWindow, from: nil)
        let scale = inputScale
        page.input("Input.dispatchMouseEvent", ["type": type, "x": lastPoint.x * scale.width, "y": lastPoint.y * scale.height,
            "button": buttons == 0 && type == "mouseMoved" ? "none" : "left", "buttons": buttons,
            "clickCount": max(1, e.clickCount), "modifiers": modifiers(e)])
    }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        page.owner?.model.controlInteraction(true)
        mouse(e, type: "mousePressed", buttons: 1)
    }
    override func mouseUp(with e: NSEvent) {
        mouse(e, type: "mouseReleased", buttons: 0)
        page.owner?.model.controlInteraction(false)
    }
    override func mouseDragged(with e: NSEvent) { mouse(e, type: "mouseMoved", buttons: 1) }
    override func mouseMoved(with e: NSEvent) { mouse(e, type: "mouseMoved", buttons: 0) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func scrollWheel(with e: NSEvent) {
        guard presented else { return }
        let point = convert(e.locationInWindow, from: nil)
        let scale = inputScale
        let factor = e.hasPreciseScrollingDeltas ? 1.0 : 24.0
        page.input("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": point.x * scale.width, "y": point.y * scale.height,
            "deltaX": -e.scrollingDeltaX * factor * scale.width, "deltaY": -e.scrollingDeltaY * factor * scale.height,
            "modifiers": modifiers(e)])
    }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), let key = e.charactersIgnoringModifiers?.lowercased() {
            if key == "v" { if let text = NSPasteboard.general.string(forType: .string) { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }; return }
            if key == "c" || key == "x" {
                page.enqueue { [weak self] in
                    guard let self else { return }
                    let text = try await page.evaluate("(() => {const e=document.activeElement;if(e?.type==='password')return '';return typeof e?.selectionStart==='number'?e.value.substring(e.selectionStart,e.selectionEnd):getSelection().toString()})()") as? String ?? ""
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if key == "x" {
                        _ = try await page.client?.call("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "Backspace",
                            "windowsVirtualKeyCode": 8, "commands": ["deleteBackward"]])
                    }
                }
                return
            }
            let commands = ["a": "selectAll", "z": e.modifierFlags.contains(.shift) ? "redo" : "undo"]
            if let command = commands[key] {
                page.input("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": key, "modifiers": modifiers(e), "commands": [command]])
                return
            }
        }
        interpretKeyEvents([e])
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = NSAttributedString(string: "")
        page.input("Input.insertText", ["text": text])
    }
    override func doCommand(by selector: Selector) {
        let mapping: [String: (String, Int)] = ["insertNewline:": ("Enter", 13), "insertTab:": ("Tab", 9),
            "insertBacktab:": ("Tab", 9), "deleteBackward:": ("Backspace", 8), "deleteForward:": ("Delete", 46),
            "moveLeft:": ("ArrowLeft", 37), "moveRight:": ("ArrowRight", 39), "moveUp:": ("ArrowUp", 38),
            "moveDown:": ("ArrowDown", 40), "moveToBeginningOfLine:": ("Home", 36), "moveToEndOfLine:": ("End", 35),
            "pageUp:": ("PageUp", 33), "pageDown:": ("PageDown", 34), "cancelOperation:": ("Escape", 27)]
        let name = NSStringFromSelector(selector)
        let base = name.replacingOccurrences(of: "AndModifySelection", with: "")
        guard let (key, code) = mapping[base] else { return }
        let shift = name.contains("AndModifySelection") || name == "insertBacktab:"
        var params: [String: Any] = ["type": "keyDown", "key": key, "windowsVirtualKeyCode": code, "modifiers": shift ? 8 : 0]
        if key == "Enter" { params["text"] = "\r" }
        page.input("Input.dispatchKeyEvent", params)
        params["type"] = "keyUp"; params.removeValue(forKey: "text")
        page.input("Input.dispatchKeyEvent", params)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        page.input("Input.imeSetComposition", ["text": marked.string, "selectionStart": selectedRange.location,
            "selectionEnd": selectedRange.location + selectedRange.length])
    }
    func unmarkText() { if !marked.string.isEmpty { insertText(marked.string, replacementRange: markedRange()) } }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = convert(NSRect(x: lastPoint.x, y: lastPoint.y + 20, width: 1, height: 20), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }
}
