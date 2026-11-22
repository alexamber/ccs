import XCTest
@testable import CCSCore

final class ReportReferenceTests: XCTestCase {
    func testClaudeBackfillWithSharedFolderAndSuccessfulToolResults() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let project = temp.appendingPathComponent("projects/a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = "reports/Quarterly Summary.html"
        let records: [[String: Any]] = [
            ["type": "assistant", "cwd": "/work", "message": ["content": [
                ["type": "tool_use", "id": "ok", "name": "Write", "input": ["file_path": path]],
                ["type": "tool_use", "id": "fail", "name": "Edit", "input": ["file_path": "other.html"]]]]],
            ["type": "user", "toolUseResult": ["type": "create"], "message": ["content": [
                ["type": "tool_result", "tool_use_id": "ok"], ["type": "tool_result", "tool_use_id": "fail", "is_error": true]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "See [report](reports/Quarterly%20Summary.html) or notes.md."]]]]
        ]
        func write(_ id: String, _ rows: [[String: Any]]) throws {
            let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            try lines.joined(separator: "\n").write(to: project.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }
        try write("writer", records)
        try write("other", [["type": "user", "cwd": "/work", "message": ["content": "Unrelated"]]])
        let index = SessionIndex(projects: project.deletingLastPathComponent(), cache: temp.appendingPathComponent("cache/index"))
        let service = SessionService(index: index)
        _ = try index.load()
        let sessions = try index.load()
        let writer = try XCTUnwrap(sessions["writer"])
        let hits = try service.reportReferences(for: writer, cancelled: { false })
        let ref = try XCTUnwrap(hits.first { $0.matches("orts/QUART") })
        XCTAssertEqual(ref, ReportReference(path: "/work/" + path, action: .created))
        XCTAssertTrue(ref.matches("Summary.ht"))
        XCTAssertTrue(ref.matches("file:///work/reports/Quarterly%20Summary.html"))
        XCTAssertFalse(hits.contains { $0.matches("other.html") })
        XCTAssertEqual(try service.reportReferences(for: XCTUnwrap(sessions["other"]), cancelled: { false }), [])
        XCTAssertEqual(try service.reportReferences(for: writer, cancelled: { false }), hits)
    }

    func testCodexPaginatesAndDistinguishesOperationsFromMentions() throws {
        let mock = MockCodexConnection { method, params in
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertEqual(params["itemsView"] as? String, "full")
            let failed: [String: Any] = ["type": "fileChange", "status": "failed", "changes": [["path": "failure.html", "kind": ["type": "add"]]]]
            let completed: [String: Any] = ["type": "fileChange", "status": "completed", "changes": [["path": "reports/output.html", "kind": ["type": "update"]]]]
            if params["cursor"] == nil { return ["data": [["items": [failed, completed]]], "nextCursor": "more"] }
            return ["data": [["items": [["type": "agentMessage", "text": "See [results](/tmp/prior report.html)."]]]], "nextCursor": NSNull()]
        }
        let provider = CodexProvider(connector: { mock })
        let session = Session(id: "one", cwd: "/work", provider: .codex)
        let hits = try provider.reportReferences(for: session, cancelled: { false })
        XCTAssertEqual(hits, [ReportReference(path: "/work/reports/output.html", action: .edited),
                              ReportReference(path: "/tmp/prior report.html", action: .mentioned)])
        XCTAssertEqual(mock.calls.count, 2)
    }
}
