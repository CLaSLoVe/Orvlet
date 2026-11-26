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
            title: task?.kind == .timer ? "Timer" : task?.title ?? "Task", symbol: task?.symbol ?? "square", accent: accent,
            closeLabel: "Release to close", reducedMotion: motionReduced)
    }
}

/// Identifies the complete capsule even when the drag begins on its smaller playback control.
struct TaskDragSourceMarker: NSViewRepresentable {
    let id: UUID
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
    }
}

private final class TaskDragPreviewState: ObservableObject {
    @Published var outside = false
}

private struct TaskDragPreview: View {
    let appearance: TaskDragAppearance
    let image: NSImage?
    @ObservedObject var state: TaskDragPreviewState
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable()
                    .mask { RoundedRectangle(cornerRadius: 9).inset(by: 2).blur(radius: 0.6) }
            } else {
                HStack(spacing: 6) {
                    CalmGlyph(symbol: appearance.symbol, accent: appearance.accent)
                    Text(appearance.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 6)
            }
        }
        .frame(width: CalmVisualStyle.rowWidth, height: CalmVisualStyle.rowHeight)
        .overlay(alignment: .bottom) {
            Label(appearance.closeLabel, systemImage: "xmark.circle.fill")
                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
                .fixedSize().background(.regularMaterial, in: Capsule())
                .offset(y: 23).opacity(state.outside ? 1 : 0)
        }
        .animation(state.outside ? CalmMotion.animation(reduced: appearance.reducedMotion) : nil, value: state.outside)
    }
}

/// Both sides of the neck are computed from the current pointer offset, so reversing a drag
/// retraces the same contour. Only the small, transparent preview window needs repainting.
private final class PeelPreviewView: NSView {
    var displacement = NSSize.zero { didSet { needsDisplay = true } }
    var cardCenter = NSPoint(x: PeelPreviewView.previewSize.width / 2, y: PeelPreviewView.previewSize.height / 2) {
        didSet {
            subviews.first?.setFrameOrigin(NSPoint(x: cardCenter.x - bounds.midX, y: cardCenter.y - bounds.midY))
            needsDisplay = true
        }
    }
    private let appearanceStyle: TaskDragAppearance
    private let material: NSColor?
    private let state: TaskDragPreviewState
    init(appearance: TaskDragAppearance, image: NSImage?, material: NSColor?, state: TaskDragPreviewState) {
        self.appearanceStyle = appearance
        self.material = material
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: Self.previewSize))
        let content = NSHostingView(rootView: TaskDragPreview(appearance: appearance, image: image, state: state))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { return nil }
    static let previewSize = NSSize(width: 244, height: 148)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = NSSize(width: CalmVisualStyle.rowWidth, height: CalmVisualStyle.rowHeight)
        let card = CGRect(x: cardCenter.x - size.width / 2, y: cardCenter.y - size.height / 2,
                          width: size.width, height: size.height)
        let dx = displacement.width, dy = displacement.height
        let peel = min(1, hypot(dx / (size.width + 22), dy / (size.height + 22)))
        let path: NSBezierPath
        if !appearanceStyle.reducedMotion && peel > 0 && peel < 1 {
            // The ink travels on the intact moving card. The empty pearl at its old position
            // draws inward as the gap grows. A single outline owns both contact shoulders.
            let remaining = 1 - peel * peel * (3 - 2 * peel)
            let width = max(0.01, size.width * remaining), height = max(0.01, size.height * remaining)
            let source = CGRect(x: cardCenter.x - dx * 0.94 - width / 2,
                                y: cardCenter.y - dy * 0.94 - height / 2, width: width, height: height)
            let smoothing = 20 * sqrt(remaining) * min(1, peel / 0.2)
            path = Self.joinedOutline(card: card, source: source, smoothing: max(0.01, smoothing))
        } else {
            path = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = material ?? NSColor(CalmVisualStyle.windowFill(dark ? .dark : .light))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.18 : 0.08)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(appearanceStyle.accent).withAlphaComponent(state.outside ? 0.48 : 0.14).setStroke()
        path.lineWidth = 0.65
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Sample the exact rounded-rectangle distance fields only around these two small pills.
    /// A smooth minimum makes their contours tangent where they meet, including at corners.
    /// Shared grid edges let both lobes close independently as the narrowing neck separates.
    private static func joinedOutline(card: CGRect, source: CGRect, smoothing: CGFloat) -> NSBezierPath {
        let box = card.union(source).insetBy(dx: -smoothing / 4 - 3, dy: -smoothing / 4 - 3)
        let pitch: CGFloat = 2
        let columns = Int(ceil(box.width / pitch)) + 1, rows = Int(ceil(box.height / pitch)) + 1
        func distance(_ x: CGFloat, _ y: CGFloat, _ r: CGRect, _ radius: CGFloat) -> CGFloat {
            let qx = abs(x - r.midX) - r.width / 2 + radius, qy = abs(y - r.midY) - r.height / 2 + radius
            return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
        }
        let radius = min(10, source.height / 2, source.width / 2)
        var samples = [CGFloat](repeating: 0, count: columns * rows)
        for y in 0..<rows {
            for x in 0..<columns {
                let px = box.minX + CGFloat(x) * pitch, py = box.minY + CGFloat(y) * pitch
                let a = distance(px, py, card, 10), b = distance(px, py, source, radius)
                let overlap = max(0, smoothing - abs(a - b))
                samples[y * columns + x] = min(a, b) - overlap * overlap / (4 * smoothing)
            }
        }
        var points = [Int: NSPoint](), neighbors = [Int: [Int]]()
        func crossing(_ edge: Int, vertical: Bool) -> Int {
            let key = 2 * edge + (vertical ? 1 : 0)
            if points[key] == nil {
                let a = samples[edge], b = samples[edge + (vertical ? columns : 1)], t = a / (a - b)
                points[key] = NSPoint(x: box.minX + (CGFloat(edge % columns) + (vertical ? 0 : t)) * pitch,
                                      y: box.minY + (CGFloat(edge / columns) + (vertical ? t : 0)) * pitch)
            }
            return key
        }
        func connect(_ a: Int, _ b: Int) {
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }
        for y in 0..<(rows - 1) {
            for x in 0..<(columns - 1) {
                let i = y * columns + x
                let a = samples[i], b = samples[i + 1], c = samples[i + columns + 1], d = samples[i + columns]
                let ab = (a < 0) != (b < 0), bc = (b < 0) != (c < 0)
                let cd = (c < 0) != (d < 0), da = (d < 0) != (a < 0)
                guard ab || bc || cd || da else { continue }
                var edges = [Int]()
                if ab { edges.append(crossing(i, vertical: false)) }
                if bc { edges.append(crossing(i + 1, vertical: true)) }
                if cd { edges.append(crossing(i + columns, vertical: false)) }
                if da { edges.append(crossing(i, vertical: true)) }
                if edges.count == 4 && (a < 0) != (a + b + c + d < 0) { edges.swapAt(1, 3) }
                connect(edges[0], edges[1])
                if edges.count == 4 { connect(edges[2], edges[3]) }
            }
        }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        var seen = Set<Int>()
        for start in points.keys where !seen.contains(start) {
            path.move(to: points[start]!)
            var node = start
            while seen.insert(node).inserted, let next = neighbors[node]?.first(where: { !seen.contains($0) }) {
                path.line(to: points[next]!)
                node = next
            }
            path.close()
        }
        return path
    }
}

/// Delay activation until release. Card drags preview closing; background drags move the window.
struct WindowDragArea: NSViewRepresentable {
    var excludedRects: [CGRect] = []
    var onClick: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var delaySingleClick = false
    var allowsWindowDrag = true
    var onOutsideDrop: (() -> Void)? = nil
    var taskID: UUID? = nil
    var taskPreview: TaskDragAppearance? = nil
    var dragging: (Bool) -> Void = { _ in }
    var enabled = true
    var pressed: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.excludedRects = excludedRects
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.delaySingleClick = delaySingleClick
        view.allowsWindowDrag = allowsWindowDrag
        view.enabled = enabled
        view.pressed = pressed
        view.onOutsideDrop = onOutsideDrop
        view.taskPreview = taskPreview
        view.dragging = dragging
        view.identifier = taskID.map { NSUserInterfaceItemIdentifier($0.uuidString) }
    }
    class DragView: NSView {
        var excludedRects: [CGRect] = []
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let topLeft = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
            guard !excludedRects.contains(where: { $0.contains(topLeft) }) else { return nil }
            return super.hitTest(point)
        }
        private static weak var pendingClickOwner: DragView?
        static func cancelPendingClicks() {
            pendingClickOwner?.pendingClick?.cancel()
            pendingClickOwner?.pendingClick = nil
            pendingClickOwner = nil
        }
        var onOutsideDrop: (() -> Void)?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var delaySingleClick = false
        var allowsWindowDrag = true
        private var pendingClick: Task<Void, Never>?
        var enabled = true
        var pressed: (Bool) -> Void = { _ in }
        var taskPreview: TaskDragAppearance?
        var dragging: (Bool) -> Void = { _ in }
        private(set) var dragPreviewPanel: NSPanel?
        private(set) var outsideDropArmed = false
        private var previewState = TaskDragPreviewState()
        private let previewMotion = CalmMotionDriver()
        // Screen coordinates of the original and moving capsule centers.
        private var previewHome = NSPoint.zero
        private var previewCenter = NSPoint.zero
        private var committedDrop = false
        private var startPoint: NSPoint?
        private weak var movingPanel: ShellPanel?
        private func endWindowMove() {
            movingPanel?.moveInteraction(false)
            movingPanel = nil
        }
        private var startOrigin: NSPoint = .zero
        private(set) var didDrag = false
        override var acceptsFirstResponder: Bool { onClick != nil && enabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard enabled, !committedDrop, let window else { return }
            Self.cancelPendingClicks()
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
                if previewState.outside != outsideDropArmed { previewState.outside = outsideDropArmed }
                positionPreview(at: NSPoint(x: previewHome.x + dx, y: previewHome.y + dy))
                setDragCursor(outsideDropArmed ? .disappearingItem : .closedHand)
                return
            }
            guard allowsWindowDrag else { return }
            if firstDrag {
                movingPanel = window as? ShellPanel
                movingPanel?.moveInteraction(true)
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
            setDragCursor(.arrow)
            endWindowMove()
            if didDrag, onOutsideDrop != nil, let window {
                let closing =
                    enabled
                    && !window.frame.insetBy(dx: -28, dy: -28).contains(
                        window.convertPoint(toScreen: event.locationInWindow))
                finishPreview(closing: closing)
                return
            }
            if enabled && !didDrag && bounds.contains(convert(event.locationInWindow, from: nil)) {
                if event.clickCount >= 2, let onDoubleClick {
                    onDoubleClick()
                } else if delaySingleClick, onDoubleClick != nil, let onClick {
                    Self.pendingClickOwner = self
                    pendingClick = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                            guard let self, self.enabled, self.window != nil,
                                Self.pendingClickOwner === self
                            else { return }
                            Self.pendingClickOwner = nil
                            self.pendingClick = nil
                            onClick()
                        } catch {}
                    }
                } else {
                    onClick?()
                }
            }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                Self.cancelPendingClicks()
            }
            if event.keyCode == 53, startPoint != nil {
                endWindowMove()
                startPoint = nil
                didDrag = false
                pressed(false)
                setDragCursor(.arrow)
                finishPreview(closing: false)
                return
            }
            if enabled && (event.keyCode == 49 || event.keyCode == 36) {
                onClick?()
            } else {
                super.keyDown(with: event)
            }
        }
        private func setDragCursor(_ cursor: NSCursor) {
            if !CommandLine.arguments.contains("--background-checks") { cursor.set() }
        }
        private func beginPreview(at point: NSPoint) {
            guard let appearance = taskPreview, let window, let root = window.contentView else { return }
            let grab = window.convertPoint(fromScreen: point)
            func marker(in view: NSView) -> TaskDragSourceMarker.Marker? {
                if let marker = view as? TaskDragSourceMarker.Marker, marker.identifier == identifier,
                    marker.bounds.contains(marker.convert(grab, from: nil)) { return marker }
                for child in view.subviews {
                    if let match = marker(in: child) { return match }
                }
                return nil
            }
            var image: NSImage?
            var material: NSColor?
            previewHome = point
            if let source = marker(in: root) {
                let rect = source.convert(source.bounds, to: root)
                let screenRect = window.convertToScreen(root.convert(rect, to: nil))
                previewHome = NSPoint(x: screenRect.midX, y: screenRect.midY)
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: rect) {
                    root.cacheDisplay(in: rect, to: bitmap)
                    let snapshot = NSImage(size: rect.size)
                    snapshot.addRepresentation(bitmap)
                    image = snapshot
                    // An unprinted point just inside the capsule matches its current composited material.
                    material = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, max(1, bitmap.pixelsWide / 32)),
                                              y: bitmap.pixelsHigh / 2)
                }
            }
            previewState = TaskDragPreviewState()
            let content = PeelPreviewView(appearance: appearance, image: image, material: material, state: previewState)
            let panel = NSPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = window.level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.appearance = window.effectiveAppearance
            panel.contentView = content
            dragPreviewPanel = panel
            positionPreview(at: previewHome)
            panel.orderFrontRegardless()
            dragging(true)
        }
        private func positionPreview(at center: NSPoint) {
            guard let panel = dragPreviewPanel, let content = panel.contentView as? PeelPreviewView else { return }
            var card = center
            var origin = NSPoint(x: card.x - content.bounds.midX, y: card.y - content.bounds.midY)
            if let source = window, NSScreen.screens.contains(where: { $0.frame.intersects(source.frame) }),
                let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? source.screen
            {
                let visible = screen.visibleFrame
                let marginX = CalmVisualStyle.rowWidth / 2 + 4
                let marginY = CalmVisualStyle.rowHeight / 2 + 4
                let hintHeight: CGFloat = previewState.outside ? 23 : 0
                card.x = min(max(card.x, visible.minX + marginX), visible.maxX - marginX)
                card.y = min(max(card.y, visible.minY + marginY + hintHeight), visible.maxY - marginY)
                origin.x = min(max(card.x - content.bounds.midX, visible.minX), visible.maxX - content.bounds.width)
                origin.y = min(max(card.y - content.bounds.midY, visible.minY), visible.maxY - content.bounds.height)
            }
            previewCenter = card
            panel.setFrameOrigin(origin)
            content.cardCenter = NSPoint(x: card.x - origin.x, y: card.y - origin.y)
            content.displacement = NSSize(width: card.x - previewHome.x, height: card.y - previewHome.y)
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
            let from = previewCenter
            let target = previewHome
            let reduced = taskPreview?.reducedMotion == true
            previewState.outside = false
            previewMotion.run(
                duration: reduced ? 0 : (closing ? 0.15 : 0.24), window: panel,
                update: { [weak self, weak panel] t in
                    if closing {
                        panel?.alphaValue = 1 - t
                    } else {
                        self?.positionPreview(at: NSPoint(x: from.x + (target.x - from.x) * t,
                                                        y: from.y + (target.y - from.y) * t))
                    }
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
                if Self.pendingClickOwner === self { Self.cancelPendingClicks() }
                pendingClick?.cancel()
                pendingClick = nil
                pressed(false)
                endWindowMove()
                startPoint = nil
                didDrag = false
                if !committedDrop { clearPreview() }
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

private struct WindowDragExclusions: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    /// Keep native controls and scrolling/reordering regions out of the window gesture.
    func windowDragControl() -> some View {
        anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
    }
    /// SwiftUI can claim transparent gaps between buttons. An explicit hit mask
    /// lets all remaining space move the window without stealing control input.
    func windowDraggableSurface() -> some View {
        overlayPreferenceValue(WindowDragExclusions.self) { anchors in
            GeometryReader { geometry in
                WindowDragArea(excludedRects: anchors.map { geometry[$0] })
                    .accessibilityHidden(true)
            }
        }
    }
}

struct WindowDragButtonStyle: PrimitiveButtonStyle {
    var onDoubleClick: (() -> Void)? = nil
    var delaySingleClick = false
    var allowsWindowDrag = true
    func makeBody(configuration: Configuration) -> some View {
        PressableDragButton(
            configuration: configuration, onDoubleClick: onDoubleClick,
            delaySingleClick: delaySingleClick, allowsWindowDrag: allowsWindowDrag)
    }
}

private struct PressableDragButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let onDoubleClick: (() -> Void)?
    let delaySingleClick: Bool
    let allowsWindowDrag: Bool
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
                WindowDragArea(
                    onClick: configuration.trigger, onDoubleClick: onDoubleClick,
                    delaySingleClick: delaySingleClick, allowsWindowDrag: allowsWindowDrag,
                    enabled: enabled, pressed: { pressed = $0 }
                )
                .accessibilityHidden(true)
            }
            .accessibilityAction { if enabled { configuration.trigger() } }
    }
}

/// A local row drag: keep mouse ownership separate from window movement and context menus.
struct TaskDragHandle: NSViewRepresentable {
    var taskID: UUID? = nil
    var onClick: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var appearance: TaskDragAppearance
    var close: () -> Void
    var begin: () -> Void
    var preview: (Int) -> Void
    var commit: (Int) -> Void
    var end: () -> Void
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.identifier = taskID.map { NSUserInterfaceItemIdentifier($0.uuidString) }
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.delaySingleClick = onDoubleClick != nil
        view.allowsWindowDrag = false
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
    var opensTask = false
    func makeBody(configuration: Configuration) -> some View {
        PressableTaskCard(configuration: configuration, model: model, id: id, opensTask: opensTask)
    }
}

private struct PressableTaskCard: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let model: AppModel
    let id: UUID
    let opensTask: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var pressed = false
    var body: some View {
        configuration.label
            .opacity(pressed ? 0.72 : 1)
            .animation(CalmMotion.response(reduced: model.motionReduced, pressed: pressed), value: pressed)
            .contentShape(Rectangle())
            .overlay {
                WindowDragArea(
                    onClick: configuration.trigger,
                    onDoubleClick: opensTask ? { model.openTaskFromDoubleClick(id) } : nil,
                    delaySingleClick: opensTask && model.taskClickWillCollapse(id),
                    onOutsideDrop: { model.closeTaskTool(id) }, taskID: id,
                    taskPreview: model.dragAppearance(id), dragging: { model.draggingTaskID = $0 ? id : nil },
                    enabled: enabled, pressed: { pressed = $0 }
                ).accessibilityHidden(true)
            }
            .accessibilityAction { if enabled { configuration.trigger() } }
    }
}
