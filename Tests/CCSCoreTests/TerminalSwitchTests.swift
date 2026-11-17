import Foundation
import XCTest
@testable import CCSCore

final class TerminalSwitchTests: XCTestCase {
    func testNormalActivationFocusesBareCodexInsteadOfLaunchingDuplicate() throws {
        let records: [[String: Any]] = ["abc", "other"].map { id in
            ["id": id, "cwd": "/tmp/work", "updatedAt": 1, "name": id == "abc" ? "Topic" : "Other topic", "preview": "", "status": ["type": "idle"]]
        }
        var failedFocus = false, failedHistory = false, focuses = 0
        let client = MockCodexConnection { method, _ in
            if method == "thread/read" { return ["thread": records[0]] }
            if failedHistory { throw CCSError.message("unavailable") }
            return ["data": records]
        }
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "n/tmp/work") }
            if script == SessionService.switchTabsScript { return CommandResult(out: "\u{1e}/dev/ttys001\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Topic") }
            XCTAssertEqual(script, SessionService.focusScript, "Never launch another viewer for the matched conversation")
            focuses += 1
            return CommandResult(code: failedFocus ? 1 : 0, out: failedFocus ? "" : "ok")
        }, codex: CodexProvider(connector: { client }), arguments: { _ in ["codex"] })
        let session = try CodexProvider.session(records[0], authoritative: true)
        try service.activate(session)
        XCTAssertEqual(focuses, 1)
        failedFocus = true
        XCTAssertThrowsError(try service.activate(session))
        XCTAssertEqual(focuses, 2)
        failedHistory = true
        XCTAssertThrowsError(try service.activate(session))
        XCTAssertEqual(focuses, 2)
    }

    func testClaudeFocusRejectsCachedPIDAfterSessionMoves() throws {
        var session = Session(id: "abc", cwd: "/tmp/work")
        session.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"abc\",\"pid\":123}".utf8))
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/usr/bin/env" { return CommandResult(out: "[{\"sessionId\":\"abc\",\"pid\":456}]") }
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 claude\n456 1 ttys002 claude") }
            XCTAssertEqual(script, SessionService.switchTabsScript, "The reused tty must not be focused")
            return CommandResult(out: "\u{1e}/dev/ttys001\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Old")
        }, arguments: { _ in ["claude"] })
        let tab = TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!
        XCTAssertThrowsError(try service.focusTerminalTarget(TerminalSwitchTarget(session: session, tab: tab), sessions: [session]))
    }
    func testFreshActionProviderReadsCodexBeforeMatchingAndUsesCurrentTitle() throws {
        var initial = Session(id: "abc", cwd: "/tmp/work", title: "Old topic", provider: .codex)
        initial.status = "idle"
        var initialized = false, focused = false
        let client = MockCodexConnection { method, _ in
            XCTAssertEqual(method, "thread/read"); initialized = true
            return ["thread": ["id": "abc", "cwd": "/tmp/work", "updatedAt": 1, "name": "New topic", "preview": "", "status": ["type": "idle"]]]
        }
        let provider = CodexProvider(connector: { client })
        let service = SessionService(runner: { path, args, script, _ in
            XCTAssertTrue(initialized, "The action service must initialize its own Codex provider before matching")
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "p123\nn/tmp/work") }
            if script == SessionService.switchTabsScript { return CommandResult(out: "\u{1e}/dev/ttys001\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}New topic") }
            XCTAssertEqual(script, SessionService.focusScript)
            XCTAssertEqual(args, ["-", "New topic", "/dev/ttys001"])
            focused = true; return CommandResult(out: "ok")
        }, codex: provider, arguments: { _ in ["codex"] })
        let tab = TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600\nOld topic")!
        try service.focusTerminalTarget(TerminalSwitchTarget(session: initial, tab: tab), sessions: [initial])
        XCTAssertTrue(focused)
    }
    func testEnumeratesMatchesCurrentAndFocusesWithoutLaunching() throws {
        var session = Session(id: "abc", cwd: "/tmp/work", title: "Quotes — café")
        session.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"abc\",\"pid\":123}".utf8))
        var exists = true, focusCalls = 0, processReads = 0
        let service = SessionService(runner: { path, args, script, _ in
            if path == "/usr/bin/env" { return CommandResult(out: exists ? "[{\"sessionId\":\"abc\",\"pid\":123}]" : "[]") }
            if path == "/bin/ps" { processReads += 1; return CommandResult(out: exists ? "123 1 ttys001 claude" : "") }
            if script == SessionService.switchTabsScript {
                return CommandResult(out: "/dev/ttys001\u{1e}/dev/ttys001\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Quotes — café\u{1e}/dev/ttys002\u{1f}0\u{1f}0\u{1f}900\u{1f}600\u{1f}Unknown")
            }
            XCTAssertEqual(script, SessionService.focusScript)
            XCTAssertEqual(args, ["-", "Quotes — café", "/dev/ttys001"])
            focusCalls += 1; return CommandResult(out: "ok")
        }, arguments: { _ in ["claude"] })
        let context = try service.terminalSwitchContext(sessions: [session])
        XCTAssertEqual(processReads, 1, "Enumerating multiple tabs shares one process snapshot")
        XCTAssertEqual(context.targets.count, 1)
        XCTAssertEqual(context.currentKey, session.key)
        let target = try XCTUnwrap(context.targets.first)
        try service.focusTerminalTarget(target, sessions: [session])
        XCTAssertEqual(focusCalls, 1)
        exists = false
        XCTAssertThrowsError(try service.focusTerminalTarget(target, sessions: [session]))
        XCTAssertEqual(focusCalls, 1, "An ended session must never be resumed by the switcher")
    }
    func testSwitchAppleScriptCompiles() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer { try? FileManager.default.removeItem(at: path) }
        let result = try ProcessRunner().run("/usr/bin/osacompile", ["-o", path.path, "-"], input: SessionService.switchTabsScript)
        XCTAssertEqual(result.code, 0, result.err)
    }
}
