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
        XCTAssertTrue(check("› finish the charts\n  and the notes\n\ngpt-6.2 · ~/git", "codex"))
        XCTAssertFalse(check("› earlier prompt\n• Answer\n›\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› Ask Codex to do anything\n  gpt-6.2 default · /tmp\n  ← for agents · ? for shortcuts", "codex"))
        XCTAssertFalse(check("› Explain this codebase\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› earlier prompt\n• Answer\n? for shortcuts", "codex"))
        XCTAssertFalse(check("› finish the charts\n", "codex"))
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
