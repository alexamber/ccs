import Foundation
import Darwin

public final class SessionIndex {
    public let projects: URL
    public let cache: URL
    private let fm = FileManager.default
    public private(set) var isComplete = true
    private struct Entry: Codable {
        var version: Int = 3
        var complete: Bool
        var size: UInt64
        var modified: Double
        var session: Session
    }

    public init(projects: URL? = nil, cache: URL? = nil) {
        let home = URL(fileURLWithPath: CCSPaths.home)
        self.projects = projects ?? home.appendingPathComponent(".claude/projects")
        self.cache = cache ?? home.appendingPathComponent(".cache/ccs/index-v1.json")
    }

    public func load(days: Int = 0, requireComplete: Bool = false) throws -> [String: Session] {
        isComplete = true
        let saved = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: cache))) ?? [:]
        var updated = [String: Entry](), result = [String: Session]()
        let cutoff = days == 0 ? 0 : Date().timeIntervalSince1970 - Double(days) * 86400
        let directories: [URL]
        do { directories = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        for directory in directories {
            guard let isDirectory = try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                isComplete = false
                if requireComplete { throw CCSError.message("Could not inspect every saved project; folders were kept.") }
                continue
            }
            guard isDirectory else { continue }
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                isComplete = false
                if requireComplete { throw CCSError.message("Could not read every saved project; folders were kept.") }
                continue
            }
            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let date = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? NSNumber else {
                    isComplete = false
                    if requireComplete { throw CCSError.message("Could not inspect every saved transcript; folders were kept.") }
                    continue
                }
                let stamp = date.timeIntervalSince1970
                if stamp < cutoff {
                    updated[file.path] = saved[file.path]
                    continue
                }
                let entry: Entry
                if let old = saved[file.path], old.version == 3, old.modified == stamp, old.size == size.uint64Value {
                    entry = old
                } else {
                    guard var scanned = try? Self.scanMetadata(file) else {
                        isComplete = false
                        if requireComplete { throw CCSError.message("Could not read every saved transcript; folders were kept.") }
                        continue
                    }
                    scanned.session.mtime = stamp
                    entry = Entry(complete: scanned.complete, size: size.uint64Value, modified: stamp, session: scanned.session)
                }
                if !entry.complete {
                    isComplete = false
                    if requireComplete { throw CCSError.message("Saved transcript metadata is incomplete; folders were kept.") }
                }
                updated[file.path] = entry
                if !entry.session.cwd.isEmpty { result[entry.session.id] = entry.session }
            }
        }
        // Cache failure must not block browsing. Atomic replacement prevents partial JSON.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(updated) {
            let folder = cache.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                if (try? Data(contentsOf: cache)) != data {
                    try data.write(to: cache, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
                }
            } catch { /* Cache is optional. */ }
        }
        return result
    }

    public static func scan(_ url: URL) throws -> Session { try scanMetadata(url).session }

    private static func scanMetadata(_ url: URL) throws -> (session: Session, complete: Bool) {
        guard let file = fopen(url.path, "r") else { throw CocoaError(.fileReadNoPermission) }
        defer { fclose(file) }
        var line: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(line) }
        var s = Session(id: url.deletingPathExtension().lastPathComponent, cwd: "")
        var custom = "", ai = "", excerpts = [String](), excerptSize = 0, complete = true
        while true {
            let count = getline(&line, &capacity, file)
            if count < 0 { break }
            guard let line else { continue }
            // Ignore large tool/assistant records before JSON decoding. Metadata
            // and user records have a type near the beginning of their line.
            let prefix = String(decoding: UnsafeRawBufferPointer(start: line, count: min(count, 512)), as: UTF8.self)
            let relevant = s.cwd.isEmpty || !prefix.contains("\"type\"") || ["custom-title", "ai-title", "agent-name", "last-prompt", "cost-state", "away_summary", "\"user\""].contains { prefix.contains($0) }
            guard relevant else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: Data(bytes: line, count: count)) as? [String: Any] else { complete = false; continue }
            if s.cwd.isEmpty { s.cwd = record["cwd"] as? String ?? "" }
            switch record["type"] as? String {
            case "custom-title": custom = cleanText(record["customTitle"]).nonempty ?? custom
            case "ai-title": ai = cleanText(record["aiTitle"]).nonempty ?? ai
            case "agent-name": s.name = cleanText(record["agentName"]).nonempty ?? s.name
            case "last-prompt": s.last = cleanText(record["lastPrompt"]).nonempty ?? s.last
            case "cost-state":
                if let value = record["totalCostUSD"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int.max) {
                    s.cost = value.doubleValue
                }
            case "user" where (record["isMeta"] as? Bool) != true && (record["isCompactSummary"] as? Bool) != true:
                let message = record["message"] as? [String: Any]
                let content = message?["content"]
                let text = content as? String ?? (content as? [[String: Any]])?.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                let prompt = cleanText(text)
                if !prompt.isEmpty && !prompt.hasPrefix("<") {
                    s.turns += 1; s.last = prompt
                    if excerptSize < 4000 {
                        let excerpt = prefixScalars(prompt, min(300, 4000 - excerptSize))
                        excerpts.append(excerpt); excerptSize += excerpt.unicodeScalars.count + 1
                    }
                }
            default: break
            }
            if record["subtype"] as? String == "away_summary" { s.recap = cleanText(record["content"]).nonempty ?? s.recap }
        }
        if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
        s.title = custom.nonempty ?? ai.nonempty ?? excerpts.first ?? ""
        s.prompts = prefixScalars(excerpts.joined(separator: " "), 4000)
        return (s, complete && s.cwd.hasPrefix("/"))
    }
}

public func cleanText(_ value: Any?) -> String {
    guard let text = value as? String else { return "" }
    let visible = text.unicodeScalars.filter { scalar in
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned: return false
        default: return true
        }
    }
    return String(String.UnicodeScalarView(visible)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func prefixScalars(_ text: String, _ count: Int) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(count)))
}

extension String { var nonempty: String? { isEmpty ? nil : self } }
