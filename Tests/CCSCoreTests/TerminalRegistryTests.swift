import XCTest
@testable import CCSCore

private final class RecordingTerminal: TerminalAdapter {
    let bundleID: String
    var name: String { bundleID }
    var panes: [TerminalTabSnapshot]
    var launched = [String]()
    var focused = [String]()

    init(_ id: String, tty: String) {
        bundleID = id
        panes = [TerminalTabSnapshot(terminalID: id, paneID: "1", tty: tty,
                                     bounds: CGRect(x: 0, y: 0, width: 900, height: 600), title: "")]
    }
    func tabs() throws -> TerminalTabs { TerminalTabs(tabs: panes, selectedTTY: panes.first?.tty) }
    func selectedTTY() throws -> String? { panes.first?.tty }
    func frontTab() -> TerminalTabSnapshot? { panes.first }
    func launch(command: String, title: String) throws { launched.append(command) }
    func focus(paneID: String, title: String) throws { focused.append(paneID) }
}

final class TerminalRegistryTests: XCTestCase {
    func testDiscoveryAndPersistedLaunchPreference() throws {
        let a = RecordingTerminal("test.a", tty: "/dev/ttys001"), b = RecordingTerminal("test.b", tty: "/dev/ttys002")
        var installed = Set([b.bundleID])
        let registry = TerminalRegistry(adapters: [a, b]) { installed.contains($0) }
        let service = SessionService(terminals: registry)
        var settings = Settings()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        // Existing settings omit the new key. Automatic picks the first installed adapter.
        try settings.save(to: url)
        XCTAssertNil(Settings.load(from: url).defaultTerminalID)
        XCTAssertEqual(registry.installed.map(\.bundleID), [b.bundleID])
        try service.openTerminal("first", preferred: nil)
        installed.insert(a.bundleID)
        settings.defaultTerminalID = b.bundleID
        try settings.save(to: url)
        try service.openTerminal("second", preferred: Settings.load(from: url).defaultTerminalID)
        try service.openTerminal("third", preferred: nil)
        installed.remove(b.bundleID)
        XCTAssertThrowsError(try service.openTerminal("missing", preferred: b.bundleID))
        XCTAssertEqual(a.launched, ["third"])
        XCTAssertEqual(b.launched, ["first", "second"])
    }

    func testSwitchingUsesOriginAndRevalidatesTheOwningPane() throws {
        let a = RecordingTerminal("test.a", tty: "/dev/ttys001"), b = RecordingTerminal("test.b", tty: "/dev/ttys002")
        let registry = TerminalRegistry(adapters: [a, b], isInstalled: { _ in true })
        let service = SessionService(runner: { path, _, _, _ in
            XCTAssertEqual(path, "/bin/ps")
            return CommandResult(out: "101 1 ttys001 codex\n102 1 ttys002 codex")
        }, terminals: registry, arguments: { _ in ["codex"] })
        let context = try service.terminalSwitchContext(sessions: [], originTerminalID: b.bundleID)
        XCTAssertEqual(context.targets.count, 2)
        let target = try XCTUnwrap(context.targets.first { $0.tab.terminalID == b.bundleID })
        XCTAssertEqual(context.currentKey, target.key)
        XCTAssertEqual(try service.selectedTerminalTTY(in: b.bundleID), target.tab.tty)
        try service.openTerminal("new", preferred: a.bundleID)
        try service.focusTerminalTarget(target, sessions: [])
        XCTAssertEqual(b.focused, ["1"])
        b.panes = []
        XCTAssertThrowsError(try service.focusTerminalTarget(target, sessions: []))
        XCTAssertEqual(b.focused, ["1"])
        XCTAssertTrue(a.focused.isEmpty)
        XCTAssertTrue(b.launched.isEmpty)
    }
}
