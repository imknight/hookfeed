# Releasing HookFeed

The release pipeline produces arm64, unsandboxed, Developer ID signed and notarized downloads. Updates use Sparkle 2.10.1 and GitHub Release assets. Local ad hoc builds cannot update themselves.

## Before the first release

- The public repository is [imknight/hookfeed](https://github.com/imknight/hookfeed). **The one repository setting is `SUFeedURL` in `Config/Info.plist`: `https://github.com/imknight/hookfeed/releases/latest/download/appcast.xml`.** Both release scripts derive the repository from it. Zip enclosure URLs are `https://github.com/imknight/hookfeed/releases/download/vX.Y.Z/HookFeed-X.Y.Z.zip`. No feed or release archive is hosted on hookfeed.app.
- `SUPublicEDKey` is configured with the official public key. Official releases require the corresponding private key in the login Keychain under the Sparkle item label `hookfeed`, selected with `generate_keys --account hookfeed`. Back up the signing key securely. The tools are in `.build-package/artifacts/sparkle/Sparkle/bin/` after a build. Never commit the private key or paste it into an issue.
- Official releases use `Developer ID Application: Rework Labs (FDRSA4WESN)`. Install the certificate and private key in your Keychain and provide its protected export to CI. Apple Development can test hardened runtime, but is not a distribution identity; Apple Distribution is for the App Store.
- Add these six GitHub Actions secrets using GitHub's private secret-entry UI:

| Secret | Value |
| --- | --- |
| `MACOS_SIGNING_P12` | Base64-encoded export of the Developer ID certificate **and private key** |
| `MACOS_SIGNING_P12_PASSWORD` | Password protecting that export |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_PRIVATE_KEY_P8` | The API key's full PEM text, not base64 |
| `SPARKLE_PRIVATE_KEY` | The base64 key string exported from Sparkle account `hookfeed` using `generate_keys --account hookfeed -x` |

Optionally add `HOMEBREW_TAP_TOKEN`: a fine-grained personal access token with **Contents: read and write** on `imknight/homebrew-tap` only. On publish, the workflow sets the cask's `version` and `sha256` from the verified zip and pushes to the tap. Without it, the step warns and the cask must be updated by hand.

The workflow uses the built-in `GITHUB_TOKEN` with `contents: write`; no personal token or cloud storage credentials are needed. It imports signing material into a temporary keychain, stores notary credentials there, and always deletes that keychain and temporary files. Only the verified release output directory is uploaded as artifacts.

Repository and public-key configuration is ready. A dry run reads the public repository's feed and never publishes; the destination repository must exist so the script can distinguish a first release from an API failure.

## Version, test, dry run

1. Set `CFBundleShortVersionString` to `X.Y.Z` and `CFBundleVersion` to a positive integer greater than every previously shipped build (including withdrawn releases). Never reuse a build number. Commit these changes with a `## [X.Y.Z] - YYYY-MM-DD` section in `CHANGELOG.md`, or use an annotated tag's message for release notes.
2. Run the local checks below. No snapshot regeneration is required for the General settings update section.
3. Dispatch **Release** on the desired branch with `tag: vX.Y.Z` and `dry_run: true`. The tag need not exist for a branch dry run; its version must match Info.plist.
4. Download the workflow artifact. Test the DMG on another Mac or a fresh user account before publishing.

```sh
swift test
./scripts/build-app.sh
HOOKFEED_CLI=dist/HookFeed.app/Contents/Helpers/hookfeed python3 scripts/test-cli.py
HOOKFEED_CLI=dist/HookFeed.app/Contents/Helpers/hookfeed python3 scripts/test-mcp.py
python3 scripts/test-release.py
bash -n scripts/build-app.sh scripts/release.sh scripts/verify-appcast.sh
```

The release tests generate disposable signing keys outside the repo, use the real pinned Sparkle tools, verify signatures, reject same-length tampering and invalid metadata, and check that a new feed preserves the previous item even without the previous zip. They do **not** test notarization or publication.

A dry run performs the same build, signing, Apple notarization, stapling, zip/DMG packaging, cumulative appcast generation and local verification as a real release. It skips GitHub Release creation and public-download verification; artifacts are uploaded to the workflow run. In GitHub Actions it still requires all six secrets and contacts Apple. Local runs use the existing signing identity, notary profile and Sparkle Keychain account instead.

## Run locally

Use an arm64 Mac, full Xcode, Python 3, and authenticated `gh`. Install the Developer ID identity in your Keychain. Create a local notarytool Keychain profile named `hookfeed-notary` with your own Apple notarization credentials before running a release. Keep credential files outside the repo.

```sh
export HOOKFEED_SIGN_IDENTITY='Developer ID Application: Rework Labs (FDRSA4WESN)'
# Optional override; the local default is hookfeed-notary.
export HOOKFEED_NOTARY_PROFILE='hookfeed-notary'
# Sparkle reads the existing login Keychain account hookfeed; no key export needed.
./scripts/release.sh --dry-run vX.Y.Z
```

`HOOKFEED_NOTARY_PROFILE` defaults to `hookfeed-notary`; CI overrides it with the temporary profile it creates. `HOOKFEED_NOTARY_KEYCHAIN` may select the keychain containing that profile; otherwise notarytool uses the default search list. `HOOKFEED_BUILD_PATH` retains its build-script meaning. The release script rejects a dirty worktree, mismatched tag/version, unresolved configuration, and a build number no higher than the current appcast's builds. It requires the signed app to be a Developer ID build from FDRSA4WESN.

Local `release.sh` calls `generate_appcast --account hookfeed`, which signs the archives itself. For manual archive signing, also select that account explicitly:

```sh
.build-package/artifacts/sparkle/Sparkle/bin/sign_update --account hookfeed /path/to/HookFeed-X.Y.Z.zip
```

In CI (`CI=true`, as set by GitHub Actions), the script requires `SPARKLE_PRIVATE_KEY` and passes it on standard input with `generate_appcast --ed-key-file -`; it never falls back to a runner's Keychain. Any manual CI `sign_update` invocation must likewise use `--ed-key-file -` with the secret on standard input. Local runs ignore an inherited `SPARKLE_PRIVATE_KEY` and use account `hookfeed`. No private key is written into the repository or release artifacts.

Output is `dist/release/`: versioned zip and DMG, cumulative `appcast.xml`, and `release-notes.md`. Existing output is replaced only after the new output passes local verification. The app is stapled **before** the Sparkle zip is made; the DMG is signed, notarized and stapled separately. Sparkle tools come from the exact, checksum-verified SwiftPM dependency, so there is no separate tool-version setting.

## Publish

After reviewing the dry run, create an annotated `vX.Y.Z` tag at the exact tested commit and push it to the **public** repository. The `v*` workflow runs on an arm64 macOS runner. Alternatively, from that clean tagged checkout, run `./scripts/release.sh --publish vX.Y.Z` with the same local credentials. Manual workflow dispatch with `dry_run: false` also requires the selected checkout's HEAD to equal the specified tag.

Publication uses `gh release create --verify-tag`; it does not create or push a tag. It uploads `HookFeed-X.Y.Z.zip`, `HookFeed-X.Y.Z.dmg` and the complete `appcast.xml`. Notes come from the matching version section of `CHANGELOG.md` (never the whole file), otherwise the annotated tag; an empty section fails before building. It never overwrites an existing release.

The post-publication check fetches the configured **latest** appcast and both assets without authentication, checks version/build, the exact enclosure URL and zip length, verifies Ed25519 against `SUPublicEDKey`, then checks signatures, Gatekeeper's `Notarized Developer ID` assessment and staple tickets. It also mounts the DMG read-only and verifies its bundled app. Run it again with:

```sh
./scripts/verify-appcast.sh vX.Y.Z
# Or recheck locally built artifacts, without downloading:
./scripts/verify-appcast.sh vX.Y.Z --local dist/release
```

A failed post-publication verification fails the job but leaves the release available for inspection/rollback; it does not silently delete it. For the first release, manually confirm an installed older official build discovers the update, installs, and relaunches without a Gatekeeper warning. Also verify the automatic-check toggle survives relaunch. These checks cannot be replaced by build or signature tests.

## Roll back

Mark the bad release as a prerelease or delete it so GitHub's latest stable release points back to the prior release and its cumulative appcast. Confirm the latest appcast URL resolves to that prior feed and rerun the verifier from the prior version's checkout. If necessary, explicitly mark the prior release as latest in GitHub. Already-updated installations will not automatically downgrade; ship a fix with a new, higher build number.

Decide separately whether to add a stable unversioned DMG asset for the landing page. This workflow publishes versioned assets only. Verify the landing-page download link and the first real update/relaunch before announcing a release.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
