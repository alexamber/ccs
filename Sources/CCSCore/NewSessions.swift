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

    @discardableResult public func start(cliPath: String, provider: Provider? = nil) throws -> URL {
        let provider = provider ?? settings.resolvingProviders(environment: environment).newProvider
        guard provider.isInstalled(environment: environment) else {
            throw CCSError.message("The \(provider.command) command was not found. Install \(provider.title), then restart CCS so it reads your updated shell PATH.")
        }
        let root = settings.newRoot(environment: environment)
        let path = try create(root: root)
        let cleanup = settings.cleanup ? "; cd; \(service.codex.cleanupEnvironment) \(shellQuote(cliPath)) --prune \(shellQuote(path.path))" : ""
        do { try service.openTerminal("cd \(shellQuote(path.path)) && \(provider == .codex ? service.codex.launchCommand : provider.command)\(cleanup)") }
        catch { _ = rmdir(path.path); throw error }
        // A separate short-lived helper survives CLI exit and cannot block the
        // launch result or share an app-server connection with foreground work.
        if settings.cleanup {
            let helper = Process(); helper.executableURL = URL(fileURLWithPath: cliPath)
            helper.arguments = ["--prune-stale", root.path]
            helper.environment = environment.merging(["CODEX_HOME": CodexProvider.dataDirectory(environment).path]) { _, value in value }
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try? helper.run()
        }
        return path
    }

    public func prune(_ paths: [URL], minimumAge: Double = 0) throws {
        let cutoff = Date().addingTimeInterval(-minimumAge)
        let candidates = paths.compactMap { path -> (URL, stat)? in
            guard path.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-\d+$"#, options: .regularExpression) != nil,
                  let attrs = try? path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]),
                  attrs.isSymbolicLink != true, attrs.isDirectory == true,
                  let date = attrs.contentModificationDate, date <= cutoff,
                  let contents = try? fm.contentsOfDirectory(atPath: path.path), contents.isEmpty else { return nil }
            var identity = stat()
            guard lstat(path.path, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return (path, identity)
        }
        guard !candidates.isEmpty else { return }
        // Metadata may take seconds. Resolve it before taking a process snapshot.
        let sessions = try service.index.load(requireComplete: true)
        let codex = try service.codex.savedWorkingDirectories()
        let named = Set(sessions.values.map { $0.cwd }).union(codex)
        let saved = named.union(named.map { physicalPath($0) })
        for (path, original) in candidates {
            let absolute = path.standardizedFileURL.path, resolved = physicalPath(path.path)
            guard !saved.contains(absolute), !saved.contains(resolved) else { continue }
            // Refresh immediately before each deletion. A failed or partial listing
            // never authorizes cleanup; macOS has no atomic "rmdir unless cwd" API.
            let result = try service.runner("/usr/sbin/lsof", ["-w", "-d", "cwd", "-Fn"], nil, 10)
            guard result.code == 0 else { continue }
            let busy = Set(result.out.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
            guard !busy.isEmpty, !busy.contains(absolute), !busy.contains(resolved),
                  !busy.contains(where: { physicalPath($0) == resolved }) else { continue }
            // Hold the counter lock only for the final filesystem operations.
            // Cleanup skips contention instead of delaying a foreground launch.
            let lockPath = path.deletingLastPathComponent().appendingPathComponent(".ccs-counter.lock").path
            let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { continue }
            defer { flock(lock, LOCK_UN); close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }
            var after = stat()
            guard lstat(absolute, &after) == 0, original.st_dev == after.st_dev, original.st_ino == after.st_ino,
                  (after.st_mode & S_IFMT) == S_IFDIR,
                  Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec) + Double(after.st_mtimespec.tv_nsec) / 1e9) <= cutoff,
                  (try? fm.contentsOfDirectory(atPath: absolute).isEmpty) == true else { continue }
            // rmdir additionally rejects files created after the emptiness check.
            _ = rmdir(absolute)
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
