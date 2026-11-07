# Native CCS: App Store feasibility

Status: completed sandbox diagnostic. The release route is now direct download
and Homebrew; App Store distribution is deferred. The diagnostic was tested locally
on November 7, 2026, with macOS 27.0.1, Apple Silicon, Swift 6.4.2, and Claude Code
2.1.228. No App Store submission or approval has occurred.

## Agreed product scope

- CCS menu bar app, native Swift controls, no persistent Dock icon.
- Swift CLI and app share one session engine; no Python or Hammerspoon dependency.
- Claude Code first; Terminal.app integration.
- Preserve the terminal picker as the default `ccs` action, with `ccs --gui` for
  the popup and compatible existing flags and JSON export.
- Search, Recent/Folders, date filters, live status, resume/start-clean, dated
  session folders, safe cleanup, keyboard navigation, and periodic refresh.
- Configurable Option-Space shortcut; repeating it creates a dated session.
- Popup on the screen containing the pointer; native light/dark appearance.
- Settings for shortcut, date range, view, new-folder root, and cleanup.
- Optional launch at login, off by default; `CCS_NEW_DIR` remains an override.
- Target macOS 14+, Apple Silicon and Intel. The diagnostic itself is arm64 only.
- Public distribution; build and install locally for verification.
- User has a paid Apple Developer membership and Stripe account. No payment
  destination or pricing has been configured. No purchases or publishing are
  authorized by this diagnostic.

The App Store compatibility experiment informed the decision to ship through
Homebrew and signed downloads first, retaining the process-based integrations.

## What was actually tested

| Operation | Result | Limit |
| --- | --- | --- |
| App Sandbox enforcement | Confirmed | The app uses a real sandbox container; ungranted transcript access is denied. |
| Read Claude projects after choosing `.claude` | Pass | Enumerated nine transcript files; no session contents were exported in the report. |
| Security-scoped folder bookmark | Pass | Restored access during the first run and again after full app relaunch. |
| Terminal tab automation | Pass | Read Terminal's window count and reselected an existing tab. |
| Open a Terminal window | Pass | Executed only a `printf` test message. No new Claude session or model request. |
| Global shortcut registration | Pass | Carbon registered Ctrl-Option-Shift-Space. Physical shortcut activation has not been verified. |
| Claude live discovery, minimal entitlements | Fail | Launching the user-installed Claude binary fails. Its symlink was selected through an Open panel. |
| Claude live discovery, narrow file exception | Pass | `agents --json` returned a valid empty list. There were no running sessions to validate. |
| Process listing using `ps` | Fail | App Sandbox denies it. |
| Working directories using `lsof` | Fail | App Sandbox denies process inspection. |
| Direct-download signing and notarization | Pass, November 8 | The existing Developer ID identity and notary profile worked; Apple accepted the app and DMG. This does not establish App Store approval. |

The headless comparison used the same executable path with and without the
Claude installation-directory exception. Headless mode sends no Terminal Apple
events. Its file and process tests still execute inside the signed app's sandbox.

## Exceptions and App Review

The Terminal tests use:

```xml
<key>com.apple.security.temporary-exception.apple-events</key>
<array><string>com.apple.Terminal</string></array>
```

The successful Claude execution test additionally uses read-only access to:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.local/share/claude/versions/</string></array>
```

This covers this Mac's native Claude installer layout. Other installation layouts
have not been tested. These are public, documented entitlements, but technical
success does not establish App Review acceptance. Exceptions need justification.

Apple's [Mac App Store requirements](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
require appropriate sandboxing and prohibit installing code into shared
locations. Consequently a Homebrew CLI installation and a Mac App Store GUI
installation need separate distribution handling. An App Store app must not
silently install an unsandboxed helper to evade these restrictions.

Apple documents [temporary exception entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html),
including the need to explain their use during review.

## Remaining product decision

Exact Hammerspoon behavior currently depends on process inspection for two
operations:

1. Associate a running Claude session with its Terminal TTY and parent processes.
   Terminal automation itself works, but reliably choosing the correct existing
   tab for sessions started elsewhere remains unresolved. Successful tab access
   is not proof of successful session-to-tab matching.
2. Confirm that no process is using a dated folder before deleting it. If that
   cannot be confirmed, keep the folder. Never substitute an unchecked deletion.

An App Store edition therefore needs a different method for associating sessions
with tabs and conservative cleanup. A direct-download/Homebrew edition can
retain the current process-based behavior. A final release architecture should
make this distinction explicit rather than promise unverified feature parity.

## Reproduce

Build the minimal-permission diagnostic:

```sh
bash scripts/build-store-probe.sh
open 'build/CCS Store Probe.app'
```

Build with the narrow Claude execution exception:

```sh
bash scripts/build-store-probe.sh --claude-execution-exception
```

For a process/file-only comparison after granting folder access in the UI:

```sh
'build/CCS Store Probe.app/Contents/MacOS/CCSStoreProbe' \
  --headless --claude "$HOME/.local/share/claude/versions/2.1.228"
```

Change the executable path to the installed version. Reports stay in the probe's
sandbox container under `Library/Application Support/CCS/feasibility.json`.
Build outputs and machine-specific diagnostic reports are ignored by Git.

The diagnostic began with four shared-core tests. The native Swift app and CLI
have since been implemented for direct distribution, with thirteen regression
tests, packaged-CLI/PTY checks, a real-process cleanup check, and native UI
verification. The legacy Python implementation remains as a compatibility reference.
