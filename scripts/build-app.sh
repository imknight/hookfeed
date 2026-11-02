#!/bin/bash
# Build both SwiftPM executables together, then package and sign the Mac app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
usage() {
    printf 'Usage: %s [--debug]\n\nBuilds dist/HookFeed.app (release by default).\n' "$0"
    printf 'Set HOOKFEED_SIGN_IDENTITY for certificate signing and hardened runtime (default: ad hoc).\n'
    printf 'Set HOOKFEED_BUILD_PATH to override the default .build-package scratch directory.\n'
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) configuration=debug ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$(uname -s)" != Darwin ]; then
    printf 'HookFeed packaging requires macOS and Xcode command-line tools.\n' >&2
    exit 1
fi
if [ ! -f "$ROOT/Package.swift" ]; then
    printf 'Missing %s/Package.swift; finish the Swift package before building.\n' "$ROOT" >&2
    exit 1
fi

scratch_path="${HOOKFEED_BUILD_PATH:-$ROOT/.build-package}"
case "$scratch_path" in
    /*) ;;
    *) scratch_path="$ROOT/$scratch_path" ;;
esac
dist_path="$ROOT/dist"
mkdir -p "$dist_path"
staging_path="$(mktemp -d "$dist_path/.HookFeed-build.XXXXXX")"
app_path="$staging_path/HookFeed.app"
destination="$dist_path/HookFeed.app"
previous_app="$staging_path/previous.app"
cleanup() {
    result=$?
    trap - EXIT
    if { [ -e "$previous_app" ] || [ -L "$previous_app" ]; } && [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        mv "$previous_app" "$destination" || {
            printf 'Restore the previous build manually from %s\n' "$previous_app" >&2
            exit 1
        }
    fi
    rm -rf "$staging_path"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Building HookFeed and hookfeed (%s)…\n' "$configuration"
# One invocation builds every product from the same package source and dependency lockfile.
# This scratch directory is separate from editor/worker and Xcode package builds.
swift build --package-path "$ROOT" --scratch-path "$scratch_path" -c "$configuration" --arch arm64 --force-resolved-versions
bin_path="$(swift build --package-path "$ROOT" --scratch-path "$scratch_path" -c "$configuration" --arch arm64 --force-resolved-versions --show-bin-path)"
for executable in HookFeedDesktop hookfeed; do
    if [ ! -f "$bin_path/$executable" ] || [ ! -x "$bin_path/$executable" ]; then
        printf 'Missing executable: %s/%s\n' "$bin_path" "$executable" >&2
        exit 1
    fi
    if ! /usr/bin/file -b "$bin_path/$executable" | /usr/bin/grep -q 'Mach-O'; then
        printf 'Expected a native Mach-O executable: %s/%s\n' "$bin_path" "$executable" >&2
        exit 1
    fi
done

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Resources"
/usr/bin/ditto "$bin_path/HookFeedDesktop" "$app_path/Contents/MacOS/HookFeed"
/usr/bin/ditto "$bin_path/hookfeed" "$app_path/Contents/Helpers/hookfeed"
/usr/bin/ditto "$ROOT/Config/Info.plist" "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Library/LaunchAgents"
/usr/bin/ditto "$ROOT/Config/app.hookfeed.receiver.plist" "$app_path/Contents/Library/LaunchAgents/app.hookfeed.receiver.plist"
chmod 755 "$app_path/Contents/MacOS/HookFeed" "$app_path/Contents/Helpers/hookfeed"

mkdir -p "$app_path/Contents/Frameworks"
/usr/bin/ditto "$bin_path/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$scratch_path/artifacts/sparkle/Sparkle/LICENSE" "$app_path/Contents/Resources/Sparkle-LICENSE.txt"

# Include dependency resource bundles (including privacy manifests) emitted by SwiftPM.
for resource_bundle in "$bin_path/"*.bundle; do
    [ -d "$resource_bundle" ] || continue
    /usr/bin/ditto "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")"
done

# Compiled accent colour: macOS uses it under Multicolor and otherwise applies the user's accent.
/usr/bin/xcrun actool "$ROOT/Config/Assets.xcassets" --compile "$app_path/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --accent-color AccentColor \
    --output-partial-info-plist "$staging_path/assets-info.plist" --errors --warnings >/dev/null

swift "$ROOT/scripts/make-icon.swift" "$staging_path/HookFeed.iconset"
/usr/bin/iconutil --convert icns --output "$app_path/Contents/Resources/HookFeed.icns" "$staging_path/HookFeed.iconset"

revision="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || printf 'unversioned')"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    revision="$revision-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :HookFeedBuildRevision string $revision" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :HookFeedBuildConfiguration string $configuration" "$app_path/Contents/Info.plist"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"

identity="${HOOKFEED_SIGN_IDENTITY:--}"
sign_options=(--force --sign "$identity")
if [ "$identity" = - ]; then
    sign_options+=(--timestamp=none)
else
    sign_options+=(--options runtime --timestamp)
fi

# Sign inside-out; the outer bundle must seal the final nested signatures.
framework="$app_path/Contents/Frameworks/Sparkle.framework"
for component in \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/Autoupdate" \
    "$framework/Versions/B/Updater.app" \
    "$framework"; do
    /usr/bin/codesign "${sign_options[@]}" "$component"
done

requirement_suffix=""
if [ "$identity" != - ]; then
    signing_info="$(/usr/bin/codesign -dv --verbose=4 "$framework" 2>&1)"
    team_id="$(printf '%s\n' "$signing_info" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        printf 'Signing identity must have a valid Apple Team ID.\n' >&2
        exit 1
    fi
    requirement_suffix=" and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\""
fi
/usr/bin/codesign "${sign_options[@]}" --identifier app.hookfeed.cli \
    --requirements "=designated => identifier \"app.hookfeed.cli\"$requirement_suffix" "$app_path/Contents/Helpers/hookfeed"
/usr/bin/codesign "${sign_options[@]}" --identifier app.hookfeed.HookFeed \
    --requirements "=designated => identifier \"app.hookfeed.HookFeed\"$requirement_suffix" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/codesign -dv --verbose=4 "$app_path"

# Only replace the prior output after the complete staged app passes verification.
if [ -e "$destination" ] || [ -L "$destination" ]; then
    mv "$destination" "$previous_app"
fi
mv "$app_path" "$destination"
printf '\nBuilt: %s\nCLI:   %s/Contents/Helpers/hookfeed\n' "$destination" "$destination"
