import Foundation
import CCSCore

struct CLIUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Options {
    enum Action {
        case picker, help, version, gui, installCLI, activate(String), prune(String), new, json, list
    }
    var action: Action = .picker
    var days: Int
    var recent = false, fresh = false
    var watch = 0
    static let help = """
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
  --install-cli      Install ccs into ~/.local/bin (backs up an existing command)
  --version          Print version
  -h, --help         Show this help

Picker: Enter opens; Ctrl-O starts clean here; Ctrl-T starts in a dated folder;
Tab toggles view; Left/Right changes range; Ctrl-R refreshes; Ctrl-C quits.
"""

    init(arguments: [String], settings: Settings) throws {
        days = settings.defaultDays
        let args = arguments.flatMap { arg -> [String] in
            if let equal = arg.firstIndex(of: "="), ["--days", "--watch", "--activate", "--prune"].contains(String(arg[..<equal])) {
                return [String(arg[..<equal]), String(arg[arg.index(after: equal)...])]
            }
            if arg.hasPrefix("-w"), arg.count > 2, !arg.hasPrefix("--") { return ["-w", String(arg.dropFirst(2))] }
            return [arg]
        }
        var i = 0, hasAction = false
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIUsageError(message: "\(flag) requires a value.") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help": action = .help; return
            case "--version": action = .version; return
            case "--days":
                guard let n = Int(try value(arg)), n >= 0 else { throw CLIUsageError(message: "--days must be zero or greater") }
                days = n
            case "-r", "--recent": recent = true
            case "-w", "--watch":
                watch = 5
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    guard n >= 0 else { throw CLIUsageError(message: "--watch must be zero or greater") }
                    i += 1; watch = n
                }
            case "--fresh": fresh = true
            case "--activate", "--prune", "--new", "--json", "--list", "--gui", "--install-cli":
                guard !hasAction else { throw CLIUsageError(message: "Choose only one action. Use --help for the available commands.") }
                hasAction = true
                switch arg {
                case "--activate": action = .activate(try value(arg))
                case "--prune": action = .prune(try value(arg))
                case "--new": action = .new
                case "--json": action = .json
                case "--list": action = .list
                case "--install-cli": action = .installCLI
                default: action = .gui
                }
            default: throw CLIUsageError(message: "Unknown option: \(arg). Use --help.")
            }
            i += 1
        }
        if fresh {
            guard case .activate = action else { throw CLIUsageError(message: "--fresh requires --activate") }
        }
    }
}
