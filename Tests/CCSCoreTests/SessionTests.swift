import Foundation
import XCTest
@testable import CCSCore

final class SessionTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func live(_ fields: [String: Any] = [:]) throws -> LiveSession {
        try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: ["sessionId": "abc"].merging(fields) { _, new in new }))
    }
    func testTranscriptAndCachePreserveMetadataAndRecoverFromMalformedJSON() throws {
        let root = try temporary(), project = root.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("saved.jsonl")
        let records: [[String: Any]] = [
            ["type": "user", "cwd": "/tmp/it's here", "message": ["content": [["type": "text", "text": "Fix   authentication"]]]],
            ["type": "user", "isMeta": true, "message": ["content": "Ignore this"]],
            ["type": "user", "message": ["content": "<system>ignore this too</system>"]],
            ["type": "ai-title", "aiTitle": "Generated"], ["type": "custom-title", "customTitle": "My\n title\u{1b}"],
            ["type": "cost-state", "totalCostUSD": 12.5],
            ["type": "system", "subtype": "away_summary", "content": "A\nrecap"]
        ]
        let data = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n{bad json\n"
        try data.write(to: file, atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: cache)
        let index = SessionIndex(projects: root.appendingPathComponent("projects"), cache: cache)
        let s = try XCTUnwrap(index.load()["saved"])
        XCTAssertEqual(s.title, "My title"); XCTAssertEqual(s.cwd, "/tmp/it's here")
        XCTAssertEqual(s.turns, 1); XCTAssertEqual(s.prompts, "Fix authentication")
        XCTAssertEqual(s.recap, "A recap"); XCTAssertEqual(s.cost, 12.5)
        XCTAssertEqual(try index.load()["saved"]?.title, "My title")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try index.load().isEmpty)
    }
    func testMalformedLiveListsNeverAuthorizeResume() throws {
        for text in ["{}", "null", "[1]", "[{\"sessionId\":1}]", "[{\"sessionId\":\"\"}]"] {
            var launched = false
            let service = SessionService(runner: { path, _, _, _ in
                if path == "/usr/bin/osascript" { launched = true }
                return CommandResult(out: text)
            })
            XCTAssertNil(service.liveSessions())
            XCTAssertThrowsError(try service.activate(Session(id: "abc", cwd: "/tmp/work")))
            XCTAssertFalse(launched)
        }
        let service = SessionService(runner: { _, _, _, _ in CommandResult(code: 1, out: "[]") })
        XCTAssertNil(service.liveSessions())
    }
    func testTextCleanupAndPromptLimitsMatchLegacyUnicodeBehavior() throws {
        XCTAssertEqual(cleanText("Fix\u{e145}\u{200d}\u{1b}  this\nnow"), "Fix this now")
        let root = try temporary(), file = root.appendingPathComponent("unicode.jsonl")
        let prompt = String(repeating: "e\u{301}", count: 200)
        try JSONSerialization.data(withJSONObject: ["cwd": "/tmp/work", "type": "user", "message": ["content": prompt]]).write(to: file)
        XCTAssertEqual(try SessionIndex.scan(file).title.unicodeScalars.count, 300)
    }
    func testActivationRefreshesLiveStatusAndQuotesShellArguments() throws {
        var commands = [[String]]()
        let service = SessionService(runner: { path, args, _, _ in
            if path == "/usr/bin/env" { return CommandResult(out: "[]") }
            commands.append(args); return CommandResult()
        })
        let s = Session(id: "id'; bad", cwd: "/tmp/it's a project")
        try service.activate(s)
        XCTAssertEqual(commands.last?.last, "cd \(shellQuote(s.cwd)) && claude --resume \(shellQuote(s.id))")
        try service.activate(s, fresh: true)
        XCTAssertEqual(commands.last?.last, "cd \(shellQuote(s.cwd)) && claude")
        let text = "it's here; $(printf wrong)\nnext"
        let echoed = try ProcessRunner().run("/bin/sh", ["-c", "printf '%s' " + shellQuote(text)])
        XCTAssertEqual(echoed.out, text)
    }
    func testLiveSessionFocusUsesExactAttachTargetAndAncestry() throws {
        let list = "10 1 ?? login\n20 10 ttys001 claude\n30 20 ?? claude daemon\n40 30 ttys010 claude --bg-pty-host\n50 10 ttys015 claude attach My task\n60 10 ttys016 claude attach abc-other\n"
        let s = Session(id: "abc", cwd: "/tmp/work"), record = try live(["pid": 40, "name": "My task"])
        XCTAssertEqual(SessionService.candidateTTYs(s, live: record, processList: list), ["ttys015", "ttys010", "ttys001"])
        var scripts = [String]()
        let liveJSON = String(decoding: try JSONSerialization.data(withJSONObject: [["sessionId": "abc", "pid": 40, "kind": "background", "name": "My task"]]), as: UTF8.self)
        let service = SessionService(runner: { path, _, input, _ in
            if path == "/usr/bin/env" { return CommandResult(out: liveJSON) }
            if path == "/bin/ps" { return CommandResult(out: list) }
            scripts.append(input ?? ""); return CommandResult(out: "ok\n")
        })
        try service.activate(s)
        XCTAssertEqual(scripts, [SessionService.focusScript])
    }
    func testFolderNumbersSurviveCleanupAndConcurrentCreation() throws {
        let root = try temporary()
        let manager = NewSessions(service: SessionService())
        let first = try manager.create(root: root, day: "2026-11-07")
        XCTAssertEqual(first.lastPathComponent, "2026-11-07-1")
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(try manager.create(root: root, day: "2026-11-07").lastPathComponent, "2026-11-07-2")
        let lock = NSLock(), group = DispatchGroup()
        var paths = [String](), errors = [Error]()
        for _ in 0..<12 {
            group.enter(); DispatchQueue.global().async {
                do { let path = try manager.create(root: root, day: "2026-11-07"); lock.lock(); paths.append(path.path); lock.unlock() }
                catch { lock.lock(); errors.append(error); lock.unlock() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.isEmpty); XCTAssertEqual(paths.count, 12); XCTAssertEqual(Set(paths).count, 12)
    }
    func testCleanupKeepsBusySavedNonemptySymlinkAndUnknownFolders() throws {
        let root = try temporary(), project = root.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var folders = [URL]()
        for name in ["2026-11-01-1", "2026-11-01-2", "2026-11-01-3", "2026-11-01-4", "notes"] {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); folders.append(path)
        }
        try Data("keep".utf8).write(to: folders[1].appendingPathComponent("file"))
        try JSONSerialization.data(withJSONObject: ["cwd": folders[2].path, "type": "user", "message": ["content": "Saved"]]).write(to: project.appendingPathComponent("saved.jsonl"))
        let symlink = root.appendingPathComponent("2026-11-01-5")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: folders[0]); folders.append(symlink)
        let index = SessionIndex(projects: root.appendingPathComponent("projects"), cache: root.appendingPathComponent("cache/index.json"))
        var result = CommandResult(code: 1, out: "n/\n")
        let service = SessionService(index: index, runner: { _, _, _, _ in result }, codex: CodexProvider(enabled: false))
        let manager = NewSessions(service: service)
        try manager.prune(folders)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[0].path))
        result = CommandResult(out: "p1\nfcwd\nn/\np2\nfcwd\nn\(folders[3].path)\n")
        try manager.prune(folders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folders[0].path))
        for folder in folders[1..<5] { XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path)) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), folders[0].path)
    }
    func testCLIInstallationBacksUpExistingVersionAndIsIdempotent() throws {
        let root = try temporary(), source = root.appendingPathComponent("source"), directory = root.appendingPathComponent("bin")
        try Data("native".utf8).write(to: source); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: directory.appendingPathComponent("ccs"))
        let target = try CLIInstaller.install(source: source, directory: directory)
        XCTAssertEqual(try String(contentsOf: target), "native")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("ccs.backup-") })
        XCTAssertEqual(try String(contentsOf: backup), "previous")
        _ = try CLIInstaller.install(source: source, directory: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }
    func testCLIStatusRecognizesShadowedAndOffPathInstallations() throws {
        let root = try temporary(), source = root.appendingPathComponent("source")
        let bin = root.appendingPathComponent(".local/bin"), older = root.appendingPathComponent("older")
        try Data("native".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let installed = try CLIInstaller.install(source: source, directory: bin)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let other = older.appendingPathComponent("ccs")
        try Data("old".utf8).write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        let ready = CLIInstaller.status(source: source, environment: ["PATH": bin.path], home: root.path)
        XCTAssertEqual(ready.location, installed); XCTAssertTrue(ready.isOnPath)
        let shadowed = CLIInstaller.status(source: source, environment: ["PATH": older.path + ":" + bin.path], home: root.path)
        XCTAssertEqual(shadowed.location, installed); XCTAssertFalse(shadowed.isOnPath)
        let offPath = CLIInstaller.status(source: source, environment: ["PATH": older.path], home: root.path)
        XCTAssertEqual(offPath.location, installed); XCTAssertFalse(offPath.isOnPath)
    }
    func testCleanupRecognizesPhysicalAndSymlinkedWorkingDirectories() throws {
        let root = try temporary(), actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let folder = actual.appendingPathComponent("2026-11-08-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache/index.json"))
        let service = SessionService(index: index, runner: { _, _, _, _ in CommandResult(out: "p1\nfcwd\nn\(alias.appendingPathComponent(folder.lastPathComponent).path)\n") }, codex: CodexProvider(enabled: false))
        try NewSessions(service: service).prune([folder])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(physicalPath(alias.appendingPathComponent(folder.lastPathComponent).path), physicalPath(folder.path))
    }
    func testIncompleteTranscriptCannotAuthorizeCleanupEvenAfterCacheHit() throws {
        let root = try temporary(), project = root.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("partial.jsonl")
        try Data("{\"type\":\"user\",\"cwd\":\"/tmp/unfinished".utf8).write(to: file)
        let index = SessionIndex(projects: root.appendingPathComponent("projects"), cache: root.appendingPathComponent("cache"))
        XCTAssertTrue(try index.load().isEmpty); XCTAssertFalse(index.isComplete)
        XCTAssertThrowsError(try index.load(requireComplete: true))
        let folder = root.appendingPathComponent("2026-11-08-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = SessionService(index: index, runner: { _, _, _, _ in CommandResult(out: "n/\n") }, codex: CodexProvider(enabled: false))
        XCTAssertTrue(try service.collect(days: 0).isEmpty)
        XCTAssertTrue(service.historyFailures.contains(.claude))
        XCTAssertThrowsError(try NewSessions(service: service).prune([folder]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        try Data("{\"type\":\"user\",\"cwd\":\"/tmp/project\"}\n{bad json".utf8).write(to: file)
        XCTAssertNotNil(try index.load()["partial"])
        XCTAssertThrowsError(try index.load(requireComplete: true))
    }

    func testExtremeCostMetadataDoesNotCrashFormatting() throws {
        let root = try temporary(), file = root.appendingPathComponent("cost.jsonl")
        try Data("{\"type\":\"user\",\"cwd\":\"/tmp/work\"}\n{\"type\":\"cost-state\",\"totalCostUSD\":1e100}".utf8).write(to: file)
        XCTAssertNil(try SessionIndex.scan(file).cost)
        XCTAssertFalse(Session(id: "test", cwd: "/tmp", cost: 1e100).statistics.isEmpty)
        XCTAssertEqual(formattedCost(.infinity), "?")
        XCTAssertEqual(formattedCost(12.5), "13")
    }

    func testCleanupProcessScanDoesNotHoldTheAllocationLock() throws {
        let root = try temporary(), folder = root.appendingPathComponent("2026-11-08-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let allocator = NewSessions(service: SessionService(codex: CodexProvider(enabled: false)))
        let completed = DispatchSemaphore(value: 0)
        let service = SessionService(index: SessionIndex(projects: root.appendingPathComponent("missing"), cache: root.appendingPathComponent("cache")), runner: { _, _, _, _ in
            DispatchQueue.global().async {
                _ = try? allocator.create(root: root, day: "2026-11-09")
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success, "Cleanup blocked a new session while listing processes")
            return CommandResult(out: "n/\n")
        }, codex: CodexProvider(enabled: false))
        try NewSessions(service: service).prune([folder])
    }

}
