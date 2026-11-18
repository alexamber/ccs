import Foundation

public struct TerminalSwitchTarget {
    public let session: Session?
    public let tab: TerminalTabSnapshot
    public let processID: Int32?
    public var key: String { session?.key ?? "terminal:\(tab.tty):\(processID ?? 0)" }
    public var title: String { session?.terminalTitle ?? "Codex tab" }
    public var subtitle: String {
        session.map { $0.provider.title + " · " + shortPath($0.cwd) }
            ?? "Conversation unconfirmed · " + tab.tty.replacingOccurrences(of: "/dev/", with: "")
    }
    public init(session: Session?, tab: TerminalTabSnapshot, processID: Int32? = nil) {
        self.session = session; self.tab = tab; self.processID = processID
    }
}

public struct TerminalSwitchContext {
    public let targets: [TerminalSwitchTarget]
    public let currentKey: String?
    public let keysByTTY: [String: String]
    public init(targets: [TerminalSwitchTarget], currentKey: String?, keysByTTY: [String: String]? = nil) {
        self.targets = targets; self.currentKey = currentKey
        self.keysByTTY = keysByTTY ?? Dictionary(targets.map { ($0.tab.tty, $0.key) }, uniquingKeysWith: { first, _ in first })
    }
}

extension SessionService {
    /// Read only the origin for a cached chooser. The chosen target is still
    /// fully validated by focusTerminalTarget before any focus action.
    public func selectedTerminalTTY() throws -> String? {
        let result = try runner("/usr/bin/osascript", ["-"], Self.selectedTTYScript, 2)
        guard result.code == 0 else { throw CCSError.message("Couldn’t read the current Terminal tab.") }
        let tty = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty else { return nil }
        guard tty.hasPrefix("/dev/tty"), !tty.contains(where: \.isWhitespace) else {
            throw CCSError.message("Terminal returned an invalid tab identifier.")
        }
        return tty
    }

    public static let selectedTTYScript = """
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      if (count of windows) is 0 then return ""
      return tty of selected tab of front window
    end tell
    """

    public func terminalSwitchContext(sessions: [Session], includeUnconfirmedCodex: Bool = true, codexSocketPath: String? = nil) throws -> TerminalSwitchContext {
        try terminalSwitchContext(sessions: sessions, includeUnconfirmedCodex: includeUnconfirmedCodex, onlyTTY: nil, codexSocketPath: codexSocketPath)
    }

    private func terminalSwitchContext(sessions: [Session], includeUnconfirmedCodex: Bool, onlyTTY: String?, codexSocketPath: String? = nil) throws -> TerminalSwitchContext {
        let result = try runner("/usr/bin/osascript", ["-"], Self.switchTabsScript, 3)
        guard result.code == 0 else { throw CCSError.message("Couldn’t read Terminal tabs. Check CCS’s Terminal Automation permission.") }
        let parts = result.out.components(separatedBy: "\u{1e}")
        let currentTTY = parts.first ?? ""
        let live = sessions.filter(\.isLive)
        guard parts.count > 1 || result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CCSError.message("Terminal returned an incomplete tab list. Refresh and try again.")
        }
        guard parts.count > 1, !live.isEmpty || includeUnconfirmedCodex else {
            return TerminalSwitchContext(targets: [], currentKey: nil)
        }
        let processes = try runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5)
        guard processes.code == 0 else { throw CCSError.message("Couldn’t inspect running Terminal sessions.") }
        var targets = [TerminalSwitchTarget](), seen = Set<String>()
        var currentKey: String?, keysByTTY = [String: String]()
        for record in parts.dropFirst() {
            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count == 6, let tab = TerminalTabSnapshot(output: fields.joined(separator: "\n")) else {
                throw CCSError.message("Terminal returned an unreadable tab. Refresh and try again.")
            }
            guard onlyTTY == nil || tab.tty == onlyTTY else { continue }
            let session = terminalSession(tty: tab.tty, title: tab.title, sessions: live, processList: processes.out, codexSocketPath: codexSocketPath)
            let process = CodexProvider.terminalProcess(tty: String(tab.tty.dropFirst(5)), processList: processes.out, arguments: processArguments)
            guard session != nil || (includeUnconfirmedCodex && process != nil) else { continue }
            let target = TerminalSwitchTarget(session: session, tab: tab, processID: process?.pid)
            keysByTTY[tab.tty] = target.key
            if tab.tty == currentTTY { currentKey = target.key }
            if seen.insert(target.key).inserted { targets.append(target) }
        }
        return TerminalSwitchContext(targets: targets, currentKey: currentKey, keysByTTY: keysByTTY)
    }

    /// Switching only focuses an existing, freshly matched tab. It never resumes
    /// or launches a process if a session has ended since the switcher opened.
    public func focusTerminalTarget(_ target: TerminalSwitchTarget, sessions: [Session]) throws {
        var candidates = sessions
        if let session = target.session {
            if session.provider == .codex {
                let current = try codex.current(session.id)
                guard current.isLive else { throw CCSError.message("That Codex session is no longer active.") }
                candidates.removeAll { $0.key == current.key }; candidates.append(current)
            } else {
                guard let running = liveSessions(), let live = running[session.id] else {
                    throw CCSError.message("That Claude session is no longer active, or its status could not be checked.")
                }
                candidates = candidates.map { session in
                    var current = session
                    if current.provider == .claude { current.live = running[current.id] }
                    return current
                }
                if !candidates.contains(where: { $0.key == session.key }) {
                    var current = session; current.live = live; candidates.append(current)
                }
            }
        } else {
            // Focus a verified interactive client without assigning it a topic,
            // reading conversation history, or overwriting its native tab title.
            guard target.processID != nil else { throw CCSError.message("That Terminal tab could not be verified.") }
            candidates = []
        }
        let context = try terminalSwitchContext(sessions: candidates, includeUnconfirmedCodex: target.session == nil, onlyTTY: target.tab.tty)
        guard let verified = context.targets.first(where: {
            $0.tab.tty == target.tab.tty && $0.key == target.key &&
                (target.processID == nil || $0.processID == target.processID)
        }) else {
            throw CCSError.message("That Terminal tab changed or is no longer available. Open the switcher again.")
        }
        let result = try runner("/usr/bin/osascript", ["-", verified.session?.terminalTitle ?? "", target.tab.tty], Self.focusScript, 5)
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
