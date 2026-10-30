#!/bin/bash
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { printf 'Usage: %s (--dry-run|--publish) vX.Y.Z\nDry run still signs and notarizes; only publication is skipped.\n' "$0"; }
if [ "$#" -eq 1 ] && [[ "$1" = --help || "$1" = -h ]]; then usage; exit 0; fi
if [ "$#" -ne 2 ] || [[ "$1" != --dry-run && "$1" != --publish ]]; then usage >&2; exit 2; fi
mode="$1"
tag="$2"
config="$(python3 "$ROOT/scripts/release-metadata.py" config "$tag")"
IFS=$'\t' read -r version build feed repository public_key <<< "$config"
[ "$(uname -sm)" = 'Darwin arm64' ] || { printf 'Release on an arm64 Mac.\n' >&2; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { printf 'Release requires a clean worktree.\n' >&2; exit 1; }
: "${HOOKFEED_SIGN_IDENTITY:?Set HOOKFEED_SIGN_IDENTITY to a Developer ID Application identity}"
HOOKFEED_NOTARY_PROFILE="${HOOKFEED_NOTARY_PROFILE:-hookfeed-notary}"
if [ "${CI:-false}" = true ]; then
    : "${SPARKLE_PRIVATE_KEY:?Provide the Sparkle private key through the CI secret}"
fi

if [ "$mode" = --publish ]; then
    [ "$(git -C "$ROOT" rev-parse "refs/tags/$tag^{commit}")" = "$(git -C "$ROOT" rev-parse HEAD)" ] || {
        printf 'Publishing requires the release tag at HEAD.\n' >&2; exit 1;
    }
    if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$GITHUB_REPOSITORY" != "$repository" ]; then
        printf 'Publishing must run in the configured public repository.\n' >&2; exit 1
    fi
    [ "$(gh api "repos/$repository" --jq .visibility)" = public ] || {
        printf 'Publishing requires a public repository.\n' >&2; exit 1;
    }
fi

mkdir -p "$ROOT/dist"
staging="$(mktemp -d "$ROOT/dist/.release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$staging/artifacts" "$staging/dmg-root"
artifacts="$staging/artifacts"
# Only an empty stable-release list is a first release; API/download errors are fatal.
gh api --paginate --slurp "repos/$repository/releases" > "$staging/releases.json"
stable_count="$(python3 - "$staging/releases.json" <<'PY'
import json, sys
pages = json.load(open(sys.argv[1]))
print(sum(not release['draft'] and not release['prerelease'] for page in pages for release in page))
PY
)"
if [ "$stable_count" -gt 0 ]; then
    curl --fail --location --retry 3 --silent --show-error "$feed" -o "$artifacts/appcast.xml"
    python3 "$ROOT/scripts/release-metadata.py" check-build "$tag" "$artifacts/appcast.xml"
fi

"$ROOT/scripts/build-app.sh"
app="$ROOT/dist/HookFeed.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :HookFeedBuildRevision' "$app/Contents/Info.plist")" = "$(git -C "$ROOT" rev-parse HEAD)" ]
codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "FDRSA4WESN" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
notary_options=(--keychain-profile "$HOOKFEED_NOTARY_PROFILE")
if [ -n "${HOOKFEED_NOTARY_KEYCHAIN:-}" ]; then notary_options+=(--keychain "$HOOKFEED_NOTARY_KEYCHAIN"); fi
notarize() {
    xcrun notarytool submit "$1" "${notary_options[@]}" --wait --output-format json > "$staging/notary-result.json"
    python3 - "$staging/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    sys.exit('Notarization failed; inspect submission ' + result.get('id', 'unknown') + ' using notarytool log')
PY
}
ditto -c -k --keepParent "$app" "$staging/notary-app.zip"
notarize "$staging/notary-app.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"
# The Sparkle archive must contain the stapled app; never modify it after signing.
ditto -c -k --keepParent "$app" "$artifacts/HookFeed-$version.zip"
ditto "$app" "$staging/dmg-root/HookFeed.app"
ln -s /Applications "$staging/dmg-root/Applications"
hdiutil create -volname HookFeed -srcfolder "$staging/dmg-root" -format UDZO "$staging/HookFeed-$version.dmg" >/dev/null
codesign --force --sign "$HOOKFEED_SIGN_IDENTITY" --timestamp "$staging/HookFeed-$version.dmg"
notarize "$staging/HookFeed-$version.dmg"
xcrun stapler staple "$staging/HookFeed-$version.dmg"

if [ -f "$ROOT/CHANGELOG.md" ]; then
    cp "$ROOT/CHANGELOG.md" "$staging/notes.md"
elif [ "$(git -C "$ROOT" cat-file -t "refs/tags/$tag" 2>/dev/null || true)" = tag ]; then
    git -C "$ROOT" for-each-ref --format='%(contents)' "refs/tags/$tag" > "$staging/notes.md"
elif [ "$mode" = --dry-run ]; then
    printf 'Dry run for HookFeed %s (build %s).\n' "$version" "$build" > "$staging/notes.md"
else
    printf 'Provide CHANGELOG.md or an annotated tag for release notes.\n' >&2; exit 1
fi
cp "$staging/notes.md" "$artifacts/HookFeed-$version.md"
scratch_path="${HOOKFEED_BUILD_PATH:-$ROOT/.build-package}"
case "$scratch_path" in /*) ;; *) scratch_path="$ROOT/$scratch_path" ;; esac
# These tools come from the checksum-verified SwiftPM artifact pinned in Package.resolved.
sparkle_bin="$scratch_path/artifacts/sparkle/Sparkle/bin"
appcast_options=(--maximum-versions 0 --maximum-deltas 0 --versions "$build"
    --embed-release-notes --download-url-prefix "https://github.com/$repository/releases/download/$tag/" "$artifacts")
if [ "${CI:-false}" = true ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - "${appcast_options[@]}"
else
    "$sparkle_bin/generate_appcast" --account hookfeed "${appcast_options[@]}"
fi
unset SPARKLE_PRIVATE_KEY
rm "$artifacts/HookFeed-$version.md"
# Keep the DMG out of generate_appcast so each build has exactly one zip enclosure.
mv "$staging/HookFeed-$version.dmg" "$artifacts/"
"$ROOT/scripts/verify-appcast.sh" "$tag" --local "$artifacts"
cp "$staging/notes.md" "$artifacts/release-notes.md"
rm -rf "$ROOT/dist/release"
mv "$artifacts" "$ROOT/dist/release"
artifacts="$ROOT/dist/release"
if [ "$mode" = --publish ]; then
    gh release create "$tag" --repo "$repository" --verify-tag --latest \
        --title "HookFeed $version" --notes-file "$artifacts/release-notes.md" \
        "$artifacts/HookFeed-$version.zip" "$artifacts/HookFeed-$version.dmg" "$artifacts/appcast.xml"
    "$ROOT/scripts/verify-appcast.sh" "$tag"
else
    printf 'Dry run complete: %s (nothing published).\n' "$artifacts"
fi
