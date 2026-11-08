import Foundation

public struct LiveSession: Decodable {
    public var sessionId: String
    public var id: String?
    public var cwd: String?
    public var name: String?
    public var status: String?
    public var kind: String?
    public var pid: Int?
    public var startedAt: Double?
}

public struct Session: Codable, Identifiable {
    public var id: String
    public var cwd: String
    public var mtime: Double
    public var title: String
    public var name: String?
    public var recap: String
    public var last: String
    public var turns: Int
    public var cost: Double?
    public var prompts: String
    public var status: String = "closed"
    public var live: LiveSession?
    private var storedProvider: Provider?
    public var provider: Provider {
        get { storedProvider ?? .claude }
        set { storedProvider = newValue }
    }
    public var key: String { provider.rawValue + ":" + id }

    enum CodingKeys: String, CodingKey {
        case id, cwd, mtime, title, name, recap, last, turns, cost, prompts, status
        case storedProvider = "provider"
    }

    public init(id: String, cwd: String, mtime: Double = 0, title: String = "",
                name: String? = nil, recap: String = "", last: String = "",
                turns: Int = 0, cost: Double? = nil, prompts: String = "", provider: Provider = .claude) {
        self.id = id; self.cwd = cwd; self.mtime = mtime; self.title = title
        self.name = name; self.recap = recap; self.last = last
        self.turns = turns; self.cost = cost; self.prompts = prompts
        self.storedProvider = provider
    }

    public var isLarge: Bool { status == "closed" && (turns >= 20 || (cost ?? 0) >= 20) }
    public var displayTitle: String { title.isEmpty ? String(id.prefix(8)) : title }
    public var isLive: Bool { live != nil || (provider == .codex && ["idle", "active", "waiting", "error"].contains(status)) }
    public var isSaved: Bool { status == "closed" || status == "saved" }
    public var statistics: String {
        provider == .claude ? "\(turns)p\(cost.map { $0 > 0 ? " · $\(formattedCost($0))" : "" } ?? "")" : ""
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [cwd, title, name ?? "", recap, last, prompts, status, provider.title]
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

public struct ExportSession: Encodable {
    public let id: String, dir: String, title: String
    public let name: String?
    public let status: String, age: String
    public let mtime: Int
    public let recap: String, last: String
    public let turns: Int?
    public let cost: Double?
    public let large: Bool

    public init(_ s: Session, home: String) {
        id = s.id; dir = shortPath(s.cwd, home: home); title = s.title; name = s.name
        status = s.status; age = ageString(s.mtime); mtime = Int(exactly: s.mtime.rounded(.towardZero)) ?? 0
        recap = s.recap; last = s.last; turns = s.provider == .claude ? s.turns : nil; cost = s.cost; large = s.isLarge
    }

    // Retain the Python CLI's explicit nulls for optional fields.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(dir, forKey: .dir)
        try c.encode(title, forKey: .title); try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status); try c.encode(age, forKey: .age)
        try c.encode(mtime, forKey: .mtime); try c.encode(recap, forKey: .recap)
        try c.encode(last, forKey: .last); try c.encode(turns, forKey: .turns)
        try c.encode(cost, forKey: .cost); try c.encode(large, forKey: .large)
    }
    enum CodingKeys: String, CodingKey { case id, dir, title, name, status, age, mtime, recap, last, turns, cost, large }
}

public func shortPath(_ path: String, home: String = CCSPaths.home) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

public func ageString(_ timestamp: Double, now: Double = Date().timeIntervalSince1970) -> String {
    guard timestamp.isFinite, timestamp >= 0 else { return "unknown" }
    let seconds = max(0, now - timestamp)
    for (unit, size) in [("d", 86400.0), ("h", 3600.0), ("m", 60.0)] {
        if seconds >= size { return "\(String(format: "%.0f", (seconds / size).rounded(.down)))\(unit)" }
    }
    return "now"
}

public let dateWindows = [1, 3, 7, 30, 0]
public func cycleWindow(_ days: Int, step: Int) -> Int {
    let order = Array(Set(dateWindows + [days])).sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
    let i = order.firstIndex(of: days) ?? 0
    return order[(i + step % order.count + order.count) % order.count]
}

public enum CCSError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Decimal formatting avoids trapping on malformed values outside the Int range.
public func formattedCost(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "?" }
    return String(format: value < 1e15 ? "%.0f" : "%.2g", locale: Locale(identifier: "en_US_POSIX"), value.rounded())
}
