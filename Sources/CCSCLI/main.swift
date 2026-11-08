import CCSCore
import Foundation
import Darwin

func openGUI(provider: ProviderFilter?) throws {
    var args = [try AppInstallation.findApp().path]
    if let provider { args += ["--args", "--provider", provider.rawValue] }
    let result = try ProcessRunner().run("/usr/bin/open", args)
    if result.code != 0 { throw CCSError.message(result.err) }
    let info = provider.map { ["provider": $0.rawValue] }
    DistributedNotificationCenter.default().postNotificationName(Product.showNotification, object: nil, userInfo: info, deliverImmediately: true)
}

do {
    let settings = Settings.load().resolvingProviders(environment: ProcessInfo.processInfo.environment)
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()), settings: settings)
    let service = SessionService(), cli = AppInstallation.cli.path
    switch options.action {
    case .help: print(Options.help)
    case .version: print("ccs \(Product.version)")
    case .gui:
        if let filter = options.provider, filter != .all, !settings.enabledProviders.contains(where: { filter.includes($0) }) {
            throw CCSError.message("\(filter.title) is disabled in CCS Settings. Enable it there to show its sessions in the popup.")
        }
        try openGUI(provider: options.provider)
    case .installCLI: print(try CLIInstaller.install(source: AppInstallation.cli).path)
    case .activate(let id): try service.activate(id: id, fresh: options.fresh, provider: options.provider ?? .all,
                                               enabledProviders: options.provider == nil ? settings.enabledProviders : Provider.allCases)
    case .prune(let folder): try NewSessions(service: service, settings: settings).prune([URL(fileURLWithPath: CCSPaths.expand(folder))])
    case .new:
        let explicit = options.provider.flatMap { Provider(rawValue: $0.rawValue) }
        print(try NewSessions(service: service, settings: settings).start(cliPath: cli, provider: explicit).path)
    case .json:
        let scope = options.provider ?? .claude
        let sessions = try service.collect(days: options.days, provider: scope)
        if service.historyFailures.contains(where: { scope.includes($0) }) {
            throw CCSError.message("Could not export complete session history. " + service.issues.filter { scope.includes($0.key) }.map(\.value).joined(separator: " "))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try scope == .claude ? encoder.encode(sessions.map { ExportSession($0, home: CCSPaths.home) }) : encoder.encode(sessions.map { CombinedExportSession($0, home: CCSPaths.home) })
        print(String(decoding: data, as: UTF8.self))
    case .list:
        let enabled = options.provider == nil ? settings.enabledProviders : Provider.allCases
        for row in sessionRows(try service.collect(days: options.days, provider: options.provider ?? .all, enabledProviders: enabled), query: "", recent: options.recent) {
            let indent = String(repeating: "  ", count: row.depth)
            if let s = row.session {
                let mark = s.isSaved ? "○" : s.status == "unknown" ? "?" : "●"
                print("\(indent)\(mark) [\(s.provider.title)] \(s.displayTitle)\(options.recent ? "  " + shortPath(s.cwd) : "")  \(s.statistics)  \(ageString(s.mtime))")
            } else { print(indent + row.label) }
        }
    case .picker:
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
            throw CCSError.message("The picker needs a terminal. Use --list, --json, or --gui.")
        }
        if Settings.load().needsProviderSetup && !settings.needsProviderSetup { try settings.save() }
        try TerminalPicker(service: service, settings: settings, days: options.days, recent: options.recent, watch: options.watch, cliPath: cli, provider: options.provider ?? settings.providerFilter,
                           enabledProviders: options.provider == nil ? settings.enabledProviders : Provider.allCases).run()
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(error is CLIUsageError ? 2 : 1)
}
