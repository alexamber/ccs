import AppKit
import CCSCore

struct SessionUpdate {
    let id = UUID()
    enum Kind { case attention, finished }
    let target: TerminalSwitchTarget
    let kind: Kind
    var key: String { target.key }
    var message: String { kind == .finished ? "Finished working" : SessionActivity.description(for: target.session) }
}

struct SessionUpdateTracker {
    private var previous = [String: SessionActivity]()
    private var turns = [String: SessionActivityTurn]()
    private var inferredClaudeCompletions = Set<String>()
    private var attentionStatus = [String: String]()
    private var initialized = false
    private(set) var finished = Set<String>()
    private(set) var attention = Set<String>()
    var count: Int { attention.union(finished).count }

    mutating func acknowledge(_ key: String) { finished.remove(key) }
    mutating func update(_ snapshot: TerminalActivitySnapshot) -> [SessionUpdate] {
        var next = [String: SessionActivity](), updates = [SessionUpdate]()
        let targets = SessionActivity.sorted(snapshot.context.targets)
        let present = Set(targets.map(\.key))
        finished.formIntersection(present)
        turns = turns.filter { key, _ in
            present.contains(key) || snapshot.unavailableProviders.contains { key.hasPrefix($0.rawValue + ":") }
        }
        attention = []
        for target in targets {
            let oldAttention = attentionStatus[target.key]
            let activity = SessionActivity(status: target.session?.status ?? "unknown")
            if activity == .unknown {
                next[target.key] = previous[target.key]
                continue
            }
            let previousTurn = turns[target.key]
            let turn = target.session?.activityTurn
            if let turn { turns[target.key] = turn }
            let completed: Bool
            if target.session?.provider == .claude {
                if activity == .busy || activity == .attention { inferredClaudeCompletions.remove(target.key) }
                if let turn, turn.status == "completed" {
                    let alreadyReported = inferredClaudeCompletions.remove(target.key) != nil
                    completed = previous[target.key] != nil && previousTurn != turn && !alreadyReported
                } else {
                    completed = activity == .ready && previous[target.key] == .busy
                    if completed { inferredClaudeCompletions.insert(target.key) }
                }
            } else if let turn {
                completed = turn.status == "completed" &&
                    (previousTurn.map { $0 != turn } ?? (previous[target.key] == .busy))
            } else { completed = previous[target.key] == .busy }
            let reason = SessionActivity.attentionReason(target.session?.status)
            attentionStatus[target.key] = reason
            next[target.key] = activity
            if activity == .attention { attention.insert(target.key) }
            if activity != .ready { finished.remove(target.key) }
            guard initialized else { continue }
            if activity == .attention, previous[target.key] != .attention || oldAttention != reason {
                updates.append(SessionUpdate(target: target, kind: .attention))
            } else if activity == .ready, completed {
                finished.insert(target.key)
                updates.append(SessionUpdate(target: target, kind: .finished))
            }
        }
        // Missing status during a provider outage must not replay old alerts on recovery.
        for (key, value) in previous where snapshot.unavailableProviders.contains(where: { key.hasPrefix($0.rawValue + ":") }) && next[key] == nil {
            next[key] = value
        }
        inferredClaudeCompletions.formIntersection(next.keys)
        previous = next; initialized = true
        return updates
    }
}

/// One status read at a time. Manual opens share any in-flight read; idle
/// monitoring never enumerates history or report folders.
final class SessionUpdateMonitor {
    typealias ResultType = Result<TerminalActivitySnapshot, Error>
    private let load: (@escaping (ResultType) -> Void) -> Void
    private let receive: (TerminalActivitySnapshot) -> Void
    private let now: () -> Date
    private(set) var cached: (snapshot: TerminalActivitySnapshot, date: Date)?
    var recentSnapshot: TerminalActivitySnapshot? {
        guard let cached, now().timeIntervalSince(cached.date) < 60 else { return nil }
        return cached.snapshot
    }
    private var timer: Timer?, loading = false, generation = 0
    private var completions = [(ResultType) -> Void]()
    private var overrides = [String: (session: Session, date: Date)]()
    private(set) var enabled = false

    init(load: @escaping (@escaping (ResultType) -> Void) -> Void, receive: @escaping (TerminalActivitySnapshot) -> Void,
         now: @escaping () -> Date = Date.init) {
        self.load = load; self.receive = receive; self.now = now
    }
    deinit { timer?.invalidate() }
    func configure(enabled: Bool, reset: Bool = false) {
        guard enabled != self.enabled || reset else { return }
        generation += 1; self.enabled = enabled
        if reset { cached = nil; overrides = [:] }
        timer?.invalidate(); timer = nil
        let obsolete = completions; completions = []
        obsolete.forEach { $0(.failure(CCSError.message("Session settings changed. Open the list again."))) }
        guard enabled else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.5; self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    /// Event delivery updates known rows immediately without waiting for a full
    /// scan. Unmatched events request a fresh identity check; they are never
    /// replayed over a later authoritative snapshot.
    func ingest(_ session: Session) {
        guard enabled else { return }
        let stamp = now()
        overrides = overrides.filter { stamp.timeIntervalSince($0.value.date) < 60 }
        overrides[session.key] = (session, stamp)
        if let cached, let snapshot = replacing(session, in: cached.snapshot) {
            self.cached = (snapshot, stamp); receive(snapshot)
        } else {
            refresh()
        }
    }
    private func replacing(_ session: Session, in snapshot: TerminalActivitySnapshot) -> TerminalActivitySnapshot? {
        guard snapshot.context.targets.contains(where: { $0.key == session.key }) else { return nil }
        let targets = snapshot.context.targets.map { target -> TerminalSwitchTarget in
            guard target.key == session.key else { return target }
            return TerminalSwitchTarget(session: session, tab: target.tab, processID: target.processID)
        }
        return TerminalActivitySnapshot(context: TerminalSwitchContext(targets: targets, currentKey: snapshot.context.currentKey,
            keysByTTY: snapshot.context.keysByTTY), unavailableProviders: snapshot.unavailableProviders)
    }
    func refresh(completion: ((ResultType) -> Void)? = nil) {
        if let completion, !loading, let cached, now().timeIntervalSince(cached.date) < 2 {
            completion(.success(cached.snapshot)); return
        }
        if let completion { completions.append(completion) }
        guard !loading, enabled || !completions.isEmpty else { return }
        loading = true
        let revision = generation
        let started = now()
        load { [weak self] result in
            guard let self else { return }
            self.loading = false
            guard revision == self.generation else { self.refresh(); return }
            var delivered = result
            if case .success(let loaded) = result {
                let snapshot = self.reconcilePoll(loaded, started: started)
                self.cached = (snapshot, self.now()); self.receive(snapshot)
                delivered = .success(snapshot)
            }
            let callbacks = self.completions; self.completions = []
            callbacks.forEach { $0(delivered) }
        }
    }
    private func reconcilePoll(_ loaded: TerminalActivitySnapshot, started: Date) -> TerminalActivitySnapshot {
        overrides = overrides.filter { now().timeIntervalSince($0.value.date) < 60 }
        let previous = Dictionary((cached?.snapshot.context.targets ?? []).compactMap { target in
            target.session.map { (target.key, $0.status) }
        }, uniquingKeysWith: { first, _ in first })
        let targets = loaded.context.targets.map { target -> TerminalSwitchTarget in
            guard var session = target.session else { return target }
            if let event = overrides[target.key], event.date >= started {
                session = event.session
            } else if session.provider == .claude, session.status == "waiting", let status = previous[target.key],
                      ["waiting_input", "waiting_for_input", "waiting_for_approval"].contains(status) {
                // A generic poll does not change the reason for an ongoing Claude wait.
                session.status = status
            } else { return target }
            return TerminalSwitchTarget(session: session, tab: target.tab, processID: target.processID)
        }
        return TerminalActivitySnapshot(context: TerminalSwitchContext(targets: targets, currentKey: loaded.context.currentKey,
            keysByTTY: loaded.context.keysByTTY), unavailableProviders: loaded.unavailableProviders)
    }

}
