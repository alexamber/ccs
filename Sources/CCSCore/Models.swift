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

    enum CodingKeys: String, CodingKey {
        case id, cwd, mtime, title, name, recap, last, turns, cost, prompts, status
    }

    public init(id: String, cwd: String, mtime: Double = 0, title: String = "",
                name: String? = nil, recap: String = "", last: String = "",
                turns: Int = 0, cost: Double? = nil, prompts: String = "") {
        self.id = id; self.cwd = cwd; self.mtime = mtime; self.title = title
        self.name = name; self.recap = recap; self.last = last
        self.turns = turns; self.cost = cost; self.prompts = prompts
    }

    public var isLarge: Bool { status == "closed" && (turns >= 20 || (cost ?? 0) >= 20) }
    public var displayTitle: String { title.isEmpty ? String(id.prefix(8)) : title }
    public var isLive: Bool { live != nil }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [cwd, title, name ?? "", recap, last, prompts, status]
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

public struct ExportSession: Encodable {
    public let id: String, dir: String, title: String
    public let name: String?
    public let status: String, age: String
    public let mtime: Int
    public let recap: String, last: String
    public let turns: Int
    public let cost: Double?
    public let large: Bool

    public init(_ s: Session, home: String) {
        id = s.id; dir = shortPath(s.cwd, home: home); title = s.title; name = s.name
        status = s.status; age = ageString(s.mtime); mtime = Int(s.mtime)
        recap = s.recap; last = s.last; turns = s.turns; cost = s.cost; large = s.isLarge
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
    let seconds = max(0, now - timestamp)
    for (unit, size) in [("d", 86400.0), ("h", 3600.0), ("m", 60.0)] {
        if seconds >= size { return "\(Int(seconds / size))\(unit)" }
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
