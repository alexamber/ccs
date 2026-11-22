import AppKit
import XCTest
import CCSCore
@testable import CCSApp

final class SessionActivityCoordinatorTests: XCTestCase {
    private func target(_ status: String, provider: Provider = .codex, turn: String? = nil) -> TerminalSwitchTarget {
        var session = Session(id: "topic", cwd: "/tmp/work", title: "Topic", provider: provider)
        session.status = status
        if let turn { session.activityTurn = SessionActivityTurn(id: turn, status: "completed") }
        return TerminalSwitchTarget(session: session, tab: TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600\nTopic")!)
    }
    private func snapshot(_ target: TerminalSwitchTarget) -> TerminalActivitySnapshot {
        TerminalActivitySnapshot(context: TerminalSwitchContext(targets: [target], currentKey: nil))
    }
    private func settings() -> Settings {
        var value = Settings(); value.terminalPopups = true; value.enabledProviders = [.codex]
        return value
    }

    func testMutedAlertsKeepLiveStatusAndUnmutingDoesNotReplayOldWork() {
        var clock = Date(), requests = [(SessionUpdateMonitor.ResultType) -> Void]()
        var statuses = [String](), shown = [SessionUpdate](), remembered = [String](), unread = -1
        let activity = SessionActivityCoordinator(load: { _, done in requests.append(done) },
            remember: { remembered.append($0.status) }, now: { clock })
        defer { activity.stop() }
        activity.onSnapshot = { statuses.append($0.context.targets.first!.session!.status); _ = $1 }
        activity.onShow = { shown.append($0) }; activity.onUnreadChange = { unread = $0 }
        var preferences = settings(); preferences.notifyAttention = false; preferences.notifyCompletion = false
        activity.configure(preferences)
        XCTAssertEqual(requests.count, 1, "Muting alerts must not disable monitoring")
        requests[0](.success(snapshot(target("idle", turn: "old"))))
        activity.ingest(target("active").session!)
        activity.ingest(target("waiting_input").session!)
        activity.ingest(target("idle", turn: "muted").session!)
        XCTAssertEqual(statuses, ["idle", "active", "waiting_input", "idle"])
        XCTAssertEqual(remembered, ["active", "waiting_input", "idle"])
        XCTAssertTrue(shown.isEmpty); XCTAssertEqual(unread, 0)
        preferences.notifyAttention = true; preferences.notifyCompletion = true
        activity.configure(preferences)
        clock.addTimeInterval(3); activity.refresh { _ in }
        requests[1](.success(snapshot(target("idle", turn: "muted"))))
        XCTAssertTrue(shown.isEmpty, "Unmuting must preserve the observed transition baseline")
        activity.ingest(target("active").session!)
        activity.ingest(target("idle", turn: "new").session!)
        XCTAssertEqual(shown.count, 1); XCTAssertEqual(shown.first?.kind, .finished)
        XCTAssertEqual(unread, 1)
    }

    func testClaudePollRetainsQuestionAndFirstStopAfterWaitNotifiesOnce() {
        var time = Date(), reply: ((SessionUpdateMonitor.ResultType) -> Void)?
        let activity = SessionActivityCoordinator(load: { _, done in reply = done }, now: { time })
        defer { activity.stop() }
        var preferences = settings(); preferences.enabledProviders = [.claude]
        var shown = Set<UUID>(), unread = 0
        activity.onShow = { shown.insert($0.id) }
        activity.onUnreadChange = { unread = $0 }
        activity.configure(preferences)
        reply?(.success(snapshot(target("idle", provider: .claude))))
        activity.ingest(target("waiting_input", provider: .claude).session!)
        time += 3; activity.refresh { _ in }
        reply?(.success(snapshot(target("waiting", provider: .claude))))
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(activity.targets.first?.session?.status, "waiting_input")
        activity.observe("claude:topic"); time += 1; activity.tick()
        XCTAssertEqual(activity.targets.first?.session?.status, "waiting_input")
        activity.observe(nil)
        let stop = target("idle", provider: .claude, turn: "first-stop").session!
        activity.ingest(stop); activity.ingest(stop)
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(activity.finished, ["claude:topic"]); XCTAssertEqual(unread, 1)
        activity.observe("claude:topic"); time += 1; activity.tick()
        XCTAssertEqual(unread, 0)
        activity.observe(nil)
        activity.ingest(target("active", provider: .claude).session!)
        time += 3; activity.refresh { _ in }
        reply?(.success(snapshot(target("idle", provider: .claude))))
        activity.observe("claude:topic"); time += 1; activity.tick(); activity.observe(nil)
        activity.ingest(target("idle", provider: .claude, turn: "second-stop").session!)
        XCTAssertEqual(unread, 0, "A Stop confirming an already announced idle poll must stay quiet")
    }

    func testEventBeatsSlowPollAndDirectTerminalVisitClearsUnreadButNotAttention() {
        var clock = Date(), requests = [(SessionUpdateMonitor.ResultType) -> Void]()
        var shown = Set<UUID>(), unread = -1, status: String?
        let activity = SessionActivityCoordinator(load: { _, done in requests.append(done) }, now: { clock })
        defer { activity.stop() }
        activity.onShow = { shown.insert($0.id) }; activity.onUnreadChange = { unread = $0 }
        activity.onSnapshot = { status = $0.context.targets.first?.session?.status; _ = $1 }
        activity.configure(settings()); requests[0](.success(snapshot(target("idle"))))
        clock.addTimeInterval(3); activity.refresh { _ in }
        clock.addTimeInterval(0.1); activity.ingest(target("waiting_input").session!)
        XCTAssertEqual(status, "waiting_input"); XCTAssertEqual(unread, 1)
        requests[1](.success(snapshot(target("idle"))))
        XCTAssertEqual(status, "waiting_input", "Older polling must not turn the live indicator green")
        XCTAssertEqual(shown.count, 1)
        activity.observe("codex:topic"); clock.addTimeInterval(1.1); activity.tick()
        XCTAssertEqual(unread, 0); XCTAssertEqual(status, "waiting_input")
    }

    func testMutingClearsCurrentAndQueuedAlertsWhileAcknowledgementUpdatesOverviewImmediately() {
        var clock = Date(), done: ((SessionUpdateMonitor.ResultType) -> Void)?
        var shown = Set<UUID>(), unread = -1, hides = 0, displayedFinished = Set<String>()
        let activity = SessionActivityCoordinator(load: { _, reply in done = reply }, now: { clock })
        defer { activity.stop() }
        activity.onShow = { shown.insert($0.id) }; activity.onUnreadChange = { unread = $0 }
        activity.onHide = { hides += 1 }; activity.onSnapshot = { _, finished in displayedFinished = finished }
        var preferences = settings()
        activity.configure(preferences); done?(.success(snapshot(target("active"))))
        activity.ingest(target("idle", turn: "first").session!)
        XCTAssertEqual(displayedFinished, ["codex:topic"])
        activity.observe("codex:topic"); clock.addTimeInterval(1.1); activity.tick()
        XCTAssertTrue(displayedFinished.isEmpty, "The overview must reflect acknowledgement without waiting for a poll")
        XCTAssertEqual(unread, 0)
        activity.observe(nil)
        activity.ingest(target("active").session!)
        activity.ingest(target("idle", turn: "second").session!)
        activity.ingest(target("waiting_input").session!)
        let beforeMute = shown.count, beforeHide = hides
        preferences.notifyAttention = false; preferences.notifyCompletion = false
        activity.configure(preferences)
        XCTAssertEqual(unread, 0); XCTAssertGreaterThan(hides, beforeHide)
        clock.addTimeInterval(10); activity.tick()
        XCTAssertEqual(shown.count, beforeMute, "Muted queued alerts must never reappear")
        preferences.notifyAttention = true; preferences.notifyCompletion = true
        activity.configure(preferences); activity.ingest(target("waiting_input").session!)
        XCTAssertEqual(shown.count, beforeMute, "Unchanged attention should not replay on unmute")
    }

    func testMutedCompletionStaysPurpleUntilViewedForOneSecond() throws {
        var clock = Date(), reply: ((SessionUpdateMonitor.ResultType) -> Void)?
        let activity = SessionActivityCoordinator(load: { _, done in reply = done }, now: { clock })
        defer { activity.stop() }
        var preferences = settings(); preferences.notifyCompletion = false
        activity.configure(preferences)
        reply?(.success(snapshot(target("active"))))
        let session = try XCTUnwrap(target("idle", turn: "new").session)
        activity.onShow = { _ in XCTFail("Completion alerts are muted") }
        activity.ingest(session)
        func indicator() throws -> NSColor? {
            let cell = SessionCell(session: session, recent: false, terminalOpen: true,
                                   unattended: activity.finished.contains(session.key))
            return try XCTUnwrap(cell.subviews.compactMap { $0 as? StatusDot }.first).color
        }
        XCTAssertEqual(try indicator(), .systemPurple)
        activity.observe(session.key)
        clock += 0.5; activity.tick(); activity.observe(nil)
        XCTAssertEqual(try indicator(), .systemPurple)
        activity.observe(session.key); clock += 1; activity.tick()
        XCTAssertEqual(try indicator(), .systemGreen)
    }

    func testProviderChangeAndStopRejectInFlightSnapshotsAndDisabledProviderEvents() {
        var clock = Date(), requests = [([Provider], (SessionUpdateMonitor.ResultType) -> Void)]()
        var received = [Provider](), remembered = [Provider](), shown = 0
        let activity = SessionActivityCoordinator(load: { requests.append(($0, $1)) },
            remember: { remembered.append($0.provider) }, now: { clock })
        defer { activity.stop() }
        activity.onSnapshot = { received += $0.context.targets.compactMap { $0.session?.provider }; _ = $1 }
        activity.onShow = { _ in shown += 1 }
        var preferences = settings(); activity.configure(preferences)
        preferences.enabledProviders = [.claude]; activity.configure(preferences)
        activity.ingest(target("waiting_input").session!)
        requests[0].1(.success(snapshot(target("waiting_input"))))
        XCTAssertTrue(received.isEmpty); XCTAssertTrue(remembered.isEmpty)
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].0, [.claude])
        requests[1].1(.success(snapshot(target("active", provider: .claude))))
        XCTAssertEqual(received, [.claude]); XCTAssertEqual(shown, 0)
        clock.addTimeInterval(3); activity.refresh { _ in }
        activity.stop()
        requests[2].1(.success(snapshot(target("idle", provider: .claude, turn: "late"))))
        activity.ingest(target("waiting_input", provider: .claude).session!)
        XCTAssertEqual(received, [.claude]); XCTAssertEqual(shown, 0)
        XCTAssertTrue(activity.targets.isEmpty); XCTAssertNil(activity.recentSnapshot)
    }
}
