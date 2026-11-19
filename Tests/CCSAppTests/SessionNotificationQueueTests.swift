import XCTest
import CCSCore
@testable import CCSApp

final class SessionNotificationQueueTests: XCTestCase {
    func update(_ id: String, waiting: Bool = false) -> SessionUpdate {
        var session = Session(id: id, cwd: "/tmp", title: id, provider: .codex)
        session.status = waiting ? "waiting_input" : "idle"
        return SessionUpdate(target: TerminalSwitchTarget(session: session, tab: TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600")!), kind: waiting ? .attention : .finished)
    }
    func testFIFOTimeoutHoverPauseAndNoReplacement() {
        var time = Date(timeIntervalSince1970: 100)
        let queue = SessionNotificationQueue(now: { time })
        let a = update("a"), b = update("b")
        queue.enqueue([a]); time += 2; queue.tick(); queue.enqueue([b])
        XCTAssertEqual(queue.current?.id, a.id); XCTAssertEqual(queue.queuedCount, 1)
        queue.hovered = true; time += 20; queue.tick()
        XCTAssertEqual(queue.current?.id, a.id)
        queue.hovered = false; time += 2.9; queue.tick()
        XCTAssertEqual(queue.current?.id, a.id)
        time += 0.1; queue.tick(); XCTAssertEqual(queue.current?.id, b.id)
        time += 5; queue.tick(); XCTAssertNil(queue.current)
        XCTAssertEqual(queue.unreadCount, 2, "Timing out must not mark results read")
    }
    func testDirectTerminalVisitAcknowledgesAfterOneSecondAndSkipsQueuedNotice() {
        var time = Date(timeIntervalSince1970: 100)
        let queue = SessionNotificationQueue(now: { time })
        queue.enqueue([update("a"), update("b")])
        queue.observe("codex:b"); time += 0.5; queue.tick()
        XCTAssertEqual(queue.queuedCount, 1)
        queue.observe(nil); time += 1; queue.tick()
        XCTAssertEqual(queue.queuedCount, 1, "Switching away before one second must not acknowledge")
        queue.observe("codex:b"); time += 1; queue.tick()
        XCTAssertEqual(queue.queuedCount, 0); XCTAssertEqual(queue.unreadCount, 1)
        queue.observe("codex:a"); time += 1; queue.tick()
        XCTAssertNil(queue.current); XCTAssertEqual(queue.unreadCount, 0)
    }
    func testResolvedWaitIsDiscardedAndCompletionRemains() {
        let queue = SessionNotificationQueue()
        let waiting = update("b", waiting: true), finished = update("b")
        queue.enqueue([update("a")]); queue.enqueue([waiting, finished])
        queue.reconcile(TerminalActivitySnapshot(context: TerminalSwitchContext(targets: [finished.target], currentKey: nil)), attention: true, completion: true)
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertEqual(queue.unreadCount, 2)
        queue.acknowledge("codex:a"); queue.tick()
        XCTAssertEqual(queue.current?.id, finished.id)
    }
    func testAttentionGoesAheadOfQueuedCompletionsWhileKeepingVisibleBubbleClickable() {
        var time = Date()
        let queue = SessionNotificationQueue(now: { time })
        let first = update("a"), second = update("b"), third = update("c"), approval = update("d", waiting: true)
        queue.enqueue([first, second, third]); queue.enqueue([approval])
        XCTAssertEqual(queue.current?.id, first.id)
        for next in [approval, second, third] {
            time += 5; queue.tick(); XCTAssertEqual(queue.current?.id, next.id)
        }
    }
    func testBlockedPresentationWaitsWithoutLosingOrAgingNotice() {
        var time = Date(timeIntervalSince1970: 100), allowed = false
        let queue = SessionNotificationQueue(now: { time })
        queue.canPresent = { allowed }; queue.enqueue([update("a"), update("b")])
        time += 60; queue.tick(); XCTAssertNil(queue.current)
        allowed = true; queue.tick(); XCTAssertEqual(queue.current?.key, "codex:a")
        time += 2; queue.tick(); allowed = false
        time += 30; queue.tick(); allowed = true; queue.tick()
        time += 2; queue.tick(); XCTAssertEqual(queue.current?.key, "codex:a")
        time += 1; queue.tick(); XCTAssertEqual(queue.current?.key, "codex:b")
    }
    func testEventUpdatesKnownRowsImmediatelyAndSlowPollCannotRevertIt() {
        var completions = [(SessionUpdateMonitor.ResultType) -> Void](), results = [String]()
        var time = Date(timeIntervalSince1970: 100)
        let target = update("a").target
        let snapshot = TerminalActivitySnapshot(context: TerminalSwitchContext(targets: [target], currentKey: nil))
        let monitor = SessionUpdateMonitor(load: { completions.append($0) }, receive: { results.append($0.context.targets[0].session!.status) }, now: { time })
        monitor.configure(enabled: true); completions[0](.success(snapshot))
        time += 1; monitor.refresh()
        var session = target.session!; session.status = "waiting_input"
        time += 1; monitor.ingest(session)
        XCTAssertEqual(results.last, "waiting_input", "Event delivery must not wait for an in-flight scan")
        completions[1](.success(snapshot)); XCTAssertEqual(results.last, "waiting_input")
    }
}
