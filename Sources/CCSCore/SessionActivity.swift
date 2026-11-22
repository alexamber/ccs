import Foundation

public struct SessionActivityTurn: Equatable {
    public let id: String
    public let status: String
    public init(id: String, status: String) { self.id = id; self.status = status }
}

public enum SessionActivity: Int, CaseIterable {
    case attention, busy, ready, unknown

    public init(status: String) {
        switch status.lowercased() {
        case "waiting", "waiting_input", "waiting_for_input", "waiting_for_approval", "needs_attention", "error": self = .attention
        case "active", "busy", "working", "running": self = .busy
        case "idle", "ready": self = .ready
        default: self = .unknown
        }
    }
    public var title: String {
        switch self {
        case .attention: return "Needs attention"
        case .busy: return "Working"
        case .ready: return "Ready"
        case .unknown: return "Status unavailable"
        }
    }
    /// Hooks can report a more precise spelling than a provider's status poll.
    /// Treat equivalent waits as the same event, rather than replaying or clearing it.
    public static func attentionReason(_ status: String?) -> String? {
        guard let status, SessionActivity(status: status) == .attention else { return nil }
        switch status.lowercased() {
        case "waiting_input", "waiting_for_input": return "input"
        case "error": return "error"
        default: return "waiting"
        }
    }
    public static func description(for session: Session?) -> String {
        guard let session else { return "Status unavailable" }
        switch session.status {
        case "waiting": return session.provider == .codex ? "Waiting for approval" : "Waiting for you"
        case "waiting_input", "waiting_for_input": return "Waiting for input"
        case "waiting_for_approval": return "Waiting for approval"
        case "error": return "Reported an error"
        default: return SessionActivity(status: session.status).title
        }
    }
    public static func sorted(_ targets: [TerminalSwitchTarget], finished: Set<String> = [], drafts: Set<String> = []) -> [TerminalSwitchTarget] {
        func priority(_ target: TerminalSwitchTarget) -> Int {
            let activity = SessionActivity(status: target.session?.status ?? "unknown")
            if activity == .attention || finished.contains(target.key) { return 0 }
            if drafts.contains(target.key) { return 1 }
            return activity.rawValue + 1
        }
        return targets.sorted {
            let a = priority($0), b = priority($1)
            if a != b { return a < b }
            let x = $0.session?.mtime ?? 0, y = $1.session?.mtime ?? 0
            return x == y ? $0.key < $1.key : x > y
        }
    }
}

public struct TerminalActivitySnapshot {
    public let context: TerminalSwitchContext
    public let unavailableProviders: [Provider]
    public init(context: TerminalSwitchContext, unavailableProviders: [Provider] = []) {
        self.context = context; self.unavailableProviders = unavailableProviders
    }
}

extension SessionService {
    /// Status-only polling: no transcript enumeration, artifact scans, or new conversations.
    public func terminalActivity(known: [Session], enabledProviders: [Provider]) throws -> TerminalActivitySnapshot {
        var sessions = [Session](), unavailable = [Provider]()
        if enabledProviders.contains(.claude) {
            if let running = liveSessions() {
                let names = Dictionary(known.filter { $0.provider == .claude }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for (id, live) in running {
                    var session = names[id] ?? Session(id: id, cwd: live.cwd ?? "", mtime: (live.startedAt ?? 0) / 1000, title: live.name ?? "")
                    session.live = live; session.status = cleanText(live.status).nonempty ?? "unknown"
                    // Claude's live list has no turn identity. A remembered Stop belongs to its hook.
                    session.activityTurn = nil
                    sessions.append(session)
                }
            } else { unavailable.append(.claude) }
        }
        if enabledProviders.contains(.codex) {
            do { sessions += try codex.loadedSessions() }
            catch { unavailable.append(.codex) }
        }
        // A failed provider stays explicitly unknown; live process/TTY checks still
        // decide whether its previously known Terminal rows can be retained.
        sessions += known.filter { unavailable.contains($0.provider) }.map {
            var session = $0; session.status = "unknown"; return session
        }
        let context = try terminalSwitchContext(sessions: sessions, includeUnconfirmedCodex: enabledProviders.contains(.codex))
        return TerminalActivitySnapshot(context: context, unavailableProviders: unavailable)
    }
}
