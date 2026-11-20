import AppKit
import XCTest
import CCSCore
@testable import CCSApp

final class InteractionTests: XCTestCase {
    private func target(_ session: Session) -> TerminalSwitchTarget {
        TerminalSwitchTarget(session: session, tab: TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n800\n600")!)
    }
    func testClosedTerminalLosesGreenStatusAndOldLoadedHistoryRespectsDateRange() throws {
        _ = NSApplication.shared
        var session = Session(id: "loaded", cwd: "/tmp", mtime: Date().timeIntervalSince1970, provider: .codex)
        session.status = "idle"
        var snapshot = HistorySnapshot(sessions: [session], issues: [:], installedProviders: [.codex], terminalTargets: [session.key: target(session)])
        let popup = Popup(engine: Engine(environment: { [:] }), settings: Settings(), loadHistory: { $0(.success(snapshot)) })
        func icon() throws -> NSImageView {
            let cell = try XCTUnwrap(popup.tableView(NSTableView(), viewFor: nil, row: 0))
            return try XCTUnwrap(cell.subviews.compactMap { $0 as? NSImageView }.first)
        }
        popup.refresh()
        XCTAssertEqual(try icon().contentTintColor, .systemGreen)
        var working = session; working.status = "active"
        snapshot = HistorySnapshot(sessions: [working], issues: [:], installedProviders: [.codex], terminalTargets: [session.key: target(session)])
        popup.refresh()
        XCTAssertEqual(try icon().contentTintColor, .systemYellow, "An open working session must not keep its idle green indicator")
        snapshot.terminalTargets = [:]
        popup.refresh()
        XCTAssertEqual(try icon().contentTintColor, .secondaryLabelColor)
        XCTAssertEqual(try icon().toolTip, "No confirmed Terminal tab")
        snapshot.terminalTargets = nil
        popup.refresh()
        XCTAssertEqual(try icon().toolTip, "Terminal status unavailable")
        var old = session; old.mtime = 1
        snapshot = HistorySnapshot(sessions: [old], issues: [:], installedProviders: [.codex], terminalTargets: [:])
        popup.refresh()
        XCTAssertNil(popup.selected, "A daemon-loaded conversation must not bypass the date filter")
    }

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

    func testSwitcherDoesNotWaitForHistoryOrActionQueueAndDoesNotCollectHistory() {
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "slow lanes blocked"); started.expectedFulfillmentCount = 2
        let loaded = expectation(description: "switcher completed independently")
        let refreshed = expectation(description: "optional refresh completed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(environment: { [:] }, makeService: { _ in
            SessionService(index: SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache")), runner: { path, _, script, _ in
                if path == "/usr/bin/env" { return CommandResult(out: "[{\"sessionId\":\"claude-session\",\"pid\":124,\"cwd\":\"/tmp/project\"}]") }
                if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex\n124 1 ttys002 claude") }
                XCTAssertEqual(script, SessionService.switchTabsScript, "Switching must not invoke provider history or live-status commands")
                return CommandResult(out: "/dev/ttys001\u{1e}/dev/ttys001\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Topic\u{1e}/dev/ttys002\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Claude")
            }, codex: CodexProvider(enabled: false), arguments: { [$0 == 123 ? "codex" : "claude"] })
        })
        let seeded = expectation(description: "metadata cached")
        engine.perform(background: true, { service, _ in
            try service.collect(days: 0, provider: .all, enabledProviders: [.claude])
        }) { _ in seeded.fulfill() }
        wait(for: [seeded], timeout: 2)
        for background in [true, false] {
            engine.perform(background: background, { _, _ in
                started.fulfill(); _ = release.wait(timeout: .now() + 5)
            }) { _ in }
        }
        wait(for: [started], timeout: 2)
        // Keep the optional label refresh pending on the blocked history queue.
        engine.loadHistory { _ in refreshed.fulfill() }
        engine.loadTerminalActivity(enabledProviders: [.claude, .codex]) { result in
            let context = try? result.get().context
            XCTAssertEqual(context?.targets.count, 2)
            XCTAssertEqual(context?.targets.first?.title, "Codex tab")
            XCTAssertEqual(context?.targets.last?.session?.id, "claude-session", "The fast lane reuses completed metadata")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        release.signal(); release.signal()
        wait(for: [refreshed], timeout: 2)
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
