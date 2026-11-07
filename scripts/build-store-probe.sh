#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/build/CCS Store Probe.app"
exception=false
case "${1:-}" in
    "") ;;
    --claude-execution-exception) exception=true ;;
    *) printf 'Usage: %s [--claude-execution-exception]\n' "$0" >&2; exit 2 ;;
esac
mkdir -p "$output/Contents/MacOS" "$PWD/.build/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -module-cache-path "$PWD/.build/module-cache" \
    macOS/StoreProbe.swift -framework AppKit -framework Carbon \
    -o "$output/Contents/MacOS/CCSStoreProbe"
cat > "$output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>CCSStoreProbe</string>
    <key>CFBundleIdentifier</key><string>io.github.alexamber.ccs.store-probe</string>
    <key>CFBundleName</key><string>CCS Store Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>CCS tests whether it can focus Terminal tabs and open a new Terminal window for a Claude Code session.</string>
</dict></plist>
PLIST
cp macOS/StoreProbe.entitlements build/store-probe.entitlements
if [ "$exception" = true ]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.files.home-relative-path.read-only array' build/store-probe.entitlements
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.files.home-relative-path.read-only:0 string /.local/share/claude/versions/' build/store-probe.entitlements
fi
/usr/libexec/PlistBuddy -c "Add :CCSExecutionException bool $exception" "$output/Contents/Info.plist"
codesign --force --sign - --entitlements build/store-probe.entitlements "$output"
codesign --verify --strict "$output"
printf 'Built sandboxed diagnostic: %s\n' "$output"
