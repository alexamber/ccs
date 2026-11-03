# Native apps and Codex

## Existing options

- [Agent Sessions](https://github.com/jazzyalex/agent-sessions) is a native Mac
  app for searching local Claude, Codex, and other agent history and resuming
  supported CLI sessions. Try it before building another history browser:
  `brew install --cask jazzyalex/agent-sessions/agent-sessions`.
- [Lunavect](https://github.com/lovach/Lunavect) combines Claude and Codex live
  activity in a Mac menu bar app. It is closer to an active-session monitor;
  exact navigation depends on the client.
- The Mac App Store has related usage tools such as
  [AI Session Meter](https://apps.apple.com/us/app/ai-session-meter/id6784566115?platform=mac).
  Its listing describes limits and usage history, not this project's terminal
  session switcher. An exact App Store equivalent was not verified.

These are third-party tools, not dependencies of `ccs`. Availability and features
were checked on November 3, 2026; they can change.

## A standalone macOS app

Yes. A small AppKit menu bar app can use an `NSPanel` for the global-hotkey picker
and reuse this popup's HTML in `WKWebView`. It would replace Hammerspoon's APIs
with Swift process execution, keyboard handling, and window management.

For the simplest installation, implement discovery in Swift too; otherwise the
app still needs a Python backend or a bundled interpreter. A signed, notarized
download/Homebrew cask is the practical first distribution target. Mac App Store
distribution requires a separate sandbox design for transcript access and
Terminal automation; approval should not be assumed. Apple's
[sandbox documentation](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
describes those restrictions.

## What Codex already has

The installed CLI supports `codex resume --all` for a cross-folder resume picker.
Current official documentation also describes `codex agents` for browsing chats
on a shared server, plus desktop chat search and configurable shortcuts:
[CLI reference](https://learn.chatgpt.com/docs/cli/reference),
[desktop commands](https://learn.chatgpt.com/docs/app/commands).
These features cover Codex; they do not aggregate Claude sessions.

## A combined picker

It makes sense if one global shortcut across both providers is the missing piece.
It is feasible, but is not implemented in this version. Keep one UI and separate
provider adapters rather than duplicating the whole application:

1. Normalize metadata to provider, id, folder, title, activity, and status. Use
   `(provider, id)` as the identity; unknown cost stays unknown.
2. Give the picker **All / Claude / Codex** filters.
3. Keep live discovery and activation provider-specific. For Codex, prefer the
   documented app-server `thread/list`/`thread/read` APIs to scraping internal
   databases. Reuse the user's shared server when available; a new isolated
   server does not prove whether a thread is active elsewhere.
4. Reuse an existing app/tab when supported; otherwise launch the appropriate
   provider's resume command. Do not promise exact desktop-thread activation
   without a supported deep link or API.

The [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes history pagination, runtime status, and thread operations. Converting a
Claude conversation into a Codex conversation is a separate feature, not a
provider-filter toggle.
