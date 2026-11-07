import AppKit
import CCSCore
import Foundation
import Darwin

let help = """
Browse Claude Code sessions in a terminal picker or a native macOS popup.

Usage: ccs [options]
  --days DAYS        Closed-session age limit (0 = all; default: saved setting)
  --list             Print the folder tree and exit
  -r, --recent       Show newest sessions first
  -w, --watch [SEC]  Keep picker open and refresh (default: 5 seconds)
  --json             Export metadata, newest first
  --activate ID      Focus, attach, or resume a session
  --fresh            With --activate: start clean in that folder
  --new              Start Claude in a new dated folder
  --prune FOLDER     Remove only an unused, empty dated folder
  --gui              Open the native popup
  --install-hotkey   Open the native app (replaces Hammerspoon setup)
  --version          Print version
  -h, --help         Show this help

Picker: Enter opens; Ctrl-O starts clean here; Ctrl-T starts in a dated folder;
Tab toggles view; Left/Right changes range; Ctrl-R refreshes; Ctrl-C quits.
"""

func openGUI() throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let embeddedApp = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [embeddedApp, URL(fileURLWithPath: "/Applications/CCS.app"),
                      URL(fileURLWithPath: CCSPaths.home).appendingPathComponent("Applications/CCS.app")]
    guard let app = candidates.first(where: { $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/CCSApp").path) }) else {
        throw CCSError.message("CCS.app was not found. Install the app from a CCS release or with Homebrew.")
    }
    let result = try ProcessRunner().run("/usr/bin/open", [app.path, "--args", "--show"])
    if result.code != 0 { throw CCSError.message(result.err) }
    // Running menu bar apps receive this distributed event instead of a second process.
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.alexamber.ccs.show"), object: nil, userInfo: nil, deliverImmediately: true)
}

do {
    let settings = Settings.load()
    var days = settings.defaultDays, recent = false, watch = 0
    // The CLI historically defaults to folders; GUI uses its own default view.
    var action: String?, id: String?, folder: String?, fresh = false
    let args = CommandLine.arguments.dropFirst().flatMap { arg -> [String] in
        if let equal = arg.firstIndex(of: "="), ["--days", "--watch", "--activate", "--prune"].contains(String(arg[..<equal])) {
            return [String(arg[..<equal]), String(arg[arg.index(after: equal)...])]
        }
        if arg.hasPrefix("-w"), arg.count > 2, !arg.hasPrefix("--") { return ["-w", String(arg.dropFirst(2))] }
        return [arg]
    }
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw CCSError.message("\(flag) requires a value.") }
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help": print(help); exit(0)
        case "--version": print("ccs \(Product.version)"); exit(0)
        case "--days":
            guard let n = Int(try value(arg)), n >= 0 else { throw CCSError.message("--days must be zero or greater") }
            days = n
        case "-r", "--recent": recent = true
        case "-w", "--watch":
            watch = 5
            if i + 1 < args.count, let n = Int(args[i + 1]) { guard n >= 0 else { throw CCSError.message("--watch must be zero or greater") }; i += 1; watch = n }
        case "--fresh": fresh = true
        case "--activate", "--prune", "--new", "--json", "--list", "--gui", "--install-hotkey":
            guard action == nil else { throw CCSError.message("Choose only one action: --activate, --prune, --new, --json, --list, or --gui.") }
            action = arg
            if arg == "--activate" { id = try value(arg) }
            if arg == "--prune" { folder = try value(arg) }
        default: throw CCSError.message("Unknown option: \(arg). Use --help.")
        }
        i += 1
    }
    if fresh && action != "--activate" { throw CCSError.message("--fresh requires --activate") }
    let service = SessionService()
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    switch action {
    case "--gui", "--install-hotkey": try openGUI()
    case "--activate": try service.activate(id: id!, fresh: fresh)
    case "--prune": try NewSessions(service: service, settings: settings).prune([URL(fileURLWithPath: CCSPaths.expand(folder!))])
    case "--new": print(try NewSessions(service: service, settings: settings).start(cliPath: cli).path)
    case "--json":
        let exported = try service.collect(days: days).map { ExportSession($0, home: CCSPaths.home) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(exported), as: UTF8.self))
    case "--list":
        for row in sessionRows(try service.collect(days: days), query: "", recent: recent) {
            let indent = String(repeating: "  ", count: row.depth)
            if let s = row.session {
                let mark = s.status == "closed" ? "○" : s.status == "unknown" ? "?" : "●"
                print("\(indent)\(mark) \(s.displayTitle)\(recent ? "  " + shortPath(s.cwd) : "")  \(s.turns)p  \(ageString(s.mtime))")
            } else { print(indent + row.label) }
        }
    default:
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
            throw CCSError.message("The picker needs a terminal. Use --list, --json, or --gui.")
        }
        try TerminalPicker(service: service, settings: settings, days: days, recent: recent, watch: watch, cliPath: cli).run()
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    // Match argparse's status for invalid options; runtime actions return 1.
    let message = error.localizedDescription
    exit(message.contains("requires") || message.contains("must be") || message.hasPrefix("Unknown option") || message.hasPrefix("Choose only") ? 2 : 1)
}
