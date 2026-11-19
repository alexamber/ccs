import Foundation
import XCTest
@testable import CCSCore

final class SessionActivityTests: XCTestCase {
    func testLiveCodexPollingReadsLoadedThreadsWithoutHistoryOrTurns() throws {
        let client = MockCodexConnection { method, params in
            if method == "thread/loaded/list" {
                return params["cursor"] == nil ? ["data": ["a"], "nextCursor": "next"] : ["data": ["b"], "nextCursor": NSNull()]
            }
            if method == "thread/turns/list" {
                XCTAssertEqual(params["limit"] as? Int, 1)
                XCTAssertEqual(params["itemsView"] as? String, "notLoaded")
                XCTAssertEqual(params["sortDirection"] as? String, "desc")
                return ["data": [["id": "latest", "status": "inProgress", "items": []]]]
            }
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params["includeTurns"] as? Bool, false)
            return ["thread": ["id": params["threadId"]!, "cwd": "/tmp/work", "updatedAt": 10, "preview": "", "name": "Topic",
                               "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]]]]
        }
        let provider = CodexProvider(connector: { client })
        let sessions = try provider.loadedSessions()
        XCTAssertEqual(sessions.map(\.id), ["a", "b"])
        XCTAssertTrue(sessions.allSatisfy { $0.isLive && $0.status == "waiting_input" })
        XCTAssertTrue(sessions.allSatisfy { $0.activityTurn == SessionActivityTurn(id: "latest", status: "inProgress") })
        XCTAssertEqual(SessionActivity.description(for: sessions[0]), "Waiting for input")
        XCTAssertFalse(client.calls.contains { $0.0 == "thread/list" })
    }
    func testFailedLiveReadReconnectsAndTurnFailureKeepsLiveStatus() throws {
        let dead = MockCodexConnection { _, _ in throw CCSError.message("Disconnected") }
        let good = MockCodexConnection { method, _ in
            if method == "thread/loaded/list" { return ["data": ["a"]] }
            if method == "thread/turns/list" { throw CCSError.message("Unsupported") }
            return ["thread": ["id": "a", "cwd": "/tmp/work", "updatedAt": 10, "preview": "", "status": ["type": "idle"]]]
        }
        var connections = 0
        let provider = CodexProvider(connector: { connections += 1; return connections == 1 ? dead : good })
        XCTAssertThrowsError(try provider.loadedSessions())
        XCTAssertTrue(dead.closed)
        let sessions = try provider.loadedSessions()
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(sessions.first?.status, "idle")
        XCTAssertNil(sessions.first?.activityTurn)
    }
    func testLoadedPollingRejectsUnsharedAndRepeatedCursors() {
        let unshared = MockCodexConnection(shared: false) { _, _ in XCTFail("Must not query a private metadata server for activity"); return [:] }
        XCTAssertThrowsError(try CodexProvider(connector: { unshared }).loadedSessions())
        let looping = MockCodexConnection { _, _ in ["data": ["a"], "nextCursor": "repeat"] }
        XCTAssertThrowsError(try CodexProvider(connector: { looping }).loadedSessions())
        XCTAssertEqual(looping.calls.count, 2)
    }
    func testNotificationPreferencesRoundTripAndOldSettingsStillLoad() throws {
        let original = Settings()
        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertFalse(restored.terminalPopups)
        XCTAssertTrue(restored.unicornAllSpaces)
        XCTAssertEqual(restored.unicornSize, .medium)
        for size in UnicornSize.allCases {
            restored.unicornSize = size
            let saved = try JSONEncoder().encode(restored)
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: saved).unicornSize, size)
        }
        restored.unicornAllSpaces = false; restored.notifyAttention = false; restored.notifyCompletion = false
        XCTAssertTrue(restored.notificationSound)
        restored.notificationSound = false
        restored.notificationBubble = false; restored.notificationWiggle = false
        let persisted = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(restored, persisted)
        XCTAssertFalse(persisted.unicornAllSpaces); XCTAssertFalse(persisted.notifyAttention); XCTAssertFalse(persisted.notifyCompletion)
        XCTAssertFalse(persisted.notificationSound)
        XCTAssertFalse(persisted.notificationBubble); XCTAssertFalse(persisted.notificationWiggle)
    }
}
