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
            ? NSSize(width: presentedCompact.width, height: 0)
            : NSSize(width: 0, height: presentedCompact.height)
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
        var anchor = compact
        switch edge {
        case .left, .right:
            anchor.origin = NSPoint(
                x: edge == .left ? content.maxX : content.minX - anchor.width,
                y: content.maxY - anchor.height)
        case .above, .below:
            anchor.origin = NSPoint(
                x: content.minX, y: edge == .above ? content.minY - anchor.height : content.maxY)
        }
        let result = ShellLayout(frame: frame, compact: anchor, content: content, edge: edge)
        return compactViewport == nil ? result : result.tuckingCompact()
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
