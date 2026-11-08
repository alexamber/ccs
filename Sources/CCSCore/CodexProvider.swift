import Foundation

public final class CodexProvider {
    public let environment: [String: String]
    private let home: URL
    private let enabled: Bool
    private var connection: CodexConnection?
    private let connector: (() throws -> CodexConnection)?
    private var socketPath: String?
    var sharedSocketPath: String? { socketPath }
    private var lastSharedProbe = Date.distantPast
    public private(set) var issue: String?
    public private(set) var historyAvailable = true
    public var hasSavedData: Bool { enabled && FileManager.default.fileExists(atPath: home.path) }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, enabled: Bool = true) {
        self.environment = environment; self.enabled = enabled; connector = nil
        home = Self.dataDirectory(environment)
    }
    init(environment: [String: String] = ProcessInfo.processInfo.environment, connector: @escaping () throws -> CodexConnection) {
        self.environment = environment; enabled = true; self.connector = connector
        home = Self.dataDirectory(environment)
    }
    private static func dataDirectory(_ env: [String: String]) -> URL {
        let userHome = env["HOME"] ?? CCSPaths.home
        var path = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
        if path == "~" { path = userHome }
        else if path.hasPrefix("~/") { path = userHome + path.dropFirst() }
        return URL(fileURLWithPath: path)
    }
    private func client() throws -> CodexConnection {
        if let connection { return connection }
        lastSharedProbe = Date()
        if let connector { let value = try connector(); connection = value; return value }
        var path = home.appendingPathComponent("app-server-control/app-server-control.sock").path
        if !FileManager.default.fileExists(atPath: path),
           let result = try? ProcessRunner(environment: environment).run("/usr/bin/env", ["codex", "app-server", "daemon", "version"], timeout: 3), result.code == 0,
           let version = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
           version["status"] as? String == "running", let actual = version["socketPath"] as? String, actual.hasPrefix("/") { path = actual }
        if FileManager.default.fileExists(atPath: path), let shared = try? CodexRPCConnection.shared(socketPath: path) {
            socketPath = path; connection = shared; return shared
        }
        socketPath = nil
        let metadata = try CodexRPCConnection.metadataProcess(environment: environment)
        connection = metadata; return metadata
    }
    private func invalidate() { connection?.close(); connection = nil; socketPath = nil }
    deinit { invalidate() }

    public func collect(days: Int = 0) -> [Session] {
        guard enabled, hasSavedData || connector != nil else { issue = nil; return [] }
        do {
            // Retry discovery when a metadata-only client may have been superseded
            // by the daemon started by the user's CLI.
            let defaultSocket = home.appendingPathComponent("app-server-control/app-server-control.sock").path
            if connection?.isShared == false,
               FileManager.default.fileExists(atPath: defaultSocket) || Date().timeIntervalSince(lastSharedProbe) >= 30 { invalidate() }
            let client = try client()
            let records = try list(client, archived: false, allSources: false)
            let cutoff = days == 0 ? 0 : Date().timeIntervalSince1970 - Double(days) * 86400
            let parsed = try records.map { try Self.session($0, authoritative: client.isShared) }
            let sessions = Dictionary(parsed.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.mtime >= b.mtime ? a : b }).values
            historyAvailable = true
            issue = client.isShared ? nil : "Codex live status unavailable; Enter opens saved history through Codex."
            return sessions.filter { $0.isLive || $0.mtime >= cutoff }.sorted { $0.mtime == $1.mtime ? $0.key < $1.key : $0.mtime > $1.mtime }
        } catch {
            invalidate(); historyAvailable = false; issue = "Codex history unavailable. Check that Codex is installed, then refresh."
            return []
        }
    }
    /// Cleanup includes archived chats and subagents, even though the picker hides them.
    public func savedWorkingDirectories() throws -> Set<String> {
        guard enabled, hasSavedData || connector != nil else { return [] }
        do {
            let client = try client()
            var paths = Set<String>()
            for archived in [false, true] {
                for record in try list(client, archived: archived, allSources: true) {
                    let session = try Self.session(record, authoritative: client.isShared)
                    paths.insert(session.cwd)
                }
            }
            return paths
        } catch { invalidate(); throw error }
    }
    func current(_ id: String) throws -> Session {
        do {
            let client = try client()
            let result = try client.request("thread/read", ["threadId": id, "includeTurns": false])
            guard let thread = result["thread"] as? [String: Any] else { throw CCSError.message("Codex returned an invalid conversation.") }
            let session = try Self.session(thread, authoritative: client.isShared)
            guard session.id == id else { throw CCSError.message("Codex returned a different conversation; nothing was opened.") }
            return session
        } catch { invalidate(); throw error }
    }
    func resumeCommand(_ session: Session) -> String {
        let remote = socketPath.map { " --remote " + shellQuote("unix://" + $0) } ?? ""
        return "codex\(remote) --cd \(shellQuote(session.cwd)) resume \(shellQuote(session.id))"
    }
    private func list(_ client: CodexConnection, archived: Bool, allSources: Bool) throws -> [[String: Any]] {
        let sources = allSources ? ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"] : ["cli", "vscode", "appServer", "unknown"]
        var records = [[String: Any]](), cursor: String?, seen = Set<String>()
        let deadline = Date().addingTimeInterval(30)
        repeat {
            guard Date() < deadline, records.count < 100_000 else { throw CCSError.message("Codex history listing did not complete; folders were kept.") }
            var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "archived": archived, "sourceKinds": sources, "modelProviders": [String]()]
            if let cursor { params["cursor"] = cursor }
            let result = try client.request("thread/list", params)
            guard let page = result["data"] as? [[String: Any]] else { throw CCSError.message("Codex returned an invalid history list.") }
            records += page
            if let next = result["nextCursor"], !(next is NSNull) {
                guard let next = next as? String, !next.isEmpty, seen.insert(next).inserted else { throw CCSError.message("Codex returned an invalid history cursor.") }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return records
    }
    static func session(_ record: [String: Any], authoritative: Bool) throws -> Session {
        guard let id = record["id"] as? String, !id.isEmpty,
              let cwd = record["cwd"] as? String, cwd.hasPrefix("/"),
              let stamp = record["updatedAt"] as? NSNumber, CFGetTypeID(stamp) != CFBooleanGetTypeID(), stamp.doubleValue.isFinite,
              stamp.doubleValue >= 0, stamp.doubleValue < Double(Int.max),
              let runtime = record["status"] as? [String: Any], let type = runtime["type"] as? String,
              ["notLoaded", "idle", "active", "systemError"].contains(type),
              let preview = record["preview"] as? String else { throw CCSError.message("Codex returned incomplete conversation metadata.") }
        let opening = String(cleanText(preview).prefix(4000))
        let title = cleanText(record["name"]).nonempty ?? String(opening.prefix(300))
        var session = Session(id: id, cwd: cwd, mtime: stamp.doubleValue, title: title, prompts: opening, provider: .codex)
        if authoritative {
            switch type {
            case "idle": session.status = "idle"
            case "active": session.status = (runtime["activeFlags"] as? [String] ?? []).contains("waitingOnApproval") ? "waiting" : "active"
            case "systemError": session.status = "error"
            default: session.status = "saved"
            }
        } else { session.status = "unknown" }
        return session
    }
    static func candidateTTYs(id: String, processList: String, localSocketPath: String? = nil) -> [String] {
        var result = [String](), seen = Set<String>()
        let valuedOptions = Set(["-C", "--cd", "-c", "--config", "--remote", "--remote-auth-token-env", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir"])
        for line in processList.split(separator: "\n") {
            let columns = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard columns.count == 4, columns[2] != "??" else { continue }
            let words = shellWords(String(columns[3]))
            guard let first = words.first, URL(fileURLWithPath: first).lastPathComponent == "codex" else { continue }
            var remote = words.first(where: { $0.hasPrefix("--remote=") }).map { String($0.dropFirst(9)) }
            if let flag = words.firstIndex(of: "--remote"), flag + 1 < words.count { remote = words[flag + 1] }
            if let remote {
                guard let localSocketPath, remote == "unix://" || remote == "unix://" + localSocketPath else { continue }
            }
            var index = 1, resume = false
            while index < words.count {
                let word = words[index]
                if valuedOptions.contains(word) { index += 2; continue }
                if word.hasPrefix("-") { index += 1; continue }
                if !resume {
                    guard word == "resume" else { break }
                    resume = true; index += 1; continue
                }
                if word == id, seen.insert(String(columns[2])).inserted { result.append(String(columns[2])) }
                break
            }
        }
        return result
    }
}
