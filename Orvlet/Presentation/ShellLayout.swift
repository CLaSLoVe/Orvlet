import AppKit

struct DockCorner: Equatable {
    var right: Bool
    var top: Bool

    init(right: Bool, top: Bool) { self.right = right; self.top = top }

    init(anchor: NSRect, screen: NSRect) {
        right = anchor.midX >= screen.midX
        top = anchor.midY >= screen.midY
    }

    func align(_ size: NSSize, to rect: NSRect) -> NSRect {
        NSRect(x: right ? rect.maxX - size.width : rect.minX,
               y: top ? rect.maxY - size.height : rect.minY, width: size.width, height: size.height)
    }
}

struct ShellLayout: Equatable {
    var frame: NSRect
    var compact: NSRect
    var content: NSRect
    var edge: DetailEdge?
    // Preserve the full anchor while only its presented rail retracts.
    var compactViewport: NSRect? = nil
    var corner = DockCorner(right: false, top: true)
    var presentedCompact: NSRect { compactViewport ?? compact }
    var localCompact: NSRect { local(presentedCompact) }
    var localContent: NSRect { local(content) }
    var localVisibleContent: NSRect {
        let visible = content.intersection(frame)
        return visible.isNull ? .zero : local(visible)
    }
    private func local(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    func translated(x: CGFloat, y: CGFloat) -> ShellLayout {
        var result = self
        result.frame.origin.x += x
        result.frame.origin.y += y
        result.compact.origin.x += x
        result.compact.origin.y += y
        if edge != nil {
            result.content.origin.x += x
            result.content.origin.y += y
        }
        if let viewport = compactViewport { result.compactViewport = viewport.offsetBy(dx: x, dy: y) }
        return result
    }
    /// Fit what is visible, not the full task strip hidden behind a pinned rail.
    func fitting(_ screen: NSRect) -> ShellLayout {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let x = min(max(frame.minX, safe.minX), max(safe.minX, safe.maxX - frame.width))
        let y = min(max(frame.minY, safe.minY), max(safe.minY, safe.maxY - frame.height))
        return translated(x: x - frame.minX, y: y - frame.minY)
    }
    var chromeSize: NSSize {
        guard let edge else { return .zero }
        return edge == .left || edge == .right
            ? NSSize(width: frame.width - content.width, height: 0)
            : NSSize(width: 0, height: frame.height - content.height)
    }
    /// Live resizing owns the actual frame. Keep content and hit regions in that
    /// frame on every event, rather than replaying an expansion after mouse-up.
    func resized(to frame: NSRect) -> ShellLayout {
        guard let edge else { return self }
        let chrome = chromeSize
        let content = NSRect(
            x: frame.minX + (edge == .right ? chrome.width : 0),
            y: frame.minY + (edge == .above ? chrome.height : 0),
            width: max(1, frame.width - chrome.width), height: max(1, frame.height - chrome.height))
        var anchor = corner.align(compact.size, to: frame)
        switch edge {
        case .left, .right:
            anchor.origin = NSPoint(
                x: edge == .left ? content.maxX : content.minX - anchor.width,
                y: anchor.minY)
        case .above, .below:
            anchor.origin = NSPoint(
                x: anchor.minX, y: edge == .above ? content.minY - anchor.height : content.maxY)
        }
        return ShellLayout(frame: frame, compact: anchor, content: content, edge: edge,
                           compactViewport: compactViewport == nil ? nil : Self.retractedStrip(in: content), corner: corner)
    }

    private static func retractedStrip(in card: NSRect) -> NSRect {
        NSRect(origin: NSPoint(x: card.maxX, y: card.maxY), size: .zero)
    }

    static func pinned(anchor: NSRect, detail: NSRect, size: NSSize, screen: NSRect,
                       alignToCapsule: Bool) -> ShellLayout {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        // Dock once on pin. Subsequent layout changes keep the right edge the
        // user chose, including after a deliberate drag to another display.
        let desiredRight = alignToCapsule ? anchor.maxX : detail.maxX
        let right = min(screen.maxX, max(screen.minX + width, desiredRight))
        let top = min(screen.maxY, max(screen.minY + height, detail.maxY))
        let card = NSRect(x: right - width, y: top - height, width: width, height: height)
        return ShellLayout(frame: card, compact: anchor, content: card, edge: .left,
                           compactViewport: retractedStrip(in: card), corner: DockCorner(right: true, top: true))
    }

    static func place(
        anchor: NSRect, content size: NSSize?, orientation: CompactLayout, screen: NSRect,
        edge preferred: DetailEdge? = nil
    ) -> ShellLayout {
        let corner = DockCorner(anchor: anchor, screen: screen)
        guard let size else {
            return ShellLayout(frame: anchor, compact: anchor, content: .zero, edge: nil, corner: corner).fitting(screen)
        }
        let safe = screen.insetBy(dx: 8, dy: 8)
        let edge = preferred ?? (orientation == .vertical
            ? (corner.right ? .left : .right) : (corner.top ? .below : .above))
        let beside = edge == .left || edge == .right
        let railWidth = beside ? anchor.width : 0
        let railHeight = beside ? 0 : anchor.height
        let fittedSize = NSSize(width: min(size.width, max(1, safe.width - railWidth)),
                                height: min(size.height, max(1, safe.height - railHeight)))
        var content = corner.align(fittedSize, to: anchor)
        switch edge {
        case .left: content.origin.x = anchor.minX - content.width
        case .right: content.origin.x = anchor.maxX
        case .above: content.origin.y = anchor.maxY
        case .below: content.origin.y = anchor.minY - content.height
        }
        let layout = ShellLayout(frame: anchor.union(content), compact: anchor, content: content, edge: edge, corner: corner)
        return layout.fitting(screen)
    }

    @MainActor func transitioning(from start: ShellLayout, progress: Double) -> ShellLayout {
        if progress >= 1 { return self }
        let rail = CalmMotion.blend(start.compact, compact, progress)
        // Keep one content layout throughout the reveal, attached to the moving rail.
        let detail = edge == nil ? start : self
        let content = start.edge != nil && edge != nil && (compactViewport != nil || start.compactViewport != nil)
            ? CalmMotion.blend(start.content, self.content, progress)
            : detail.content.offsetBy(dx: rail.minX - detail.compact.minX, dy: rail.maxY - detail.compact.maxY)
        let viewport = CalmMotion.blend(start.presentedCompact, presentedCompact, progress)
        return ShellLayout(frame: CalmMotion.blend(start.frame, frame, progress), compact: rail,
                          content: content, edge: detail.edge, compactViewport: viewport,
                          corner: detail.corner)
    }
}
