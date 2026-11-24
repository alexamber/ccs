import JavaScriptCore
import XCTest
import CCSCore
@testable import CCSApp

final class VisibleDraftTests: XCTestCase {
    func testRenderedComposersAndPlaceholders() throws {
        let context = try XCTUnwrap(JSContext())
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CCSApp/Resources/VisibleDraft.js")
        context.evaluateScript(try String(contentsOf: file))
        let possible = try XCTUnwrap(context.objectForKeyedSubscript("possibleDraft"))
        func check(_ screen: String, _ provider: String) -> Bool {
            possible.call(withArguments: [screen, provider]).toBool()
        }
        XCTAssertTrue(check("───────\r❯\u{00a0}finish the charts\r───────\r? for shortcuts", "claude"))
        XCTAssertFalse(check("───────\n❯ Try \"fix the build\"\n───────", "claude"))
        XCTAssertFalse(check("───────\n❯\n───────", "claude"))
        func claudeBox(_ input: [String]) -> String {
            (["────────"] + input + ["────────", "? for shortcuts"]).joined(separator: "\n")
        }
        XCTAssertTrue(check(claudeBox(["❯ try the other port"]), "claude"))
        XCTAssertTrue(check(claudeBox(["❯", "  write the summary"]), "claude"))
        XCTAssertTrue(check(claudeBox(["❯paste this"] + Array(repeating: "  wrapped text", count: 18)), "claude"))
        XCTAssertFalse(check(claudeBox(["❯", "   "]), "claude"))
        XCTAssertFalse(check(claudeBox(["❯ Try “fix the build”"]), "claude"))
        XCTAssertFalse(check(claudeBox(["❯ earlier draft"]) + "\n• Assistant reply", "claude"))
        XCTAssertFalse(check(claudeBox(["❯ earlier draft"]) + "\n" + claudeBox(["❯"]), "claude"))
        XCTAssertFalse(check("❯ submitted request\n• reply\n? for shortcuts", "claude"))
        let footer = "⏵⏵ auto mode on (shift+tab to cycle)"
        let status = ["Opus · ctx", "cache · 7d", "session", "week"]
        for border in ["────────", "     "] {
            let screen = status + [border, "❯ post", border, footer]
            XCTAssertTrue(check(screen.joined(separator: "\r"), "claude"))
            XCTAssertFalse(check([border, "❯", border, footer].joined(separator: "\r"), "claude"))
            XCTAssertFalse(check([border, "❯ Try “fix the build”", border, footer].joined(separator: "\r"), "claude"))
        }
        XCTAssertFalse(check(["❯ post", "• Already sent", footer].joined(separator: "\n"), "claude"))
        let normalizedTitle = try XCTUnwrap(context.objectForKeyedSubscript("terminalTitle"))
        let title = "  Build\u{200B}\n the\u{00a0} report "
        XCTAssertEqual(normalizedTitle.call(withArguments: [title]).toString(), "Build the report")
        XCTAssertEqual(normalizedTitle.call(withArguments: [cleanText(title)]).toString(), "Build the report")
        XCTAssertTrue(check("› finish the charts\n  and the notes\n\ngpt-6.2 · ~/git", "codex"))
        XCTAssertFalse(check("› earlier prompt\n• Answer\n›\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› Ask Codex to do anything\n  gpt-6.2 default · /tmp\n  ← for agents · ? for shortcuts", "codex"))
        XCTAssertFalse(check("› Explain this codebase\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› earlier prompt\n• Answer\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› finish the charts\n", "codex"))
    }

    func testConfirmedDraftSurvivesUnrelatedTabChangesUntilRescanned() {
        var completions = [(Set<String>) -> Void]()
        let drafts = VisibleDrafts { _, done in completions.append(done) }
        func target(_ id: String, x: CGFloat = 0) -> TerminalSwitchTarget {
            let tab = TerminalTabSnapshot(terminalID: "com.apple.Terminal", paneID: id, tty: id,
                                          bounds: CGRect(x: x, y: 0, width: 300, height: 200), title: id)
            return TerminalSwitchTarget(session: Session(id: id, cwd: "/work"), tab: tab)
        }
        let one = target("one"), two = target("two")
        drafts.check([one]); completions[0]([one.key])
        drafts.check([target("one", x: 80)])
        XCTAssertEqual(completions.count, 1)
        drafts.check([one, two])
        XCTAssertEqual(drafts.keys, [one.key])
        completions[1]([])
        XCTAssertTrue(drafts.keys.isEmpty)
    }

    func testLateScanCannotMarkReusedTab() {
        var completions = [(Set<String>) -> Void]()
        let drafts = VisibleDrafts { _, done in completions.append(done) }
        let tab = TerminalTabSnapshot(terminalID: "com.apple.Terminal", paneID: "p", tty: "/dev/ttys01", bounds: .zero, title: "one")
        let old = TerminalSwitchTarget(session: Session(id: "one", cwd: "/work"), tab: tab)
        let new = TerminalSwitchTarget(session: Session(id: "two", cwd: "/work"), tab: tab)
        drafts.check([old]); drafts.check([new])
        completions[1]([new.key]); completions[0]([old.key])
        XCTAssertEqual(drafts.keys, [new.key])
        drafts.clear(); XCTAssertTrue(drafts.keys.isEmpty)
    }
}
