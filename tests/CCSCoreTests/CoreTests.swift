import Foundation
import XCTest
@testable import CCSCore

final class CoreTests: XCTestCase {
    func testLegacyExportKeepsOptionalFieldsAndDoesNotExportPromptSearchText() throws {
        let s = Session(id: "example", cwd: "/tmp/work", title: "Title", prompts: "private prompt text")
        let data = try JSONEncoder().encode(ExportSession(s, home: "/Users/example"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(value["name"] is NSNull)
        XCTAssertTrue(value["cost"] is NSNull)
        XCTAssertNil(value["prompts"])
        XCTAssertEqual(value["status"] as? String, "closed")
        XCTAssertEqual(Set(value.keys), Set(["id", "dir", "title", "name", "status", "age", "mtime", "recap", "last", "turns", "cost", "large"]))
    }

    func testUnknownActivityDoesNotTriggerClosedSessionConfirmation() {
        var s = Session(id: "x", cwd: "/tmp/work", turns: 30)
        XCTAssertTrue(s.isLarge)
        s.status = "unknown"
        XCTAssertFalse(s.isLarge)
    }

    func testProcessRunnerDrainsBothPipesAndTerminatesTimeouts() throws {
        let runner = ProcessRunner()
        let result = try runner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf 'stdout line\\n'; printf 'stderr line\\n' >&2; i=$((i+1)); done"])
        XCTAssertEqual(result.code, 0)
        XCTAssertGreaterThan(result.out.count, 65536)
        XCTAssertGreaterThan(result.err.count, 65536)
        let start = Date()
        XCTAssertThrowsError(try runner.run("/bin/sleep", ["10"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testEnvironmentOverrideWinsOverSavedNewFolder() {
        var settings = Settings(); settings.newDirectory = "/tmp/settings"
        XCTAssertEqual(settings.newRoot(environment: ["CCS_NEW_DIR": "/tmp/override"]).path, "/tmp/override")
        XCTAssertEqual(settings.newRoot(environment: ["CCS_NEW_DIR": ""]).path, "/tmp/settings")
    }
}
