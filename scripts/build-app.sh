#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---development}"
app_only="${2:-}"
if [ -n "$app_only" ] && [ "$app_only" != --app-only ]; then printf 'Second argument must be --app-only.\n' >&2; exit 2; fi
case "$mode" in
    --development|--release) ;;
    *) printf 'Usage: %s [--development|--release]\n' "$0" >&2; exit 2 ;;
esac
identity="${CCS_SIGN_IDENTITY:--}"
if [ "$mode" = --release ]; then
    : "${CCS_SIGN_IDENTITY:?Set CCS_SIGN_IDENTITY to your Developer ID Application identity}"
    : "${CCS_NOTARY_PROFILE:?Set CCS_NOTARY_PROFILE to a notarytool keychain profile}"
    case "$identity" in 'Developer ID Application:'*) ;; *) printf 'Release signing requires a Developer ID Application identity.\n' >&2; exit 1 ;; esac
fi
args=(--configuration release --scratch-path "$PWD/.build" --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
for arch in ${CCS_BUILD_ARCHS:-arm64 x86_64}; do
    case "$arch" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 2 ;; esac
    args+=(--arch "$arch")
done
swift build "${args[@]}" --product CCSApp
swift build "${args[@]}" --product ccs
bin=$(swift build "${args[@]}" --show-bin-path)
app="$PWD/build/CCS.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/dist" "$PWD/.build/module-cache"
install -m 755 "$bin/CCSApp" "$app/Contents/MacOS/CCSApp"
install -m 755 "$bin/ccs" "$app/Contents/MacOS/ccs"
if [ "$app_only" != --app-only ]; then
    for arch in arm64 x86_64; do
        lipo "$app/Contents/MacOS/CCSApp" -verify_arch "$arch"
        lipo "$app/Contents/MacOS/ccs" -verify_arch "$arch"
    done
fi
cp macOS/App/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
if [ -n "${CCS_DONATION_URL:-}" ]; then
    case "$CCS_DONATION_URL" in https://*) ;; *) printf 'CCS_DONATION_URL must use HTTPS.\n' >&2; exit 2 ;; esac
    /usr/bin/plutil -insert CCSDonationURL -string "$CCS_DONATION_URL" "$app/Contents/Info.plist"
fi
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" macOS/App/Icon.swift -o build/ccs-icon-generator
build/ccs-icon-generator build/CCS.iconset
iconutil -c icns build/CCS.iconset -o "$app/Contents/Resources/CCS.icns"
sign=(--force --sign "$identity" --options runtime --entitlements macOS/App/CCS.entitlements)
if [ "$identity" != - ]; then sign+=(--timestamp); fi
codesign "${sign[@]}" "$app/Contents/MacOS/ccs"
codesign "${sign[@]}" "$app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [ "$mode" = --release ]; then
    ditto -c -k --keepParent "$app" build/CCS-notarization.zip
    xcrun notarytool submit build/CCS-notarization.zip --keychain-profile "$CCS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    suffix=""
else
    suffix="-development"
fi
if [ "$app_only" = --app-only ]; then printf 'Built app: %s\n' "$app"; exit 0; fi
stage=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
ditto "$app" "$stage/CCS.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<'TEXT'
Drag CCS.app into Applications, then open it.
CCS lives in the menu bar. Option-Space opens the session picker.
Press Option-Space again to start a new session in a dated folder.
To install the terminal picker, choose Install Command-Line Tool from CCS's menu.
Claude Code and Terminal.app are required. No Python or Hammerspoon is needed.
TEXT
artifact="$PWD/dist/CCS-$version-macos-universal$suffix"
hdiutil create -volname CCS -srcfolder "$stage" -ov -format UDZO "$artifact.dmg"
if [ "$mode" = --release ]; then
    codesign --force --timestamp --sign "$identity" "$artifact.dmg"
    xcrun notarytool submit "$artifact.dmg" --keychain-profile "$CCS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$artifact.dmg"
    xcrun stapler validate "$artifact.dmg"
fi
ditto -c -k --keepParent "$app" "$artifact.zip"
artifact_name=$(basename "$artifact")
(cd dist; shasum -a 256 "$artifact_name.dmg" "$artifact_name.zip" > "$artifact_name.sha256")
printf 'Built app: %s\nDMG: %s.dmg\nZIP: %s.zip\n' "$app" "$artifact" "$artifact"
if [ "$mode" = --development ]; then printf 'Development build: ad-hoc signed, not notarized for public distribution.\n'; fi
