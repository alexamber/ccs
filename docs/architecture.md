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

The picker preloads history at startup and retains its latest snapshot in memory.
Reopening immediately displays searchable rows while refreshing in the background;
closing the picker does not discard an in-flight result. Provider changes invalidate
older requests. No periodic history refresh runs while hidden, and activation still checks
current session state before opening it. The first load after launch may take longer.

Session metadata comes from Claude's local transcripts. Live status is refreshed
from `claude agents --json`, including immediately before activation. An unknown
live state prevents Claude resume. Existing Terminal tabs are matched by process TTY;
commands are passed as quoted arguments to AppleScript rather than interpolated
into AppleScript source.

Both executables route terminal operations through `TerminalRegistry`. To support
another macOS terminal, implement `TerminalAdapter` and register it in
`TerminalRegistry.system`. Launch Services discovers installed registered apps by
bundle ID. Registration order determines the automatic launch preference. An
explicit preference is saved by bundle ID. If the chosen terminal is missing,
the launch fails with a message directing the user to Settings.

An adapter provides a complete list of local panes, the selected TTY, the
frontmost pane and its window bounds, and operations to focus a pane or launch a
command. Each snapshot carries its terminal bundle ID, native pane ID and local
TTY. CCS shares one process snapshot across terminals to match conversations.
Option-Tab captures the originating terminal before its chooser takes focus.
Selecting a target revalidates its owner, pane, TTY and conversation or process.
An incomplete inventory blocks automatic resume of an already loaded conversation.

Launch/focus scripts set the selected tab's custom title only when it differs.
The title is a separate argument, and a local AppleScript error handler keeps
cosmetic failures from failing the action. There is no title-ownership cache.

The optional Terminal session popup has a quarter-second timer only while Terminal
is frontmost. A dedicated queue reads the front tab's tty and window bounds with
a bounded AppleScript call. A changed tty or normalized topic title triggers history collection and
process matching on the existing history lane. A full history snapshot can be
reused for ten seconds, with fresh process inspection and a metadata refresh on
a miss. Unmatched tabs retry after five seconds; activity spinners do not trigger
metadata loads. Ambiguous matches are discarded. The last observed tab/topic
survives app deactivation, so returning to the same context restores only the
compact icon. Native Space-change notifications collapse the panel in place.
Tab switches and desktop returns never announce names; only hover reveals them.
Reapplying unchanged popup settings does not reset this identity.
Codex labels require one recognized interactive client on the tty and exactly one
live conversation matching its folder and native title. A launch `resume ID` must
agree with that match; it cannot resolve ambiguous titles or prove current identity.
Remote clients can receive labels only when connected to the local metadata socket.
This remains a conservative heuristic, not a provider-owned tty/thread mapping.
There is at most one tab read and one metadata lookup in flight; generation checks
discard results after a tab/app switch or settings change. A nonactivating
panel stays as a compact persistent unicorn. Hovering it for 120 ms reveals the
name without keyboard focus or file discovery; leaving collapses it immediately.
Clicking expands a searchable file selector and
allows keyboard focus; resigning key collapses it. All phases retain the same
saved draggable anchor (initially near the upper-right of the display). A nonblocking 180 ms AppKit animation interpolates
the frame and corner radius; interrupted transitions begin from the current frame.
The unicorn mark remains visible throughout. The expanded selector fits up to five
file rows and scrolls beyond that. PNG assets use SwiftPM resources in development
and are copied into the signed app's Resources directory when packaging. The menu
bar uses a monochrome template; the bubble uses the color artwork. The feature defaults off and
uses the existing Apple-events permission, with no Accessibility observer.

`SessionActivityCoordinator` owns activity delivery, transition tracking, unread
notices, acknowledgement, and the notification timer. Provider adapters remain
separate: Codex events and Claude hooks feed the same event/poll reconciliation
used by five-second recovery reads. AppDelegate connects native UI callbacks;
the coordinator delivers status and finished-state changes to the overview and session picker.
Alert preferences filter delivery without stopping monitoring or resetting its
baseline. Muting clears queued notices, and unmuting does not replay observed
changes. Disabling the unicorn or changing providers invalidates pending reads
and resets notification state. Combined-flow tests exercise this coordination
through the same interface used by AppDelegate, including delayed polling,
muted transitions, direct Terminal acknowledgement, and provider changes. Events
for unidentified tabs request an identity refresh; they never replay over a newer
status snapshot. Once identified, events are delivered immediately and protect
against older in-flight polling results.

`ArtifactIndex` discovers documents from file metadata within the selected folder
and two subdirectory levels, excluding symlinks, hidden files, packages, common
source/build/cache directories, and housekeeping documents. Each scan stops after
2,500 entries or one second between enumeration steps, and retains up to 100 files.
`ArtifactService` serializes discovery and a local usage ledger, with a five-second,
32-folder cache. No file contents are indexed and no filesystem watcher runs.
`ArtifactSearch` coordinates progressive cross-folder filename/path discovery
through the existing artifact loader. Query edits reuse discovered metadata;
scope changes and dismissal invalidate pending results. The search is bounded to
10,000 discovered files and 200 displayed matches, with partial-result notices.
The browser preserves row positions once the user interacts with search results.

`ArtifactBrowser` shares the list and default-app opening behavior between the
picker sidebar and expanded bubble selector. Selection loads are debounced and
generation-checked; hidden views cancel pending results. Expanded selectors refresh
every five seconds; collapsing or hiding stops that timer. Successful opens update a
bounded local usage ledger, which gives frequently used reports a ranking boost.
Home roots and their ancestors, privacy-protected user folders, system roots,
and mounted/network volumes are rejected before enumeration. The same check runs
after canonicalization; enumeration does not prefetch resource metadata, and
protected child names are skipped before requesting their properties. A readability
check alone is not sufficient to prevent macOS folder-access prompts.

Option-Tab and Option-Shift-Tab have distinct Carbon hotkey IDs. They navigate
the same `SessionOverview` popover and activity snapshot as the unicorn’s context
menu. An on-demand activity refresh also works when the unicorn is disabled.
Before opening the popover, CCS captures the foreground terminal. A dedicated
queue reads its selected TTY and the snapshot maps that TTY to a row, including
alternate viewers of the same conversation. The menu accumulates key presses
until the origin and rows are ready. A gesture in an open menu starts from its
highlight and preserves its filter. Dismissal invalidates pending callbacks.

The menu skips unavailable rows and checks for Option release every 25 ms during
a gesture. On focus, the terminal adapter revalidates the pane and the service
checks the current process and conversation. Apple Terminal inventories include
window IDs so a confirmed target can be addressed by window and TTY using Apple
events. A completed switch requires Terminal to be active, its target window to
be visible, and its front tab to have the expected TTY. During a Space change
the adapter can recheck the session identity and raise its window once more.
A moved tab can be rediscovered in a fresh inventory. The full picker
also retains confirmed pane references and checks live Codex identities before
using them. It falls back to its normal activation flow for stale references.

Unconfirmed interactive Codex clients are represented by tty and PID, without
conversation metadata. Focusing these rows checks that the same recognized process
still owns the tty, preserves the native title, and requires no metadata connection.
Confirmed Codex targets also recheck their process identity before focus.
The regular picker refuses to open an additional viewer for an unmatched live
conversation or unknown live state; only authoritatively saved history can resume.
Confirmed conversations are deduplicated by provider and ID. Unconfirmed clients
remain separate because their conversation identity is unknown.

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
