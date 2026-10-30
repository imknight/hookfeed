# Cursor integration

Checked 2026-10-27 against Cursor's rolling official documentation:

- [Hooks](https://cursor.com/docs/hooks): user config `~/.cursor/hooks.json`, configuration version **1**, flat `hooks.stop` command entries, common input fields and stop status.
- [MCP](https://cursor.com/docs/mcp): `~/.cursor/mcp.json`, `mcpServers`, stdio `command`/`args`, remote Streamable HTTP `url`/`headers`.
- [CLI](https://cursor.com/docs/cli/using): MCP and CLI usage. CLI hook delivery remains unverified.

No Cursor application release was installed or tested; these pages are not version-pinned. Fixture `cursor_version` values are deliberately labeled `docs-fixture`.

## Choice and scope

Hooks are the default because they report local agent completion without relying on model instructions. Install and Connect all merge a `stop` command calling `hookfeed hook cursor`; existing settings and other hooks survive. Cursor is detected through `cursor-agent`, `cursor`, `.cursor`, or `Cursor.app` in /Applications or ~/Applications.

The payload adapter uses the first workspace root and conversation ID for project and thread grouping. Completed, error and aborted stops become completed, failed and informational messages. Stop has no final response text; the body reports status. No transcript is read.

There is no documented permission-wait notification. The pre-execution policy hooks can return an approval decision but fire before ordinary operations too; HookFeed does not install them or emit misleading needs-input alerts. MCP fallback instructions allow agent-requested needs-attention updates and richer summaries. Use one completion route per session to avoid duplicate messages.

The setup prompt includes the local MCP fallback. The remote token sheet includes copyable Cursor MCP configuration. Cloud agents do not load this Mac's user hooks. Their repository hooks require a separately available binary and delivery endpoint; this local install does not configure cloud VMs.

## Verification boundary

The JSON fixtures in Tests/HookFeedCoreTests/Fixtures are constructed from the documented schema, not captured sessions. Swift tests cover mapping, configuration merging, registry, detection, escaping, stale status, installation and Connect all. The CLI black-box suite submits these fixtures into an isolated inbox.

**Real Cursor delivery is unverified**, including IDE, cursor-agent, background/cloud sessions, and permission/input requests. Cursor is not installed on this Mac.
