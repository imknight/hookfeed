# Adding an integration

Integrations are compiled-in data in `Sources/HookFeedCore/Integrations.swift`. Payload parsers stay reviewed Swift code; this is not a plugin system.

1. Add one `Integration.all` entry with a stable source/id, name, summary, promise, route, config directory relative to HOME, executable name, snippets and setup prompt. Keep the displayed promise limited to demonstrated behavior. Settings cards, terminal prompts and detection use this registry.
2. Put prompt generation in `IntegrationPrompts`, then add the expected text to `Tests/HookFeedCLITests/Fixtures/setup-prompts.json`. Use the resolved bundled CLI path and the appropriate quoting for the target configuration. Set `rulesSource` for MCP agents; hook agents use nil.
3. For a hook agent, add the fixed parser in `HookPayload.draft`, capture a redacted real event fixture, and define its events in `HookAgent.hookEvents`. Test parsing, timeout 1, silent hook stdout, merge idempotency, removal, unrelated settings and stale-path repair. Hook installation edits JSON only.
4. For an MCP agent, verify its own CLI's add/list/test/remove commands non-interactively with closed stdin, a timeout and an isolated HOME. Record its version, argv, outputs and result with your contribution. Only a passing gate permits an `mcpCommand`. Otherwise leave it nil and keep the card copy-only. HookFeed must not edit YAML or TOML.
5. Add detection tests for a config directory, login-shell PATH, fallbacks and non-executable files. Inject fallback directories to avoid real installed tools in tests. Test command argv with spaces and apostrophes, list parsing, timeouts, failures and partial Connect all success using fake runners.
6. Record and inspect affected snapshots. Run `swift build`, `swift test`, `swift build --scratch-path .build-cli --product hookfeed`, `python3 scripts/test-cli.py`, and `python3 scripts/test-mcp.py`. Exercise the packaged app using temp HOME plus `HOOKFEED_CLAUDE_CONFIG_PATH` and `HOOKFEED_CODEX_CONFIG_PATH`. Compare real config files against pre-test backups.

Connect all is a review-first flow: detection does not install anything. It includes only detected, actionable integrations needing installation or stale-path repair. Applying the selection runs in registry order and reports each result independently. Changes to a JSON config after preview require a fresh preview.

As of 2026-10-26, Hermes is copy-only: v0.22.2 prompts for tool selection during `mcp add` and cancels on EOF even though it exits 0. The positive MCP command tests and two-agent Connect all snapshot use an explicitly synthetic descriptor; they do not prove unattended Hermes installation.

Grok Bot uses a generic, copy-only MCP entry because this repository has no verified Grok Bot config path or schema. Its examples assume stdio MCP on the same Mac or Streamable HTTP with a URL and bearer token remotely. The prompt asks the agent to find its own documented config format, sets `source` to `grokbot`, and offers `hookfeed send --source grokbot` for scripts. Detection checks only for an executable named `grokbot`; it does not guess a config directory or install command.
