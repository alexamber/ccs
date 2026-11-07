#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macOS/App/Info.plist)
artifact="dist/CCS-$version-macos-universal.dmg"
if [ ! -f "$artifact" ]; then printf 'Build a signed, notarized release first: bash scripts/build-app.sh --release\n' >&2; exit 1; fi
xcrun stapler validate "$artifact"
checksum=$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)
mkdir -p Casks
cat > Casks/ccs.rb <<RUBY
cask "ccs" do
  version "$version"
  sha256 "$checksum"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code sessions"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
RUBY
printf 'Generated Casks/ccs.rb with the release checksum.\n'
