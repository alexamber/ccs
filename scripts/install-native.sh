#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/CCS.app"
destination="${1:-$HOME/Applications}/CCS.app"
test -x "$source_app/Contents/MacOS/CCSApp"
test -x "$source_app/Contents/MacOS/ccs"
mkdir -p "$(dirname "$destination")"
stamp=$(date +%Y%m%d-%H%M%S)
if [ -e "$destination" ]; then mv "$destination" "$destination.backup-$stamp"; fi
ditto "$source_app" "$destination"
"$destination/Contents/MacOS/ccs" --install-cli
printf 'Installed %s\n' "$destination"
