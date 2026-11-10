import AppKit
import Combine
import SwiftUI

struct TaskDragAppearance {
    let title: String
    let symbol: String
    let accent: Color
    let closeLabel: String
    let reducedMotion: Bool
}

extension AppModel {
    func dragAppearance(_ id: UUID) -> TaskDragAppearance {
        let task = sideTasks.first { $0.id == id }
        return TaskDragAppearance(
            title: task?.title ?? "Task", symbol: task?.symbol ?? "square", accent: accent,
            closeLabel: "Release to close", reducedMotion: motionReduced)
    }
}

private final class TaskDragPreviewState: ObservableObject {
    @Published var outside = false
}

private struct TaskDragPreview: View {
    let appearance: TaskDragAppearance
    @ObservedObject var state: TaskDragPreviewState
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                CalmGlyph(symbol: appearance.symbol, accent: appearance.accent)
                Text(appearance.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 6).frame(width: 120, height: 34)
                .background(
                    scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        appearance.accent.opacity(state.outside ? 0.6 : 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                .scaleEffect(state.outside && !appearance.reducedMotion ? 0.94 : 1)
            Label(appearance.closeLabel, systemImage: "xmark.circle.fill")
                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule()).opacity(state.outside ? 1 : 0)
        }.padding(10).frame(width: 160, height: 82)
            .animation(CalmMotion.animation(reduced: appearance.reducedMotion), value: state.outside)
    }
}

/// Delay activation until release. Card drags preview closing; background drags move the window.
struct WindowDragArea: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    var onOutsideDrop: (() -> Void)? = nil
    var taskID: UUID? = nil
    var taskPreview: TaskDragAppearance? = nil
    var dragging: (Bool) -> Void = { _ in }
    var enabled = true
    var pressed: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick
        view.enabled = enabled
        view.pressed = pressed
        view.onOutsideDrop = onOutsideDrop
        view.taskPreview = taskPreview
        view.dragging = dragging
        view.identifier = taskID.map { NSUserInterfaceItemIdentifier($0.uuidString) }
    }
    class DragView: NSView {
        var onOutsideDrop: (() -> Void)?
        var onClick: (() -> Void)?
        var enabled = true
        var pressed: (Bool) -> Void = { _ in }
        var taskPreview: TaskDragAppearance?
        var dragging: (Bool) -> Void = { _ in }
        private(set) var dragPreviewPanel: NSPanel?
        private(set) var outsideDropArmed = false
        private var previewState = TaskDragPreviewState()
        private let previewMotion = CalmMotionDriver()
        private var previewHome = NSRect.zero
        private var committedDrop = false
        private var startPoint: NSPoint?
        private var startOrigin: NSPoint = .zero
        private(set) var didDrag = false
        override var acceptsFirstResponder: Bool { onClick != nil && enabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard enabled, !committedDrop, let window else { return }
            clearPreview()
            if onOutsideDrop != nil { window.makeFirstResponder(self) }
            startPoint = window.convertPoint(toScreen: event.locationInWindow)
            startOrigin = window.frame.origin
            didDrag = false
            pressed(true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startPoint, let window else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            guard didDrag || hypot(dx, dy) >= 5 else { return }
            let firstDrag = !didDrag
            didDrag = true
            pressed(false)
            if onOutsideDrop != nil {
                if firstDrag { beginPreview(at: startPoint) }
                outsideDropArmed = !window.frame.insetBy(dx: -28, dy: -28).contains(point)
                previewState.outside = outsideDropArmed
                dragPreviewPanel?.setFrameOrigin(previewFrame(at: point).origin)
                if outsideDropArmed { NSCursor.disappearingItem.set() } else { NSCursor.closedHand.set() }
                return
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        func isOutsideDrop(_ event: NSEvent) -> Bool {
            guard let window else { return false }
            return !window.frame.insetBy(dx: -28, dy: -28).contains(
                window.convertPoint(toScreen: event.locationInWindow))
        }
        override func mouseUp(with event: NSEvent) {
            guard startPoint != nil else { return }
            startPoint = nil
            pressed(false)
            NSCursor.arrow.set()
            if didDrag, onOutsideDrop != nil, let window {
                let closing =
                    enabled
                    && !window.frame.insetBy(dx: -28, dy: -28).contains(
                        window.convertPoint(toScreen: event.locationInWindow))
                finishPreview(closing: closing)
                return
            }
            if enabled && !didDrag && bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, startPoint != nil {
                startPoint = nil
                didDrag = false
                pressed(false)
                NSCursor.arrow.set()
                finishPreview(closing: false)
                return
            }
            if enabled && (event.keyCode == 49 || event.keyCode == 36) {
                onClick?()
            } else {
                super.keyDown(with: event)
            }
        }
        private func beginPreview(at point: NSPoint) {
            guard let appearance = taskPreview, let window else { return }
            previewState = TaskDragPreviewState()
            let panel = NSPanel(
                contentRect: previewFrame(at: point), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = window.level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.appearance = window.effectiveAppearance
            panel.contentView = NSHostingView(rootView: TaskDragPreview(appearance: appearance, state: previewState))
            previewHome = panel.frame
            dragPreviewPanel = panel
            panel.alphaValue = appearance.reducedMotion ? 1 : 0
            panel.orderFrontRegardless()
            dragging(true)
            previewMotion.run(
                duration: appearance.reducedMotion ? 0 : CalmMotion.content, window: panel,
                update: { [weak panel] t in panel?.alphaValue = t })
        }
        private func previewFrame(at point: NSPoint) -> NSRect {
            var frame = NSRect(x: point.x - 80, y: point.y - 58, width: 160, height: 82)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? window?.screen {
                let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            return frame
        }
        private func finishPreview(closing: Bool) {
            let action = closing ? onOutsideDrop : nil
            committedDrop = closing
            outsideDropArmed = false
            guard let panel = dragPreviewPanel else {
                committedDrop = false
                dragging(false)
                action?()
                return
            }
            let from = panel.frame
            let reduced = taskPreview?.reducedMotion == true
            let target =
                reduced ? from : closing ? from.insetBy(dx: from.width * 0.13, dy: from.height * 0.13) : previewHome
            let alpha = panel.alphaValue
            previewMotion.run(
                duration: reduced ? 0 : CalmMotion.content, window: panel,
                update: { [weak panel] t in
                    panel?.setFrame(CalmMotion.blend(from, target, t), display: true)
                    panel?.alphaValue = alpha * (1 - t)
                },
                completion: { [self] in
                    clearPreview()
                    action?()
                })
        }
        private func clearPreview() {
            let wasDragging = dragPreviewPanel != nil
            previewMotion.cancel()
            dragPreviewPanel?.orderOut(nil)
            dragPreviewPanel = nil
            outsideDropArmed = false
            committedDrop = false
            if wasDragging { dragging(false) }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // A source refresh may replace its view during the dismissal. Once
            // released outside, finish that one committed close independently.
            if newWindow == nil {
                startPoint = nil
                didDrag = false
                if !committedDrop { clearPreview() }
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct WindowDragButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PressableDragButton(configuration: configuration) }
}

private struct PressableDragButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.calmReducedMotion) private var reduced
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @State private var pressed = false
    var body: some View {
        configuration.label
            .scaleEffect(pressed && !reduced && !systemReduced ? 0.96 : 1)
            .opacity(pressed ? 0.72 : 1)
            .animation(CalmMotion.response(reduced: reduced || systemReduced, pressed: pressed), value: pressed)
            .contentShape(Rectangle())
            .overlay {
                WindowDragArea(onClick: configuration.trigger, enabled: enabled, pressed: { pressed = $0 })
                    .accessibilityHidden(true)
            }
            .accessibilityAction { if enabled { configuration.trigger() } }
    }
}

/// A local row drag: keep mouse ownership separate from window movement and context menus.
struct TaskDragHandle: NSViewRepresentable {
    var appearance: TaskDragAppearance
    var close: () -> Void
    var begin: () -> Void
    var preview: (Int) -> Void
    var commit: (Int) -> Void
    var end: () -> Void
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.taskPreview = appearance
        view.onOutsideDrop = close
        view.dragging = { active in if active { begin() } else { end() } }
        view.preview = preview
        view.commit = commit
    }
    /// Shelf reordering extends the same cancellable outside-drop gesture as compact cards.
    final class HandleView: WindowDragArea.DragView {
        var preview: (Int) -> Void = { _ in }
        var commit: (Int) -> Void = { _ in }
        private var rowStart: NSPoint?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            rowStart = window?.convertPoint(toScreen: event.locationInWindow)
        }
        private func offset(_ event: NSEvent) -> Int {
            guard let rowStart, let window else { return 0 }
            return Int(((rowStart.y - window.convertPoint(toScreen: event.locationInWindow).y) / 46).rounded())
        }
        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            guard didDrag else { return }
            preview(outsideDropArmed ? 0 : offset(event))
        }
        override func mouseUp(with event: NSEvent) {
            let reorder = didDrag && !isOutsideDrop(event) ? offset(event) : 0
            super.mouseUp(with: event)
            rowStart = nil
            if reorder != 0 { commit(reorder) }
        }
    }
}

struct TaskCardButtonStyle: PrimitiveButtonStyle {
    let model: AppModel
    let id: UUID
    func makeBody(configuration: Configuration) -> some View {
        PressableTaskCard(configuration: configuration, model: model, id: id)
    }
}

private struct PressableTaskCard: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let model: AppModel
    let id: UUID
    @Environment(\.isEnabled) private var enabled
    @State private var pressed = false
    var body: some View {
        configuration.label
            .opacity(pressed ? 0.72 : 1)
            .animation(CalmMotion.response(reduced: model.motionReduced, pressed: pressed), value: pressed)
            .contentShape(Rectangle())
            .overlay {
                WindowDragArea(
                    onClick: configuration.trigger, onOutsideDrop: { model.closeTask(id) }, taskID: id,
                    taskPreview: model.dragAppearance(id), dragging: { model.draggingTaskID = $0 ? id : nil },
                    enabled: enabled, pressed: { pressed = $0 }
                ).accessibilityHidden(true)
            }
            .accessibilityAction { if enabled { configuration.trigger() } }
    }
}
