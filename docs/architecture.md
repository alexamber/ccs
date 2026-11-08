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
| `Tests/CCSAppTests` | Native focus routing and foreground responsiveness tests |
| `scripts/check-native.py` | Developer-only packaged CLI and real PTY integration checks |
| `scripts` | Build, signing, notarization, local installation and cask generation |
| `Casks` / `Formula` | Download installation / optional local source build |

The app uses separate serial queues and service instances for foreground actions
and history refreshes. Each queue owns its RPC connection; UI callbacks return to
the main queue. Abandoned-folder cleanup runs in a separate CLI helper. The CLI calls the same core directly. Both use the same settings
and metadata cache; neither executable depends on Hammerspoon or Python.

Session metadata comes from Claude's local transcripts. Live status is refreshed
from `claude agents --json`, including immediately before activation. An unknown
live state prevents Claude resume. Existing Terminal tabs are matched by process TTY;
commands are passed as quoted arguments to AppleScript rather than interpolated
into AppleScript source.

Codex history comes from read-only `thread/list` and `thread/read` requests.
`CodexRPCConnection` uses WebSocket framing over the existing daemon’s local Unix
socket, with an owned JSONL metadata process as a fallback. It opens no listening
TCP port. The fallback cannot establish global live state. Metadata reads never
call thread/resume, start turns, or approve server requests. Frames, waits and
pagination are bounded; incomplete metadata cannot authorize folder cleanup.

Session selection uses provider-qualified keys. Existing Claude JSON remains
compatible; explicit combined exports include provider identity and nulls for
unavailable Codex statistics. Settings auto-detect providers until the first
successful setup, then retain explicit enabled-provider and new-provider choices.
The app observes preference changes through distributed notifications. Open terminal
pickers reload saved preferences once a second; an explicit `--provider` keeps its
query scope while new-session preferences continue to update.

New folders use a cross-process lock and a persistent daily high-water counter.
Cleanup requires an empty, correctly named, nonsymlink folder, a complete saved
session index (including cached completeness), and a fresh process working-directory
check after metadata reads. Final identity, age and emptiness checks run under a
nonblocking allocation lock. Unknown state
keeps the folder. Physical paths handle macOS filesystem aliases consistently.

`AppInstallation` centralizes bundle discovery and product metadata;
`CLIInstaller` owns backup, installation and PATH status. Settings and the local
installer use the same implementation. `macOS/Info.plist` is the version source.

`TransientUIDismissal` closes the picker and status menu on outside clicks and
application switches. Outside clicks retain their normal delivery and focus.
Native menu tracking and modal confirmation sheets retain AppKit's behavior.
The Carbon shortcut tracks press/release events rather than suppressing quick
presses with a timer; held-key repeats do not launch repeated sessions.

Releases use Developer ID signing, hardened runtime, Apple-events entitlement,
notarization and stapling. Direct distribution retains the Terminal/process
integration tested during the App Store feasibility investigation. The retired
Python/Hammerspoon implementation and sandbox probe are preserved in Git history.
