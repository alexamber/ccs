import Foundation
import Darwin

public final class NewSessions {
    public let service: SessionService
    public let settings: Settings
    public let environment: [String: String]
    private let fm = FileManager.default
    public init(service: SessionService, settings: Settings = Settings(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.service = service; self.settings = settings; self.environment = environment
    }
    public func create(root: URL? = nil, day: String? = nil) throws -> URL {
        let root = root ?? settings.newRoot(environment: environment)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(".ccs-counter.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CCSError.message("Could not lock the session folder counter.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CCSError.message("Could not lock the session folder counter.") }
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let day = day ?? formatter.string(from: Date())
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CCSError.message("Invalid session date.") }
        // Keep a high-water mark so cleanup never makes a number reusable.
        let counter = root.appendingPathComponent(".ccs-counter.json")
        var counts = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: counter))) ?? [:]
        let taken = files.compactMap { url -> Int? in
            guard url.lastPathComponent.hasPrefix(day + "-") else { return nil }
            return Int(url.lastPathComponent.dropFirst(day.count + 1))
        }.max() ?? 0
        var number = max(taken, counts[day] ?? 0)
        while number < Int.max {
            number += 1
            let folder = root.appendingPathComponent("\(day)-\(number)")
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                counts[day] = number
                do { try JSONEncoder().encode(counts).write(to: counter, options: .atomic) }
                catch { try? fm.removeItem(at: folder); throw error }
                return folder
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw CCSError.message("No session folder numbers remain for today.")
    }

    @discardableResult public func start(cliPath: String) throws -> URL {
        let root = settings.newRoot(environment: environment)
        if settings.cleanup, let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try? prune(files, minimumAge: 300)
        }
        let path = try create(root: root)
        let cleanup = settings.cleanup ? "; cd; \(shellQuote(cliPath)) --prune \(shellQuote(path.path))" : ""
        do { try service.openTerminal("cd \(shellQuote(path.path)) && claude\(cleanup)") }
        catch { _ = rmdir(path.path); throw error }
        return path
    }

    public func prune(_ paths: [URL], minimumAge: Double = 0) throws {
        let cutoff = Date().addingTimeInterval(-minimumAge)
        let candidates = paths.filter { path in
            guard path.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-\d+$"#, options: .regularExpression) != nil,
                  let attrs = try? path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]),
                  attrs.isSymbolicLink != true, attrs.isDirectory == true,
                  let date = attrs.contentModificationDate, date <= cutoff,
                  let contents = try? fm.contentsOfDirectory(atPath: path.path), contents.isEmpty else { return false }
            return true
        }
        guard !candidates.isEmpty else { return }
        let result = try service.runner("/usr/sbin/lsof", ["-w", "-d", "cwd", "-Fn"], nil, 10)
        // A nonzero/partial process listing cannot authorize deletion.
        guard result.code == 0 else { return }
        let busy = Set(result.out.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
        guard !busy.isEmpty else { return }
        let sessions = try service.index.load(requireComplete: true)
        let named = busy.union(sessions.values.map { $0.cwd })
        let used = named.union(named.map { physicalPath($0) })
        for path in candidates {
            let absolute = path.standardizedFileURL.path, resolved = physicalPath(path.path)
            if !used.contains(absolute) && !used.contains(resolved) {
                // rmdir is atomic and fails if files appeared since the check.
                _ = rmdir(absolute)
            }
        }
    }
}

// Foundation can shorten /private/var back to /var while lsof reports the
// physical path. Use POSIX realpath on both sides of a safety comparison.
func physicalPath(_ path: String) -> String {
    guard let value = realpath(path, nil) else { return path }
    defer { free(value) }
    return String(cString: value)
}
