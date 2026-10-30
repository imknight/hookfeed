# Changelog

Each release publishes only its own section below as the GitHub release notes and
the in-app update notes. Headings must name the version, e.g. `## [0.2.0] - YYYY-MM-DD`.

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

[0.1.0]: https://github.com/imknight/hookfeed/releases/tag/v0.1.0
