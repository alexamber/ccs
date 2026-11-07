#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/CCS.app"
destination="${1:-$HOME/Applications}/CCS.app"
test -x "$source_app/Contents/MacOS/CCSApp"
test -x "$source_app/Contents/MacOS/ccs"
mkdir -p "$(dirname "$destination")" "$HOME/.local/bin"
stamp=$(date +%Y%m%d-%H%M%S)
if [ -e "$destination" ]; then mv "$destination" "$destination.backup-$stamp"; fi
ditto "$source_app" "$destination"
target="$HOME/.local/bin/ccs"
if [ -e "$target" ] || [ -L "$target" ]; then mv "$target" "$target.backup-$stamp"; fi
ln -s "$destination/Contents/MacOS/ccs" "$target"
printf 'Installed %s\nCLI: %s\n' "$destination" "$target"
