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
