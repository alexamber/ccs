import Foundation

public struct CLIInstallationStatus {
    public let location: URL?
    public let isOnPath: Bool
}

public enum CLIInstaller {
    public static func status(source: URL, environment: [String: String], home: String = CCSPaths.home) -> CLIInstallationStatus {
        let fm = FileManager.default, resolved = source.resolvingSymlinksInPath().path
        let search = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map {
            URL(fileURLWithPath: $0.isEmpty ? fm.currentDirectoryPath : String($0))
        }
        let pathCommands = search.map { $0.appendingPathComponent("ccs") }.filter { fm.isExecutableFile(atPath: $0.path) }
        let candidates = pathCommands + [URL(fileURLWithPath: home).appendingPathComponent(".local/bin/ccs"),
                                        URL(fileURLWithPath: "/opt/homebrew/bin/ccs"), URL(fileURLWithPath: "/usr/local/bin/ccs")]
        let location = candidates.first { fm.isExecutableFile(atPath: $0.path) && $0.resolvingSymlinksInPath().path == resolved }
        // An earlier, different ccs on PATH shadows this app's command.
        let isOnPath = pathCommands.first?.resolvingSymlinksInPath().path == resolved
        return CLIInstallationStatus(location: location, isOnPath: isOnPath)
    }
    @discardableResult public static func install(source: URL, directory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: source.path) else { throw CCSError.message("The bundled ccs command is missing. Reinstall CCS.app.") }
        let directory = directory ?? URL(fileURLWithPath: CCSPaths.home).appendingPathComponent(".local/bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("ccs")
        if target.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path { return target }
        let exists = fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
        var backup: URL?
        if exists {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory != true || values.isSymbolicLink == true else { throw CCSError.message("\(target.path) is a directory; it was kept.") }
            backup = directory.appendingPathComponent("ccs.backup-\(UInt64(Date().timeIntervalSince1970 * 1_000_000))")
            try fm.moveItem(at: target, to: backup!)
        }
        do { try fm.createSymbolicLink(at: target, withDestinationURL: source) }
        catch { if let backup { try? fm.moveItem(at: backup, to: target) }; throw error }
        return target
    }
}
