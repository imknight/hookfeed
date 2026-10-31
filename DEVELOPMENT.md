# Developing HookFeed

Build, sign and test HookFeed from source. For installing a release, see the [README](README.md); for publishing one, see [RELEASING.md](RELEASING.md).

## Build and install

Use the full Xcode toolchain (`xcode-select -p`) with Swift 6 or later; Xcode 27 is the development toolchain. The first build downloads the dependencies declared in `Package.swift`: GRDB, Swift Argument Parser, the Swift MCP SDK, and Sparkle 2.10.1. Keep `Package.resolved` with the source revision for repeatable dependency resolution.

```sh
git clone https://github.com/imknight/hookfeed.git
cd hookfeed
./scripts/build-app.sh          # swift build -c release, then package and sign
./scripts/install-app.sh --skip-build
```

The build creates `dist/HookFeed.app`:

```text
Contents/Info.plist
Contents/MacOS/HookFeed
Contents/Helpers/hookfeed
Contents/Frameworks/Sparkle.framework
Contents/Resources/HookFeed.icns
```

Both executables come from one SwiftPM build, using `.build-package` as a separate scratch directory. The script verifies native binaries, copies dependency resource bundles, generates the icon with AppKit, signs the helper and app ad hoc with stable identifiers, and verifies the completed bundle before replacing the previous output. The app ID is `app.hookfeed.HookFeed`, with no app sandbox or provisioning profile. Builds target arm64; universal binaries are not supported.

For faster iteration, use `./scripts/build-app.sh --debug`. Set `HOOKFEED_BUILD_PATH` to change the scratch directory. Run `./scripts/install-app.sh --debug` to build and install a debug app, or `./scripts/install-app.sh` to build and install release. The installer stages and verifies a copy in the destination directory, keeps the existing bundle until replacement, and restores it if the replacement move fails. It uses `/Applications` when writable and otherwise `~/Applications`, prints the exact installed app and CLI paths, and needs no elevation. Quit the running app before installing and reopen afterward. Installation does not modify any agent configuration or launch the app automatically; see [SETUP.md](SETUP.md) for the CLI symlink.

## Signing and updates

Local builds are ad hoc signed and never update themselves. Sparkle updates are enabled only for non-debug builds signed by the official team (FDRSA4WESN). The feed is `https://github.com/imknight/hookfeed/releases/latest/download/appcast.xml`, and `SUPublicEDKey` in `Config/Info.plist` holds the official Sparkle public key. Only the public key belongs in source control.

For Developer ID signing, use an identity already installed in your Keychain:

```sh
HOOKFEED_SIGN_IDENTITY="Developer ID Application: Rework Labs (FDRSA4WESN)" ./scripts/build-app.sh
```

Certificate mode signs Sparkle’s nested code, framework, CLI, and app inside-out with hardened runtime and secure timestamps. The app and CLI designated requirements include the Team ID read from the signed framework. The CLI signing ID is `app.hookfeed.cli`. The Sparkle license is bundled in `Contents/Resources/Sparkle-LICENSE.txt`. An Apple Development identity can exercise hardened runtime locally but cannot produce a notarized release; Apple Distribution certificates are for the App Store and must not be used here.

Moving an existing ad hoc installation to Developer ID changes its designated requirement: existing Remote Keychain items may prompt once or become unreadable. Reconnect Remote clients if needed; the Keychain service and app preferences identifiers are unchanged.

Notarization, dry runs, the Homebrew cask, and public releases are covered in [RELEASING.md](RELEASING.md).

## Xcode

Open `HookFeed.xcodeproj` and select the shared **HookFeed** scheme. Its aggregate target invokes `scripts/build-app.sh`; Debug uses `--debug`, and Release uses the release build. The scheme's Run action points to the resulting `dist/HookFeed.app`. The synchronized source folder includes new Swift files automatically, while SwiftPM owns source compilation, dependencies, and the `HookFeedCore` relationship.

This project is a build-and-run entry point, rather than a second native app target or an Xcode Archive pipeline. The packaged executable is the native SwiftUI app from the `HookFeedDesktop` SwiftPM product. Its name differs from `hookfeed` to avoid product-directory and binary collisions on a case-insensitive filesystem. For package-aware source navigation and tests, also open `Package.swift` in Xcode. From the terminal:

```sh
xcodebuild -project HookFeed.xcodeproj -scheme HookFeed -configuration Debug build
swift test
open dist/HookFeed.app
```

## Tests

```sh
swift build
swift test
python3 scripts/test-cli.py
```

The CLI checks use the binary from `swift build` and isolated temporary data. The Tailscale route test is opt-in and skips unless `HOOKFEED_TEST_TAILSCALE_IP` is set. UI snapshot references are included; see [snapshot testing notes](Tests/HookFeedAppTests/README.md) for rendering requirements.
