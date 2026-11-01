import SwiftUI
import AppKit

/// Delay click activation until release; moving five points turns the same target into a window drag.
struct WindowDragArea: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    var enabled = true
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.onClick = onClick; view.enabled = enabled }
    final class DragView: NSView {
        var onClick: (() -> Void)?
        var enabled = true
        private var startPoint: NSPoint?
        private var startOrigin: NSPoint = .zero
        private(set) var didDrag = false
        override var acceptsFirstResponder: Bool { onClick != nil && enabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard enabled, let window else { return }
            startPoint = window.convertPoint(toScreen:event.locationInWindow)
            startOrigin = window.frame.origin; didDrag = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startPoint, let window else { return }
            let point = window.convertPoint(toScreen:event.locationInWindow)
            let dx = point.x-startPoint.x, dy = point.y-startPoint.y
            guard didDrag || hypot(dx,dy) >= 5 else { return }
            didDrag = true
            window.setFrameOrigin(NSPoint(x:startOrigin.x+dx,y:startOrigin.y+dy))
        }
        override func mouseUp(with event: NSEvent) {
            guard startPoint != nil else { return }
            startPoint = nil
            if enabled && !didDrag && bounds.contains(convert(event.locationInWindow,from:nil)) { onClick?() }
        }
        override func keyDown(with event: NSEvent) {
            if enabled && (event.keyCode == 49 || event.keyCode == 36) { onClick?() }
            else { super.keyDown(with:event) }
        }
    }
}

struct WindowDragButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .overlay { WindowDragArea(onClick:configuration.trigger,enabled:enabled).accessibilityHidden(true) }
            .accessibilityAction { if enabled { configuration.trigger() } }
    }
}
