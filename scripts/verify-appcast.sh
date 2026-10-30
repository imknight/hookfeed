#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { printf 'Usage: %s vX.Y.Z [--local ARTIFACT_DIRECTORY]\n' "$0"; }
if [ "$#" -eq 1 ] && [[ "$1" = --help || "$1" = -h ]]; then usage; exit 0; fi
if [ "$#" -ne 1 ] && { [ "$#" -ne 3 ] || [ "$2" != --local ]; }; then usage >&2; exit 2; fi
tag="$1"
config="$(python3 "$ROOT/scripts/release-metadata.py" config "$tag")"
IFS=$'\t' read -r version build feed repository public_key <<< "$config"
temporary="$(mktemp -d)"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then hdiutil detach "$temporary/mount" >/dev/null; fi
    rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$#" -eq 3 ]; then
    artifacts="$(cd "$3" && pwd)"
    cp "$artifacts/appcast.xml" "$temporary/appcast.xml"
else
    artifacts="$temporary"
    curl --fail --location --retry 3 --silent --show-error "$feed" -o "$temporary/appcast.xml"
fi
metadata="$(python3 "$ROOT/scripts/release-metadata.py" enclosure "$tag" "$temporary/appcast.xml")"
IFS=$'\t' read -r url length signature <<< "$metadata"
zip="$artifacts/HookFeed-$version.zip"
dmg="$artifacts/HookFeed-$version.dmg"
if [ "$#" -eq 1 ]; then
    curl --fail --location --retry 3 --silent --show-error "$url" -o "$zip"
    curl --fail --location --retry 3 --silent --show-error "https://github.com/$repository/releases/download/$tag/HookFeed-$version.dmg" -o "$dmg"
fi
[ "$(stat -f %z "$zip")" = "$length" ] || { printf 'Enclosure length mismatch\n' >&2; exit 1; }
swift "$ROOT/scripts/verify-update-signature.swift" "$zip" "$public_key" "$signature"
ditto -x -k "$zip" "$temporary/unpacked"
verify_app() {
    local app="$1" assessment
    codesign --verify --deep --strict -R='identifier "app.hookfeed.HookFeed" and anchor apple generic and certificate leaf[subject.OU] = "FDRSA4WESN" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "$build" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = "$public_key" ]
    assessment="$(spctl --assess --type execute -vv "$app" 2>&1)"
    printf '%s\n' "$assessment"
    [[ "$assessment" = *'source=Notarized Developer ID'* ]]
    xcrun stapler validate "$app"
}
verify_app "$temporary/unpacked/HookFeed.app"
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "FDRSA4WESN" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$dmg"
assessment="$(spctl --assess --type open --context context:primary-signature -vv "$dmg" 2>&1)"
printf '%s\n' "$assessment"
[[ "$assessment" = *'source=Notarized Developer ID'* ]]
xcrun stapler validate "$dmg"
mkdir "$temporary/mount"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$temporary/mount" >/dev/null
mounted=true
verify_app "$temporary/mount/HookFeed.app"
printf 'Verified %s: appcast, zip signature, app and DMG Gatekeeper assessments and staples.\n' "$tag"
