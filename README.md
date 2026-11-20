# CCS

CCS brings your Claude Code and Codex sessions into one macOS picker. Press
**Option-Space** to pick up a conversation where you left off, whether its
Terminal tab is still open or you closed it yesterday. The optional floating
unicorn lets you see which session needs you while you work in another app.

## Common uses

- **Resume yesterday’s work.** Search by topic or project folder and press **Return** to focus the existing Terminal tab or reopen a saved session.
- **Switch between running sessions.** Hold **Option**, tap **Tab** to cycle through active tabs, then release **Option** to jump to the selected one.
- **Answer a waiting session.** Enable **Settings → Floating unicorn → Show unicorn**. The firefly marks unread updates. Right-click the unicorn to see **Needs attention** at the top, then select the session.
- **Find a report when you forget which chat it came from.** Type part of its filename in the picker. The file results show matching documents and their project folders. Select a file and press **Return** to open it.
- **Start fresh.** In the picker, press **Shift-Return** to start a new conversation in the selected session’s folder, or **⌘N** to start in a new dated folder.

Requires macOS 14 or later, Terminal.app, and at least one installed command,
`claude` or `codex`. The native app and the `ccs` terminal picker share the same session history.

## Install

Download the [signed, notarized universal DMG](https://github.com/alexamber/ccs/releases/download/v1.3.1/CCS-1.3.1-macos-universal.dmg),
drag CCS into Applications, and open it. Choose **Install Command-Line Tool** in
the CCS menu to install the terminal picker too. Both Apple Silicon and Intel
executables are included.

Or install both the app and CLI with Homebrew:

```sh
brew tap alexamber/ccs https://github.com/alexamber/ccs.git
brew install --cask alexamber/ccs/ccs
```

If the old formula is installed, uninstall it with
`brew uninstall --formula alexamber/ccs/ccs` before installing the cask.

To build from this checkout, with Xcode 15 or newer installed:

```sh
bash scripts/build-app.sh --development
bash scripts/install-native.sh
open ~/Applications/CCS.app
```

This builds a universal Apple Silicon/Intel app plus a DMG and ZIP in `dist/`.
Development artifacts are ad-hoc signed and are not notarized public downloads.
The local installer installs `~/Applications/CCS.app` and links `~/.local/bin/ccs`.
It backs up an existing app and command before replacing them. If needed, add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.

## Use

Press **Option-Space** to open the native picker. Type to search, use the arrow
keys to select, and press Enter to focus, attach, or resume a session. Click to
select a row or double-click to open it.

| Shortcut | Action |
| --- | --- |
| Option-Tab / Option-Shift-Tab | Cycle active Terminal sessions; release Option to focus |
| Option-Space while open, or Cmd-N | New dated session using the remembered provider |
| Cmd-Shift-N | Choose the provider for new sessions |
| Cmd-1 / Cmd-2 / Cmd-3 | All / Claude / Codex filter |
| Shift-Enter | Start clean using the selected row’s provider and folder |
| Tab / Shift-Tab | Move between controls |
| Control-Tab | Toggle Recent / Folders |
| Cmd-Left / Cmd-Right | Change the date range |
| Cmd-R | Refresh |
| Escape | Close, or cancel the large-session dialog |
| Cmd-comma | Settings |
| Cmd-/ or Shortcuts | Show all picker shortcuts |

The popup opens on the screen containing the pointer, follows system appearance,
and refreshes every five seconds while visible. Click outside or press Escape to
dismiss the picker or menu. CCS stays in the menu bar;
launch at login is optional and off by default. Quit CCS to release its shortcut.
If Hammerspoon still has the old CCS shortcut, remove its `require("ccs").start()`
line and reload Hammerspoon, or choose another shortcut in CCS Settings.

macOS requests Automation permission when CCS first controls Terminal. Allow it
in System Settings → Privacy & Security → Automation. Browsing does not require
Terminal automation. Missing commands are reported before creating a dated folder.
Claude resume is disabled when its live status cannot be verified.

## Terminal session labels

Opening or focusing a session through CCS sets its native Terminal tab title to
the saved session topic. Untitled sessions use the folder name; new and fresh
sessions start with the folder name. Titles update on the next CCS open/focus
action, which also replaces any title you set by hand. Naming failures do not
block a successful launch or focus. Browsing, exports, and picker refreshes do
not rename tabs.

Enable Settings → **Floating unicorn → Show unicorn** for persistent access to
active work. Choose **Small**, **Medium** (default), or **Large** beside **Show unicorn**.
The unicorn and its notification firefly scale together. While Terminal is focused, hover over the compact icon to reveal the
selected session's name; moving away collapses it. Tab switches and desktop changes
do not announce names automatically. Click the icon or name to open files for that
identified Terminal session, with its folder, provider, and status. Outside Terminal,
hover shows no session name and left-click does nothing. The expanded selector
takes keyboard focus; clicking away, Escape, or opening a file collapses it.
Moving the pointer away does not close a file selector opened by clicking.
The unicorn stays visible during a smooth 180 ms size-and-corner transition.
The expanded view fits up to five file rows, scrolling for more. The small bubble
remains available across apps and, by default, all desktops. Turn off **Show on
every desktop** to keep it on one Space. Drag the unicorn to move it; CCS remembers
its position and keeps it within a connected display. A monochrome unicorn also
identifies CCS in the menu bar.
**Open session picker…** opens its files in the full picker. The unicorn is off by default and requires CCS to remain
running in the menu bar. It uses the existing Terminal Automation permission;
Accessibility permission is not needed.

Right-click the unicorn (or Control-click), from any app, for active Terminal sessions, ordered
by **Needs attention**, **Working**, **Ready**, and **Status unavailable**, newest
activity first within each group. Claude recency combines known history timestamps
with observed live-state changes. Selecting a row validates and focuses its tab;
it never starts a replacement session. Compact rows show colored status dots and
text labels, with up to twelve sessions visible and scrolling for the rest. Recent
snapshots appear immediately while a fresh read runs; quick reopenings reuse the
same read. Start typing in **Filter active sessions** to match names, folders,
providers, or status words such as “working” or “input.” Down moves into the list;
Return opens the selected session. Escape clears a filter first, then closes the
menu. Filtering preserves the status/recency order. Once you navigate or move into
the list, refreshes update statuses in
place. Use the refresh control to apply a changed order or show newly found rows.

Optional updates use a read-only Codex daemon event connection and managed Claude
hooks. They remain active across apps and desktops. Events update confirmed
sessions without waiting for the full status scan. Five-second status checks remain
as recovery when events are unavailable; these can take longer if a provider is
slow. Neither path enumerates history or scans report folders. Codex reads only
metadata and the latest turn's ID/status, excluding message and tool contents.

Each event appears in a separate speech bubble pointing at the unicorn, with the
event and session name. Each bubble shows for five seconds and pauses while hovered.
A short grasshopper chirp plays once per delivered update. To mute it, turn off
**Settings → Floating unicorn → Play notification sound**.
Pending attention requests appear before queued completions, in arrival order within each group. Clicking the speech bubble opens that session; the icon
keeps its normal behavior. Opening a menu, dragging, or browsing files pauses delivery
instead of dropping notices. Visiting an identified session in foreground Terminal
for one second acknowledges its updates and skips queued notices for it, however you
switched there. Resolved waiting notices are removed; later completions remain.
Opening the active-session list alone does not acknowledge anything. A firefly with
a bright yellow tail perches on the unicorn launcher's lower-left rim while updates are unread.
Right-click the unicorn to review them. Attention status remains until the provider resolves it,
even after its notification has been read.

**Finished working** reports a completed turn or an observed working-to-idle
transition when turn metadata is unavailable. It does not guarantee task success.
Startup and unchanged states stay quiet. Unknown or unconfirmed tabs cannot
produce reliable conversation-specific notifications or acknowledgments.

Settings independently control attention and completion updates, the text bubble,
the sound, and the wiggle. Reduce Motion suppresses the wiggle. Turning off both update types
mutes alerts and clears queued notices while live status continues to update.
Turning alerts back on does not replay changes observed while muted. Disable the
unicorn to stop automatic status checks and event listening.
CCS adds only its own command hooks to Claude's settings and removes those hooks
when the Claude provider or the unicorn is disabled, preserving other hooks and
settings. Hook payloads contain only session identity, folder, event, and time;
they never forward messages or tool inputs. Existing Claude sessions may need to
reload hook configuration. CCS presents these alerts locally without requesting
macOS notification permission.

While enabled, CCS checks the selected tab about every quarter-second only while
Terminal is frontmost. It reuses session metadata for up to ten seconds, with
a fresh process check on each tab/topic change and a metadata refresh on a miss.
Unmatched tabs are retried at five-second intervals while Terminal is frontmost.
Unknown or ambiguous tabs produce no popup. Claude sessions can be started outside
CCS. Codex labels require a recognized interactive client and exactly one live
conversation matching its folder and native tab title. If the client was launched
with `resume ID`, that ID must agree too; launch arguments alone are not proof of
the current conversation. Sessions selected through `codex resume` without an ID
use the same title and folder checks. Renamed tabs, conflicting IDs, unsupported launch options,
or unavailable metadata can prevent a label. Switching quickly can skip intermediate
tabs. Popups never rename tabs or open a session.

**Option-Tab** opens a compact switcher of existing Terminal tabs across enabled
providers. Recognized Codex clients without a confirmed conversation appear as
**Codex tab**, with their terminal identifier and “Conversation unconfirmed.”
These rows focus the existing client without renaming it or guessing its files.
The switcher reuses its recent list and reads only the current Terminal tab before
showing the first selection. That highlight already includes the opening Tab press;
refreshes never move it or reorder rows during a gesture. The chosen tab is validated
before focus. Session labels refresh separately, so newly started conversations may
appear on the next opening. A cold start still needs the initial tab enumeration. Hold Option and tap Tab to
cycle, add Shift to move backward, and release Option to focus the highlighted tab.
Escape cancels. Each confirmed conversation appears once, even if multiple tabs share its
session ID; different conversations in the same folder remain separate. Unconfirmed
clients appear individually until CCS can identify them. This view does not scan folders or show artifacts; Option-Space
opens the full picker with files. CCS remembers recently chosen sessions for quick switching back. Each
focus rechecks the tab; an ended session is never resumed by this shortcut. These
shortcuts use native hotkey registration and need no Accessibility permission.

## Nearby reports and documents

The native picker shows **Files in this folder** beside the selected session.
Move through sessions to browse their files; press Right to enter the file list,
Return to open a file, and Left to return to sessions. Clicks open files in their
default app. The sidebar also has a file-name filter. In the sidebar and expanded
bubble, click the folder icon beside the path to open the workspace in Finder.

The picker's main **Search sessions and files** field also finds artifacts by
filename and path across known session folders. File results appear on the right
with their parent folder, even when no conversation title matches. This search
uses all session dates and respects the provider filter; shared folders and files
are deduplicated. Right moves into file results; Down also enters files when no
session matches. Return opens the selected file when no session matches. ⌘F
returns to the main search. File rows keep their positions once you interact
with them, while new matches arrive. Clearing the query restores the selected folder's files.
Use ⌘R to refresh discovery. Document contents are not searched.

Cross-folder discovery runs only during an explicit search, one folder at a time,
and stops when the picker closes or its scope changes. Typing reuses discovered
metadata. Existing protected-folder and scan limits still apply; skipped/limited
folders are indicated. Each search holds at most 10,000 discovered files and shows
up to 200 matches, with a notice when results are limited.

Files are discovered automatically in the session folder and two levels of
subfolders. HTML, PDF, Markdown, text, Office documents, and CSV are supported.
Recent files, report-like names, and files opened through CCS rank higher.
Sessions in the same folder share the list; it does not claim which session wrote
a file. Updates to a report keep the same path and open its latest contents.

Discovery skips hidden folders, symlinks, app packages, common source/build/cache
folders, and housekeeping files such as README and AGENTS. Scans are bounded and
run only when a file list is requested or visible; the visible list refreshes
about every five seconds. CCS reads file metadata, not document contents. Opening
history is stored locally in `~/.cache/ccs/artifact-usage-v1.json`. This first version
does not discover references outside the session folder.

Automatic discovery does not scan the home directory or its parent directories,
privacy-protected folders (Desktop, Documents, Downloads, Library, Pictures, Music,
Movies), system folders, or external/network volumes. These roots are rejected
before enumeration; protected subdirectories are skipped before metadata reads.
This avoids discovery-triggered access prompts for these known locations; custom
mounts and other macOS-protected locations may still require permission. Reports in ordinary
project folders, such as `~/git` and `~/ccs-sessions`, remain available.

Terminal's profile controls whether process names accompany a custom title.
To display just the title, turn off **Show other items when there is a custom
title** under Terminal → Settings → Profiles → Tab.

## Choose providers

On first launch CCS detects commands on your shell PATH. A Codex-only installation
starts in Codex mode; a Claude-only installation starts in Claude mode. With both
installed, both are enabled. Settings → **Providers** lets you enable Claude,
Codex, or both. Explicit choices are saved and are not changed when another tool
is installed later. Restart CCS after changing shell PATH.

With one provider enabled, the provider filter is hidden and new sessions use
that provider. With both enabled, the picker has an **All / Claude / Codex**
filter and a **New: Claude / Codex** selector. Filtering the list does not change
the new-session provider. The selector and Settings → **New sessions** share the
same preference. Shift-Enter always uses the selected row’s provider.

Two distinct Option-Space presses register immediately, including rapid taps.
Holding the shortcut suppresses auto-repeat. Further presses are ignored while a
new-session launch is already pending.

Codex history uses the local app-server metadata API. Main CLI/editor/app-server
conversations appear; archived chats and subagents are hidden. Search covers the
title, folder and opening prompt. Unknown prompt counts and dollar totals are
omitted. Integration was verified with Codex CLI 0.167.0.

When available, CCS reads live status from the existing local Codex daemon. If it
can only read saved metadata, rows show unknown live status. Enter focuses a
matched live Terminal tab or resumes a conversation confirmed as saved. An idle
conversation may stay loaded after its tab closes: CCS can reopen it after a
successful tab scan finds neither a matching tab nor an unidentified Codex client.
Working conversations, ambiguous tabs, and failed status checks still block an
automatic reopen. Use Option-Tab for an unconfirmed open client, or
resume it directly in Codex. A new view does not submit a prompt. Codex desktop-window focus
is outside this release. CCS never resumes threads or starts model turns merely
to list history. See the [official app-server documentation](https://learn.chatgpt.com/docs/app-server).

In the native picker, colored dots require a confirmed open Terminal tab. A hollow
circle means no tab was confirmed; a question mark means tab status is unavailable.
Native session indicators use yellow for working, green for ready, and purple for
attention. The open unicorn session menu receives status changes as they arrive,
without moving rows while you are interacting with it.
The picker checks tabs during its five-second refresh while open, and checks
again when opening a conversation. Codex’s loaded status alone never turns a
native picker row green.

## Terminal CLI

A download includes the CLI inside the app. Choose **Install Command-Line Tool**
in CCS's menu to install it into `~/.local/bin`. Homebrew installations link the
command into Homebrew's `bin` directory.

```sh
ccs                    # terminal folder tree, last 7 days
ccs --recent           # newest first
ccs --days 0           # all saved sessions
ccs --watch            # stay open; refresh every 5 seconds
ccs --watch 10 --recent
ccs --days 30 --list    # plain text
ccs --json             # compatible Claude-only JSON
ccs --provider all --json    # combined JSON with provider and qualified key
ccs --provider codex         # Codex terminal picker
ccs --provider claude --list # one-command override of saved providers
ccs --gui              # show the native popup
ccs --new              # remembered provider, new dated folder
ccs --provider codex --new   # one Codex launch; keeps your app preferences
ccs --activate ID      # focus, attach, or resume
ccs --activate ID --fresh
ccs --activate codex:ID # provider-qualified ID avoids ambiguity
```

| Terminal key | Action |
| --- | --- |
| Up / Down, Page Up / Page Down, Home / End | Select a session |
| Enter | Focus, attach, or resume |
| Ctrl-O | Start clean in the selected folder |
| Ctrl-T | New dated session with the displayed new-session provider |
| Ctrl-F | Cycle provider filter |
| Ctrl-B | Change the remembered new-session provider |
| Tab | Toggle folders / recent |
| Left / Right | Change date range |
| Type / Backspace / Escape | Search / delete / clear |
| Ctrl-R / Ctrl-C | Refresh / quit |

`--provider` overrides saved providers for terminal queries and launches without
changing app preferences. With `--gui`, it selects the popup’s saved filter; that
provider must be enabled in Settings → Providers. Bare
`--json` keeps its original Claude-only fields, including explicit nulls and no
provider field. Combined JSON adds `provider` and `key` (`codex:ID` / `claude:ID`);
unavailable Codex counts and costs are null. An ID shared by both providers must
be qualified when activating it. Incomplete history exports fail explicitly.

Green means idle, orange means another live status, a hollow circle means saved,
and a question mark means live status is unavailable. For Codex, saved status
describes the connected daemon, not every possible client. Closed Claude sessions with at
least 20 prompts or $20 recorded cost offer **Start clean here** or **Resume**.
Recorded cost is saved metadata, not a subscription bill or a price prediction.
Explicit CLI actions do not show that confirmation dialog.

## New sessions and settings

New sessions use folders such as `~/ccs-sessions/2026-11-08-1`. The counter is
locked across concurrent launches and retains its high-water mark after cleanup.
Choose another base folder in Settings, or override it in your shell:

```sh
export CCS_NEW_DIR=~/mind/ccs
```

Restart CCS after changing shell settings. CCS reads PATH, `CCS_NEW_DIR`, and
`CODEX_HOME` from your login shell at startup. Settings are shared with the CLI in
`~/.config/ccs/settings.json`.

When Claude or Codex exits, the bundled CLI removes the folder only if it is empty, no
saved session names it, and no process is using it. Another launch also checks
abandoned folders older than five minutes. Cleanup keeps symlinks, other folder
names, nonempty folders, saved-session folders, and folders whose safety cannot
be verified. Cleanup checks saved folders from both providers, including archived
Codex chats and subagents, even when hidden from the picker. If a required history
source is unavailable, folders are kept. Cleanup uses a fresh process snapshot;
macOS cannot atomically prevent an unrelated process entering a folder between
that check and removal. Disable cleanup in Settings if you need to retain all folders.

Claude transcripts remain under `~/.claude/projects`; Codex retains its own data
under `CODEX_HOME` (normally `~/.codex`). The Claude metadata cache in
`~/.cache/ccs/index-v1.json` contains titles, recaps, and prompt excerpts, with
private file permissions. It may be deleted to rebuild it. Session data is not
uploaded by CCS.

## Distribution

The alternative source Homebrew formula builds the native app and CLI locally:

```sh
brew tap alexamber/ccs https://github.com/alexamber/ccs.git
brew install --HEAD alexamber/ccs/ccs
```

The source formula requires Xcode. The release cask installs both the app and CLI
from the signed universal DMG without a compiler dependency. Its checksum is
generated from the notarized artifact.

See [release and signing instructions](docs/releasing.md) and the
[architecture guide](docs/architecture.md). CCS uses direct distribution to retain
Terminal integration and process-aware cleanup. There is an optional HTTPS
tip-link slot in the build; no payment page
or paid features are configured.

## Development

```sh
swift test
bash scripts/build-app.sh --development
python3 scripts/check-native.py build/CCS.app/Contents/MacOS/ccs
```

The developer-only smoke script checks the packaged CLI, installation, cleanup
with a real process, and terminal interaction. Python is used only for this test
harness. The retired Python/Hammerspoon implementation and sandbox experiment
are available in Git history.

[MIT license](LICENSE).
