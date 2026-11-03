#!/bin/sh
# Install from a checkout or pipe this file to sh.
set -eu

main() {
    if [ "$#" -gt 1 ]; then
        printf 'Usage: %s [destination-directory]\n' "$0" >&2
        exit 2
    fi

    destination=${1:-"$HOME/.local/bin"}

    if ! command -v python3 >/dev/null 2>&1; then
        printf 'ccs requires Python 3. Install Python 3 and retry.\n' >&2
        exit 1
    fi
    if ! python3 -c 'import curses' >/dev/null 2>&1; then
        printf 'ccs requires a Python 3 installation with curses support.\n' >&2
        exit 1
    fi

    download_dir=
    trap 'if [ -n "$download_dir" ]; then rm -rf "$download_dir"; fi' EXIT
    trap 'exit 1' HUP INT TERM
    if [ -f "$0" ]; then
        source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        source_file="$source_dir/ccs"
    else
        download_dir=$(mktemp -d)
        source_file="$download_dir/ccs"
        curl -fsSL https://raw.githubusercontent.com/alexamber/ccs/main/ccs -o "$source_file"
    fi

    mkdir -p "$destination"
    install -m 755 "$source_file" "$destination/ccs"
    printf 'Installed %s/ccs\n' "$destination"
    case ":$PATH:" in
        *":$destination:"*) printf 'Run: ccs\n' ;;
        *) printf 'Add the install directory to PATH, then run ccs:\n  export PATH="%s:$PATH"\n' "$destination" ;;
    esac
}

main "$@"
