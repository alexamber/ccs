# ccs

Browse Claude Code sessions in a searchable terminal directory tree. Press Enter
to focus an open session's Terminal tab, attach to a live agent, or resume a closed
session in a new Terminal window.

## Requirements

- macOS and Terminal.app for switching, attaching, and resuming sessions.
- Python 3 with `curses` (no third-party Python packages).
- Claude Code on your `PATH`. Live-session discovery uses `claude agents --json`;
  attaching uses `claude attach`. These commands must be available in your version.
  Saved sessions can still be listed if live-session discovery is unavailable.

The first time you switch or resume, macOS may ask your terminal for permission
to control Terminal.app.

## Install

With Homebrew (the repository also serves as its own tap):

```sh
brew tap alexamber/ccs https://github.com/alexamber/ccs.git && brew install --HEAD alexamber/ccs/ccs
```

This installs the latest commit from `main` and its Python dependency. Claude Code
must already be installed separately. To update: `brew reinstall --HEAD alexamber/ccs/ccs`.

Or use the standalone installer if Python 3 is already installed:

```sh
curl -fsSL https://raw.githubusercontent.com/alexamber/ccs/main/install.sh | sh
```

From a local checkout:

```sh
./install.sh
```

This copies `ccs` to `~/.local/bin` without sudo. If that directory is not on your
`PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`, then open a new
terminal. To choose a different directory: `./install.sh /your/bin`.

You can also run `./ccs` directly without installing.

## Usage

```sh
ccs                       # folder tree; sessions active in the last 14 days
ccs --recent              # most recent first
ccs --days 0              # all saved sessions
ccs --days 30 --list       # print the tree without the interactive UI
```

Live sessions are included regardless of `--days`. The age filter for saved
sessions uses the transcript file's modification time.

| Key | Action |
| --- | --- |
| Up / Down, Ctrl-P / Ctrl-N | Select a session |
| Page Up / Page Down | Move by a page |
| Enter | Switch, attach, or resume |
| Tab | Toggle folder / recent view |
| Type | Search folders, titles, names, prompts, and recaps |
| Backspace | Delete a search character |
| Escape | Clear search |
| Ctrl-R | Refresh |
| Ctrl-C | Quit |

Green indicates an idle live session; yellow indicates another live status.
Closed sessions are dimmed. Larger terminals show a recap, last prompt, prompt
count, and saved cost for the selected session.

## Data

Reads transcripts under `~/.claude/projects/*/*.jsonl` and caches their extracted
metadata in `~/.cache/ccs-index.json`. The cache contains session text, including
prompt excerpts. Delete that file to rebuild it. Transcript files are not changed.

The transcript records and live-agent commands are Claude Code interfaces that
may vary by version.

## Development

```sh
python3 -m unittest discover -s tests -v
```

## License

[MIT](LICENSE).
