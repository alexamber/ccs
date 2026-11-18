import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class BubbleDragTests: XCTestCase {
    func testSmallPointerMovementIsAClickButReturningAfterADragIsNot() {
        var drag = BubbleDrag()
        drag.begin(at: NSPoint(x: 10, y: 20), anchor: NSPoint(x: 100, y: 200))
        XCTAssertNil(drag.move(to: NSPoint(x: 13, y: 23)))
        XCTAssertFalse(drag.didDrag)
        XCTAssertEqual(drag.move(to: NSPoint(x: 40, y: 5)), NSPoint(x: 130, y: 185))
        XCTAssertEqual(drag.move(to: NSPoint(x: 10, y: 20)), NSPoint(x: 100, y: 200))
        XCTAssertTrue(drag.didDrag, "Dragging back to the starting point must not open files on release")
        drag.reset(); XCTAssertFalse(drag.isTracking)
        XCTAssertNil(drag.move(to: .zero))
    }
    func testDragIgnoresHoverAndMetadataAndSavesOnlyOnRelease() {
        _ = NSApplication.shared
        var saved = [NSPoint]()
        let popup = TerminalSessionPopup(saveAnchor: { saved.append($0) })
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        let screen = NSScreen.main!.visibleFrame
        popup.moveAnchor(to: NSPoint(x: screen.midX, y: screen.midY))
        let anchor = NSPoint(x: popup.panel.frame.maxX, y: popup.panel.frame.maxY)
        let pointer = NSPoint(x: anchor.x - 28, y: anchor.y - 28)
        popup.beginPointerInteraction(at: pointer)
        popup.setHovering(true)
        let tab = TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!
        popup.show(Session(id: "a", cwd: "/tmp", title: "New topic"), tab: tab)
        popup.movePointerInteraction(to: NSPoint(x: pointer.x + 80, y: pointer.y + 45))
        XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertEqual(popup.panel.frame.maxX, anchor.x + 80, accuracy: 0.5)
        XCTAssertEqual(popup.panel.frame.maxY, anchor.y + 45, accuracy: 0.5)
        popup.contextEnded(.spaceChanged)
        popup.setHovering(false)
        XCTAssertEqual(popup.panel.frame.maxX, anchor.x + 80, accuracy: 0.5)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(popup.endPointerInteraction(at: NSPoint(x: pointer.x + 100, y: pointer.y + 50)))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].x, anchor.x + 100, accuracy: 0.5)
        XCTAssertEqual(saved[0].y, anchor.y + 50, accuracy: 0.5)
        popup.show(Session(id: "a", cwd: "/tmp", title: "New topic"), tab: tab)
        XCTAssertEqual(popup.panel.frame.maxX, saved[0].x, accuracy: 0.5)
        XCTAssertEqual(popup.panel.frame.maxY, saved[0].y, accuracy: 0.5)
        XCTAssertFalse(popup.endPointerInteraction(at: pointer), "A second mouse-up must not activate anything")
    }
    func testPressDuringAnimationDoesNotJumpAndSmallClickDoesNotSavePosition() {
        _ = NSApplication.shared
        var saves = 0
        let popup = TerminalSessionPopup(saveAnchor: { _ in saves += 1 })
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        let tab = TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!
        popup.show(Session(id: "a", cwd: "/tmp", title: "Topic"), tab: tab)
        let frame = popup.panel.frame
        let point = NSPoint(x: frame.maxX - 28, y: frame.maxY - 28)
        popup.beginPointerInteraction(at: point)
        XCTAssertEqual(popup.panel.frame, frame, "Mouse-down must freeze the presented frame, not jump to the animation's end")
        XCTAssertTrue(popup.endPointerInteraction(at: NSPoint(x: point.x + 2, y: point.y + 1)))
        XCTAssertEqual(saves, 0)
    }
    func testUpdateDotDoesNotInterceptPointerEventsOrGrowWithCount() throws {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup()
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        popup.setUpdateCount(1)
        popup.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(popup.updateIndicator.isHidden)
        let size = popup.updateIndicator.frame.size
        XCTAssertEqual(size, NSSize(width: 9, height: 9))
        XCTAssertNil(popup.updateIndicator.hitTest(.zero))
        popup.setUpdateCount(100)
        popup.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(popup.updateIndicator.frame.size, size)
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            let view = popup.panel.contentView!
            view.appearance = NSAppearance(named: .darkAqua); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("unicorn-update-dot.png"))
        }
        popup.setUpdateCount(0); XCTAssertTrue(popup.updateIndicator.isHidden)
    }
    func testDraggingTheNameBubbleKeepsTheCompactUnicornUnderThePointer() {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup(saveAnchor: { _ in })
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        let tab = TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!
        popup.show(Session(id: "a", cwd: "/tmp", title: "Topic"), tab: tab)
        let settled = expectation(description: "name expanded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        let start = NSPoint(x: popup.panel.frame.minX + 30, y: popup.panel.frame.midY)
        let end = NSPoint(x: start.x - 30, y: start.y - 40)
        popup.beginPointerInteraction(at: start)
        popup.movePointerInteraction(to: end)
        XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertTrue(popup.panel.frame.contains(end), "The original wide title must not leave the dragged icon far from the grip")
        XCTAssertFalse(popup.endPointerInteraction(at: end))
    }
}
