import Foundation

public struct TerminalSwitchTarget {
    public let session: Session?
    public let tab: TerminalTabSnapshot
    public let processID: Int32?
    public var key: String { session?.key ?? "terminal:\(tab.terminalID):\(tab.paneID):\(processID ?? 0)" }
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
    public func selectedTerminalTTY(in terminalID: String) throws -> String? {
        try terminals.adapter(for: terminalID).selectedTTY()
    }

    public func selectedTerminalTTY() throws -> String? {
        try selectedTerminalTTY(in: AppleTerminalAdapter.id)
    }

    public static let selectedTTYScript = AppleTerminalAdapter.selectedTTYScript

    public func terminalSwitchContext(sessions: [Session], includeUnconfirmedCodex: Bool = true, codexSocketPath: String? = nil,
                                      originTerminalID: String? = nil) throws -> TerminalSwitchContext {
        try terminalSwitchContext(sessions: sessions, includeUnconfirmedCodex: includeUnconfirmedCodex, onlyTab: nil,
                                  codexSocketPath: codexSocketPath, originTerminalID: originTerminalID)
    }

    private func terminalSwitchContext(sessions: [Session], includeUnconfirmedCodex: Bool, onlyTab: TerminalTabSnapshot?,
                                       codexSocketPath: String? = nil, originTerminalID: String? = nil) throws -> TerminalSwitchContext {
        let adapters: [any TerminalAdapter]
        if let onlyTab {
            adapters = [try terminals.adapter(for: onlyTab.terminalID)]
        } else {
            adapters = terminals.installed
        }
        var tabs = [TerminalTabSnapshot](), currentTTY: String?
        for adapter in adapters {
            let inventory = try adapter.tabs()
            tabs += inventory.tabs
            if adapter.bundleID == originTerminalID || (originTerminalID == nil && adapters.count == 1) {
                currentTTY = inventory.selectedTTY
            }
        }
        let live = sessions.filter(\.isLive)
        guard !tabs.isEmpty, !live.isEmpty || includeUnconfirmedCodex else {
            return TerminalSwitchContext(targets: [], currentKey: nil)
        }
        let processes = try runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5)
        guard processes.code == 0 else { throw CCSError.message("Couldn’t inspect running Terminal sessions.") }
        var targets = [TerminalSwitchTarget](), seen = Set<String>()
        var currentKey: String?, keysByTTY = [String: String]()
        for tab in tabs {
            if let onlyTab, tab.paneID != onlyTab.paneID || tab.tty != onlyTab.tty { continue }
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
        let context = try terminalSwitchContext(sessions: candidates, includeUnconfirmedCodex: target.session == nil, onlyTab: target.tab)
        guard let verified = context.targets.first(where: {
            $0.tab.tty == target.tab.tty && $0.key == target.key &&
                (target.processID == nil || $0.processID == target.processID)
        }) else {
            throw CCSError.message("That Terminal tab changed or is no longer available. Open the switcher again.")
        }
        try terminals.focus(verified.tab, title: verified.session?.terminalTitle ?? "")
    }

    public static let switchTabsScript = AppleTerminalAdapter.switchTabsScript
}
