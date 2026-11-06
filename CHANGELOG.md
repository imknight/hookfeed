# Changelog

Each release publishes only its own section below as the GitHub release notes and
the in-app update notes. Headings must name the version, e.g. `## [0.2.0] - YYYY-MM-DD`.

## [0.2.0] - 2026-11-07

### Added

- Optional background receiving keeps remote updates arriving after you quit the app. Enable **Receive while HookFeed is closed** in Settings → Remote; macOS may ask you to allow the background item. The CLI also gains `hookfeed serve`.
- A **Show in Dock** setting lets HookFeed run from the menu bar only.
- Tailscale HTTPS setup and reset controls in Settings → Remote, with confirmation before changing Serve mappings.
- A Grok Bot integration card with generic local and remote MCP setup instructions.
- A copyable Hermes MCP setup command with an optional profile in the Remote connection token sheet. Existing YAML setup remains available.

### Fixed

- Launching HookFeed again reopens the running inbox instead of starting a second instance.
- Feed rows keep stable spacing when incoming updates reorder threads, including at larger accessibility text sizes.
- Tailscale CLI discovery works with login-shell and Homebrew paths, and MCP accepts the detected MagicDNS hostname on forwarded ports.
- Background receiver handoff and recovery, including token revocation, locked-Keychain recovery, and token-cache invalidation after reauthorization.
- Hiding the Dock icon preserves the active window's focus.

### Changed

- Removed the Gemini CLI integration and its `hook gemini-cli` adapter. **Antigravity CLI (agy)** remains supported for completions and failures; permission and input events are not supported.
- Existing Gemini users should install or update **Antigravity CLI (agy)** in Settings → Integrations before starting a new `agy` session. Imported HookFeed Gemini handlers in `~/.gemini/config/hooks.json` show **Needs update** and are removed during installation after a backup. Manually added workspace or plugin hooks need updating separately.
- Hermes setup prompts now direct configuration changes to the active profile. The URL command uses `--auth header` and asks for the connection token interactively.

Requires an Apple silicon Mac running macOS 14 or later.

## [0.1.0] - 2026-10-31

First public release.

- Native SwiftUI inbox for updates from local agents and scripts, with a main window and a menu bar inbox
- Threads grouped by project, source and bot, with search, pinning and an attention-only view
- Markdown message bodies
- Optional macOS notifications, batched to avoid noise
- Bundled `hookfeed` CLI and a local stdio MCP server
- One-click setup for Claude Code, Codex, Cursor, Gemini CLI, Google Antigravity, Hermes Agent and OpenClaw
- Optional remote access over Tailscale with per-device tokens for the HTTP API and web MCP
- Messages stay in a local SQLite store; no account, API key or inference involved
- Signed, notarized and updated automatically with Sparkle

Requires an Apple silicon Mac running macOS 14 or later.

[0.2.0]: https://github.com/imknight/hookfeed/releases/tag/v0.2.0
[0.1.0]: https://github.com/imknight/hookfeed/releases/tag/v0.1.0
