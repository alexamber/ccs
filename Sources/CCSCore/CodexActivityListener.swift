import Foundation

/// A separate, read-only connection observes daemon-wide status broadcasts.
/// It never resumes a thread, subscribes as its owner, or handles approvals.
public final class CodexActivityListener {
    private let lock = NSLock()
    private var revision = 0
    private let queue = DispatchQueue(label: "io.github.alexamber.ccs.codex-events", qos: .utility)
    public init() {}
    public func stop() { lock.lock(); revision += 1; lock.unlock() }
    private func valid(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return revision == value }
    public func start(environment: [String: String], receive: @escaping (Session) -> Void) {
        stop(); lock.lock(); let value = revision; lock.unlock()
        let home = CodexProvider.dataDirectory(environment)
        connect(home: home, environment: environment, revision: value, receive: receive)
    }
    private func connect(home: URL, environment: [String: String], revision: Int, receive: @escaping (Session) -> Void) {
        queue.async { [weak self] in
            guard let self, self.valid(revision) else { return }
            do {
                var path = home.appendingPathComponent("app-server-control/app-server-control.sock").path
                if !FileManager.default.fileExists(atPath: path),
                   let result = try? ProcessRunner(environment: environment).run("/usr/bin/env", ["codex", "app-server", "daemon", "version"], timeout: 3), result.code == 0,
                   let record = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
                   record["status"] as? String == "running", let actual = record["socketPath"] as? String, actual.hasPrefix("/") { path = actual }
                let connection = try CodexRPCConnection.shared(socketPath: path)
                defer { connection.close() }
                var pending = [[String: Any]]()
                connection.onNotification = { pending.append($0) }
                while self.valid(revision) {
                    guard let message = try pending.isEmpty ? connection.nextNotification() : pending.removeFirst() else { continue }
                    guard message["method"] as? String == "thread/status/changed",
                          let params = message["params"] as? [String: Any], let id = params["threadId"] as? String,
                          let status = params["status"] as? [String: Any], status["type"] as? String != "notLoaded" else { continue }
                    let result = try connection.request("thread/read", ["threadId": id, "includeTurns": false])
                    guard var record = result["thread"] as? [String: Any], record["id"] as? String == id else { continue }
                    // Preserve event order even if the metadata read sees a later state.
                    record["status"] = status
                    var session = try CodexProvider.session(record, authoritative: true)
                    if session.status == "idle",
                       let latest = try? connection.request("thread/turns/list", ["threadId": id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"]),
                       let turn = (latest["data"] as? [[String: Any]])?.first,
                       let turnID = turn["id"] as? String, let state = turn["status"] as? String {
                        session.activityTurn = SessionActivityTurn(id: turnID, status: state)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard self?.valid(revision) == true else { return }; receive(session)
                    }
                }
            } catch { /* The normal status poll remains available during reconnect. */ }
            guard self.valid(revision) else { return }
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connect(home: home, environment: environment, revision: revision, receive: receive)
            }
        }
    }
}
