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
    func testSwitchWrapsReversesAndCommitsOnlyOnOptionRelease() throws {
        _ = NSApplication.shared
        let popup = SessionSwitcher(), targets = targets()
        var held = true, committed = [String]()
        popup.onCommit = { committed.append($0.session!.id); XCTAssertEqual($1.count, 3) }
        let first = popup.show(step: 1, optionHeld: { held })
        popup.supply(targets, currentKey: targets[0].key, presentation: first)
        XCTAssertEqual(popup.selected?.session?.id, "b")
        popup.cycle(2); XCTAssertEqual(popup.selected?.session?.id, "a")
        popup.cycle(-1); XCTAssertEqual(popup.selected?.session?.id, "c")
        popup.supply(Array(targets.reversed()), currentKey: nil, presentation: first)
        XCTAssertEqual(popup.selected?.session?.id, "c", "A refresh must not change the choice mid-gesture")
        XCTAssertTrue(committed.isEmpty)
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = try XCTUnwrap(popup.panel.contentView)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                popup.panel.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("switcher-\(name).png"))
            }
        }
        held = false; settle()
        XCTAssertEqual(committed, ["c"]); XCTAssertFalse(popup.panel.isVisible)
        let next = popup.show(step: 1, optionHeld: { true })
        popup.supply(targets, currentKey: nil, presentation: next)
        XCTAssertEqual(popup.selected?.session?.id, "a")
        popup.hide()
        XCTAssertEqual(committed, ["c"], "Dismissal cancels a pending switch")
    }
    func testFirstHighlightIsNextSessionAndLateRefreshCannotMoveIt() {
        _ = NSApplication.shared
        let popup = SessionSwitcher(), targets = targets()
        var commits = 0
        popup.onCommit = { _, _ in commits += 1 }
        let request = popup.show(targets: targets, step: 1, optionHeld: { true })
        XCTAssertNil(popup.highlighted, "Do not flash a guessed current-row highlight")
        popup.commit(); XCTAssertEqual(commits, 0)
        popup.supply(targets, currentKey: targets[0].key, presentation: request)
        XCTAssertEqual(popup.highlighted?.key, targets[1].key, "Opening press is applied before the first highlight")
        popup.supply(Array(targets.reversed()), currentKey: targets[2].key, presentation: request)
        XCTAssertEqual(popup.highlighted?.key, targets[1].key, "A slower refresh must not change selection or order")
        popup.cycle(1); XCTAssertEqual(popup.selected?.key, targets[2].key)
        popup.cycle(-1); XCTAssertEqual(popup.selected?.key, targets[1].key)
        popup.commit(); XCTAssertEqual(commits, 1)
    }
    func testReverseOpeningAndKeysDuringOriginLookupAreAppliedExactlyOnce() {
        _ = NSApplication.shared
        let popup = SessionSwitcher(), targets = targets()
        let request = popup.show(step: -1, optionHeld: { true })
        popup.cycle(-1)
        XCTAssertNil(popup.highlighted)
        popup.supply(targets, currentKey: targets[0].key, presentation: request)
        XCTAssertEqual(popup.selected?.key, targets[1].key)
        popup.cycle(-1); XCTAssertEqual(popup.selected?.key, targets[0].key)
        popup.hide()
    }
    func testGenericTabCanCommitWithoutInventingAConversation() {
        _ = NSApplication.shared
        let popup = SessionSwitcher()
        let target = TerminalSwitchTarget(session: nil, tab: targets()[0].tab, processID: 123)
        var committed = false
        popup.onCommit = { selected, sessions in
            XCTAssertEqual(selected.key, target.key)
            XCTAssertNil(selected.session); XCTAssertTrue(sessions.isEmpty)
            committed = true
        }
        let presentation = popup.show(step: 1, optionHeld: { false })
        popup.supply([target], currentKey: nil, presentation: presentation)
        settle(); XCTAssertTrue(committed)
    }
    func testPendingOriginRejectsAnEarlierGesture() {
        _ = NSApplication.shared
        let popup = SessionSwitcher(), targets = targets()
        var committed = [String]()
        popup.onCommit = { target, _ in committed.append(target.session!.id) }
        let old = popup.show(step: 1, optionHeld: { false })
        settle()
        XCTAssertNil(popup.selected); XCTAssertTrue(committed.isEmpty)
        popup.hide()
        let current = popup.show(step: 1, optionHeld: { false })
        popup.supply(targets, currentKey: targets[0].key, presentation: old)
        settle(); XCTAssertTrue(committed.isEmpty)
        popup.supply(targets, currentKey: targets[1].key, presentation: current)
        settle(); XCTAssertEqual(committed, ["c"])
    }
    func testShowsBeforeLoadingAndKeepsStepsUntilResultsArrive() {
        _ = NSApplication.shared
        let popup = SessionSwitcher(), targets = targets()
        var committed = [String]()
        popup.onCommit = { target, _ in committed.append(target.session!.id) }
        let request = popup.show(step: 1, optionHeld: { false })
        XCTAssertTrue(popup.panel.isVisible); XCTAssertNil(popup.selected)
        popup.cycle(1); popup.supply(targets, currentKey: targets[0].key, presentation: request)
        XCTAssertEqual(popup.selected?.session?.id, "c")
        settle(); XCTAssertEqual(committed, ["c"])
        let cancelled = popup.show(step: 1, optionHeld: { false })
        popup.hide(); popup.supply(targets, currentKey: nil, presentation: cancelled); settle()
        XCTAssertEqual(committed, ["c"], "Late results after cancellation must not switch a tab")
    }
}
