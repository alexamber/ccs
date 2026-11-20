import Foundation
import CCSCore

/// Main-thread owner of activity delivery and notification policy. Muting alerts
/// never stops status reads or resets the transition baseline.
final class SessionActivityCoordinator {
    typealias Load = ([Provider], @escaping (SessionUpdateMonitor.ResultType) -> Void) -> Void
    private let load: Load
    private let remember: (Session) -> Void
    private let now: () -> Date
    private var settings = Settings()
    private var tracker = SessionUpdateTracker()
    private let notices: SessionNotificationQueue
    private var timer: Timer?
    private lazy var monitor = SessionUpdateMonitor(load: { [weak self] done in
        guard let self else { return }
        self.load(self.settings.enabledProviders, done)
    }, receive: { [weak self] in self?.receive($0) }, now: now)

    var onSnapshot: ((TerminalActivitySnapshot, Set<String>) -> Void)?
    var onShow: ((SessionUpdate) -> Void)?, onHide: (() -> Void)?
    var onUnreadChange: ((Int) -> Void)?
    var canPresent: () -> Bool = { true }
    var hovered: Bool { get { notices.hovered } set { notices.hovered = newValue } }
    var recentSnapshot: TerminalActivitySnapshot? { monitor.recentSnapshot }
    var targets: [TerminalSwitchTarget] { monitor.cached?.snapshot.context.targets ?? [] }
    var finished: Set<String> { tracker.finished }

    init(load: @escaping Load, remember: @escaping (Session) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.load = load; self.remember = remember; self.now = now
        notices = SessionNotificationQueue(now: now)
        notices.hasUnattendedCompletion = { [weak self] in self?.tracker.finished.contains($0) == true }
        notices.canPresent = { [weak self] in self?.canPresent() == true }
        notices.onShow = { [weak self] in self?.onShow?($0) }
        notices.onHide = { [weak self] in self?.onHide?() }
        notices.onChange = { [weak self] in self?.updatePresentation() }
        notices.onViewed = { [weak self] key in
            guard let self else { return }
            self.tracker.acknowledge(key)
            if let snapshot = self.monitor.cached?.snapshot { self.onSnapshot?(snapshot, self.tracker.finished) }
        }
    }
    deinit { timer?.invalidate() }

    func configure(_ value: Settings) {
        let reset = settings.enabledProviders != value.enabledProviders || settings.terminalPopups != value.terminalPopups
        settings = value
        if reset { tracker = SessionUpdateTracker(); notices.reset() }
        monitor.configure(enabled: value.terminalPopups, reset: reset)
        if let snapshot = monitor.cached?.snapshot {
            notices.reconcile(snapshot, attention: value.notifyAttention, completion: value.notifyCompletion)
        }
        updatePresentation()
    }
    func stop() {
        var disabled = settings; disabled.terminalPopups = false
        configure(disabled)
    }
    func ingest(_ session: Session) {
        guard settings.terminalPopups, settings.enabledProviders.contains(session.provider) else { return }
        remember(session)
        monitor.ingest(session)
    }
    func observe(_ key: String?) { notices.observe(key) }
    func refresh(force: Bool = false, completion: @escaping (SessionUpdateMonitor.ResultType) -> Void) {
        monitor.refresh(force: force, completion: completion)
    }
    func tick() { notices.tick() }

    private func receive(_ snapshot: TerminalActivitySnapshot) {
        let updates = tracker.update(snapshot)
        for update in updates where update.kind == .finished { notices.completionArrived(for: update.key) }
        let alerts = updates.filter {
            settings.terminalPopups && ($0.kind == .attention ? settings.notifyAttention : settings.notifyCompletion)
        }
        notices.reconcile(snapshot, attention: settings.notifyAttention, completion: settings.notifyCompletion)
        notices.enqueue(alerts)
        onSnapshot?(snapshot, tracker.finished)
    }
    private func updatePresentation() {
        onUnreadChange?(notices.unreadCount)
        if notices.needsTick && settings.terminalPopups {
            if timer == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
                timer.tolerance = 0.02; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        } else { timer?.invalidate(); timer = nil }
    }
}
