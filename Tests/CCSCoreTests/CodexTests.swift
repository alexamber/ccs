import Foundation
import XCTest
@testable import CCSCore

final class MockCodexConnection: CodexConnection {
    let isShared: Bool
    var calls = [(String, [String: Any])](), closed = false
    var handler: (String, [String: Any]) throws -> [String: Any]
    init(shared: Bool = true, handler: @escaping (String, [String: Any]) throws -> [String: Any]) {
        isShared = shared; self.handler = handler
    }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        calls.append((method, params)); return try handler(method, params)
    }
    func close() { closed = true }
}

final class CodexTests: XCTestCase {
    func record(_ id: String = "example", cwd: String = "/tmp/project", status: String = "notLoaded") -> [String: Any] {
        ["id": id, "cwd": cwd, "updatedAt": Date().timeIntervalSince1970, "name": "Codex example", "preview": "Fix authentication", "status": ["type": status], "source": "cli"]
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testPaginationProviderIdentityAndUnavailableStatistics() throws {
        let first = record(), second = record("second", status: "active")
        let client = MockCodexConnection { method, params in
            XCTAssertEqual(method, "thread/list")
            XCTAssertEqual(params["archived"] as? Bool, false)
            XCTAssertFalse((params["sourceKinds"] as? [String] ?? []).contains("subAgent"))
            return params["cursor"] == nil ? ["data": [first], "nextCursor": "page2"] : ["data": [second], "nextCursor": NSNull()]
        }
        let sessions = CodexProvider(connector: { client }).collect()
        XCTAssertEqual(sessions.count, 2); XCTAssertEqual(client.calls.count, 2)
        let saved = try XCTUnwrap(sessions.first { $0.id == "example" }), active = try XCTUnwrap(sessions.first { $0.id == "second" })
        XCTAssertEqual(saved.provider, .codex); XCTAssertEqual(saved.key, "codex:example")
        XCTAssertEqual(saved.status, "saved"); XCTAssertFalse(saved.isLive)
        XCTAssertTrue(active.isLive); XCTAssertTrue(saved.statistics.isEmpty)
        XCTAssertNotEqual(saved.key, Session(id: "example", cwd: "/tmp").key)
        let export = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CombinedExportSession(saved, home: "/tmp/home"))) as! [String: Any]
        XCTAssertEqual(export["provider"] as? String, "codex")
        XCTAssertEqual(export["key"] as? String, "codex:example")
        XCTAssertTrue(export["turns"] is NSNull); XCTAssertTrue(export["cost"] is NSNull)
    }
    func testMetadataOnlyServerNeverClaimsGlobalLiveState() throws {
        let session = try CodexProvider.session(record(status: "notLoaded"), authoritative: false)
        XCTAssertEqual(session.status, "unknown"); XCTAssertFalse(session.isLive)
        var waiting = record(status: "active"); waiting["status"] = ["type": "active", "activeFlags": ["waitingOnApproval"]]
        XCTAssertEqual(try CodexProvider.session(waiting, authoritative: true).status, "waiting")
        var bad = record(); bad["updatedAt"] = true
        XCTAssertThrowsError(try CodexProvider.session(bad, authoritative: true))
        bad = record(); bad["updatedAt"] = Double.greatestFiniteMagnitude
        XCTAssertThrowsError(try CodexProvider.session(bad, authoritative: true))
        bad = record(); bad.removeValue(forKey: "cwd")
        XCTAssertThrowsError(try CodexProvider.session(bad, authoritative: true))
    }
    func testMalformedPaginationDoesNotReturnPartialHistory() {
        let entry = record()
        let client = MockCodexConnection { _, _ in ["data": [entry], "nextCursor": "same-cursor"] }
        let provider = CodexProvider(connector: { client })
        XCTAssertTrue(provider.collect().isEmpty); XCTAssertNotNil(provider.issue); XCTAssertTrue(client.closed)
    }
    func testExactCodexResumeArgumentsFindOnlyTheCorrectTerminal() {
        let processes = """
        1 0 ttys001 codex --remote unix:///tmp/socket --cd '/tmp/project' resume abc
        2 0 ttys002 codex resume abc-other
        3 0 ttys003 codex resume other abc
        4 0 ttys004 /bin/sh -c 'codex resume abc'
        5 0 ttys005 codex exec resume abc
        6 0 ?? codex resume abc
        7 0 ttys006 /usr/local/bin/codex resume --model example abc
        8 0 ttys007 codex --remote ws://remote-host:4500 resume abc
        9 0 ttys008 codex --remote=unix:///tmp/another-server resume abc
        """
        XCTAssertEqual(CodexProvider.candidateTTYs(id: "abc", processList: processes, localSocketPath: "/tmp/socket", arguments: { pid in
            let line = processes.split(separator: "\n").first { $0.split(separator: " ").first == Substring(String(pid)) }!
            return shellWords(String(line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })[3]))
        }), ["ttys001", "ttys006"])
    }
    func testCodexActivationFocusesExactTabOrOpensSameConversationWithoutATurn() throws {
        let entry = record("abc", cwd: "/tmp/it's here", status: "idle")
        let client = MockCodexConnection { method, params in
            XCTAssertEqual(method, "thread/read"); XCTAssertEqual(params["threadId"] as? String, "abc")
            XCTAssertEqual(params["includeTurns"] as? Bool, false)
            return ["thread": entry]
        }
        let codex = CodexProvider(connector: { client })
        var scripts = [(String, [String])](), found = true
        let service = SessionService(runner: { path, args, script, _ in
            if path == "/bin/ps" { return CommandResult(out: "1 0 ttys001 codex resume abc") }
            scripts.append((script ?? "", args)); return CommandResult(out: found ? "ok\n" : "missing\n")
        }, codex: codex, arguments: { _ in ["codex", "resume", "abc"] })
        let session = try CodexProvider.session(entry, authoritative: true)
        try service.activate(session)
        XCTAssertEqual(scripts.count, 1); XCTAssertEqual(scripts[0].0, SessionService.focusScript)
        found = false; scripts.removeAll(); try service.activate(session)
        XCTAssertEqual(scripts.last?.0, SessionService.launchScript)
        XCTAssertEqual(scripts.last?.1.last, codex.launchCommand + " --cd '/tmp/it'\\''s here' resume 'abc'")
        scripts.removeAll(); try service.activate(session, fresh: true)
        XCTAssertEqual(scripts.last?.1.last, "cd '/tmp/it'\\''s here' && " + codex.launchCommand)
        XCTAssertTrue(client.calls.allSatisfy { $0.0 == "thread/read" })
    }
    func testCleanupPreservesArchivedAndSubagentFoldersAndFailsClosed() throws {
        let root = try temporary()
        let folders = try (1...3).map { number -> URL in
            let path = root.appendingPathComponent("2026-11-08-\(number)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
        }
        let main = record("agent", cwd: folders[0].path), archived = record("archive", cwd: folders[1].path)
        var failed = false
        let client = MockCodexConnection { method, params in
            XCTAssertEqual(method, "thread/list")
            XCTAssertTrue((params["sourceKinds"] as? [String] ?? []).contains("subAgent"))
            if failed { throw CCSError.message("Unavailable") }
            return ["data": [(params["archived"] as? Bool) == true ? archived : main]]
        }
        let service = SessionService(index: SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache")),
                                     runner: { _, _, _, _ in CommandResult(out: "p1\nfcwd\nn/\n") }, codex: CodexProvider(connector: { client }))
        let manager = NewSessions(service: service)
        try manager.prune(folders)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folders[2].path))
        try FileManager.default.createDirectory(at: folders[2], withIntermediateDirectories: true)
        failed = true
        XCTAssertThrowsError(try manager.prune([folders[2]]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[2].path))
    }
    func testOldSettingsAndCachedSessionsKeepTheirMeaning() throws {
        let old = Data(#"{"defaultDays":30,"folders":true,"newDirectory":"~/work","cleanup":false,"hotkeyCode":40,"hotkeyModifiers":256,"hotkeyLabel":"⌘K"}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: old)
        XCTAssertEqual(settings.defaultDays, 30); XCTAssertFalse(settings.cleanup)
        XCTAssertEqual(settings.newProvider, .claude); XCTAssertEqual(settings.providerFilter, .all)
        settings.newProvider = .codex
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        XCTAssertEqual(value["newProvider"] as? String, "codex")
        var cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Session(id: "old", cwd: "/tmp"))) as! [String: Any]
        cached.removeValue(forKey: "provider")
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: cached))
        XCTAssertEqual(session.provider, .claude); XCTAssertEqual(session.key, "claude:old")
    }
    func testMissingProviderDoesNotCreateDatedFolders() throws {
        let root = try temporary().appendingPathComponent("sessions")
        var settings = Settings(); settings.newDirectory = root.path; settings.newProvider = .codex
        let manager = NewSessions(service: SessionService(codex: CodexProvider(enabled: false)), settings: settings, environment: ["PATH": ""])
        XCTAssertThrowsError(try manager.start(cliPath: "/tmp/ccs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testSingleProviderDetectionAndExplicitChoicesSurviveInstallingAnotherTool() throws {
        let root = try temporary()
        let codex = root.appendingPathComponent("codex"), claude = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let env = ["PATH": root.path]
        var settings = Settings().resolvingProviders(environment: env)
        XCTAssertEqual(settings.enabledProviders, [.codex]); XCTAssertEqual(settings.newProvider, .codex)
        XCTAssertFalse(settings.needsProviderSetup)
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        XCTAssertEqual(settings.resolvingProviders(environment: env).enabledProviders, [.codex])
        settings.enabledProviders = [.claude]; settings.providerFilter = .codex
        settings = settings.resolvingProviders(environment: env)
        XCTAssertEqual(settings.enabledProviders, [.claude]); XCTAssertEqual(settings.newProvider, .claude)
        XCTAssertEqual(settings.providerFilter, .all)
        XCTAssertEqual(Settings().resolvingProviders(environment: env).enabledProviders, [.claude, .codex])
        try FileManager.default.removeItem(at: codex)
        let claudeOnly = Settings().resolvingProviders(environment: env)
        XCTAssertEqual(claudeOnly.enabledProviders, [.claude]); XCTAssertEqual(claudeOnly.newProvider, .claude)
    }
    func testDisabledProviderIsNeverQueriedWhileBrowsing() throws {
        let entry = record()
        let client = MockCodexConnection { _, _ in ["data": [entry]] }
        var claudeQueries = 0
        let root = try temporary()
        let service = SessionService(index: SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache")),
                                     runner: { _, _, _, _ in claudeQueries += 1; return CommandResult(out: "[]") }, codex: CodexProvider(connector: { client }))
        XCTAssertTrue(try service.collect(days: 0, provider: .all, enabledProviders: [.claude]).isEmpty)
        XCTAssertTrue(client.calls.isEmpty); XCTAssertEqual(claudeQueries, 1)
        XCTAssertEqual(try service.collect(days: 0, provider: .all, enabledProviders: [.codex]).count, 1)
        XCTAssertEqual(claudeQueries, 1)
    }
    func testMetadataOnlyConnectionIsReusedBetweenRefreshes() throws {
        let root = try temporary(), entry = record()
        let client = MockCodexConnection(shared: false) { _, _ in ["data": [entry]] }
        var connections = 0
        let provider = CodexProvider(environment: ["HOME": root.path], connector: { connections += 1; return client })
        XCTAssertEqual(provider.collect().count, 1)
        XCTAssertEqual(provider.collect().count, 1)
        XCTAssertEqual(connections, 1); XCTAssertFalse(client.closed)
    }
    func testSavedFilterAndNewProviderCannotSelectADisabledProvider() throws {
        let path = try temporary().appendingPathComponent("settings.json")
        var settings = Settings()
        settings.defaultDays = 30; settings.enabledProviders = [.claude]
        settings.providerFilter = .codex; settings.newProvider = .codex
        try settings.save(to: path)
        let loaded = Settings.load(from: path)
        XCTAssertEqual(loaded.providerFilter, .all); XCTAssertEqual(loaded.newProvider, .claude)
        XCTAssertEqual(loaded.enabledProviders, [.claude]); XCTAssertEqual(loaded.defaultDays, 30)
    }
    func testKernelArgumentsPreserveSpacesApostrophesAndEmptyArguments() throws {
        let root = try temporary(), binary = root.appendingPathComponent("codex")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/hold-args.c")
        let compiled = try ProcessRunner().run("/usr/bin/clang", [source.path, "-o", binary.path])
        XCTAssertEqual(compiled.code, 0, compiled.err)
        let child = Process(); child.executableURL = binary
        child.arguments = ["--cd", "/tmp/it's here", "resume", "abc", ""]
        try child.run(); defer { child.terminate(); child.waitUntilExit() }
        let words = try XCTUnwrap(ProcessArguments.read(child.processIdentifier))
        XCTAssertEqual(Array(words.dropFirst()), child.arguments!)
        // This is the exact, unescaped command representation emitted by ps.
        let listing = "\(child.processIdentifier) 1 ttys001 " + words.joined(separator: " ")
        XCTAssertEqual(CodexProvider.candidateTTYs(id: "abc", processList: listing), ["ttys001"])
        XCTAssertTrue(CodexProvider.candidateTTYs(id: "abc-other", processList: listing).isEmpty)
    }

    func testCodexHomeIsPreservedForResumeFreshAndNewSessionCommands() throws {
        let root = try temporary(), home = root.appendingPathComponent("it's my data")
        let env = ["CODEX_HOME": home.path, "PATH": root.path, "HOME": root.path]
        let codex = CodexProvider(environment: env, connector: { MockCodexConnection { _, _ in ["thread": self.record()] } })
        let executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var commands = [String]()
        let service = SessionService(runner: { _, args, _, _ in commands.append(args.last!); return CommandResult() }, codex: codex)
        let session = Session(id: "abc", cwd: "/tmp/project", provider: .codex)
        XCTAssertTrue(codex.resumeCommand(session).contains("CODEX_HOME=" + shellQuote(home.path)))
        try service.activate(session, fresh: true)
        XCTAssertTrue(commands.last!.contains(codex.launchCommand))
        var settings = Settings(); settings.newDirectory = root.appendingPathComponent("sessions").path
        settings.newProvider = .codex
        _ = try NewSessions(service: service, settings: settings, environment: env).start(cliPath: "/nonexistent/ccs")
        XCTAssertTrue(commands.last!.contains(codex.launchCommand))
        XCTAssertTrue(commands.last!.contains(codex.cleanupEnvironment + " '/nonexistent/ccs' --prune"))
    }

    func testProcessEnteringFolderDuringMetadataReadPreventsDeletion() throws {
        let root = try temporary(), folder = root.appendingPathComponent("2026-11-08-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["30"]; holder.currentDirectoryURL = folder
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        let client = MockCodexConnection { _, _ in
            if !holder.isRunning { try holder.run() }
            return ["data": []]
        }
        let service = SessionService(index: SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache")), codex: CodexProvider(connector: { client }))
        try NewSessions(service: service).prune([folder])
        XCTAssertTrue(holder.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testActivationConnectionDiscoversDaemonAfterMetadataFallback() throws {
        let root = try temporary(), entry = record("abc", status: "idle")
        let fallback = MockCodexConnection(shared: false) { _, _ in ["thread": entry] }
        let daemon = MockCodexConnection { _, _ in ["thread": entry] }
        var connections = 0
        let provider = CodexProvider(environment: ["CODEX_HOME": root.path], connector: {
            connections += 1; return connections == 1 ? fallback : daemon
        })
        XCTAssertEqual(try provider.current("abc").status, "unknown")
        XCTAssertEqual(try provider.current("abc").status, "unknown")
        XCTAssertEqual(connections, 1)
        let socket = root.appendingPathComponent("app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: socket)
        XCTAssertEqual(try provider.current("abc").status, "idle")
        XCTAssertEqual(connections, 2); XCTAssertTrue(fallback.closed)
    }

}
