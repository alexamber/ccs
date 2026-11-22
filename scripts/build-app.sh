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
sparkle="$PWD/.build/artifacts/sparkle/Sparkle"
app="$PWD/build/CCS.app"
if [ "$mode" = --development ] && [ "$app_only" = --app-only ]; then
    app="${CCS_DEVELOPMENT_APP_PATH:-$app}"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$PWD/dist" "$PWD/.build/module-cache"
install -m 755 "$bin/CCSApp" "$app/Contents/MacOS/CCSApp"
install -m 755 "$bin/ccs" "$app/Contents/MacOS/ccs"
framework="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$framework"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
# SwiftPM embeds its local product directory as a runtime search path. Packaged
# executables should resolve frameworks only from the bundle and macOS.
for executable in "$app/Contents/MacOS/"*; do
    while IFS= read -r path; do
        case "$path" in /usr/lib/swift) ;; *) install_name_tool -delete_rpath "$path" "$executable" ;; esac
    done < <(otool -l "$executable" | awk '/cmd LC_RPATH/{getline; getline; sub(/^ *path /,""); sub(/ \(offset [0-9]+\)$/,""); print}' | sort -u)
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/CCSApp"
if [ "$mode" = --release ]; then
    # Debug symbols include absolute paths from the build machine.
    xcrun strip -S "$app/Contents/MacOS/CCSApp" "$app/Contents/MacOS/ccs"
fi
if [ "$app_only" != --app-only ]; then
    for arch in arm64 x86_64; do
        lipo "$app/Contents/MacOS/CCSApp" -verify_arch "$arch"
        lipo "$app/Contents/MacOS/ccs" -verify_arch "$arch"
    done
fi
cp macOS/Info.plist "$app/Contents/Info.plist"
if [ "$mode" = --development ]; then
    /usr/bin/plutil -remove SUFeedURL "$app/Contents/Info.plist"
else
    account=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    public_key=$("$sparkle/bin/generate_keys" --account "$account" -p)
    if [ "$public_key" != "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" ]; then
        echo 'The local Sparkle signing key does not match the CCS public key.' >&2; exit 1
    fi
fi
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Sources/CCSApp/Resources/{Unicorn.png,UnicornTemplate.png,Firefly.png,Grasshopper.caf,VisibleDraft.js} "$app/Contents/Resources/"
if [ -n "${CCS_DONATION_URL:-}" ]; then
    case "$CCS_DONATION_URL" in https://*) ;; *) printf 'CCS_DONATION_URL must use HTTPS.\n' >&2; exit 2 ;; esac
    /usr/bin/plutil -insert CCSDonationURL -string "$CCS_DONATION_URL" "$app/Contents/Info.plist"
fi
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" macOS/Icon.swift -o build/ccs-icon-generator
build/ccs-icon-generator build/CCS.iconset Sources/CCSApp/Resources/Unicorn.png
iconutil -c icns build/CCS.iconset -o "$app/Contents/Resources/CCS.icns"
sign=(--force --sign "$identity")
if [ "$identity" != - ]; then sign+=(--options runtime); fi
if [ "$identity" != - ]; then sign+=(--timestamp); fi
helpers="$framework/Versions/B"
codesign "${sign[@]}" "$helpers/XPCServices/Installer.xpc"
codesign "${sign[@]}" --preserve-metadata=entitlements "$helpers/XPCServices/Downloader.xpc"
codesign "${sign[@]}" "$helpers/Autoupdate"
codesign "${sign[@]}" "$helpers/Updater.app"
codesign "${sign[@]}" "$framework"
codesign "${sign[@]}" --entitlements macOS/CCS.entitlements "$app/Contents/MacOS/ccs"
codesign "${sign[@]}" --entitlements macOS/CCS.entitlements "$app"
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
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/CCS.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<'TEXT'
Drag CCS.app into Applications, then open it.
CCS lives in the menu bar. Option-Space opens the session picker.
Press Option-Space again to start a new session in a dated folder.
To install the terminal picker, choose Install Command-Line Tool from CCS's menu.
Claude Code or Codex, and Terminal.app, are required. No Python or Hammerspoon is needed.
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
files=("$artifact_name.dmg" "$artifact_name.zip")
if [ "$mode" = --release ]; then
    feed_stage="$stage/feed"
    mkdir "$feed_stage"
    ln "$artifact.zip" "$feed_stage/"
    "$sparkle/bin/generate_appcast" --account "$account" \
        --download-url-prefix "https://github.com/alexamber/ccs/releases/download/v$version/" "$feed_stage"
    "$sparkle/bin/sign_update" --account "$account" --verify "$feed_stage/appcast.xml"
    mv "$feed_stage/appcast.xml" dist/appcast.xml
    files+=(appcast.xml)
fi
(cd dist; shasum -a 256 "${files[@]}" > "$artifact_name.sha256")
printf 'Built app: %s\nDMG: %s.dmg\nZIP: %s.zip\n' "$app" "$artifact" "$artifact"
if [ "$mode" = --development ]; then printf 'Development build: ad-hoc signed, not notarized for public distribution.\n'; fi
