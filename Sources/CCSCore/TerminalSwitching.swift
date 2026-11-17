import Foundation

public struct TerminalSwitchTarget {
    public let session: Session
    public let tab: TerminalTabSnapshot
    public init(session: Session, tab: TerminalTabSnapshot) { self.session = session; self.tab = tab }
}

public struct TerminalSwitchContext {
    public let targets: [TerminalSwitchTarget]
    public let currentKey: String?
    public init(targets: [TerminalSwitchTarget], currentKey: String?) { self.targets = targets; self.currentKey = currentKey }
}

extension SessionService {
    public func terminalSwitchContext(sessions: [Session]) throws -> TerminalSwitchContext {
        try terminalSwitchContext(sessions: sessions, onlyTTY: nil)
    }

    private func terminalSwitchContext(sessions: [Session], onlyTTY: String?) throws -> TerminalSwitchContext {
        let result = try runner("/usr/bin/osascript", ["-"], Self.switchTabsScript, 3)
        guard result.code == 0 else { throw CCSError.message("Couldn’t read Terminal tabs. Check CCS’s Terminal Automation permission.") }
        let parts = result.out.components(separatedBy: "\u{1e}")
        let currentTTY = parts.first ?? ""
        let live = sessions.filter(\.isLive)
        guard !live.isEmpty else { return TerminalSwitchContext(targets: [], currentKey: nil) }
        let processes = try runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5)
        guard processes.code == 0 else { throw CCSError.message("Couldn’t inspect running Terminal sessions.") }
        var targets = [TerminalSwitchTarget](), seen = Set<String>()
        var currentKey: String?
        for record in parts.dropFirst() {
            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count == 6, let tab = TerminalTabSnapshot(output: fields.joined(separator: "\n")),
                  onlyTTY == nil || tab.tty == onlyTTY,
                  let session = terminalSession(tty: tab.tty, title: tab.title, sessions: live, processList: processes.out) else { continue }
            if tab.tty == currentTTY { currentKey = session.key }
            if seen.insert(session.key).inserted { targets.append(TerminalSwitchTarget(session: session, tab: tab)) }
        }
        return TerminalSwitchContext(targets: targets, currentKey: currentKey)
    }

    /// Switching only focuses an existing, freshly matched tab. It never resumes
    /// or launches a process if a session has ended since the switcher opened.
    public func focusTerminalTarget(_ target: TerminalSwitchTarget, sessions: [Session]) throws {
        var candidates = sessions
        if target.session.provider == .codex {
            // The action lane owns a separate provider from history. Initialize
            // its connection so local --remote clients can be recognized too.
            let current = try codex.current(target.session.id)
            guard current.isLive else { throw CCSError.message("That Codex session is no longer active.") }
            candidates.removeAll { $0.key == current.key }; candidates.append(current)
        } else {
            guard let running = liveSessions(), let live = running[target.session.id] else {
                throw CCSError.message("That Claude session is no longer active, or its status could not be checked.")
            }
            candidates = candidates.map { session in
                var current = session
                if current.provider == .claude { current.live = running[current.id] }
                return current
            }
            // Use freshly read PIDs, never a cached process identity.
            if !candidates.contains(where: { $0.key == target.session.key }) {
                var current = target.session; current.live = live; candidates.append(current)
            }
        }
        let context = try terminalSwitchContext(sessions: candidates, onlyTTY: target.tab.tty)
        guard let verified = context.targets.first(where: { $0.session.key == target.session.key && $0.tab.tty == target.tab.tty }) else {
            throw CCSError.message("That session’s Terminal tab is no longer available.")
        }
        let result = try runner("/usr/bin/osascript", ["-", verified.session.terminalTitle, target.tab.tty], Self.focusScript, 5)
        guard result.code == 0, result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw CCSError.message("Couldn’t focus that Terminal tab.")
        }
    }

    public static let switchTabsScript = """
    if application "Terminal" is not running then return ""
    set fs to ASCII character 31
    set rs to ASCII character 30
    tell application "Terminal"
      set output to ""
      if (count of windows) is 0 then return ""
      set output to tty of selected tab of front window
      repeat with w in windows
        set edges to bounds of w
        repeat with t in tabs of w
          set output to output & rs & tty of t & fs & (item 1 of edges as text) & fs & (item 2 of edges as text) & fs & (item 3 of edges as text) & fs & (item 4 of edges as text) & fs & custom title of t
        end repeat
      end repeat
      return output
    end tell
    """
}
