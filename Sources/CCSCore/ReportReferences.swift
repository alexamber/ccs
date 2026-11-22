import Foundation
import Darwin
import CryptoKit

public struct ReportReference: Equatable, Codable {
    public enum Action: Int, Codable {
        case created, edited, wrote, read, mentioned

        public var label: String {
            switch self {
            case .created: return "Created"
            case .edited: return "Edited"
            case .wrote: return "Wrote"
            case .read: return "Read"
            case .mentioned: return "Mentioned"
            }
        }
    }
    public let path: String
    public let action: Action

    public init(path: String, action: Action) { self.path = path; self.action = action }

    public func matches(_ query: String) -> Bool {
        let fragment = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { return false }
        let value = fragment.hasPrefix("file://") ? URL(string: fragment)?.path ?? fragment : (fragment as NSString).expandingTildeInPath
        let normalized = value.hasPrefix("/") ? (value as NSString).standardizingPath : value
        return !normalized.isEmpty && path.localizedStandardContains(normalized)
    }
}

/// Extract only supported document paths. Successful tool outcomes and mentions
/// are kept distinct. The strongest known operation on each path wins.
struct ReportReferences {
    typealias Record = [String: Any]
    private var paths = [String: ReportReference.Action]()
    private var pending = [String: (String, String, ReportReference.Action)]()
    private static let mentions: NSRegularExpression = {
        let extensions = ArtifactIndex.types.sorted().joined(separator: "|")
        let end = "\\.(?:" + extensions + ")"
        // Markdown link destinations, quoted paths (including spaces), and plain paths.
        let pattern = #"https?://[^\s<>)]*|\]\(<?([^<>\n()]+?"# + end + #")>?\)|[`"']([^`"'\n]+?"# + end + #")[`"']|(?<![\w:/])((?:file:///|~/|/|\.{1,2}/)?[\p{L}\p{N}_.%+@/-]+"# + end + #")(?![\w./-])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    var files: [ReportReference] {
        paths.map { ReportReference(path: $0.key, action: $0.value) }.sorted {
            $0.action == $1.action ? $0.path < $1.path : $0.action.rawValue < $1.action.rawValue
        }
    }

    mutating func add(_ raw: String?, cwd: String, action: ReportReference.Action) {
        guard var path = raw, !path.isEmpty else { return }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL,
           url.host == nil || url.host == "" || url.host == "localhost" { path = url.path }
        guard !path.contains("://"), !path.contains("\n"), !path.contains("\0"),
              ArtifactIndex.types.contains((path as NSString).pathExtension.lowercased()) else { return }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") || cwd.hasPrefix("/") else { return }
        let absolute = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        path = (absolute as NSString).standardizingPath
        if paths[path].map({ $0.rawValue <= action.rawValue }) != true { paths[path] = action }
    }

    private mutating func text(_ text: String?, cwd: String) {
        guard let text else { return }
        let string = text as NSString
        for match in Self.mentions.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                let candidate = string.substring(with: match.range(at: group))
                let path = group == 1 ? candidate.removingPercentEncoding ?? candidate : candidate
                add(path, cwd: cwd, action: .mentioned)
            }
        }
    }

    mutating func codex(_ item: Record, cwd: String) {
        switch item["type"] as? String {
        case "fileChange" where item["status"] as? String == "completed":
            for change in item["changes"] as? [Record] ?? [] {
                guard let kind = change["kind"] as? Record else { continue }
                switch kind["type"] as? String {
                case "add": add(change["path"] as? String, cwd: cwd, action: .created)
                case "update":
                    add(change["path"] as? String, cwd: cwd, action: .edited)
                    add(kind["move_path"] as? String ?? kind["movePath"] as? String, cwd: cwd, action: .edited)
                default: break
                }
            }
        case "agentMessage": text(item["text"] as? String, cwd: cwd)
        case "userMessage":
            for part in item["content"] as? [Record] ?? [] where part["type"] as? String == "text" { text(part["text"] as? String, cwd: cwd) }
        case "commandExecution":
            let directory = item["cwd"] as? String ?? cwd
            text(item["command"] as? String, cwd: directory)
            if item["status"] as? String == "completed", item["exitCode"] as? Int == 0 {
                for action in item["commandActions"] as? [Record] ?? [] where action["type"] as? String == "read" {
                    add(action["path"] as? String, cwd: directory, action: .read)
                }
            }
        default: break
        }
    }

    mutating func claude(_ record: Record, cwd: String) {
        guard ["user", "assistant"].contains(record["type"] as? String),
              record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
              record["isCompactSummary"] as? Bool != true,
              let message = record["message"] as? Record else { return }
        let directory = record["cwd"] as? String ?? cwd
        text(message["content"] as? String, cwd: directory)
        for block in message["content"] as? [Record] ?? [] {
            switch block["type"] as? String {
            case "text": text(block["text"] as? String, cwd: directory)
            case "tool_use":
                guard let id = block["id"] as? String, let input = block["input"] as? Record else { continue }
                if block["name"] as? String == "Bash" { text(input["command"] as? String, cwd: directory) }
                guard let path = input["file_path"] as? String,
                      ArtifactIndex.types.contains((path as NSString).pathExtension.lowercased()),
                      let action = ["Read": ReportReference.Action.read, "Edit": .edited, "Write": .wrote][block["name"] as? String ?? ""] else { continue }
                pending[id] = (path, directory, action)
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, let (path, root, action) = pending.removeValue(forKey: id),
                      block["is_error"] as? Bool != true else { continue }
                let result = record["toolUseResult"] as? Record
                add(path, cwd: root, action: action == .wrote && result?["type"] as? String == "create" ? .created : action)
            default: break
            }
        }
    }

    static func loadClaude(_ session: Session, cancelled: () -> Bool) throws -> [ReportReference] {
        guard let url = session.transcriptURL, let file = fopen(url.path, "r") else { throw CocoaError(.fileReadNoSuchFile) }
        defer { fclose(file) }
        var refs = Self(), line: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(line) }
        while !cancelled() {
            let count = getline(&line, &capacity, file)
            guard count >= 0, let line else { break }
            guard let record = try JSONSerialization.jsonObject(with: Data(bytes: line, count: count)) as? Record else { continue }
            refs.claude(record, cwd: session.cwd)
        }
        if cancelled() { throw CancellationError() }
        if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
        return refs.files
    }
}

extension SessionService {
    public func reportReferences(for session: Session, cancelled: () -> Bool) throws -> [ReportReference] {
        struct Entry: Codable {
            let stamp: Double
            let files: [ReportReference]
        }
        let root = index.cache.deletingLastPathComponent().appendingPathComponent("report-references-v1")
        let identity = [session.key, session.cwd, session.transcriptURL?.path ?? codex.environment["CODEX_HOME"] ?? ""].joined(separator: "\0")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(name)
        if let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
           entry.stamp == session.mtime { return entry.files }
        let refs = try session.provider == .codex ? codex.reportReferences(for: session, cancelled: cancelled)
            : ReportReferences.loadClaude(session, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        // Local cache is optional. Only paths and operation labels are persisted.
        if let data = try? JSONEncoder().encode(Entry(stamp: session.mtime, files: refs)) {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: .atomic)
            } catch {}
        }
        return refs
    }
}
