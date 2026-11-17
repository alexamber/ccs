import AppKit
import Carbon
import XCTest
@testable import CCSApp

final class HotKeyTests: XCTestCase {
    func testNativeEventsReachOnlyTheirOwnShortcutAndDebounceRepeats() throws {
        _ = NSApplication.shared
        let first = HotKey(id: 901), second = HotKey(id: 902)
        var a = 0, b = 0
        first.onPress = { a += 1 }; second.onPress = { b += 1 }
        func send(_ id: UInt32, released: Bool = false) throws {
            var reference: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(released ? kEventHotKeyReleased : kEventHotKeyPressed), 0, 0, &reference), noErr)
            let event = try XCTUnwrap(reference)
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x43435332, id: id)
            XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
            XCTAssertEqual(SendEventToEventTarget(event, GetApplicationEventTarget()), noErr)
        }
        try send(901); try send(901); try send(902)
        XCTAssertEqual(a, 1); XCTAssertEqual(b, 1)
        try send(901, released: true); try send(901)
        XCTAssertEqual(a, 2); XCTAssertEqual(b, 1)
    }
}
