# ccs

Find, switch, and resume Claude Code sessions from a searchable terminal tree or
an optional global hotkey popup. Requires macOS, Terminal.app, and Claude Code.

## Install

```sh
brew tap alexamber/ccs https://github.com/alexamber/ccs.git && brew install --HEAD alexamber/ccs/ccs
```

Homebrew installs Python. Run `ccs` to open the picker. Update with
`brew reinstall --HEAD alexamber/ccs/ccs`.

Already have Python 3? The standalone installer needs no sudo:

```sh
curl -fsSL https://raw.githubusercontent.com/alexamber/ccs/main/install.sh | sh
```

It installs to `~/.local/bin`. If needed, add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`. From a checkout, run
`./install.sh` or use `./ccs` directly.

## Use

```sh
ccs                    # folder tree, last 7 days
ccs --recent           # newest first
ccs --days 0           # all saved sessions
ccs --watch            # stay open; refresh every 5 seconds
ccs --watch 10 --recent
ccs --days 30 --list    # plain text
```

| Key | Action |
| --- | --- |
| Up / Down, Page Up / Page Down, Home / End | Select a session |
| Enter | Focus, attach, or resume |
| Ctrl-O | Start a new session in the selected folder |
| Tab | Toggle folders / recent |
| Left / Right | Cycle 1, 3, 7, 30 days, all |
| Type / Backspace / Escape | Search / delete / clear |
| Ctrl-R / Ctrl-C | Refresh / quit |

Green ● means idle, yellow ● means another live status, ○ means closed, and ?
means status is unavailable. Rows show prompts, saved cost, and age; taller
windows also show a recap. Watch mode stays open after Enter.

`ccs` looks for an existing Terminal tab before attaching. Before resuming a
closed session it checks the live list again; if that check fails, it stops.
This reduces accidental duplicate sessions but is not an atomic lock. Other
terminal apps cannot be focused by this version.

For closed sessions with at least 20 prompts or $20 recorded cost, the picker
offers **Start clean here** (default) or **Resume**. Recorded cost is not your
subscription bill; it does not predict the cost of the next prompt.

## Optional hotkey popup

After installing `ccs`, run:

```sh
brew install --cask hammerspoon && ccs --install-hotkey && open -a Hammerspoon
```

In Hammerspoon's menu, choose **Reload Config**, then press **Option-Space**.
Allow macOS permissions when requested. Setup preserves existing config, makes
backups before changes, and avoids duplicate startup entries.

Type to search; Enter opens; Shift-Enter starts clean; Tab toggles folder view;
Cmd-Left / Cmd-Right change the date range; Escape or Option-Space closes.
The popup refreshes every 5 seconds while open and follows the system appearance.

To customize, replace the `ccs` line in `~/.hammerspoon/init.lua`:

```lua
require("ccs").start({ mods = { "cmd", "alt" }, key = "k", days = 30, folders = true })
```

After updating `ccs`, rerun `ccs --install-hotkey` and **Reload Config** to update
the popup. To remove it, delete that startup line and reload Hammerspoon.

## Scripts and data

`ccs --json` exports session metadata, newest first. `ccs --activate ID` focuses,
attaches, or resumes a session; add `--fresh` to start clean in its folder.
These explicit CLI actions do not show the large-session dialog.

Transcripts stay unchanged under `~/.claude/projects`. The local cache at
`~/.cache/ccs-index.json` contains titles, recaps, and prompt excerpts; delete it
to rebuild it. Search in the terminal includes prompt excerpts; the popup
searches the exported titles, names, folders, recaps, and last prompts.

Live discovery requires `claude agents --json`; background attach requires
`claude attach`. If your Claude Code version lacks these, browsing still works,
but resuming is disabled when live status cannot be checked. Date ranges use
transcript modification times and always include known live sessions.

See [native apps, existing alternatives, and Codex support](docs/options.md).
Tests: `python3 -m unittest discover -s tests -v` and `node --test tests/test_hotkey.mjs`.

[MIT license](LICENSE).
