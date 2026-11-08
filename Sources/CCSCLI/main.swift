import CCSCore
import Foundation
import Darwin

func openGUI() throws {
    let result = try ProcessRunner().run("/usr/bin/open", [try AppInstallation.findApp().path])
    if result.code != 0 { throw CCSError.message(result.err) }
    DistributedNotificationCenter.default().postNotificationName(Product.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
}

do {
    let settings = Settings.load()
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()), settings: settings)
    let service = SessionService(), cli = AppInstallation.cli.path
    switch options.action {
    case .help: print(Options.help)
    case .version: print("ccs \(Product.version)")
    case .gui: try openGUI()
    case .installCLI: print(try CLIInstaller.install(source: AppInstallation.cli).path)
    case .activate(let id): try service.activate(id: id, fresh: options.fresh)
    case .prune(let folder): try NewSessions(service: service, settings: settings).prune([URL(fileURLWithPath: CCSPaths.expand(folder))])
    case .new: print(try NewSessions(service: service, settings: settings).start(cliPath: cli).path)
    case .json:
        let exported = try service.collect(days: options.days).map { ExportSession($0, home: CCSPaths.home) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(exported), as: UTF8.self))
    case .list:
        for row in sessionRows(try service.collect(days: options.days), query: "", recent: options.recent) {
            let indent = String(repeating: "  ", count: row.depth)
            if let s = row.session {
                let mark = s.status == "closed" ? "○" : s.status == "unknown" ? "?" : "●"
                print("\(indent)\(mark) \(s.displayTitle)\(options.recent ? "  " + shortPath(s.cwd) : "")  \(s.turns)p  \(ageString(s.mtime))")
            } else { print(indent + row.label) }
        }
    case .picker:
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
            throw CCSError.message("The picker needs a terminal. Use --list, --json, or --gui.")
        }
        try TerminalPicker(service: service, settings: settings, days: options.days, recent: options.recent, watch: options.watch, cliPath: cli).run()
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(error is CLIUsageError ? 2 : 1)
}
