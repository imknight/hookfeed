#!/bin/bash
# Install without elevation. Does not launch the app or change integration configs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skip_build=false
debug_build=false
usage() {
    printf 'Usage: %s [--debug] [--skip-build]\n\n' "$0"
    printf 'Build and install HookFeed; --skip-build installs the existing dist/HookFeed.app.\n'
    printf 'Uses /Applications when writable, otherwise ~/Applications. No sudo.\n'
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) debug_build=true ;;
        --skip-build) skip_build=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$(uname -s)" != Darwin ]; then
    printf 'HookFeed installation requires macOS.\n' >&2
    exit 1
fi
if [ "$skip_build" = false ]; then
    if [ "$debug_build" = true ]; then
        "$ROOT/scripts/build-app.sh" --debug
    else
        "$ROOT/scripts/build-app.sh"
    fi
fi

source_app="$ROOT/dist/HookFeed.app"
if [ ! -x "$source_app/Contents/MacOS/HookFeed" ] || [ ! -x "$source_app/Contents/Helpers/hookfeed" ]; then
    printf 'Missing app or helper. Run scripts/build-app.sh first.\n' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$source_app"

applications_path=/Applications
if [ ! -d "$applications_path" ] || [ ! -w "$applications_path" ]; then
    applications_path="$HOME/Applications"
    mkdir -p "$applications_path"
fi
destination="$applications_path/HookFeed.app"
staging_path="$(mktemp -d "$applications_path/.HookFeed-install.XXXXXX")"
staged_app="$staging_path/HookFeed.app"
previous_app="$staging_path/previous.app"
cleanup() {
    result=$?
    trap - EXIT
    if { [ -e "$previous_app" ] || [ -L "$previous_app" ]; } && [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        mv "$previous_app" "$destination" || {
            printf 'Restore the previous install manually from %s\n' "$previous_app" >&2
            exit 1
        }
    fi
    rm -rf "$staging_path"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mv "$destination" "$previous_app"
fi
mv "$staged_app" "$destination"
printf '\nInstalled: %s\nCLI:       %s/Contents/Helpers/hookfeed\n' "$destination" "$destination"
printf 'Open with: open "%s"\n' "$destination"
printf 'Quit and reopen HookFeed after replacing an app that was already running.\n'
