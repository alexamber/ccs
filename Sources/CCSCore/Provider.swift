import Foundation

public enum Provider: String, Codable, CaseIterable {
    case claude, codex
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public var command: String { rawValue }
    public func isInstalled(environment: [String: String]) -> Bool {
        (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).contains {
            let directory = $0.isEmpty ? FileManager.default.currentDirectoryPath : String($0)
            return FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent(command).path)
        }
    }
}

public enum ProviderFilter: String, Codable, CaseIterable {
    case all, claude, codex
    public var title: String { self == .all ? "All" : Provider(rawValue: rawValue)!.title }
    public func includes(_ provider: Provider) -> Bool { self == .all || rawValue == provider.rawValue }
}

public struct CombinedExportSession: Encodable {
    private let session: Session
    private let home: String
    public init(_ session: Session, home: String) { self.session = session; self.home = home }
    public func encode(to encoder: Encoder) throws {
        try ExportSession(session, home: home).encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(session.provider, forKey: .provider)
        try container.encode(session.key, forKey: .key)
    }
    private enum Keys: String, CodingKey { case provider, key }
}
