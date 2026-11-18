import XCTest
@testable import CCSCore

final class ClaudeActivityHookTests: XCTestCase {
    func testInstallationIsIdempotentAndRemovalPreservesOtherSettingsAndHooks() throws {
        let original: [String: Any] = ["model": "my-model", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo user-hook"]]]], "CustomEvent": [["hooks": []]]]]
        let data = try JSONSerialization.data(withJSONObject: original)
        let installed = try ClaudeActivityHook.configuration(data, enabled: true, cli: "/tmp/it's CCS/ccs")
        XCTAssertEqual(installed, try ClaudeActivityHook.configuration(installed, enabled: true, cli: "/tmp/it's CCS/ccs"))
        let removed = try ClaudeActivityHook.configuration(installed, enabled: false, cli: "/tmp/it's CCS/ccs")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, original as NSDictionary)
        let updated = try ClaudeActivityHook.configuration(installed, enabled: true, cli: "/new/ccs")
        XCTAssertFalse(String(decoding: updated, as: UTF8.self).contains("/tmp/it"))
        XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("echo user-hook"))
    }
    func testPayloadContainsOnlyActivityMetadataAndDistinguishesWaiting() throws {
        for (event, expected) in [("Stop", "idle"), ("PermissionRequest", "waiting_for_approval"), ("PreToolUse", "waiting_input"), ("UserPromptSubmit", "active")] {
            let input: [String: Any] = ["session_id": "session", "cwd": "/tmp", "hook_event_name": event, "tool_name": "AskUserQuestion",
                                       "tool_input": ["secret": "do not forward"], "last_assistant_message": "private response"]
            let payload = try XCTUnwrap(ClaudeActivityHook.payload(JSONSerialization.data(withJSONObject: input)))
            XCTAssertEqual(payload["status"], expected)
            XCTAssertNil(payload["tool_input"]); XCTAssertNil(payload["last_assistant_message"])
            XCTAssertEqual(Set(payload.keys), Set(["id", "cwd", "status", "event", "eventID", "time"]))
        }
        XCTAssertNil(ClaudeActivityHook.payload(Data("{}".utf8)))
        XCTAssertThrowsError(try ClaudeActivityHook.configuration(Data("{\"hooks\":false}".utf8), enabled: true, cli: "/tmp/ccs"))
    }
}
