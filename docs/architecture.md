# Architecture

CCS has two native executables and one shared engine. Swift Package Manager
defines the build in `Package.swift`; macOS 14 is the minimum supported version.

| Component | Responsibility |
| --- | --- |
| `Sources/CCSCore` | Session indexing, live status, Terminal activation, dated folders, settings, app discovery and CLI installation |
| `Sources/CCSApp` | AppKit picker, compact Settings, menu bar, global shortcut and transient UI dismissal |
| `Sources/CCSCLI` | Argument parsing, text/JSON commands and terminal picker |
| `Sources/CTerminal` | Small ncurses bridge for terminal input and drawing |
| `macOS` | Bundle metadata, Apple-events entitlement and icon generator |
| `Tests/CCSCoreTests` | Shared-engine regression and safety tests |
| `scripts/check-native.py` | Developer-only packaged CLI and real PTY integration checks |
| `scripts` | Build, signing, notarization, local installation and cask generation |
| `Casks` / `Formula` | Download installation / optional local source build |

The app sends blocking work to one serial engine queue. UI callbacks return to
the main queue. The CLI calls the same core directly. Both use the same settings
and metadata cache; neither executable depends on Hammerspoon or Python.

Session metadata comes from Claude's local transcripts. Live status is refreshed
from `claude agents --json`, including immediately before activation. An unknown
live state prevents resume. Existing Terminal tabs are matched by process TTY;
commands are passed as quoted arguments to AppleScript rather than interpolated
into AppleScript source.

New folders use a cross-process lock and a persistent daily high-water counter.
Cleanup requires an empty, correctly named, nonsymlink folder, a complete saved
session index, and a successful process working-directory check. Unknown state
keeps the folder. Physical paths handle macOS filesystem aliases consistently.

`AppInstallation` centralizes bundle discovery and product metadata;
`CLIInstaller` owns backup, installation and PATH status. Settings and the local
installer use the same implementation. `macOS/Info.plist` is the version source.

`TransientUIDismissal` closes the picker and status menu on outside clicks and
application switches. Outside clicks retain their normal delivery and focus.
Native menu tracking and modal confirmation sheets retain AppKit's behavior.

Releases use Developer ID signing, hardened runtime, Apple-events entitlement,
notarization and stapling. Direct distribution retains the Terminal/process
integration tested during the App Store feasibility investigation. The retired
Python/Hammerspoon implementation and sandbox probe are preserved in Git history.
