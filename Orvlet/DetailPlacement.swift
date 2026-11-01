import AppKit

/// A detail surface is placed beside the dock; it never changes the dock's frame.
enum DetailEdge: Equatable { case left, right, above, below }
enum DetailPlacement {
    static let gap: CGFloat = 6
    static func edge(anchor: NSRect, size: NSSize, screen: NSRect) -> DetailEdge {
        let safe = screen.insetBy(dx:12,dy:12)
        let left = anchor.minX-safe.minX-gap, right = safe.maxX-anchor.maxX-gap
        if max(left,right) >= size.width { return right >= left ? .right : .left }
        let above = safe.maxY-anchor.maxY-gap, below = anchor.minY-safe.minY-gap
        if max(above,below) >= size.height { return above >= below ? .above : .below }
        return right >= left ? .right : .left
    }
    static func frame(anchor: NSRect, size: NSSize, screen: NSRect, edge: DetailEdge) -> NSRect {
        let safe = screen.insetBy(dx:12,dy:12)
        var width = min(size.width,safe.width), height = min(size.height,safe.height)
        var x = anchor.minX, y = anchor.maxY-height
        switch edge {
        case .left:
            width = min(width,max(120,anchor.minX-safe.minX-gap)); x = anchor.minX-gap-width
        case .right:
            width = min(width,max(120,safe.maxX-anchor.maxX-gap)); x = anchor.maxX+gap
        case .above:
            height = min(height,max(100,safe.maxY-anchor.maxY-gap)); y = anchor.maxY+gap
        case .below:
            height = min(height,max(100,anchor.minY-safe.minY-gap)); y = anchor.minY-gap-height
        }
        x = min(max(safe.minX,x),safe.maxX-width)
        y = min(max(safe.minY,y),safe.maxY-height)
        return NSRect(x:x,y:y,width:width,height:height)
    }
}
