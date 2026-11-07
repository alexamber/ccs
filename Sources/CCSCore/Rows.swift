import Foundation

public struct SessionRow {
    public var session: Session?
    public var label: String
    public var depth: Int
    public init(session: Session? = nil, label: String = "", depth: Int = 0) {
        self.session = session; self.label = label; self.depth = depth
    }
}

public func sessionRows(_ sessions: [Session], query: String, recent: Bool, tree: Bool = true) -> [SessionRow] {
    let found = sessions.filter { $0.matches(query) }
    if recent { return found.sorted { $0.mtime > $1.mtime }.map { SessionRow(session: $0) } }
    let grouped = Dictionary(grouping: found, by: { $0.cwd })
    let directories = tree ? grouped.keys.sorted() : grouped.keys.sorted {
        (grouped[$0]?.map(\.mtime).max() ?? 0) > (grouped[$1]?.map(\.mtime).max() ?? 0)
    }
    var rows = [SessionRow](), shown = Set<String>()
    for directory in directories {
        let parts = shortPath(directory).components(separatedBy: "/")
        if tree {
            for depth in 1...max(parts.count, 1) {
                let prefix = parts.prefix(depth).joined(separator: "/")
                if shown.insert(prefix).inserted { rows.append(SessionRow(label: parts[depth - 1] + "/", depth: depth - 1)) }
            }
        } else { rows.append(SessionRow(label: shortPath(directory))) }
        let sorted = (grouped[directory] ?? []).sorted {
            tree && $0.isLive != $1.isLive ? $0.isLive : $0.mtime > $1.mtime
        }
        rows += sorted.map { SessionRow(session: $0, depth: tree ? parts.count : 0) }
    }
    return rows
}
