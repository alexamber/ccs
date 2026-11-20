import Foundation
import CoreGraphics

/// Terminal's bounds use global screen coordinates with the origin at the top left.
public struct TerminalTabSnapshot: Equatable {
    public let terminalID: String
    public let paneID: String
    public let tty: String
    public let bounds: CGRect
    public let title: String
    /// Ignore the provider's activity spinner when detecting a topic change.
    public var matchingTitle: String { CodexProvider.normalizedTerminalTitle(title) }

    public init(terminalID: String, paneID: String, tty: String, bounds: CGRect, title: String) {
        self.terminalID = terminalID
        self.paneID = paneID
        self.tty = tty
        self.bounds = bounds
        self.title = title
    }
}

extension SessionService {
    /// Resolve only an unambiguous match. In particular, shared ancestor TTYs
    /// must not label a tab with an arbitrarily chosen background conversation.
    public func session(inTerminalTTY tty: String, sessions: [Session]) -> Session? {
        terminalSession(tty: tty, title: "", sessions: sessions)
    }
    public func session(inTerminalTab tab: TerminalTabSnapshot, sessions: [Session]) -> Session? {
        terminalSession(tty: tab.tty, title: tab.title, sessions: sessions)
    }
    func terminalSession(tty: String, title: String, sessions: [Session], processList: String? = nil, codexSocketPath: String? = nil) -> Session? {
        // A switcher enumeration shares one process snapshot across all tabs.
        let listing: String
        if let processList { listing = processList }
        else {
            guard let processes = try? runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5), processes.code == 0 else { return nil }
            listing = processes.out
        }
        guard tty.hasPrefix("/dev/tty") else { return nil }
        let device = String(tty.dropFirst(5))
        // Codex matches only the requested device. Avoid reading argv for every
        // unrelated process once for each saved conversation in a large history.
        let codexProcesses = listing.split(separator: "\n").filter {
            let columns = $0.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            return columns.count == 4 && columns[2] == device
        }.joined(separator: "\n")
        var matches = [Session]()
        // Read argv at most once per PID, even with many saved Codex sessions.
        var argv = [Int32: [String]](), missing = Set<Int32>()
        let arguments: (Int32) -> [String]? = { pid in
            if let words = argv[pid] { return words }
            if missing.contains(pid) { return nil }
            if let words = self.processArguments(pid) { argv[pid] = words; return words }
            missing.insert(pid); return nil
        }
        for session in sessions where session.provider == .claude {
            guard let live = session.live else { continue }
            if Self.candidateTTYs(session, live: live, processList: listing, arguments: arguments).contains(device) {
                matches.append(session)
            }
        }
        let process = CodexProvider.terminalProcess(tty: device, processList: codexProcesses, arguments: arguments)
        if !matches.isEmpty { return matches.count == 1 && process == nil ? matches[0] : nil }
        // Every Codex label needs a unique live topic + folder match. A resume
        // argument alone must not label or activate a conversation changed in-app.
        let topics = sessions.filter {
            $0.provider == .codex && $0.isLive && CodexProvider.terminalTitle(title, matches: $0.title)
        }
        // Generic tab focus requires no folder inspection or metadata lookup.
        guard !topics.isEmpty, let process, process.canMatchSession(localSocketPath: codexSocketPath ?? codex.sharedSocketPath),
              let cwdResult = try? runner("/usr/sbin/lsof", ["-a", "-p", String(process.pid), "-d", "cwd", "-Fn"], nil, 3), cwdResult.code == 0 else { return nil }
        let paths = cwdResult.out.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        guard paths.count == 1 else { return nil }
        let cwd = process.directory.map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: paths[0], isDirectory: true)).standardizedFileURL.path
        } ?? paths[0]
        let directory = physicalPath(cwd)
        let candidates = topics.filter { physicalPath($0.cwd) == directory }
        guard candidates.count == 1 else { return nil }
        let candidate = candidates[0]
        if let launchID = process.launchSessionID, launchID != candidate.id { return nil }
        return candidate
    }
}
