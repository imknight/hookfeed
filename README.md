# HookFeed

Your agents. One inbox.

HookFeed is a native SwiftUI Mac app for updates from local agents and scripts. Version 0.1 targets macOS 14 or later, with a window, menu bar inbox, bundled CLI, and local stdio MCP entry point. Messages live in SQLite on your Mac. No account, API key, model inference, or inference bill is involved.

Visit [hookfeed.app](https://hookfeed.app) or browse the [documentation](docs/README.md) for setup, usage, and integration guides.

## Build and install

Use an Apple silicon Mac running macOS 14 or later with the full Xcode toolchain selected (`xcode-select -p`) and Swift 6 or later. Xcode 27 is the development toolchain. The first build downloads the Swift package dependencies declared in `Package.swift`: GRDB, Swift Argument Parser, the Swift MCP SDK, and Sparkle 2.10.1. Keep `Package.resolved` with the source revision for repeatable dependency resolution.

Clone the public repository:

```sh
git clone https://github.com/imknight/hookfeed.git
cd hookfeed
```

From a fresh checkout, build and install in two commands:

```sh
./scripts/build-app.sh          # swift build -c release, then package and sign
./scripts/install-app.sh --skip-build
```

The build creates `dist/HookFeed.app`, containing:

```text
Contents/Info.plist
Contents/MacOS/HookFeed
Contents/Helpers/hookfeed
Contents/Frameworks/Sparkle.framework
Contents/Resources/HookFeed.icns
```

Both executables come from one SwiftPM build, using `.build-package` as a separate scratch directory. The script verifies native binaries, copies dependency resource bundles, generates the icon with AppKit, signs the helper and app ad hoc with stable identifiers, and verifies the completed bundle before replacing the previous output. The app ID is `app.hookfeed.HookFeed`, version `0.1.0`, with no app sandbox or provisioning profile. This is a local development package. Certificate signing is available below; see [RELEASING.md](RELEASING.md) for notarization, dry runs and public releases. Universal binaries are not supported.

Sparkle updates are enabled only for non-debug builds signed by the official team (FDRSA4WESN). Ad hoc and debug builds never create an updater. The feed is `https://github.com/imknight/hookfeed/releases/latest/download/appcast.xml`; `SUPublicEDKey` in `Config/Info.plist` contains the official Sparkle public key. Only the public key belongs in source control. For every release, bump `CFBundleShortVersionString` and increase the integer `CFBundleVersion` above every previous release; never reuse a build number.

For Developer ID distribution, use an identity already installed in your Keychain:

```sh
HOOKFEED_SIGN_IDENTITY="Developer ID Application: Rework Labs (FDRSA4WESN)" ./scripts/build-app.sh
```

Certificate mode signs Sparkle’s nested code, framework, CLI, and app inside-out with hardened runtime and secure timestamps. The app and CLI designated requirements include the Team ID read from the signed framework. The CLI signing ID is `app.hookfeed.cli`; the app ID remains `app.hookfeed.HookFeed`. The Sparkle license is bundled in `Contents/Resources/Sparkle-LICENSE.txt`. Builds target arm64. An Apple Development identity may be used to exercise hardened runtime locally, but cannot produce a notarized public release. Apple Distribution certificates are for the App Store and must not be used for this release path.

Moving an existing ad hoc installation to Developer ID changes its designated requirement: existing Remote Keychain items may prompt once or become unreadable. Reconnect Remote clients if needed; the Keychain service and app preferences identifiers are unchanged.

For faster iteration, use `./scripts/build-app.sh --debug`. Set `HOOKFEED_BUILD_PATH` to change the scratch directory. Run `./scripts/install-app.sh --debug` to build and install a debug app, or `./scripts/install-app.sh` to build and install release. The installer stages and verifies a copy in the destination directory, keeps the existing bundle until replacement, and restores it if the replacement move fails. It uses `/Applications` when writable and otherwise `~/Applications`, prints the exact installed app and CLI paths, and needs no elevation. Quit the running app before installing and reopen afterward.

See [SETUP.md](SETUP.md) for launching, the CLI symlink, and integration templates. Installation does not modify any agent configuration or launch the app automatically.

## Xcode

Open `HookFeed.xcodeproj` and select the shared **HookFeed** scheme. Its aggregate target invokes `scripts/build-app.sh`; Debug uses `--debug`, and Release uses the release build. The scheme's Run action points to the resulting `dist/HookFeed.app`. The synchronized source folder includes new Swift files automatically, while SwiftPM owns source compilation, dependencies, and the `HookFeedCore` relationship.

This project is a build-and-run entry point, rather than a second native app target or an Xcode Archive pipeline. The packaged executable is the native SwiftUI app from the `HookFeedDesktop` SwiftPM product. Its name differs from `hookfeed` to avoid product-directory and binary collisions on a case-insensitive filesystem. For package-aware source navigation and tests, also open `Package.swift` in Xcode. From the terminal:

```sh
xcodebuild -project HookFeed.xcodeproj -scheme HookFeed -configuration Debug build
swift test
open dist/HookFeed.app
```

## Local behavior

The store is `~/Library/Application Support/HookFeed/inbox.sqlite`; hook diagnostics are in `~/Library/Logs/HookFeed/hook.log`. CLI sends can initialize the store before the app first runs. A successful receipt means saved, not read. With the app quit, sends persist and banners wait for future new activity while the app is running; old messages are not meant to replay as banners on launch.

Defaults are all-update notifications, no sound, and an attention-only menu bar count. Permission is requested after **Enable notifications** is clicked. System notification settings and Focus still govern delivery. The hook adapters are intended to fail open for the originating agent; configure one delivery route per agent to avoid duplicate updates. MCP sends depend on the agent choosing to call the tool.

## Tests

```sh
swift build
swift test
python3 scripts/test-cli.py
```

The CLI checks use the binary from `swift build` and isolated temporary data. The Tailscale route test is opt-in and skips unless `HOOKFEED_TEST_TAILSCALE_IP` is set. UI snapshot references are included; see [snapshot testing notes](Tests/HookFeedAppTests/README.md) for rendering requirements.

## License

HookFeed is open source under the [MIT License](LICENSE).
