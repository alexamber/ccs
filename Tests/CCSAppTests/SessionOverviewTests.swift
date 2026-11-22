import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class SessionOverviewTests: XCTestCase {
    private func target(_ id: String, status: String = "active", time: Double = 0) -> TerminalSwitchTarget {
        var session = Session(id: id, cwd: "/projects/" + id, mtime: time, title: id, provider: .codex)
        session.status = status
        return TerminalSwitchTarget(session: session, tab: TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!)
    }
    private func snapshot(_ targets: [TerminalSwitchTarget]) -> TerminalActivitySnapshot {
        TerminalActivitySnapshot(context: TerminalSwitchContext(targets: targets, currentKey: nil))
    }
    func testRecentSnapshotIsImmediateAndQuickReopensDoNotRepeatTheRead() {
        var clock = Date(), completions = [(SessionUpdateMonitor.ResultType) -> Void](), receipts = 0
        let monitor = SessionUpdateMonitor(load: { completions.append($0) }, receive: { _ in receipts += 1 }, now: { clock })
        monitor.refresh { _ in }
        completions[0](.success(snapshot([target("a")])))
        XCTAssertEqual(monitor.recentSnapshot?.context.targets.count, 1)
        var returned = false
        monitor.refresh { _ in returned = true }
        XCTAssertTrue(returned); XCTAssertEqual(completions.count, 1); XCTAssertEqual(receipts, 1)
        clock.addTimeInterval(3)
        monitor.refresh { _ in }
        XCTAssertEqual(completions.count, 2)
        completions[1](.failure(CCSError.message("Offline")))
        XCTAssertNotNil(monitor.recentSnapshot, "A failed refresh must not blank a useful recent list")
        clock.addTimeInterval(60)
        XCTAssertNil(monitor.recentSnapshot, "Old snapshots must not be presented as recent")
        monitor.configure(enabled: false, reset: true)
        XCTAssertNil(monitor.cached)
    }
    func testCacheShowsBeforeRefreshAndInteractingKeepsRowsStable() {
        _ = NSApplication.shared
        let bubble = TerminalSessionPopup(), menu = SessionOverview()
        bubble.configureFloating(enabled: true, allSpaces: true)
        defer { menu.close(); bubble.hide() }
        let cached = snapshot([target("a", time: 20), target("b", time: 10)])
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: cached)
        XCTAssertEqual(menu.visibleKeys, ["codex:a", "codex:b"], "Recent data must be present without waiting for a callback")
        menu.noteInteraction()
        let fresh = snapshot([target("new", status: "waiting", time: 30), target("b", status: "idle", time: 10)])
        menu.supply(fresh, finished: [], generation: generation)
        XCTAssertEqual(menu.visibleKeys, ["codex:a", "codex:b"])
        XCTAssertFalse(menu.selectableKeys.contains("codex:a"))
        XCTAssertTrue(menu.hasPendingReorder)
        var opened = [String]()
        menu.onSelect = { opened.append($0.key); _ = $1 }
        menu.openRow(0)
        XCTAssertTrue(opened.isEmpty, "Clicking an ended row must not open the previous selection")
        menu.refreshList()
        XCTAssertEqual(menu.visibleKeys, ["codex:new", "codex:b"])
        XCTAssertFalse(menu.hasPendingReorder)
        menu.openRow(0)
        XCTAssertEqual(opened, ["codex:new"])
    }
    func testPurpleThenDraftThenWorkingAndReadyWithLateDraftUpdates() {
        _ = NSApplication.shared
        var resolve: ((Set<String>) -> Void)?
        let drafts = VisibleDrafts { _, done in resolve = done }
        let bubble = TerminalSessionPopup(), menu = SessionOverview(drafts: drafts)
        bubble.configureFloating(enabled: true, allSpaces: true)
        defer { menu.close(); bubble.hide() }
        let waiting = target("attention", status: "waiting", time: 1)
        let finished = target("finished", status: "idle", time: 2)
        let writing = target("writing", status: "idle", time: 3)
        let busyDraft = target("busy-draft", time: 4)
        let working = target("working", time: 7)
        let ready = target("ready", status: "idle", time: 9)
        let unknown = target("unknown", status: "unknown", time: 11)
        let data = snapshot([ready, working, writing, finished, waiting, busyDraft, unknown])
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: data, finished: [finished.key])
        resolve?([writing.key, busyDraft.key, waiting.key])
        XCTAssertEqual(menu.visibleKeys, [finished, waiting, busyDraft, writing, working, ready, unknown].map(\.key))
        menu.noteInteraction()
        menu.supply(data, finished: [], generation: generation)
        XCTAssertEqual(menu.visibleKeys.first, finished.key)
        XCTAssertTrue(menu.hasPendingReorder)
        menu.refreshList()
        XCTAssertEqual(menu.visibleKeys, [waiting, busyDraft, writing, working, ready, finished, unknown].map(\.key))
        menu.search.stringValue = "draft"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: menu.search))
        XCTAssertEqual(menu.visibleKeys, [waiting, busyDraft, writing].map(\.key))
    }

    func testUntouchedListAcceptsFreshOrderAndErrorsKeepRecentRows() {
        _ = NSApplication.shared
        let bubble = TerminalSessionPopup(), menu = SessionOverview()
        bubble.configureFloating(enabled: true, allSpaces: true)
        defer { menu.close(); bubble.hide() }
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: snapshot([target("a")]))
        menu.supply(snapshot([target("a", status: "idle"), target("b", status: "waiting")]), finished: [], generation: generation)
        XCTAssertEqual(menu.visibleKeys, ["codex:b", "codex:a"])
        menu.fail(CCSError.message("Unavailable"), generation: generation)
        XCTAssertEqual(menu.visibleKeys.count, 2)
        menu.close()
        menu.supply(snapshot([]), finished: [], generation: generation)
        XCTAssertEqual(menu.visibleKeys.count, 2, "A late response after dismissal cannot replace the old menu state")
    }
    func testCompactListShowsTwelveRowsAndKeepsAllOtherSessionsScrollable() throws {
        _ = NSApplication.shared
        var finishScan: ((Set<String>) -> Void)?
        let bubble = TerminalSessionPopup(), menu = SessionOverview(drafts: VisibleDrafts { _, done in finishScan = done })
        bubble.configureFloating(enabled: true, allSpaces: true)
        defer { menu.close(); bubble.hide() }
        let titles = ["Review authentication changes", "Prepare interview questions", "Improve architecture cheatsheet", "Write system design report", "Update project dashboard", "Investigate failing integration", "Review pricing proposal", "Prepare launch notes", "Research customer feedback", "Summarize design decisions", "Fix search indexing", "Polish session controls", "Explore caching options", "Organize project references", "Check deployment results", "Review onboarding flow"]
        let values = titles.enumerated().map { index, title in
            target(title, status: index < 2 ? "waiting" : index < 6 ? "active" : index < 15 ? "idle" : "unknown", time: Double(100 - index))
        }
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: snapshot(values))
        menu.supply(snapshot(values), finished: [], generation: generation)
        finishScan?([values[2].key, values[6].key])
        XCTAssertEqual(menu.visibleKeys.count, 16)
        // Lay out actual delegate rows at the popup width. A stretching marker
        // stack previously pushed shorter titles toward the right edge.
        for index in 0..<5 {
            let cell = try XCTUnwrap(menu.tableView(NSTableView(), viewFor: nil, row: index))
            cell.frame = NSRect(x: 0, y: 0, width: 380, height: 32)
            cell.layoutSubtreeIfNeeded()
            let labels = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSStackView }.first)
            for field in labels.arrangedSubviews {
                let frame = field.convert(field.bounds, to: cell)
                XCTAssertEqual(frame.minX, 22, accuracy: 2)
                XCTAssertGreaterThan(frame.width, 350)
            }
        }
        if NSScreen.main!.visibleFrame.height >= 588 { XCTAssertEqual(menu.visibleListHeight, 408) }
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = menu.popover.contentViewController!.view
            view.appearance = NSAppearance(named: .darkAqua); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-session-overview.png"))
        }
    }
    func testFilteringRetainsTypingFocusAndOpensTheFilteredTarget() {
        _ = NSApplication.shared
        let bubble = TerminalSessionPopup(), menu = SessionOverview()
        bubble.configureFloating(enabled: true, allSpaces: true)
        defer { menu.close(); bubble.hide() }
        let initial = snapshot([target("Authentication", status: "active"), target("Report", status: "waiting_input")])
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: initial)
        menu.search.stringValue = "codex auth working"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: menu.search))
        XCTAssertEqual(menu.visibleKeys, ["codex:Authentication"])
        menu.supply(initial, finished: [], generation: generation)
        XCTAssertTrue(menu.search.currentEditor() === menu.popover.contentViewController?.view.window?.firstResponder)
        menu.search.stringValue = "/projects/report input"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: menu.search))
        XCTAssertEqual(menu.visibleKeys, ["codex:Report"])
        menu.search.stringValue = "no match"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: menu.search))
        XCTAssertTrue(menu.visibleKeys.isEmpty)
        XCTAssertTrue(menu.control(menu.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(menu.visibleKeys.count, 2); XCTAssertTrue(menu.isShown)
        menu.search.stringValue = "auth"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: menu.search))
        var selected: String?, contextCount = 0
        menu.onSelect = { selected = $0.key; contextCount = $1.count }
        XCTAssertTrue(menu.control(menu.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(selected, "codex:Authentication"); XCTAssertEqual(contextCount, 2)
    }
}
