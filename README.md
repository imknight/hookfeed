# HookFeed

Your agents. One inbox.

**[hookfeed.app](https://hookfeed.app)** · [Download](https://github.com/imknight/hookfeed/releases/latest) · [Documentation](docs/README.md)

HookFeed is a native Mac app that collects updates from local agents and scripts in one inbox: finished work, failures, and requests for input. Messages stay in a local SQLite store. No account, API key, or model inference is involved.

- Main window and menu bar inbox, with threads grouped by project, source and bot
- Search, pinning, an attention-only view, and Markdown message bodies
- Optional macOS notifications, batched to avoid noise
- Bundled `hookfeed` CLI and a local stdio MCP server
- One-click setup for Claude Code, Codex, Cursor, Antigravity CLI (`agy`), Hermes Agent and OpenClaw
- Optional remote access over Tailscale with per-device tokens
- Signed, notarized, and updated automatically with Sparkle

Requires an Apple silicon Mac running macOS 14 or later.

## Install

### Homebrew

```sh
brew tap imknight/tap
brew trust imknight/tap
brew install --cask hookfeed
```

This installs the app and links the `hookfeed` CLI onto your PATH. HookFeed updates itself, so `brew upgrade` leaves it alone. `brew uninstall --cask --zap hookfeed` also removes your inbox and preferences.

### Download

Download `HookFeed-X.Y.Z.dmg` from [hookfeed.app](https://hookfeed.app) or the [latest release](https://github.com/imknight/hookfeed/releases/latest), and drag HookFeed to Applications. To use the CLI, choose **Install for me** in **Settings → Integrations → Command-line tool**.

### Build from source

```sh
git clone https://github.com/imknight/hookfeed.git
cd hookfeed
./scripts/build-app.sh
./scripts/install-app.sh --skip-build
```

Requires the full Xcode toolchain with Swift 6 or later. See [DEVELOPMENT.md](DEVELOPMENT.md) for debug builds, signing, Xcode and tests.

## Quick start

Open HookFeed and go to **Settings → Integrations** to connect your agents and send a test message. From a terminal:

```sh
hookfeed send "Hello from HookFeed" --source cli --kind info
hookfeed run --project MyProject -- make test   # report when a command finishes or fails
```

See [SETUP.md](SETUP.md) for integration templates and the [app guide](docs/guides/app-guide.md) for everyday use. Release history is in [CHANGELOG.md](CHANGELOG.md).

## Privacy

Messages stay on your Mac in `~/Library/Application Support/HookFeed/inbox.sqlite`. No account, API key, model inference, or hosted relay is involved. See [SETUP.md](SETUP.md#notifications-and-storage) for storage, logs and notification defaults.

## License

HookFeed is open source under the [MIT License](LICENSE).
