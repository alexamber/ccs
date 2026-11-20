import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class SessionSwitchTests: XCTestCase {
    private func targets() -> [TerminalSwitchTarget] {
        zip(["a", "b", "c"], ["Review terminal tab spec", "Interview questions", "Architecture cheat sheet"]).enumerated().map { index, value in
            TerminalSwitchTarget(session: Session(id: value.0, cwd: "/projects/" + value.0, title: value.1, provider: .codex),
                                 tab: TerminalTabSnapshot(output: "/dev/ttys00\(index)\n0\n0\n900\n600\n\(value.1)")!)
        }
    }
    private func settle() {
        let done = expectation(description: "release processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    private var menu: SessionOverview!
    private var bubble: TerminalSessionPopup!
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        menu = SessionOverview()
        bubble = TerminalSessionPopup()
        bubble.configureFloating(enabled: true, allSpaces: true)
    }
    override func tearDown() {
        menu.close(); bubble.hide()
        menu = nil; bubble = nil
        super.tearDown()
    }
    private func snapshot(_ values: [TerminalSwitchTarget]) -> TerminalActivitySnapshot {
        TerminalActivitySnapshot(context: TerminalSwitchContext(targets: values, currentKey: nil))
    }

    func testReleaseCommitsOnceInMenuOrderWithWrapAndReverse() {
        let rows = targets()
        var held = true, committed = [String]()
        menu.onSelect = { committed.append($0.key); XCTAssertEqual($1.count, 3) }
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: snapshot(Array(rows.reversed())))
        menu.beginSwitch(step: 1, optionHeld: { held })
        XCTAssertNil(menu.highlighted)
        menu.commitSwitch()
        XCTAssertTrue(committed.isEmpty)
        menu.supplyOrigin(tty: rows[0].tab.tty, generation: generation)
        XCTAssertEqual(menu.highlighted?.key, rows[1].key)
        menu.cycle(2); XCTAssertEqual(menu.highlighted?.key, rows[0].key)
        menu.cycle(-1); XCTAssertEqual(menu.highlighted?.key, rows[2].key)
        menu.supplyOrigin(tty: nil, generation: generation)
        menu.supply(snapshot(rows), finished: [], generation: generation)
        XCTAssertEqual(menu.highlighted?.key, rows[2].key)
        held = false; settle()
        XCTAssertEqual(committed, [rows[2].key]); XCTAssertFalse(menu.isShown)
    }

    func testQuickReverseWhileLoadingPreservesAllKeystrokes() {
        let rows = targets()
        var committed = [String]()
        menu.onSelect = { target, _ in committed.append(target.key) }
        let generation = menu.show(anchor: bubble.panel.contentView!)
        menu.beginSwitch(step: -1, optionHeld: { false })
        menu.cycle(-1)
        menu.supplyOrigin(tty: rows[0].tab.tty, generation: generation)
        settle(); XCTAssertTrue(committed.isEmpty)
        menu.supply(snapshot(rows), finished: [], generation: generation)
        settle()
        XCTAssertEqual(committed, [rows[1].key])
    }

    func testAlreadyOpenMenuCyclesWithinFilterAndSkipsUnavailableRows() {
        var rows = targets()
        rows = rows.enumerated().map { index, target in
            var session = target.session!
            session.title = index == 1 ? "Unrelated" : "Review item"
            return TerminalSwitchTarget(session: session, tab: target.tab)
        }
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: snapshot(rows))
        menu.search.stringValue = "Review"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(menu.visibleKeys, [rows[0].key, rows[2].key])
        menu.beginSwitch(step: 1, fromSelection: true, optionHeld: { true })
        XCTAssertEqual(menu.generation, generation)
        XCTAssertEqual(menu.highlighted?.key, rows[2].key)
        menu.supply(snapshot([rows[2]]), finished: [], generation: generation)
        menu.cycle(1); XCTAssertEqual(menu.highlighted?.key, rows[2].key)
        menu.onSelect = { _, _ in XCTFail("Escape must cancel even when the list is filtered") }
        menu.cancelSearchOrClose()
        XCTAssertFalse(menu.isShown); XCTAssertFalse(menu.isSwitching)
    }

    func testStaleOriginCannotSelectInReopenedMenu() {
        let rows = targets()
        var committed = [String]()
        menu.onSelect = { target, _ in committed.append(target.key) }
        let old = menu.show(anchor: bubble.panel.contentView!, cached: snapshot(rows))
        menu.beginSwitch(step: 1, optionHeld: { false })
        menu.close()
        let current = menu.show(anchor: bubble.panel.contentView!, cached: snapshot(rows))
        menu.beginSwitch(step: 1, optionHeld: { false })
        menu.supplyOrigin(tty: rows[2].tab.tty, generation: old)
        settle(); XCTAssertTrue(committed.isEmpty)
        menu.supplyOrigin(tty: rows[1].tab.tty, generation: current)
        settle(); XCTAssertEqual(committed, [rows[2].key])
    }

    func testUnconfirmedTabCanCommitWithoutConversation() {
        let target = TerminalSwitchTarget(session: nil, tab: targets()[0].tab, processID: 123)
        var committed = false
        menu.onSelect = { choice, sessions in
            XCTAssertEqual(choice.key, target.key); XCTAssertTrue(sessions.isEmpty); committed = true
        }
        let generation = menu.show(anchor: bubble.panel.contentView!, cached: snapshot([target]))
        menu.beginSwitch(step: -1, optionHeld: { false })
        menu.supplyOrigin(tty: nil, generation: generation)
        settle(); XCTAssertTrue(committed)
    }
}
