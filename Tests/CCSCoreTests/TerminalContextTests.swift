import Foundation
import CoreGraphics
import XCTest
@testable import CCSCore

final class TerminalContextTests: XCTestCase {
    func testLaunchAndFocusPassTitlesAsDataAndFreshUsesFolder() throws {
        let title = "Fix \"quotes\" — Łódź 🐈 $(touch /tmp/never)"
        var live = false, calls = [([String], String)]()
        let service = SessionService(runner: { path, args, script, _ in
            if path == "/usr/bin/env" { return CommandResult(out: live ? "[{\"sessionId\":\"abc\",\"pid\":123,\"kind\":\"interactive\"}]" : "[]") }
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 claude") }
            if script == SessionService.switchTabsScript {
                return CommandResult(out: terminalInventory([("/dev/ttys001", "Topic")]))
            }
            calls.append((args, script ?? "")); return CommandResult(out: "ok")
        })
        let session = Session(id: "abc", cwd: "/tmp/folder", title: title)
        try service.activate(session)
        XCTAssertEqual(calls[0].0, ["-", title, "cd '/tmp/folder' && claude --resume 'abc'"])
        XCTAssertFalse(calls[0].1.contains(title))
        live = true
        try service.activate(session)
        XCTAssertEqual(calls[1].0, ["-", title, "/dev/ttys001"])
        XCTAssertFalse(calls[1].1.contains(title))
        try service.activate(session, fresh: true)
        XCTAssertEqual(calls[2].0, ["-", "folder", "cd '/tmp/folder' && claude"])
        XCTAssertEqual(Session(id: "abc", cwd: "/tmp/2026-11-16-5").terminalTitle, "2026-11-16-5")
        XCTAssertEqual(Session(id: "abc", cwd: "").terminalTitle, "Claude")
    }

    func testTitleHandlerComparesBeforeWritingAndSwallowsWriteFailure() throws {
        // Execute the actual AppleScript handler against a local script object.
        // Replace only the setter with an instrumented failure: no Terminal tab
        // is opened, focused, or modified by this test.
        let instrumented = SessionService.titleScript.replacingOccurrences(
            of: "then set custom title of targetTab to newTitle",
            with: "then\nset my writes to (my writes) + 1\nerror \"simulated naming failure\"\nend if")
        let script = """
        property writes : 0
        using terms from application "Terminal"
          script fakeTab
            property custom title : ""
          end script
          on run argv
            set custom title of fakeTab to item 1 of argv
            my nameTab(fakeTab, item 2 of argv)
            return "continued:" & (my writes as text)
          end run
        end using terms from
        """ + "\n" + instrumented
        for (old, new, count) in [("Same 🐈", "Same 🐈", 0), ("old", "Fix \"quotes\" — Łódź", 1), ("title", "Title", 1), ("cafe", "café", 1), ("old", "", 0)] {
            let result = try ProcessRunner().run("/usr/bin/osascript", ["-", old, new], input: script)
            XCTAssertEqual(result.code, 0, result.err)
            XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "continued:\(count)")
        }
    }

    func testActualTitleHandlerSetsUnicodeOnLocalTabObject() throws {
        let script = """
        using terms from application "Terminal"
          script fakeTab
            property custom title : "old"
          end script
          on run argv
            my nameTab(fakeTab, item 1 of argv)
            return custom title of fakeTab
          end run
        end using terms from
        """ + "\n" + SessionService.titleScript
        let title = "Fix \"quotes\" — Łódź 🐈"
        let result = try ProcessRunner().run("/usr/bin/osascript", ["-", title], input: script)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), title)
    }

    func testTerminalAutomationScriptsCompile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for script in [SessionService.launchScript, SessionService.focusScript, TerminalTabSnapshot.script] {
            let source = directory.appendingPathComponent("source.applescript")
            try script.write(to: source, atomically: true, encoding: .utf8)
            let result = try ProcessRunner().run("/usr/bin/osacompile", ["-o", directory.appendingPathComponent("compiled.scpt").path, source.path])
            XCTAssertEqual(result.code, 0, result.err)
        }
    }

    func testFocusAndLaunchFailuresStillReachCaller() {
        let service = SessionService(runner: { path, _, _, _ in
            if path == "/usr/bin/env" { return CommandResult(out: "[{\"sessionId\":\"abc\",\"pid\":123,\"kind\":\"interactive\"}]") }
            if path == "/bin/ps" { return CommandResult(out: "123 1 ttys001 claude") }
            return CommandResult(code: 1, err: "Automation denied")
        })
        XCTAssertThrowsError(try service.activate(Session(id: "abc", cwd: "/tmp")))
        XCTAssertThrowsError(try service.openTerminal("true", title: "Title"))
    }

    func testTTYMatchingRejectsUnknownAndAmbiguousTabsAndSupportsCodex() throws {
        let processes = "10 1 ttys001 claude\n20 1 ttys002 codex resume abc\n30 10 ?? claude daemon"
        let service = SessionService(runner: { path, _, _, _ in CommandResult(out: path == "/usr/sbin/lsof" ? "n/tmp/codex" : processes) },
                                     arguments: { $0 == 20 ? ["codex", "resume", "abc"] : ["claude"] })
        var claude = Session(id: "abc", cwd: "/tmp/claude")
        claude.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"abc\",\"pid\":10}".utf8))
        var codex = Session(id: "abc", cwd: "/tmp/codex", title: "Topic", provider: .codex)
        codex.status = "idle"
        XCTAssertEqual(service.session(inTerminalTTY: "/dev/ttys001", sessions: [claude, codex])?.key, "claude:abc")
        XCTAssertNil(service.session(inTerminalTTY: "/dev/ttys002", sessions: [claude, codex]))
        let tab = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys002\n0\n0\n900\n600\nTopic"))
        XCTAssertEqual(service.session(inTerminalTab: tab, sessions: [claude, codex])?.key, "codex:abc")
        XCTAssertNil(service.session(inTerminalTTY: "/dev/ttys003", sessions: [claude, codex]))
        XCTAssertNil(service.session(inTerminalTTY: "ttys001", sessions: [claude]))
        var background = Session(id: "background", cwd: "/tmp")
        background.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"background\",\"pid\":30}".utf8))
        XCTAssertNil(service.session(inTerminalTTY: "/dev/ttys001", sessions: [claude, background]))
    }

    func testFailedTabReadAndProcessInspectionAreSilent() {
        let denied: CommandRunner = { _, _, _, _ in CommandResult(code: 1, err: "denied") }
        XCTAssertNil(TerminalTabSnapshot.read(runner: denied))
        XCTAssertNil(TerminalTabSnapshot.read(runner: { _, _, _, _ in throw CCSError.message("timeout") }))
        XCTAssertNil(SessionService(runner: denied).session(inTerminalTTY: "/dev/ttys001", sessions: []))
    }

    func testPlainCodexPopupNeedsMatchingTitleDirectoryAndUniqueLiveSession() throws {
        let tab = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys007\n0\n0\n900\n600\n⠼ Review terminal tab spec | ccs"))
        var words = ["codex"], directory = "/tmp/ccs", lsofFails = false
        let service = SessionService(runner: { path, args, _, _ in
            if path == "/bin/ps" { return CommandResult(out: "42 1 ttys007 codex") }
            XCTAssertEqual(path, "/usr/sbin/lsof")
            XCTAssertEqual(args, ["-a", "-p", "42", "-d", "cwd", "-Fn"])
            return CommandResult(code: lsofFails ? 1 : 0, out: "p42\nfcwd\nn\(directory)\n")
        }, arguments: { _ in words })
        var session = Session(id: "abc", cwd: "/tmp/ccs", title: "Review terminal tab spec", provider: .codex)
        session.status = "active"
        XCTAssertEqual(service.session(inTerminalTab: tab, sessions: [session])?.key, session.key)
        // TTY-only lookup cannot use the title-based fallback.
        XCTAssertNil(service.session(inTerminalTTY: tab.tty, sessions: [session]))
        var duplicate = session; duplicate.id = "other"
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session, duplicate]))
        duplicate.title = "Another topic"
        XCTAssertEqual(service.session(inTerminalTab: tab, sessions: [session, duplicate])?.key, session.key)
        directory = "/tmp/other"
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session]))
        directory = "/tmp/ccs"; words = ["codex", "--remote", "ws://another-machine"]
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session]))
        words = ["codex"]; lsofFails = true
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session]))
        lsofFails = false; session.status = "unknown"
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session]))
        session.status = "active"; session.title = "Wrong topic"
        XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session]))
    }

    func testCodexResumeWithoutLaunchIDMatchesSelectedConversationButNeverGuesses() throws {
        var words = ["codex", "resume"]
        let service = SessionService(runner: { path, _, _, _ in
            CommandResult(out: path == "/usr/sbin/lsof" ? "n/tmp/ccs" : "42 1 ttys001 codex resume")
        }, arguments: { _ in words })
        var session = Session(id: "abc", cwd: "/tmp/ccs", title: "Review terminal tab spec", provider: .codex)
        session.status = "active"
        func tab(_ title: String) throws -> TerminalTabSnapshot {
            try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600\n" + title))
        }
        let selected = try tab("⠼ Review terminal tab spec | ccs")
        for command in [["codex", "resume"], ["codex", "resume", "--last"], ["codex", "resume", "--all"]] {
            words = command
            XCTAssertEqual(service.session(inTerminalTab: selected, sessions: [session])?.key, session.key)
            for title in ["", "Codex", "Resume a session", "Another topic | ccs"] {
                XCTAssertNil(service.session(inTerminalTab: try tab(title), sessions: [session]))
            }
            var other = session; other.id = "other"
            XCTAssertNil(service.session(inTerminalTab: selected, sessions: [session, other]))
            other = session; other.cwd = "/tmp/other"
            XCTAssertNil(service.session(inTerminalTab: selected, sessions: [other]))
            other = session; other.status = "saved"
            XCTAssertNil(service.session(inTerminalTab: selected, sessions: [other]))
        }
        for command in [["codex", "--remote", "ws://other-host", "resume"], ["codex", "resume", "different-id"]] {
            words = command
            XCTAssertNil(service.session(inTerminalTab: selected, sessions: [session]))
        }
    }

    func testPlainCodexProcessDetectionRejectsOtherCommandsAndMultipleClients() {
        let listing = "42 1 ttys001 codex\n43 1 ttys002 codex"
        for words in [["codex"], ["/bin/codex", "--cd", "/tmp/work", "--model=example"], ["codex", "--remote", "unix:///tmp/local"]] {
            XCTAssertEqual(CodexProvider.terminalProcess(tty: "ttys001", processList: listing,
                arguments: { _ in words })?.pid, 42)
        }
        for words in [["codex", "exec"], ["codex", "app-server"], ["sh", "codex"], ["codex", "--cd"], ["codex", "--unknown"]] {
            XCTAssertNil(CodexProvider.terminalProcess(tty: "ttys001", processList: listing,
                arguments: { _ in words }))
        }
        XCTAssertNil(CodexProvider.terminalProcess(tty: "ttys001", processList: "42 1 ttys001 codex\n43 1 ttys001 codex",
            arguments: { _ in ["codex"] }))
    }

    func testCodexDialogKeepsConfirmedIdentityAndAttentionStatusThroughBothBlinkPhases() throws {
        let service = SessionService(runner: { path, _, _, _ in
            CommandResult(out: path == "/usr/sbin/lsof" ? "n/tmp/work" : "42 1 ttys001 codex")
        }, arguments: { _ in ["codex"] })
        for status in ["waiting", "waiting_input"] {
            var session = Session(id: "a", cwd: "/tmp/work", title: "Choose a color", provider: .codex)
            session.status = status
            for prefix in ["[ ! ] Action Required | ", "[ . ] Action Required | ", "● [ ! ] Action Required | "] {
                let tab = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600\n" + prefix + "Choose a color | work"))
                let match = try XCTUnwrap(service.session(inTerminalTab: tab, sessions: [session]))
                XCTAssertEqual(match.key, session.key)
                XCTAssertEqual(SessionActivity(status: match.status), .attention)
                XCTAssertEqual(tab.matchingTitle, "Choose a color | work")
                var duplicate = session; duplicate.id = "b"
                XCTAssertNil(service.session(inTerminalTab: tab, sessions: [session, duplicate]), "A dialog must not weaken ambiguous-topic checks")
            }
        }
    }

    func testCodexNativeTitlesMatchWholeNamesAndConservativeTruncation() {
        let name = "Review terminal tab spec"
        for title in [name, name + " | ccs", "⠼ " + name + " | ccs", "● ⠋ " + name + " | ccs", "[ ! ] Action Required " + name + " | ccs",
                      "[ ! ] Action Required | " + name + " | ccs", "[ . ] Action Required | " + name + " | ccs",
                      "● [ ! ] Action Required | " + name + " | ccs", "● [ . ] Action Required | " + name + " | ccs"] {
            XCTAssertTrue(CodexProvider.terminalTitle(title, matches: name))
        }
        for title in ["Other " + name, name + " extra | ccs", "ccs", "", "[ ! ] Action Required", "[ . ] Action Required",
                      "[ ! ] Action Required | Other " + name + " | ccs", "[ ! ] Action Requiredness | " + name] {
            XCTAssertFalse(CodexProvider.terminalTitle(title, matches: name))
        }
        let long = String(repeating: "é", count: 55)
        XCTAssertTrue(CodexProvider.terminalTitle(String(long.prefix(45)) + "... | ccs", matches: long))
        XCTAssertTrue(CodexProvider.terminalTitle("[ . ] Action Required | " + String(long.prefix(45)) + "... | ccs", matches: long))
        XCTAssertFalse(CodexProvider.terminalTitle(String(long.prefix(10)) + "... | ccs", matches: long))
    }

    func testPopupReusesHistoryButRefreshesOnNewSessionAndRechecksProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache"))
        var loads = 0, second = false, processes = "42 1 ttys001 claude\n43 1 ttys002 claude"
        let service = SessionService(index: index, runner: { path, _, _, _ in
            if path == "/usr/bin/env" {
                loads += 1
                let records = [["sessionId": "abc", "pid": 42, "cwd": "/tmp/first"]] +
                    (second ? [["sessionId": "def", "pid": 43, "cwd": "/tmp/second"]] : [])
                return CommandResult(out: String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self))
            }
            return CommandResult(out: processes)
        }, codex: CodexProvider(enabled: false), arguments: { _ in ["claude"] })
        _ = try service.collect(days: 0, provider: .all, enabledProviders: [.claude])
        let collectedAt = try XCTUnwrap(service.cachedTerminalMetadata?.updatedAt)
        let first = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600"))
        XCTAssertEqual(try service.session(inTerminalTab: first, enabledProviders: [.claude])?.id, "abc")
        XCTAssertEqual(loads, 1, "A tab switch should reuse the picker's recent history")
        XCTAssertEqual(service.cachedTerminalMetadata?.updatedAt, collectedAt, "A cached lookup must not extend metadata freshness")
        second = true
        let next = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys002\n0\n0\n900\n600"))
        XCTAssertEqual(try service.session(inTerminalTab: next, enabledProviders: [.claude])?.id, "def")
        XCTAssertEqual(loads, 2, "A new session must refresh on a cache miss")
        XCTAssertNil(try service.session(inTerminalTab: next, enabledProviders: [.codex]))
        processes = ""
        XCTAssertNil(try service.session(inTerminalTab: first, enabledProviders: [.claude]), "Cached metadata must not label a closed process")
    }

    func testSnapshotParsingAndPopupSettingCompatibility() throws {
        let tab = try XCTUnwrap(TerminalTabSnapshot(output: "/dev/ttys001\n-500\n30\n200\n430\n"))
        XCTAssertEqual(tab.bounds, CGRect(x: -500, y: 30, width: 700, height: 400))
        for invalid in ["", "missing", "/dev/ttys001\n0\n0\nnan\n100", "/dev/ttys001\n0\n0\n0\n100"] {
            XCTAssertNil(TerminalTabSnapshot(output: invalid))
        }
        let old = Data("{\"defaultDays\":7,\"folders\":false,\"newDirectory\":\"~/sessions\",\"cleanup\":true,\"hotkeyCode\":49,\"hotkeyModifiers\":2048,\"hotkeyLabel\":\"⌥Space\"}".utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertFalse(settings.terminalPopups)
        settings.terminalPopups = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).terminalPopups)
    }
}
