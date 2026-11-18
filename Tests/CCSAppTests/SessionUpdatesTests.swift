import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class SessionUpdatesTests: XCTestCase {
    private func target(_ id: String, _ status: String, time: Double = 0, turn: SessionActivityTurn? = nil) -> TerminalSwitchTarget {
        var session = Session(id: id, cwd: "/projects/" + id, mtime: time, title: "Project " + id, provider: .codex)
        session.status = status
        session.activityTurn = turn
        return TerminalSwitchTarget(session: session, tab: TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!)
    }
    func testCompletedCodexTurnBetweenPollsIsReportedOnceWithoutTitleChangeFalsePositives() {
        var tracker = SessionUpdateTracker()
        let old = SessionActivityTurn(id: "old", status: "completed")
        let new = SessionActivityTurn(id: "new", status: "completed")
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", turn: old)])).isEmpty)
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", time: 200, turn: old)])).isEmpty)
        let updates = tracker.update(snapshot([target("a", "idle", turn: new)]))
        XCTAssertEqual(updates.map(\.message), ["Finished working"])
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", turn: new)])).isEmpty)
        tracker.acknowledge("codex:a")
        XCTAssertTrue(tracker.update(snapshot([], unavailable: [.codex])).isEmpty)
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", turn: new)])).isEmpty)
        XCTAssertEqual(tracker.count, 0)
    }
    func testCodexWaitAndCompletionAndFailedTurnsAreDistinct() {
        var tracker = SessionUpdateTracker()
        let running = SessionActivityTurn(id: "a", status: "inProgress")
        _ = tracker.update(snapshot([target("a", "active", turn: running)]))
        XCTAssertEqual(tracker.update(snapshot([target("a", "waiting_input", turn: running)])).map(\.message), ["Waiting for input"])
        XCTAssertEqual(tracker.update(snapshot([target("a", "idle", turn: .init(id: "a", status: "completed"))])).map(\.message), ["Finished working"])
        _ = tracker.update(snapshot([target("a", "active", turn: .init(id: "b", status: "inProgress"))]))
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", turn: .init(id: "b", status: "failed"))])).isEmpty)
        _ = tracker.update(snapshot([target("a", "active", turn: .init(id: "c", status: "inProgress"))]))
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle", turn: .init(id: "c", status: "interrupted"))])).isEmpty)
    }
    private func snapshot(_ targets: [TerminalSwitchTarget], unavailable: [Provider] = []) -> TerminalActivitySnapshot {
        TerminalActivitySnapshot(context: TerminalSwitchContext(targets: targets, currentKey: nil), unavailableProviders: unavailable)
    }
    func testAttentionFirstThenBusyThenReadyWithNewestWithinEachGroup() {
        let values = [target("idle", "idle", time: 100), target("busy-old", "active", time: 10),
                      target("waiting", "waiting", time: 1), target("busy-new", "active", time: 20), target("unknown", "unknown", time: 200)]
        XCTAssertEqual(SessionActivity.sorted(values).map { $0.session!.id }, ["waiting", "busy-new", "busy-old", "idle", "unknown"])
    }
    func testInitialStateIsQuietAndUpdatesAreOncePerTransition() {
        var tracker = SessionUpdateTracker()
        XCTAssertTrue(tracker.update(snapshot([target("a", "active"), target("b", "waiting")])).isEmpty)
        XCTAssertEqual(tracker.count, 1)
        let result = tracker.update(snapshot([target("a", "idle"), target("b", "waiting"), target("c", "waiting_input")]))
        XCTAssertEqual(result.map { $0.target.session!.id }, ["c", "a"])
        XCTAssertEqual(result.map(\.message), ["Waiting for input", "Finished working"])
        XCTAssertEqual(tracker.count, 3)
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle"), target("b", "waiting"), target("c", "waiting_input")])).isEmpty)
        tracker.acknowledge("codex:a"); XCTAssertEqual(tracker.count, 2)
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle"), target("new", "idle")])).isEmpty, "An unfamiliar idle session is not a completion event")
    }
    func testUnknownAndOutageDoNotCreateOrReplayAttention() {
        var tracker = SessionUpdateTracker()
        _ = tracker.update(snapshot([target("a", "waiting")]))
        XCTAssertTrue(tracker.update(snapshot([], unavailable: [.codex])).isEmpty)
        XCTAssertTrue(tracker.update(snapshot([target("a", "waiting")])).isEmpty)
        _ = tracker.update(snapshot([target("a", "unknown")]))
        XCTAssertTrue(tracker.update(snapshot([target("a", "idle")])).isEmpty, "Waiting-to-idle does not prove work finished")
    }
    func testHookAndPollSpellingsDoNotDuplicateAnApprovalNotice() {
        var tracker = SessionUpdateTracker()
        _ = tracker.update(snapshot([target("a", "active")]))
        XCTAssertEqual(tracker.update(snapshot([target("a", "waiting_for_approval")])).count, 1)
        XCTAssertTrue(tracker.update(snapshot([target("a", "waiting")])).isEmpty)
        XCTAssertEqual(tracker.update(snapshot([target("a", "waiting_input")])).count, 1)
    }
    func testMonitorCoalescesManualReadsAndRejectsDisabledResults() {
        var loads = [(SessionUpdateMonitor.ResultType) -> Void](), received = 0, completed = 0
        let monitor = SessionUpdateMonitor(load: { loads.append($0) }, receive: { _ in received += 1 })
        monitor.configure(enabled: true)
        monitor.refresh { _ in completed += 1 }; monitor.refresh()
        XCTAssertEqual(loads.count, 1)
        monitor.configure(enabled: false)
        loads[0](.success(snapshot([target("a", "waiting")])))
        XCTAssertEqual(received, 0); XCTAssertEqual(completed, 1)
        monitor.refresh(); XCTAssertEqual(loads.count, 1)
        monitor.refresh { _ in completed += 1 }
        XCTAssertEqual(loads.count, 2, "An explicit menu open can refresh with automatic nudges disabled")
        loads[1](.success(snapshot([])))
        XCTAssertEqual(received, 1); XCTAssertEqual(completed, 2)
    }
    func testUnmatchedEventsCannotReplayOverNewerStatusOrDuplicateCompletion() {
        var clock = Date(), loads = [(SessionUpdateMonitor.ResultType) -> Void]()
        var statuses = [String](), updates = [SessionUpdate](), tracker = SessionUpdateTracker()
        let monitor = SessionUpdateMonitor(load: { loads.append($0) }, receive: {
            statuses += $0.context.targets.compactMap { $0.session?.status }
            updates += tracker.update($0)
        }, now: { clock })
        monitor.configure(enabled: true)
        defer { monitor.configure(enabled: false) }
        loads[0](.success(snapshot([])))
        clock.addTimeInterval(3)
        monitor.ingest(target("a", "waiting_input").session!)
        loads[1](.success(snapshot([]))) // Still no confirmed Terminal tab.
        clock.addTimeInterval(3); monitor.refresh()
        loads[2](.success(snapshot([target("a", "active")])))
        XCTAssertEqual(statuses, ["active"], "Old unmatched waits must not overwrite a newer poll")
        XCTAssertTrue(updates.isEmpty)
        clock.addTimeInterval(3); monitor.refresh()
        clock.addTimeInterval(0.1)
        monitor.ingest(target("b", "active").session!)
        clock.addTimeInterval(0.1)
        monitor.ingest(target("b", "idle", turn: .init(id: "done", status: "completed")).session!)
        loads[3](.success(snapshot([target("a", "active"), target("b", "idle", turn: .init(id: "done", status: "completed"))])))
        XCTAssertTrue(updates.isEmpty, "First identification establishes state instead of replaying an unconfirmed task")
        XCTAssertEqual(monitor.cached?.snapshot.context.targets.last?.session?.activityTurn?.id, "done")
    }
    func testPersistentLauncherAndAnchorSurviveContextChanges() {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup()
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        XCTAssertTrue(popup.panel.isVisible); XCTAssertTrue(popup.panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(popup.panel.canBecomeKey)
        let screen = NSScreen.main!.visibleFrame
        let anchor = NSPoint(x: screen.midX, y: screen.midY)
        popup.moveAnchor(to: anchor)
        popup.contextEnded(.tabChanged); popup.contextEnded(.inactive); popup.contextEnded(.spaceChanged)
        XCTAssertTrue(popup.panel.isVisible); XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertEqual(popup.panel.frame.maxX, anchor.x, accuracy: 1)
        XCTAssertEqual(popup.panel.frame.maxY, anchor.y, accuracy: 1)
        popup.expand()
        XCTAssertEqual(popup.phase, .collapsed, "Without a focused identified Terminal session, clicking must do nothing")
        popup.moveAnchor(to: NSPoint(x: -100000, y: -100000))
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(popup.panel.frame) })
        popup.configureFloating(enabled: true, allSpaces: false)
        XCTAssertFalse(popup.panel.collectionBehavior.contains(.canJoinAllSpaces))
        popup.configureFloating(enabled: false, allSpaces: false); XCTAssertFalse(popup.panel.isVisible)
    }
    func testSessionMenuKeepsHoverAndTopicUpdatesFromMovingItsAnchor() {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup()
        let menu = SessionOverview()
        defer { menu.close(); popup.hide() }
        popup.onShowSessions = { _ = menu.show(anchor: $0) }
        menu.onClose = { popup.sessionOverviewClosed() }
        popup.configureFloating(enabled: true, allSpaces: true)
        popup.showSessions()
        let frame = popup.panel.frame
        popup.setHovering(true)
        let target = target("new", "active")
        popup.show(target.session!, tab: target.tab)
        XCTAssertEqual(popup.phase, .collapsed); XCTAssertEqual(popup.panel.frame, frame)
        popup.setHovering(false)
        let settled = expectation(description: "pointer left the unicorn for its menu")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertTrue(menu.isShown, "Moving from the unicorn into its popover must not dismiss it")
        menu.close()
        popup.show(target.session!, tab: target.tab)
        XCTAssertEqual(popup.phase, .collapsed)
    }
    func testNotificationClickTargetsTheAnnouncedSessionWithoutOpeningItsFiles() throws {
        _ = NSApplication.shared
        var scans = 0, opened: String?
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(loader: { _, _ in scans += 1 }))
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        popup.onNotificationOpen = { opened = $0.key }
        popup.notify(SessionUpdate(target: target("other", "idle"), kind: .finished), bubble: true, wiggle: false)
        XCTAssertEqual(popup.phase, .collapsed); XCTAssertFalse(popup.panel.canBecomeKey)
        XCTAssertTrue(popup.speech.panel.isVisible); XCTAssertFalse(popup.speech.panel.canBecomeKey)
        let current = target("current", "active")
        popup.show(current.session!, tab: current.tab)
        XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertTrue(popup.speech.panel.isVisible, "A quiet tab refresh must not hide a session update")
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            let done = expectation(description: "notification animation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
            wait(for: [done], timeout: 1)
            let view = popup.speech.panel.contentView!
            view.appearance = NSAppearance(named: .darkAqua); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("session-update-bubble.png"))
            // Include the actual icon/window positions so the thought trail can
            // be reviewed in context rather than as an isolated shape.
            let bounds = popup.panel.frame.union(popup.speech.panel.frame).insetBy(dx: -8, dy: -8)
            let composition = NSImage(size: bounds.size)
            composition.lockFocus()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            for window in [popup.panel, popup.speech.panel] {
                let content = window.contentView!
                content.appearance = NSAppearance(named: .darkAqua)
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                if let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: image)
                    let layer = NSImage(size: content.bounds.size); layer.addRepresentation(image)
                    layer.draw(in: NSRect(x: window.frame.minX - bounds.minX, y: window.frame.minY - bounds.minY,
                                          width: window.frame.width, height: window.frame.height),
                               from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            composition.unlockFocus()
            let composed = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(composition.tiffRepresentation)))
            try XCTUnwrap(composed.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("unicorn-thought-bubble.png"))
        }
        popup.speech.open()
        XCTAssertEqual(opened, "codex:other"); XCTAssertEqual(scans, 0)
        XCTAssertEqual(popup.phase, .collapsed)
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            var session = current.session!
            session.title = "Review architecture and authentication changes for the customer portal"
            session.status = "waiting_input"
            let notice = SessionUpdate(target: TerminalSwitchTarget(session: session, tab: current.tab), kind: .attention)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                popup.speech.panel.appearance = NSAppearance(named: appearance)
                let view = popup.speech.panel.contentView!
                view.appearance = NSAppearance(named: appearance)
                popup.notify(notice, bubble: true, wiggle: false)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("thought-long-" + name + ".png"))
            }
        }
    }
    func testFilesAndHoverAreInertOutsideTerminalButRightClickAndNoticesWork() {
        _ = NSApplication.shared
        var scans = 0, menus = 0
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(loader: { _, _ in scans += 1 }))
        defer { popup.hide() }
        popup.configureFloating(enabled: true, allSpaces: true)
        let current = target("a", "active")
        popup.show(current.session!, tab: current.tab)
        popup.contextEnded(.inactive)
        popup.expand(); popup.setHovering(true)
        XCTAssertEqual(popup.phase, .collapsed); XCTAssertEqual(scans, 0)
        popup.onShowSessions = { _ in menus += 1 }; popup.showSessions()
        XCTAssertEqual(menus, 1); popup.sessionOverviewClosed()
        popup.notify(SessionUpdate(target: current, kind: .finished), bubble: true, wiggle: false)
        XCTAssertTrue(popup.speech.panel.isVisible)
        popup.expand(); XCTAssertEqual(scans, 0, "Icon click must not become notification click")
    }
    func testOverviewAndSettingsRender() throws {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup()
        popup.configureFloating(enabled: true, allSpaces: true)
        let overview = SessionOverview()
        defer { overview.close(); popup.hide() }
        let generation = overview.show(anchor: popup.panel.contentView!)
        overview.supply(snapshot([target("Approval needed", "waiting", time: 10), target("Writing report", "active", time: 20), target("Interview preparation", "idle", time: 30)]), finished: ["codex:Interview preparation"], generation: generation)
        let settings = Preferences(settings: Settings(), engine: Engine(environment: { [:] }))
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, view) in [("session-overview", overview.popover.contentViewController!.view), ("unicorn-settings", settings.window.contentView!)] {
                view.appearance = NSAppearance(named: .darkAqua); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
        let previous = overview.generation
        overview.close()
        overview.supply(snapshot([]), finished: [], generation: previous)
        XCTAssertFalse(overview.isShown)
    }
}
