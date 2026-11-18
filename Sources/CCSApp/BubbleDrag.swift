import AppKit

/// Screen-space translation stays stable as the panel resizes or crosses displays.
struct BubbleDrag {
    private var start: NSPoint?
    private var anchor = NSPoint.zero
    private(set) var didDrag = false
    var isTracking: Bool { start != nil }

    mutating func begin(at point: NSPoint, anchor: NSPoint) {
        start = point; self.anchor = anchor; didDrag = false
    }
    mutating func move(to point: NSPoint) -> NSPoint? {
        guard let start else { return nil }
        let dx = point.x - start.x, dy = point.y - start.y
        if hypot(dx, dy) >= 5 { didDrag = true }
        guard didDrag else { return nil }
        return NSPoint(x: anchor.x + dx, y: anchor.y + dy)
    }
    mutating func reset() { start = nil; didDrag = false }
}
