import AppKit
import XCTest
import CCSCore
@testable import CCSApp

final class InteractionTests: XCTestCase {
    func testNativeFocusKeysAreNotConsumedByThePicker() throws {
        _ = NSApplication.shared
        let popup = Popup(engine: Engine(environment: { [:] }), settings: Settings())
        let control = NSTextView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        popup.panel.contentView!.addSubview(control)
        XCTAssertTrue(popup.panel.makeFirstResponder(control))
        func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: popup.panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        XCTAssertFalse(popup.handle(event(48)))
        XCTAssertFalse(popup.handle(event(48, .shift)))
        for key: UInt16 in [36, 76, 125, 126, 115, 119] { XCTAssertFalse(popup.handle(event(key))) }
        XCTAssertTrue(popup.handle(event(48, .control)))
        XCTAssertTrue(popup.panel.firstResponder === control)
    }

    func testForegroundActionDoesNotWaitForBlockedHistoryRefresh() {
        let engine = Engine(environment: { ["PATH": "/usr/bin:/bin"] })
        let started = expectation(description: "history started"), opened = expectation(description: "foreground completed")
        let release = DispatchSemaphore(value: 0)
        engine.perform(background: true, { _, _ in
            started.fulfill(); _ = release.wait(timeout: .now() + 5)
        }) { _ in }
        wait(for: [started], timeout: 2)
        defer { release.signal() }
        engine.perform({ _, _ in true }) { result in
            XCTAssertEqual(try? result.get(), true); opened.fulfill()
        }
        wait(for: [opened], timeout: 2)
    }
}
