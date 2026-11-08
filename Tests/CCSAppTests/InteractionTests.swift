import AppKit
import XCTest
import CCSCore
@testable import CCSApp

final class InteractionTests: XCTestCase {
    func testHistoryLoadsWhileHiddenAndSurvivesRapidReopening() {
        _ = NSApplication.shared
        var requests = [(Result<HistorySnapshot, Error>) -> Void]()
        let popup = Popup(engine: Engine(environment: { [:] }), settings: Settings(),
                          loadHistory: { requests.append($0) })
        let session = Session(id: "cached", cwd: "/tmp", mtime: Date().timeIntervalSince1970)
        popup.refresh()
        XCTAssertFalse(popup.panel.isVisible)
        requests[0](.success(HistorySnapshot(sessions: [session], issues: [:], installedProviders: [.claude])))
        XCTAssertEqual(popup.selected?.id, "cached")

        popup.show()
        defer { popup.hide(restoreFocus: false) }
        XCTAssertEqual(requests.count, 2)
        // The new provider request has not completed; cached rows are already usable.
        XCTAssertEqual(popup.selected?.id, "cached")
        popup.hide(restoreFocus: false)
        popup.show()
        XCTAssertEqual(popup.selected?.id, "cached")
        XCTAssertEqual(requests.count, 2, "Reopening must reuse the in-flight refresh")
        popup.hide(restoreFocus: false)
        let updated = Session(id: "updated", cwd: "/tmp", mtime: Date().timeIntervalSince1970)
        requests[1](.success(HistorySnapshot(sessions: [updated], issues: [:], installedProviders: [.claude])))
        popup.show()
        XCTAssertEqual(popup.selected?.id, "updated", "Results received while hidden must be retained")
        requests[2](.failure(CCSError.message("Offline")))
        XCTAssertEqual(popup.selected?.id, "updated", "A failed refresh must not erase the previous snapshot")
    }

    func testProviderChangesDiscardAnObsoleteInFlightSnapshot() {
        _ = NSApplication.shared
        var requests = [(Result<HistorySnapshot, Error>) -> Void]()
        var settings = Settings(); settings.enabledProviders = [.claude]
        let popup = Popup(engine: Engine(environment: { [:] }), settings: settings,
                          loadHistory: { requests.append($0) })
        popup.refresh()
        settings.enabledProviders = [.codex]
        popup.apply(settings)
        let old = Session(id: "old", cwd: "/tmp", mtime: Date().timeIntervalSince1970)
        requests[0](.success(HistorySnapshot(sessions: [old], issues: [:], installedProviders: [.claude])))
        XCTAssertNil(popup.selected)
        XCTAssertEqual(requests.count, 2)
        let current = Session(id: "current", cwd: "/tmp", mtime: Date().timeIntervalSince1970, provider: .codex)
        requests[1](.success(HistorySnapshot(sessions: [current], issues: [:], installedProviders: [.codex])))
        XCTAssertEqual(popup.selected?.id, "current")
    }

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
