import Foundation
import CoreGraphics

/// Terminal's bounds use global screen coordinates with the origin at the top left.
public struct TerminalTabSnapshot: Equatable {
    public let tty: String
    public let bounds: CGRect
    public let title: String
    /// Ignore the provider's activity spinner when detecting a topic change.
    public var matchingTitle: String { CodexProvider.normalizedTerminalTitle(title) }

    public init?(output: String) {
        let lines = output.split(maxSplits: 5, whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 5, lines[0].hasPrefix("/dev/tty") else { return nil }
        let edges = lines[1...4].compactMap(Double.init)
        guard edges.count == 4, edges.allSatisfy(\.isFinite),
              edges[2] > edges[0], edges[3] > edges[1] else { return nil }
        tty = lines[0]
        title = lines.count == 6 ? cleanText(lines[5]) : ""
        bounds = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
    }

    public static func read(runner: CommandRunner = ProcessRunner().command) -> TerminalTabSnapshot? {
        guard let result = try? runner("/usr/bin/osascript", ["-"], script, 2), result.code == 0 else { return nil }
        return TerminalTabSnapshot(output: result.out)
    }

    // Never launch or activate Terminal. An app switch between the native
    // frontmost check and this Apple event must not produce a popup.
    public static let script = """
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      if not frontmost then return ""
      if (count of windows) is 0 then return ""
      set w to front window
      set device to tty of selected tab of w
      set edges to bounds of w
      return device & linefeed & (item 1 of edges as text) & linefeed & (item 2 of edges as text) & linefeed & (item 3 of edges as text) & linefeed & (item 4 of edges as text) & linefeed & (custom title of selected tab of w)
    end tell
    """
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
    func terminalSession(tty: String, title: String, sessions: [Session], processList: String? = nil) -> Session? {
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
        for session in sessions {
            let candidates: [String]
            if session.provider == .codex {
                candidates = CodexProvider.candidateTTYs(id: session.id, processList: codexProcesses,
                                                       localSocketPath: codex.sharedSocketPath, arguments: arguments)
            } else if let live = session.live {
                candidates = Self.candidateTTYs(session, live: live, processList: listing, arguments: arguments)
            } else { continue }
            if candidates.contains(device) { matches.append(session) }
            if matches.count > 1 { return nil }
        }
        if let match = matches.first { return match }
        // A bare `codex` has no thread ID in argv. Require a local interactive
        // process, its folder, and a unique live title match. This supports
        // labels and focus-only switching, never launching or resuming a process.
        guard !title.isEmpty,
              let process = CodexProvider.untargetedTerminalProcess(tty: device, processList: codexProcesses,
                  localSocketPath: codex.sharedSocketPath, arguments: arguments),
              let cwdResult = try? runner("/usr/sbin/lsof", ["-a", "-p", String(process.pid), "-d", "cwd", "-Fn"], nil, 3), cwdResult.code == 0 else { return nil }
        let paths = cwdResult.out.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        guard paths.count == 1 else { return nil }
        let cwd = process.directory.map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: paths[0], isDirectory: true)).standardizedFileURL.path
        } ?? paths[0]
        let directory = physicalPath(cwd)
        let candidates = sessions.filter {
            $0.provider == .codex && $0.isLive && physicalPath($0.cwd) == directory &&
                CodexProvider.terminalTitle(title, matches: $0.title)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
