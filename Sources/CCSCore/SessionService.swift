import Foundation

public final class SessionService {
    public let index: SessionIndex
    public let runner: CommandRunner
    public let codex: CodexProvider
    private let arguments: (Int32) -> [String]?
    public private(set) var issues = [Provider: String]()
    public private(set) var historyFailures = Set<Provider>()
    public init(index: SessionIndex = SessionIndex(), runner: @escaping CommandRunner = ProcessRunner().command,
                codex: CodexProvider = CodexProvider(), arguments: @escaping (Int32) -> [String]? = ProcessArguments.read) {
        self.index = index; self.runner = runner; self.codex = codex; self.arguments = arguments
    }

    public func liveSessions() -> [String: LiveSession]? {
        guard let result = try? runner("/usr/bin/env", ["claude", "agents", "--json"], nil, 15), result.code == 0,
              let records = try? JSONDecoder().decode([LiveSession].self, from: Data(result.out.utf8)),
              records.allSatisfy({ !$0.sessionId.isEmpty }) else { return nil }
        return Dictionary(records.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func collect(days: Int, provider: ProviderFilter = .claude, enabledProviders: [Provider] = Provider.allCases) throws -> [Session] {
        var sessions = [Session]()
        if provider.includes(.claude), enabledProviders.contains(.claude) {
            do {
                sessions += try collectClaude(days: days)
                if index.isComplete { historyFailures.remove(.claude) } else {
                    historyFailures.insert(.claude)
                    issues[.claude] = "Some Claude history is incomplete or unreadable. Check ~/.claude/projects, then refresh."
                }
            }
            catch {
                historyFailures.insert(.claude)
                issues[.claude] = "Claude history unavailable. Check access to ~/.claude/projects, then refresh."
                if provider == .claude { throw error }
            }
        }
        if provider.includes(.codex), enabledProviders.contains(.codex) {
            sessions += codex.collect(days: days)
            issues[.codex] = codex.issue
            if codex.historyAvailable { historyFailures.remove(.codex) } else { historyFailures.insert(.codex) }
        }
        return sessions.sorted { $0.mtime == $1.mtime ? $0.key < $1.key : $0.mtime > $1.mtime }
    }
    private func collectClaude(days: Int) throws -> [Session] {
        var sessions = try index.load(days: days)
        if let running = liveSessions() {
            issues[.claude] = nil
            for (id, live) in running {
                var s = sessions[id] ?? Session(id: id, cwd: live.cwd ?? "", mtime: (live.startedAt ?? 0) / 1000)
                s.live = live; s.status = cleanText(live.status).nonempty ?? "open"
                s.name = live.name?.nonempty ?? s.name
                sessions[id] = s
            }
        } else {
            issues[.claude] = "Claude live status unavailable; resume is disabled. Start clean or refresh."
            for id in Array(sessions.keys) { sessions[id]?.status = "unknown" }
        }
        return sessions.values.sorted { $0.mtime > $1.mtime }
    }

    public func activate(id: String, fresh: Bool = false, provider: ProviderFilter = .all, enabledProviders: [Provider] = Provider.allCases) throws {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let qualified = parts.count == 2 && Provider(rawValue: parts[0]) != nil ? ProviderFilter(rawValue: parts[0]) : nil
        let scope = qualified ?? provider
        let rawID = qualified == nil ? id : parts[1]
        let matches = try collect(days: 0, provider: scope, enabledProviders: qualified == nil ? enabledProviders : Provider.allCases).filter { $0.id == rawID }
        if scope == .codex && !codex.historyAvailable { throw CCSError.message(codex.issue ?? "Codex history unavailable.") }
        guard matches.count <= 1 else { throw CCSError.message("This ID exists in both providers. Use claude:ID or codex:ID.") }
        guard let s = matches.first else {
            throw CCSError.message("No session with id \(id).")
        }
        try activate(s, fresh: fresh)
    }
    public func activate(_ s: Session, fresh: Bool = false) throws {
        if s.provider == .codex { return try activateCodex(s, fresh: fresh) }
        if fresh { try openTerminal("cd \(shellQuote(s.cwd)) && claude"); return }
        // Always refresh at activation time. A stale screen must not authorize a duplicate resume.
        guard let running = liveSessions() else {
            throw CCSError.message("Cannot tell whether this session is still open (claude agents --json failed), so it was not resumed.")
        }
        if let live = running[s.id] {
            let ttys = (try? candidateTTYs(s, live: live)) ?? []
            if !ttys.isEmpty {
                let result = try runner("/usr/bin/osascript", ["-"] + ttys.map { "/dev/" + $0 }, Self.focusScript, 15)
                if result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" { return }
                if result.code != 0 { throw CCSError.message(result.err.nonempty ?? "Terminal automation failed. Allow CCS in System Settings → Privacy & Security → Automation.") }
            }
            if live.kind == "interactive" {
                throw CCSError.message("Window not found in Terminal.app (it may run in another terminal app).")
            }
            try openTerminal("claude attach \(shellQuote(live.name?.nonempty ?? s.id))")
        } else { try openTerminal("cd \(shellQuote(s.cwd)) && claude --resume \(shellQuote(s.id))") }
    }

    private func activateCodex(_ s: Session, fresh: Bool) throws {
        if fresh { try openTerminal("cd \(shellQuote(s.cwd)) && \(codex.launchCommand)"); return }
        let current = try codex.current(s.id)
        if let processes = try? runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5), processes.code == 0 {
            let ttys = CodexProvider.candidateTTYs(id: current.id, processList: processes.out, localSocketPath: codex.sharedSocketPath, arguments: arguments)
            if !ttys.isEmpty {
                let focus = try runner("/usr/bin/osascript", ["-"] + ttys.map { "/dev/" + $0 }, Self.focusScript, 15)
                if focus.code != 0 { throw CCSError.message(focus.err.nonempty ?? "Terminal automation failed.") }
                if focus.out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" { return }
            }
        }
        try openTerminal(codex.resumeCommand(current))
    }

    public func openTerminal(_ command: String) throws {
        let result = try runner("/usr/bin/osascript", ["-", command], Self.launchScript, 15)
        if result.code != 0 {
            throw CCSError.message(result.err.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Could not open Terminal.app. Allow CCS in System Settings → Privacy & Security → Automation.")
        }
    }
    public func candidateTTYs(_ s: Session, live: LiveSession) throws -> [String] {
        let result = try runner("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], nil, 5)
        guard result.code == 0 else { throw CCSError.message("Could not inspect Terminal processes.") }
        return Self.candidateTTYs(s, live: live, processList: result.out, arguments: arguments)
    }
    public static func candidateTTYs(_ s: Session, live: LiveSession, processList: String, arguments: ((Int32) -> [String]?)? = nil) -> [String] {
        var procs = [Int: (Int, String, String)](), viewers = [String]()
        let keys = Set([s.id, live.id, live.name].compactMap { $0 })
        for line in processList.split(separator: "\n") {
            let p = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard p.count >= 3, let pid = Int(p[0]), let parent = Int(p[1]) else { continue }
            let command = p.count == 4 ? String(p[3]) : ""
            procs[pid] = (parent, String(p[2]), command)
            if let arguments, let words = arguments(Int32(clamping: pid)) {
                if words.count >= 3, URL(fileURLWithPath: words[0]).lastPathComponent == "claude", words[1] == "attach", keys.contains(words[2]) { viewers.append(String(p[2])) }
            } else if arguments == nil, let range = command.range(of: #"(?:^|/)claude attach "#, options: .regularExpression) {
                let target = String(command[range.upperBound...])
                if keys.contains(target) || shellWords(target).first.map(keys.contains) == true { viewers.append(String(p[2])) }
            }
        }
        var pid = live.pid, seen = Set<Int>()
        while let current = pid, seen.insert(current).inserted, let p = procs[current] {
            viewers.append(p.1); pid = p.0
        }
        var unique = Set<String>()
        return viewers.filter { !$0.isEmpty && $0 != "??" && unique.insert($0).inserted }
    }
    public static let launchScript = """
    on run argv
      tell application "Terminal"
        do script (item 1 of argv)
        activate
      end tell
    end run
    """
    public static let focusScript = """
    on run argv
      tell application "Terminal"
        repeat with candidate in argv
          set wanted to contents of candidate
          repeat with w in windows
            try
              set wtabs to tabs of w
            on error
              set wtabs to {}
            end try
            repeat with t in wtabs
              if tty of t is wanted then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "missing"
    end run
    """
}

// Enough shell tokenization to compare the first attach argument exactly,
// including shell-quoted names. Never execute or evaluate the process text.
func shellWords(_ text: String) -> [String] {
    var words = [String](), word = "", quote: Character?, escaped = false
    for c in text {
        if escaped { word.append(c); escaped = false; continue }
        if c == "\\" && quote != "'" { escaped = true; continue }
        if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
        if c == "'" || c == "\"" { quote = c }
        else if c.isWhitespace { if !word.isEmpty { words.append(word); word = "" } }
        else { word.append(c) }
    }
    if quote != nil || escaped { return [] }
    if !word.isEmpty { words.append(word) }; return words
}
