import Foundation

public struct SessionArtifact: Equatable {
    public let url: URL
    public let relativePath: String
    public let modifiedAt: Date
    public let openCount: Int
    public var name: String { url.lastPathComponent }
    public var kind: String { url.pathExtension.uppercased() }
    public init(url: URL, relativePath: String, modifiedAt: Date, openCount: Int = 0) {
        self.url = url; self.relativePath = relativePath; self.modifiedAt = modifiedAt; self.openCount = openCount
    }
}

public struct ArtifactSnapshot {
    public let files: [SessionArtifact]
    public let issue: String?
    public init(files: [SessionArtifact] = [], issue: String? = nil) { self.files = files; self.issue = issue }
}

/// Metadata-only discovery: no file contents, symlink traversal, or filesystem watcher.
/// Instances are owned by one serial queue, including their small usage ledger.
public final class ArtifactIndex {
    private struct Usage: Codable { var count: Int; var openedAt: Date }
    private let usageURL: URL
    private let home: String
    private var usage: [String: Usage]
    private let fm = FileManager.default
    private static let types = Set(["html", "htm", "pdf", "md", "markdown", "txt", "rtf", "docx", "pptx", "xlsx", "csv"])
    private static let ignoredDirectories = Set(["node_modules", "vendor", "build", "dist", "target", "venv", "env", "__pycache__", "src", "sources", "tests", "test", "bin", "obj", "packages", "assets", "coverage"])
    private static let housekeeping = Set(["readme", "agents", "skill", "license", "licence", "changelog", "contributing", "code_of_conduct", "security", "package-lock"])
    private static let protectedNames = Set(["desktop", "documents", "downloads", "library", "movies", "music", "pictures"])

    public init(usageURL: URL = URL(fileURLWithPath: CCSPaths.home).appendingPathComponent(".cache/ccs/artifact-usage-v1.json"), home: String = CCSPaths.home) {
        self.usageURL = usageURL
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path.lowercased()
        usage = (try? JSONDecoder().decode([String: Usage].self, from: Data(contentsOf: usageURL))) ?? [:]
    }

    // Check before enumerating or requesting metadata. Permission checks such as
    // isReadableFile do not prevent macOS from displaying folder-access prompts.
    private func excludedRoot(_ path: String) -> String? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        if path == home || home.hasPrefix(path + "/") || path == "/" {
            return "Select a project folder to see files. Home folders are not scanned."
        }
        let excluded = Self.protectedNames.map { home + "/" + $0 } + ["/volumes", "/network", "/library", "/system"]
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Automatic file discovery skips protected and external folders."
        }
        return nil
    }

    public func scan(folder: String, now: Date = Date(), entryLimit: Int = 2500, timeLimit: TimeInterval = 1) -> ArtifactSnapshot {
        guard folder.hasPrefix("/"), folder != "/" else { return ArtifactSnapshot(issue: "Choose a session with a project folder.") }
        if let reason = excludedRoot(folder) { return ArtifactSnapshot(issue: reason) }
        // Keep realpath's spelling: standardizedFileURL rewrites /private/var to
        // /var, while FileManager's enumerator returns /private/var children.
        let root = URL(fileURLWithPath: physicalPath(folder), isDirectory: true)
        if let reason = excludedRoot(root.path) { return ArtifactSnapshot(issue: reason) }
        guard root.path != "/" else { return ArtifactSnapshot(issue: "Choose a session with a project folder.") }
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true,
              fm.isReadableFile(atPath: root.path) else { return ArtifactSnapshot(issue: "This folder is unavailable.") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey]
        var encounteredError = false
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in encounteredError = true; return true }) else {
            return ArtifactSnapshot(issue: "Couldn’t read this folder.")
        }
        let prefix = root.path + "/", deadline = Date().addingTimeInterval(timeLimit)
        var files = [SessionArtifact](), inspected = 0, limited = false
        while let url = entries.nextObject() as? URL {
            inspected += 1
            if inspected > entryLimit || Date() > deadline { limited = true; break }
            if Self.protectedNames.contains(url.lastPathComponent.lowercased()) || excludedRoot(url.path) != nil {
                entries.skipDescendants(); continue
            }
            guard url.path.hasPrefix(prefix), let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let relative = String(url.path.dropFirst(prefix.count)), parts = relative.split(separator: "/")
            if values.isSymbolicLink == true || values.isPackage == true { entries.skipDescendants(); continue }
            if values.isDirectory == true {
                if parts.count >= 3 || Self.ignoredDirectories.contains(url.lastPathComponent.lowercased()) { entries.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, Self.types.contains(url.pathExtension.lowercased()),
                  !Self.housekeeping.contains(url.deletingPathExtension().lastPathComponent.lowercased()) else { continue }
            files.append(SessionArtifact(url: url, relativePath: relative, modifiedAt: values.contentModificationDate ?? .distantPast,
                                         openCount: usage[url.path]?.count ?? 0))
        }
        func score(_ file: SessionArtifact) -> Int {
            let age = max(0, now.timeIntervalSince(file.modifiedAt))
            let recent = age < 86400 ? 12 : age < 7 * 86400 ? 8 : age < 30 * 86400 ? 4 : 0
            let used = usage[file.url.path].map { now.timeIntervalSince($0.openedAt) < 30 * 86400 ? min($0.count, 4) * 2 : 0 } ?? 0
            let report = ["report", "summary", "analysis", "plan", "cheatsheet"].contains { file.relativePath.localizedCaseInsensitiveContains($0) } ? 3 : 0
            return recent + used + report + (["HTML", "HTM", "PDF"].contains(file.kind) ? 2 : 0)
        }
        files.sort {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return ArtifactSnapshot(files: Array(files.prefix(100)), issue: limited || files.count > 100 ? "Large folder: showing files from a limited scan." : encounteredError ? "Some subfolders could not be read." : nil)
    }

    public func recordOpen(_ file: SessionArtifact, now: Date = Date()) {
        usage[file.url.path] = Usage(count: min(1000, (usage[file.url.path]?.count ?? 0) + 1), openedAt: now)
        if usage.count > 1000 {
            usage = Dictionary(uniqueKeysWithValues: usage.sorted { $0.value.openedAt > $1.value.openedAt }.prefix(1000).map { ($0.key, $0.value) })
        }
        // Remembering usage is optional; failure must not prevent opening a file.
        do {
            try fm.createDirectory(at: usageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(usage).write(to: usageURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usageURL.path)
        } catch {}
    }
}
