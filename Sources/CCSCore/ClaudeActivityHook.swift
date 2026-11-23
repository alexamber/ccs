import Foundation

public enum ClaudeActivityHook {
    public static let notification = Notification.Name("io.github.alexamber.ccs.claude-activity")
    private static let marker = " # CCS activity notifications"
    private static let events = ["UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// Only a small allowlist leaves the hook process; messages and tool input never do.
    public static func payload(_ input: Data) -> [String: String]? {
        guard input.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let id = object["session_id"] as? String, !id.isEmpty, id.count < 200,
              let event = object["hook_event_name"] as? String else { return nil }
        let status: String
        switch event {
        case "UserPromptSubmit": status = "active"
        case "PostToolUse", "PostToolUseFailure":
            // A background subagent can finish a tool after the main turn has stopped.
            guard (object["agent_id"] as? String)?.nonempty == nil else { return nil }
            status = "active"
        case "Stop": status = "idle"
        case "StopFailure": status = "error"
        case "PermissionRequest": status = "waiting_for_approval"
        case "PreToolUse" where object["tool_name"] as? String == "AskUserQuestion": status = "waiting_input"
        default: return nil
        }
        return ["id": id, "status": status, "event": event, "eventID": UUID().uuidString,
                "cwd": String((object["cwd"] as? String ?? "").prefix(4096)), "time": String(Date().timeIntervalSince1970)]
    }

    public static func configure(enabled: Bool, cli: String, environment: [String: String]) throws {
        let url = CCSPaths.claudeConfiguration(in: environment).appendingPathComponent("settings.json").resolvingSymlinksInPath()
        let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if original == nil && !enabled { return }
        let updated = try configuration(original ?? Data("{}".utf8), enabled: enabled, cli: cli)
        if let original,
           (try JSONSerialization.jsonObject(with: original) as? NSDictionary) == (try JSONSerialization.jsonObject(with: updated) as? NSDictionary) { return }
        // Refuse to overwrite an edit made while preparing the new configuration.
        guard (try? Data(contentsOf: url)) == original else { throw CCSError.message("Claude settings changed; retry notification setup.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        try updated.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: attributes?[.posixPermissions] ?? 0o600], ofItemAtPath: url.path)
    }
    static func configuration(_ data: Data, enabled: Bool, cli: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CCSError.message("Claude settings are not a JSON object; notification hooks were not changed.") }
        if object["hooks"] != nil && !(object["hooks"] is [String: Any]) { throw CCSError.message("Unsupported Claude hooks configuration; nothing was changed.") }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for event in events {
            if hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw CCSError.message("Unsupported Claude hook entries; nothing was changed.") }
            var entries = [[String: Any]]()
            for var entry in hooks[event] as? [[String: Any]] ?? [] {
                guard let commands = entry["hooks"] as? [[String: Any]] else { entries.append(entry); continue }
                let retained = commands.filter { !(($0["command"] as? String)?.hasSuffix(marker) ?? false) }
                if retained.count == commands.count { entries.append(entry) }
                else if !retained.isEmpty { entry["hooks"] = retained; entries.append(entry) }
            }
            if enabled {
                let command: [String: Any] = ["type": "command", "command": shellQuote(cli) + " --ccs-activity-hook" + marker, "async": true, "timeout": 5]
                var entry: [String: Any] = ["hooks": [command]]
                if event == "PreToolUse" { entry["matcher"] = "AskUserQuestion" }
                entries.append(entry)
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { object.removeValue(forKey: "hooks") } else { object["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
