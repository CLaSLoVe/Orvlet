import AppKit

struct ShellLayout: Equatable {
    var frame: NSRect
    var compact: NSRect
    var content: NSRect
    var edge: DetailEdge?
    // Preserve the full anchor while only its presented rail retracts.
    var compactViewport: NSRect? = nil
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
    func tuckingCompact() -> ShellLayout {
        guard let edge else { return self }
        var result = self
        let rail: NSRect
        switch edge {
        case .left:
            rail = NSRect(x: content.maxX, y: content.maxY - 36, width: 28, height: 36)
        case .right:
            rail = NSRect(x: content.minX - 28, y: content.maxY - 36, width: 28, height: 36)
        case .above:
            rail = NSRect(x: content.minX, y: content.minY - 28, width: 36, height: 28)
        case .below:
            rail = NSRect(x: content.minX, y: content.maxY, width: 36, height: 28)
        }
        result.compactViewport = rail
        result.frame = content.union(rail)
        return result
    }
    static func place(
        anchor: NSRect, content size: NSSize?, orientation: CompactLayout, screen: NSRect,
        edge preferred: DetailEdge? = nil
    ) -> ShellLayout {
        guard let size else { return ShellLayout(frame: anchor, compact: anchor, content: .zero, edge: nil) }
        let safe = screen.insetBy(dx: 8, dy: 8)
        let edge: DetailEdge
        if let preferred {
            edge = preferred
        } else if orientation == .vertical {
            edge = anchor.minX - safe.minX >= safe.maxX - anchor.maxX ? .left : .right
        } else {
            edge = safe.maxY - anchor.maxY >= anchor.minY - safe.minY ? .above : .below
        }
        var content = NSRect(origin: anchor.origin, size: size)
        switch edge {
        case .left, .right:
            content.size.width = min(
                size.width, max(120, edge == .left ? anchor.minX - safe.minX : safe.maxX - anchor.maxX))
            content.size.height = min(size.height, safe.height)
            content.origin.x = edge == .left ? anchor.minX - content.width : anchor.maxX
            content.origin.y = min(max(safe.minY, anchor.maxY - content.height), safe.maxY - content.height)
        case .above, .below:
            content.size.width = min(size.width, safe.width)
            content.size.height = min(
                size.height, max(100, edge == .above ? safe.maxY - anchor.maxY : anchor.minY - safe.minY))
            content.origin.x = min(max(safe.minX, anchor.minX), safe.maxX - content.width)
            content.origin.y = edge == .above ? anchor.maxY : anchor.minY - content.height
        }
        return ShellLayout(frame: anchor.union(content), compact: anchor, content: content, edge: edge)
    }
}
