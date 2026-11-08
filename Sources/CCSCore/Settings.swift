import Foundation

public enum CCSPaths {
    public static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    public static var settings: URL {
        if let path = ProcessInfo.processInfo.environment["CCS_SETTINGS_PATH"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/ccs/settings.json")
    }
    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }
}

public struct Settings: Codable {
    public var defaultDays = 7
    public var folders = false
    public var newDirectory = "~/ccs-sessions"
    public var cleanup = true
    public var hotkeyCode: UInt32 = 49 // Space
    public var hotkeyModifiers: UInt32 = 2048 // Carbon optionKey
    public var hotkeyLabel = "⌥Space"

    public init() {}
    public static func load(from url: URL = CCSPaths.settings) -> Settings {
        guard let data = try? Data(contentsOf: url),
              var result = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        if !dateWindows.contains(result.defaultDays) { result.defaultDays = 7 }
        if result.newDirectory.isEmpty { result.newDirectory = "~/ccs-sessions" }
        return result
    }
    public func save(to url: URL = CCSPaths.settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func newRoot(environment: [String: String]) -> URL {
        let override = environment["CCS_NEW_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: CCSPaths.expand(override ?? newDirectory)).standardizedFileURL
    }
}
