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

Development outputs carry `-development` in their filenames and default to ad-hoc
signatures. Setting `CCS_SIGN_IDENTITY` signs them with that identity but does not
notarize them. Do not present them as notarized public releases.

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
5. Use the CCS Sparkle signing key in the login Keychain under account
   `io.github.alexamber.ccs`. Restore the existing key on a replacement signing
   Mac. The release build checks its public half against `SUPublicEDKey`.

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
written alongside the artifacts in `dist/`. Sparkle also signs the final ZIP and
generates the signed `dist/appcast.xml` for the same build. Increment both the
marketing version and the integer `CFBundleVersion` before each public release.

With the signing identity still set, run `python3 scripts/check-update.py` to
exercise the Sparkle installer on disposable copies. It uses a loopback feed,
a temporary signing key and a separate bundle identifier.

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
   attach the release DMG, ZIP, checksum manifest and `appcast.xml` to the draft.
   Match all four asset digests against the local files, then publish the draft
   as the latest stable release. Verify that
   `https://github.com/alexamber/ccs/releases/latest/download/appcast.xml` serves
   the signed feed byte for byte and that its enclosure downloads the verified
   ZIP. Keep prereleases out of the latest stable slot. Publish the generated cask in
   the tap. Set the version in `macOS/Info.plist`; both app and bundled CLI read
   it there. Match the Git tag and release notes to that version.

The source formula and cask conflict on the `ccs` command. Users switching from
the old formula should uninstall it before installing the cask. A standalone
`~/.local/bin/ccs` can also shadow Homebrew; retain its backup until the new command
is verified. Removing the cask should leave user transcripts and settings intact.

No release has been published merely by running the local build scripts.

## Manual sign-off checklist

Use the installed build intended for release. Record the macOS version, machine,
Claude/Codex versions and build number. Avoid testing with unsaved work at risk.

1. **Basic session identity.** Open two different Claude conversations and two
   different Codex conversations, including two in the same folder. Open the full
   picker and Option-Tab. Pass: distinct live conversations appear separately;
   choosing each returns to the correct conversation. Multiple viewers of one
   conversation may intentionally share one row.
2. **Terminal context and hover.** Enable Show unicorn, then switch tabs with
   Terminal's own shortcuts and by clicking. Pass: the icon stays compact until
   hovered. Hover reveals the selected conversation without taking keyboard focus;
   leaving collapses it. Clicking opens the correct folder's files, which remain
   open when the pointer leaves. On a plain shell tab or outside Terminal, hover
   shows no name and left-click does nothing. Right-click still opens active
   sessions from any app. Tab changes and desktop returns never announce names.
3. **Identity edge cases.** Rename a Codex tab, then separately change conversations
   inside a running Codex client. Pass: CCS either identifies the current
   conversation correctly or shows “Codex tab · Conversation unconfirmed” in
   Option-Tab, without a session popup. The generic row must still focus that tab.
   Enter on a working or ambiguously matched conversation in the full picker must
   explain the failure without opening another viewer. A closed, idle conversation
   can reopen only after a successful tab scan finds no matching or unidentified
   client. A wrong topic, wrong focus, or duplicate viewer is a failure.
4. **Fast switching and cancellation.** Hold Option and tap Tab repeatedly; reverse
   with Shift; release Option. Then press Escape and immediately reopen/cancel.
   Pass: selection stays stable during a gesture, release focuses the highlighted
   conversation, and cancelled/older requests never cause a delayed switch.
   Close a test session while the chooser is open: it must not restart that session.
   From Finder, use both the picker and a notification to switch to windows on
   another desktop and to minimized windows. Confirm Terminal becomes active
   and the requested window and tab are visible. If either build reports an
   error, observe for two more seconds to distinguish a late transition from
   a failed switch.
5. **Spaces, displays, and dragging.** With Show on every desktop enabled, swipe to
   a desktop without Terminal and back. Repeat with a full-screen app and an
   external display if available. Pass: the compact icon follows, but does not
   replay a name. Disable that preference: it stays on one Space. Drag the icon
   across displays, relaunch, and disconnect a display. Its position is remembered
   and stays onscreen. A drag must not open files or a session.
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
   Filter to two sessions with different folders and traverse them. Each sidebar
   should show that folder’s files even when their names differ from the query.
   Select **Search files across sessions** to search filenames with the same query.
   Also search for a file whose conversation title does not match, including an
   older session outside the selected date range. Pass: global files respect the
   provider filter, show their folders, and open with Return/Right/Down as appropriate.
   ⌘F returns to search; clearing it restores the selected folder. Filter the
   right-click active-session menu by topic/status and verify Escape clears first,
   then closes. Late results must not move a file row under the pointer.
8. **First-run account.** In a fresh macOS user account with one supported provider
   installed, install and start CCS. Pass: provider detection, default shortcuts,
   optional popup/login settings, first permission request, and CLI installation
   work without development caches or prior permissions. Quit/relaunch and verify
   saved settings and that quitting releases the shortcuts.
9. **Energy comparison.** On battery, keep Terminal frontmost with an idle session
   for five minutes with the unicorn off, then on, then off again. Keep
   screen brightness and workload similar. In Activity Monitor compare CCS's
   CPU/Energy Impact and its short-lived `osascript` children, not CCS alone.
   Also bring another app forward: selected-tab polling stops, while enabled
   background status updates continue. Sustained additional
   CPU, noticeable heat/fans, or a repeatable large energy increase requires
   profiling before release. This short test detects obvious regressions; it does
   not establish a precise battery-life percentage.
10. **Updates and acknowledgement.** With attention and completion alerts enabled,
    run work in two identified sessions while another app is focused. Trigger an
    approval/input request and a completed turn. In the lists, working is yellow,
    ready is green, and attention and unattended completions are purple.
    Visiting a finished session for one second returns its dot to green.
    Each event shows its own message and session name in
    a readable thought bubble. A second event waits its turn; hover pauses the
    five-second timeout. Opening files, the active-session menu, or dragging pauses
    delivery. Visit the session through Terminal's own controls for one second:
    its unread dot/queued notices clear, while an unresolved attention status stays.
    Clicking a notice focuses that session. Mute both alert types: statuses still
    update, notices clear, and unmuting does not replay old events. Test both
    providers; existing Claude clients may need to reload their hook configuration.

Cases 3, 5 and 6 are particularly important: unit tests do not prove live provider
identity, macOS Space behavior, or real privacy-permission recovery.

## Distribution scope

This build targets Developer ID distribution. It is not sandboxed and is not
prepared for Mac App Store submission. Store distribution needs a separate design
for external CLI execution, process inspection, history/socket access, Terminal
automation, and CLI installation.
