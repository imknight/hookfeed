# OpenClaw integration

Checked 27 October 2026 against the current official docs and release
[v2026.10.7](https://github.com/openclaw/openclaw/releases/tag/v2026.10.7).
OpenClaw is not installed on the development Mac. All OpenClaw fixtures are
constructed from documentation/source, not captured sessions. **Real local and
remote delivery, completions, and input requests remain unverified.**

## Route decision

Use MCP with explicit when-to-send instructions, as with Hermes. This is
agent-directed notification, not automatic lifecycle delivery.

- [Internal hooks](https://docs.openclaw.ai/automation/hooks/event-types) report
  commands, session events, and message delivery outcomes. A message send is not
  a task completion, and observations may be omitted by some paths.
- [Plugin hooks](https://docs.openclaw.ai/plugins/hooks) include `agent_end`, but
  the catalog does not guarantee emission by every runtime. Its
  [turn semantics](https://docs.openclaw.ai/plugins/hooks/prompt-and-session)
  are generally fire-and-forget for channel-backed runs. This is not a reliable
  task-completion contract for the remote-first integration. It would also
  require installing a separate plugin on the agent host.
- [MCP configuration](https://docs.openclaw.ai/gateway/config-extensions) supports
  `mcp.servers.hookfeed` with either `command`/`args` or `url`,
  `transport: "streamable-http"`, and `headers.Authorization`.
- [Configuration location](https://docs.openclaw.ai/gateway/configuration) is
  `~/.openclaw/openclaw.json` (JSON5), with `OPENCLAW_CONFIG_PATH` overrides.
- [MCP setup](https://docs.openclaw.ai/tools/mcp) describes new/reset sessions
  after configuration changes. Persist instructions in the active agent
  workspace's AGENTS.md, not in the config file.
- [CLI registry](https://docs.openclaw.ai/cli/mcp/registry) documents `add` with
  repeatable `--arg`, `list`, `unset`, and `probe`. The
  [v2026.10.7 CLI source](https://github.com/openclaw/openclaw/blob/v2026.10.7/src/cli/mcp-cli.ts)
  confirms bullet-prefixed list output and add refusing existing names.

## Scope and fixtures

The registry adds local detection, the integration card, setup prompt, and local
Connect all support. Remote hosts do not need a local OpenClaw installation:
use Settings → Remote and configure the URL/token on that host. The
`openclawRemote(url:token:)` builder appends `/mcp` to the connection base URL
and JSON-escapes credentials. The remote token sheet includes this MCP example.

`Tests/HookFeedCoreTests/Fixtures/openclaw-local.json` and
`openclaw-remote.json` are minimal examples derived from the official MCP
configuration schema. `openclaw-list.txt` models the CLI source's output with
invented paths/server names. The setup prompt fixture records the complete
instructions including remote setup, preservation, reload, test, and rules.
No hook payloads are invented or labelled as real captures: the route is MCP,
so HookAgent/install/merge/payload changes and hook-only tests do not apply.

## Acceptance on an OpenClaw host (pending)

1. Create a HookFeed remote connection and use a reachable base URL and bearer
   token in the remote builder output. Merge into the active OpenClaw config,
   preserving other servers and JSON5 content.
2. Run `openclaw mcp probe hookfeed`, then start a new/reset session.
3. Paste the when-to-send rules into the active workspace instructions and send
   the connection test. Verify the actual HookFeed inbox message.
4. Finish a task and ask a question requiring user input. Confirm `completed`
   and `needs_attention` messages with source `openclaw`, bot/project/workdir,
   and a stable per-task thread key. Verify failure reporting too.
5. For local acceptance, use the same-Mac stdio config and verify Connect all,
   probe, actual message delivery, and removal. A mocked CLI test or successful
   probe does not establish any of these real-agent outcomes.
