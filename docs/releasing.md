# Native CCS releases

Builds target macOS 14+, Apple Silicon and Intel. `CCS.app` contains both the
`CCSApp` GUI executable and the `ccs` terminal executable. The two executables
have different names because macOS commonly uses a case-insensitive filesystem.

## Local development

```sh
swift test
bash scripts/build-app.sh --development
python3 scripts/check-native.py build/CCS.app/Contents/MacOS/ccs
bash scripts/install-native.sh
```

The installer defaults to `~/Applications`; pass `/Applications` to install there
instead. Existing app and CLI installations are backed up. CLI installation from
the app is idempotent and backs up an older command before creating its symlink.

Development outputs carry `-development` in their filenames and use ad-hoc
signatures. Do not present them as notarized public releases.

## Signing prerequisites

1. Sign into the paid Apple Developer team in Xcode Settings → Accounts.
2. In Manage Certificates, create or import a **Developer ID Application**
   certificate with its private key. A generic Apple Development certificate is
   insufficient for this release route. Keep the private key on the signing Mac.
3. Configure a `notarytool` keychain profile locally. Use Apple's supported
   credential setup; do not put passwords, private keys, or API keys in this
   repository or in chat.
4. Confirm that `security find-identity -v -p codesigning` lists the Developer ID
   identity. Merely having a paid membership does not install the certificate.

See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/)
and [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Build the public artifacts

Set `CCS_SIGN_IDENTITY` to the exact local `Developer ID Application: …` identity
and `CCS_NOTARY_PROFILE` to the configured keychain profile name, then run:

```sh
bash scripts/build-app.sh --release
bash scripts/make-cask.sh
```

The script builds both architectures, generates the icon, signs the nested CLI
and app with hardened runtime and the Apple-events entitlement, submits the app
to notarization, staples its ticket, builds and signs the DMG, and notarizes and
staples the DMG. The ZIP contains the already-stapled app. SHA-256 checksums are
written alongside the artifacts in `dist/`.

The release command fails if signing credentials or the notary profile are
missing. Cask generation fails without a real release DMG and a valid stapled
ticket. No payment destination is embedded by default. To add an existing hosted
Stripe tip page or another owner-supplied tip page, set `CCS_DONATION_URL` to its
public HTTPS URL when building. This opens the browser; no payment secrets or
Stripe SDK are included in the app.

## Review and publish

1. Install the app and test the popup, shortcut, search, date/view switching,
   large-session confirmation, both providers, Terminal activation, and CLI installation.
2. Run the packaged-CLI smoke checks, including a real process holding a dated
   working directory and archived/subagent Codex history. Verify Claude-only,
   Codex-only, and both-provider setup, and physically test rapid Option-Space
   presses. Confirm launch-at-login behavior on an installed build.
3. Inspect the signed artifacts and generated `Casks/ccs.rb`.
4. Publish only after owner approval: create the matching versioned GitHub release,
   upload the release DMG, ZIP and checksums, then publish the generated cask in
   the tap. Set the version in `macOS/Info.plist`; both app and bundled CLI read
   it there. Match the Git tag and release notes to that version.

The source formula and cask conflict on the `ccs` command. Users switching from
the old formula should uninstall it before installing the cask. A standalone
`~/.local/bin/ccs` can also shadow Homebrew; retain its backup until the new command
is verified. Removing the cask should leave user transcripts and settings intact.

No release has been published merely by running the local build scripts.

## Terminal switcher release review (2026-11-17)

The working branch adds native tab titles, an optional floating session bubble,
an Option-Tab chooser, folder artifact discovery, and unicorn artwork. The original
proposal's “Current” marker in the main/CLI pickers and periodic tab renaming are
not implemented. Titles change on launch/focus and replace manually assigned titles.

Review fixes cover bare-Codex duplicate viewers, fresh Claude PID validation,
cancel/reopen races and stale current-tab selection in the compact chooser,
shared process inspection across tabs, retrying unmatched popup tabs, and detecting
topic changes without reacting to spinner animation. Unused compact artifact-list
code was removed. Shortcut registration now rolls back both switcher shortcuts
if either fails. Picker positioning is clamped to the screen’s visible area.

Validation for this review: 58 core tests and 18 AppKit tests passed; light/dark
test renders were generated and the main dark layouts inspected. The development
app and CLI built for arm64 and x86_64, strict signature verification passed, and
`scripts/check-native.py` passed metadata/CLI, real-process cleanup, and PTY picker
checks. No public release or live Spaces/clean-account sign-off is implied.

Before publishing:

- Choose a new version/build number; the bundle still declares 1.0.2 (7).
  Do not overwrite the existing release artifacts or cask checksum.
- The user supplied a generated replacement unicorn, now used by the app. Its
  provenance is recorded in `unicorn-icon.md`; generation alone does not establish
  third-party rights clearance. Publish only the clean `feat/terminal-session-ui`
  branch; the earlier local `feat/terminal-session-titles` history contains the
  replaced VectorStock-derived assets and should not be pushed.
- Test real Claude and Codex tabs, rapid Option-Tab/reverse/cancel/reopen, denied
  Automation, multiple displays and Spaces, and protected folders on a clean user
  account. Unit tests simulate these integrations; compilation is not live OS QA.
- Build and notarize with the release credentials. A development app is not a
  signed, notarized public release. Run the packaged CLI checks on the final build.

Known limitations worth keeping visible:

- The switcher counts conversations, not clients. Two tabs attached to the same
  session ID produce one row. Shared folders alone do not merge sessions.
- Bare Codex matching is a conservative title/folder heuristic. Custom titles,
  unknown flags, identical topics in one folder, or unavailable live metadata can
  prevent matching. The normal picker may then open another viewer of the same
  conversation; Option-Tab never resumes one. Launch argv can also become stale
  if the client switches conversations internally. A provider-owned tty/thread
  mapping would be stronger than either argv or titles.
- The monitor starts up to four short AppleScript processes per second while
  Terminal is frontmost and popups are enabled. Profile energy use on a laptop
  before increasing polling frequency. The feature remains optional and off by default.
- First switch/refresh can wait for provider metadata on the history queue. Cached
  rows appear immediately, but an unverified current tab cannot authorize a switch.
- Discovery is shallow and intentionally skips protected folders and external
  volumes. Its time budget is checked between filesystem calls, not a hard I/O
  timeout. Custom mounts or privacy controls may still produce access prompts.

## Mac App Store assessment

This variant targets Developer ID distribution, not the Mac App Store. Its
entitlements enable hardened-runtime Apple events but do not enable App Sandbox.
Sandboxing is mandatory under Apple's [guideline 2.4.5(i)](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility).

A Store build needs a separate design for reading other apps' history, inspecting
processes, accessing the local Codex socket, running external CLIs, creating session
folders, and installing the `~/.local/bin/ccs` symlink. These behaviors do not become
sandbox-compatible just by adding an entitlement. The self-contained-installation
requirements in guideline 2.4.5(ii) also need review for CLI installation.

Terminal automation is not automatically prohibited, but sandboxed Apple events
require supported scripting targets or an approved temporary exception, in
addition to user consent. Apple's [Apple-event exception documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
and [submission requirements](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/)
describe that review path; approval is not assured. The floating panel and icon
are not themselves the sandbox blocker. Asset licensing still applies to either
distribution route.

## Manual sign-off checklist

Use the installed build intended for release. Record the macOS version, machine,
Claude/Codex versions and build number. Avoid testing with unsaved work at risk.

1. **Basic session identity.** Open two different Claude conversations and two
   different Codex conversations, including two in the same folder. Open the full
   picker and Option-Tab. Pass: distinct live conversations appear separately;
   choosing each returns to the correct conversation. Multiple viewers of one
   conversation may intentionally share one row.
2. **Ordinary Terminal switching.** Enable the popup preference, then switch tabs
   with Terminal's own shortcuts and by clicking. Pass: the bubble names the
   selected conversation, keeps keyboard focus in Terminal, shrinks, and opens
   the correct folder's files on click. A plain shell tab gets no session bubble.
3. **Identity edge cases.** Rename a Codex tab, then separately change conversations
   inside a running Codex client. Pass: CCS either identifies the current
   conversation correctly or declines to match it. A wrong topic, wrong focus,
   or unexpected extra viewer is a failure; record which action caused it.
4. **Fast switching and cancellation.** Hold Option and tap Tab repeatedly; reverse
   with Shift; release Option. Then press Escape and immediately reopen/cancel.
   Pass: selection stays stable during a gesture, release focuses the highlighted
   conversation, and cancelled/older requests never cause a delayed switch.
   Close a test session while the chooser is open: it must not restart that session.
5. **Spaces and displays.** With the bubble showing, swipe to a desktop without
   Terminal and back. Repeat with a full-screen app and an external display if
   available. Pass: the bubble does not follow onto unrelated desktops or appear
   offscreen; returning to Terminal and switching a tab shows the correct bubble.
6. **Denied Automation.** In a separate macOS test account, refuse CCS's request
   to control Terminal (or disable it under Privacy & Security → Automation).
   Pass: session browsing still works; activation reports failure clearly; automatic
   popup checks stay quiet; no repeated alerts, hangs, or duplicate sessions.
   Re-enable permission and verify focus and popups recover.
7. **Folder privacy and artifacts.** Browse sessions whose folders are Home,
   Desktop, Documents, Downloads, and an ordinary project. Pass: restricted roots
   show an explanation without discovery-triggered permission prompts; a project
   report appears, filters, opens, and reflects edits within the refresh interval.
   Selecting sessions quickly must never show another folder's late results.
8. **First-run account.** In a fresh macOS user account with one supported provider
   installed, install and start CCS. Pass: provider detection, default shortcuts,
   optional popup/login settings, first permission request, and CLI installation
   work without development caches or prior permissions. Quit/relaunch and verify
   saved settings and that quitting releases the shortcuts.
9. **Polling comparison.** On battery, keep Terminal frontmost with an idle session
   for five minutes with popups off, then five minutes on, then off again. Keep
   screen brightness and workload similar. In Activity Monitor compare CCS's
   CPU/Energy Impact and its short-lived `osascript` children, not CCS alone.
   Also bring another app forward: popup polling should stop. Sustained additional
   CPU, noticeable heat/fans, or a repeatable large energy increase requires
   profiling before release. This short test detects obvious regressions; it does
   not establish a precise battery-life percentage.

Cases 3, 5 and 6 are particularly important: unit tests do not prove live provider
identity, macOS Space behavior, or real privacy-permission recovery.
