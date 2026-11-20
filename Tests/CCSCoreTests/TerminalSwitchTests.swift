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
            if script == SessionService.switchTabsScript { return CommandResult(out: terminalInventory([("/dev/ttys001", "Topic")])) }
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

    func testCachedPickerChecksLoadedIdentitiesAndRejectsNewAmbiguity() throws {
        var ids = ["abc"], focuses = 0, historyReads = 0
        func record(_ id: String) -> [String: Any] {
            ["id": id, "cwd": "/tmp/work", "updatedAt": 1, "name": "Topic", "preview": "", "status": ["type": "idle"]]
        }
        let client = MockCodexConnection { method, params in
            switch method {
            case "thread/loaded/list": return ["data": ids]
            case "thread/read": return ["thread": record(try XCTUnwrap(params["threadId"] as? String))]
            case "thread/list": historyReads += 1; return ["data": ids.map(record)]
            default: XCTFail("Unexpected RPC " + method); throw CCSError.message("Unexpected method")
            }
        }
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "n/tmp/work") }
            if script == SessionService.switchTabsScript {
                return CommandResult(out: terminalInventory([("/dev/ttys001", "Topic")]))
            }
            XCTAssertEqual(script, SessionService.focusScript)
            focuses += 1; return CommandResult(out: "ok")
        }, codex: CodexProvider(connector: { client }), arguments: { _ in ["codex"] })
        let session = try CodexProvider.session(record("abc"), authoritative: true)
        let target = try XCTUnwrap(service.terminalSwitchContext(sessions: [session]).targets.first)
        try service.activate(session, target: target, sessions: [session])
        XCTAssertEqual(client.calls.map { $0.0 }, ["thread/loaded/list", "thread/read"])
        XCTAssertEqual(focuses, 1)
        ids.append("new")
        XCTAssertThrowsError(try service.activate(session, target: target, sessions: [session]))
        XCTAssertGreaterThan(historyReads, 0)
        XCTAssertEqual(focuses, 1)
    }

    func testClaudeFocusRejectsCachedPIDAfterSessionMoves() throws {
        var session = Session(id: "abc", cwd: "/tmp/work")
        session.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"abc\",\"pid\":123}".utf8))
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/usr/bin/env" { return CommandResult(out: "[{\"sessionId\":\"abc\",\"pid\":456}]") }
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 claude\n456 1 ttys002 claude") }
            XCTAssertEqual(script, SessionService.switchTabsScript, "The reused tty must not be focused")
            return CommandResult(out: terminalInventory([("/dev/ttys001", "Old")]))
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
            if script == SessionService.switchTabsScript { return CommandResult(out: terminalInventory([("/dev/ttys001", "New topic")])) }
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
                return CommandResult(out: terminalInventory([("/dev/ttys001", "Quotes — café"), ("/dev/ttys002", "Unknown")], selected: "/dev/ttys001"))
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
    func testUnconfirmedCodexTabRemainsFocusableWithoutMetadataOrRenaming() throws {
        var pid = 123, title = "Other topic", focusCalls = 0
        let service = SessionService(runner: { path, args, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "\(pid) 1 ttys001 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "n/tmp/work") }
            if script == SessionService.switchTabsScript {
                return CommandResult(out: terminalInventory([("/dev/ttys001", title)], selected: "/dev/ttys001"))
            }
            XCTAssertEqual(script, SessionService.focusScript)
            XCTAssertEqual(args, ["-", "", "/dev/ttys001"], "Unconfirmed focus must preserve the native title")
            focusCalls += 1; return CommandResult(out: "ok")
        }, codex: CodexProvider(connector: { XCTFail("Generic tab switching needs no metadata connection"); throw CCSError.message("unexpected") }),
           arguments: { _ in ["codex", "resume", "abc"] })
        var original = Session(id: "abc", cwd: "/tmp/work", title: "Original topic", provider: .codex)
        original.status = "idle"
        var other = original; other.id = "def"; other.title = "Other topic"
        let context = try service.terminalSwitchContext(sessions: [original, other])
        let target = try XCTUnwrap(context.targets.first)
        XCTAssertNil(target.session, "Stale resume ID must not override the current native title")
        XCTAssertEqual(target.title, "Codex tab")
        XCTAssertEqual(context.currentKey, target.key)
        XCTAssertEqual(target.processID, 123)
        try service.focusTerminalTarget(target, sessions: [original, other])
        XCTAssertEqual(focusCalls, 1)
        pid = 124
        XCTAssertThrowsError(try service.focusTerminalTarget(target, sessions: [original, other]))
        XCTAssertEqual(focusCalls, 1, "A reused tty must not authorize focus")
        for renamed in ["", "Custom name"] {
            title = renamed
            XCTAssertNil(try service.terminalSwitchContext(sessions: [original]).targets.first?.session)
            XCTAssertTrue(try service.terminalSwitchContext(sessions: [], includeUnconfirmedCodex: false).targets.isEmpty)
        }
    }

    func testConfirmedResumeNeedsUniqueLiveTitleAndFolderAndDeduplicatesViewers() throws {
        var title = "Topic", directory = "/tmp/work"
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex\n124 1 ttys002 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "n" + directory) }
            XCTAssertEqual(script, SessionService.switchTabsScript)
            return CommandResult(out: terminalInventory([("/dev/ttys001", title), ("/dev/ttys002", title)], selected: "/dev/ttys002"))
        }, arguments: { _ in ["codex", "resume", "abc"] })
        var session = Session(id: "abc", cwd: "/tmp/work", title: "Topic", provider: .codex)
        session.status = "idle"
        let matched = try service.terminalSwitchContext(sessions: [session])
        XCTAssertEqual(matched.targets.count, 1)
        XCTAssertEqual(matched.currentKey, session.key)
        XCTAssertEqual(matched.keysByTTY, ["/dev/ttys001": session.key, "/dev/ttys002": session.key], "Either viewer must identify the same origin in a cached chooser")
        XCTAssertEqual(matched.targets.first?.session?.key, session.key)
        var duplicate = session; duplicate.id = "other"
        let ambiguous = try service.terminalSwitchContext(sessions: [session, duplicate])
        XCTAssertEqual(ambiguous.targets.count, 2, "Unconfirmed clients cannot safely be deduplicated by conversation")
        XCTAssertTrue(ambiguous.targets.allSatisfy { $0.session == nil })
        XCTAssertEqual(Set(ambiguous.targets.map(\.key)).count, 2)
        directory = "/tmp/another"
        XCTAssertTrue(try service.terminalSwitchContext(sessions: [session]).targets.allSatisfy { $0.session == nil })
        directory = "/tmp/work"; title = "Renamed"
        XCTAssertTrue(try service.terminalSwitchContext(sessions: [session]).targets.allSatisfy { $0.session == nil })
    }

    func testCachedSocketIdentityMatchesRemoteClientWithoutOpeningMetadataConnection() throws {
        var session = Session(id: "abc", cwd: "/tmp/work", title: "Topic", provider: .codex)
        session.status = "idle"
        let service = SessionService(runner: { path, _, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 codex") }
            if path == "/usr/sbin/lsof" { return CommandResult(out: "n/tmp/work") }
            XCTAssertEqual(script, SessionService.switchTabsScript)
            return CommandResult(out: terminalInventory([("/dev/ttys001", "Topic")]))
        }, codex: CodexProvider(connector: { XCTFail("Tab enumeration must not connect to the provider"); throw CCSError.message("unexpected") }),
           arguments: { _ in ["codex", "--remote", "unix:///tmp/socket", "resume", "abc"] })
        XCTAssertEqual(try service.terminalSwitchContext(sessions: [session], codexSocketPath: "/tmp/socket").targets.first?.session?.key, session.key)
        XCTAssertNil(try service.terminalSwitchContext(sessions: [session], codexSocketPath: "/tmp/other").targets.first?.session)
    }

    func testOriginLookupReadsOnlySelectedTTYAndPropagatesAutomationFailure() throws {
        var code: Int32 = 0, output = "/dev/ttys001\n"
        let service = SessionService(runner: { path, args, script, timeout in
            XCTAssertEqual(path, "/usr/bin/osascript")
            XCTAssertEqual(args, ["-"]); XCTAssertEqual(script, SessionService.selectedTTYScript)
            XCTAssertEqual(timeout, 2)
            return CommandResult(code: code, out: output)
        })
        XCTAssertEqual(try service.selectedTerminalTTY(), "/dev/ttys001")
        output = ""; XCTAssertNil(try service.selectedTerminalTTY())
        output = "unexpected"; XCTAssertThrowsError(try service.selectedTerminalTTY())
        output = "/dev/ttys001\n/dev/ttys002"; XCTAssertThrowsError(try service.selectedTerminalTTY())
        output = "/dev/ttys001"; code = 1
        XCTAssertThrowsError(try service.selectedTerminalTTY())
    }

    func testPartialScanKeepsReadableClaudeViewerWithoutSelectedTabOrGeometry() throws {
        let tty = "/dev/ttys005"
        let output = terminalInventory([(tty, "Claude\u{1e} topic\u{1f}\nnext"), ("missing value", "")])
        var focused = [String]()
        let adapter = AppleTerminalAdapter { _, args, script, _ in
            if script == SessionService.switchTabsScript { return CommandResult(out: output) }
            XCTAssertEqual(script, SessionService.focusScript)
            focused = args
            return CommandResult(out: "ok")
        }
        let registry = TerminalRegistry(adapters: [adapter], isInstalled: { _ in true })
        let inventory = try adapter.tabs()
        XCTAssertFalse(inventory.isComplete)
        XCTAssertNil(inventory.selectedTTY)
        XCTAssertEqual(inventory.tabs.map(\.tty), [tty])
        XCTAssertEqual(inventory.tabs.first?.title, "Claude topic next")
        XCTAssertTrue(try registry.focusViewer(ttys: [tty], title: "Claude"))
        XCTAssertEqual(focused, ["-", "Claude", tty])
        XCTAssertThrowsError(try registry.focusViewer(ttys: ["/dev/ttys006"], title: "Missing"))
    }

    func testSwitchAutomationScriptsCompile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer { try? FileManager.default.removeItem(at: path) }
        for (script, language) in [(SessionService.switchTabsScript, "JavaScript"), (SessionService.selectedTTYScript, "AppleScript")] {
            let result = try ProcessRunner().run("/usr/bin/osacompile", ["-l", language, "-o", path.path, "-"], input: script)
            XCTAssertEqual(result.code, 0, result.err)
        }
    }
}

func terminalInventory(_ tabs: [(String, String)], selected: String? = nil, complete: Bool = true) -> String {
    var payload: [String: Any] = ["complete": complete, "tabs": tabs.map { ["tty": $0.0, "title": $0.1] }]
    payload["selectedTTY"] = selected
    return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}
