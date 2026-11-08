# CCS

A native macOS popup and terminal picker for Claude Code sessions. Search saved
sessions, focus an existing Terminal tab, resume a closed conversation, or start
clean in a project or a new dated folder.

CCS requires macOS 14 or later, Terminal.app, and an installed `claude` command.
The Swift app and CLI share one engine. Neither Python nor Hammerspoon is needed.

## Install

Download the [signed, notarized universal DMG](https://github.com/alexamber/ccs/releases/download/v0.2.0/CCS-0.2.0-macos-universal.dmg),
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
keys to select, and press Enter to focus, attach, or resume a session.

| Shortcut | Action |
| --- | --- |
| Option-Space while open, or Cmd-N | New session in a dated folder |
| Shift-Enter | Start clean in the selected session's folder |
| Tab | Toggle Recent / Folders |
| Cmd-Left / Cmd-Right | Change the date range |
| Cmd-R | Refresh |
| Escape | Close, or cancel the large-session dialog |
| Cmd-comma | Settings |

The popup opens on the screen containing the pointer, follows system appearance,
and refreshes every five seconds while visible. Click outside or press Escape to
dismiss the picker or menu. CCS stays in the menu bar;
launch at login is optional and off by default. Quit CCS to release its shortcut.
If Hammerspoon still has the old CCS shortcut, remove its `require("ccs").start()`
line and reload Hammerspoon, or choose another shortcut in CCS Settings.

macOS requests Automation permission when CCS first controls Terminal. Allow it
in System Settings → Privacy & Security → Automation. Browsing does not require
Terminal automation. A missing `claude` command or failed live-status check is
reported; CCS does not resume a session when it cannot verify whether it is open.

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
ccs --json             # metadata as JSON, newest first
ccs --gui              # show the native popup
ccs --new              # new session in a dated folder
ccs --activate ID      # focus, attach, or resume
ccs --activate ID --fresh
```

| Terminal key | Action |
| --- | --- |
| Up / Down, Page Up / Page Down, Home / End | Select a session |
| Enter | Focus, attach, or resume |
| Ctrl-O | Start clean in the selected folder |
| Ctrl-T | New session in a dated folder |
| Tab | Toggle folders / recent |
| Left / Right | Change date range |
| Type / Backspace / Escape | Search / delete / clear |
| Ctrl-R / Ctrl-C | Refresh / quit |

Green means idle, orange means another live status, a hollow circle means closed,
and a question mark means live status is unavailable. Closed sessions with at
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

Restart CCS after changing shell settings. CCS reads its shell PATH and this
override at startup. Settings are shared with the CLI in
`~/.config/ccs/settings.json`.

When Claude exits, the bundled CLI removes the folder only if it is empty, no
saved session names it, and no process is using it. Another launch also checks
abandoned folders older than five minutes. Cleanup keeps symlinks, other folder
names, nonempty folders, saved-session folders, and folders whose safety cannot
be verified. Cleanup can be disabled in Settings.

Transcripts remain under `~/.claude/projects`. The native metadata cache in
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
Terminal integration and process-aware cleanup. Codex session support is outside this first native
release. There is an optional HTTPS tip-link slot in the build; no payment page
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
