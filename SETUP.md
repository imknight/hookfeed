# HookFeed setup

Requires an Apple silicon Mac running macOS 14+.

## Install with Homebrew

```sh
brew tap imknight/tap
brew trust imknight/tap
brew install --cask hookfeed
open -a HookFeed
hookfeed --version
```

The cask installs the signed release app and links its bundled CLI onto your Homebrew PATH, so skip the symlink step below. HookFeed updates itself with Sparkle; `brew upgrade` leaves it alone. `brew uninstall --cask --zap hookfeed` also removes the inbox database and preferences. The integration examples below use `/Applications/HookFeed.app/Contents/Helpers/hookfeed`, which is where Homebrew installs it.

## Build from source

Building requires the full Xcode toolchain with Swift 6 or later. Run from this checkout:

```sh
./scripts/build-app.sh
./scripts/install-app.sh --skip-build
```

For development use `./scripts/build-app.sh --debug`. Installation uses `/Applications/HookFeed.app` if `/Applications` is writable, otherwise `~/Applications/HookFeed.app`. The installer prints the exact destination; it does not launch the app, create a CLI symlink, or change agent settings. Quit HookFeed before replacing an existing install.

Set `HOOKFEED_APP` to the absolute destination printed by the installer, then launch it and expose its bundled CLI:

```sh
HOOKFEED_APP="/Applications/HookFeed.app"
# For the fallback install instead:
# HOOKFEED_APP="$HOME/Applications/HookFeed.app"
open "$HOOKFEED_APP"
mkdir -p "$HOME/.local/bin"
ln -sfn "$HOOKFEED_APP/Contents/Helpers/hookfeed" "$HOME/.local/bin/hookfeed"
export PATH="$HOME/.local/bin:$PATH"
hookfeed --version
hookfeed send "Hello from HookFeed" --source cli --kind info
```

Add the PATH line to your shell configuration if needed. Agent clients should use the absolute bundled CLI path, because their PATH may differ from your terminal's. The examples below use `/Applications/HookFeed.app/Contents/Helpers/hookfeed`; for a fallback install, replace that entire path with the full path to `~/Applications/HookFeed.app/Contents/Helpers/hookfeed`, expanding `~` to your home directory.

## Notifications and storage

Click **Enable notifications** in HookFeed to request permission. Defaults: **All updates**, no sound, and badge counts for unread attention/failed threads. Confirm banner delivery on your own Mac; permissions and Focus settings affect it. If a permission alert was dismissed, enable HookFeed in System Settings → Notifications.

Data stays in `~/Library/Application Support/HookFeed/inbox.sqlite`; hook logs are in `~/Library/Logs/HookFeed/hook.log`. No account, API key, model inference, network listener, or hosted relay is required. The CLI can create the store before the app runs. A receipt means stored locally, not seen. Agents may need write access to that folder under their own sandbox settings.

## Burst delivery and queued hooks

HookFeed uses SQLite WAL so inbox reads do not block writers. When a local hook cannot acquire storage in time, it queues the normalized update in `spool/` beside `inbox.sqlite`. `HOOKFEED_STORE_PATH` moves both together. The directory is private (0700), each JSON file is private (0600), and no raw hook payload or transcript is queued. The queue is capped at 10,000 files; a full or unwritable queue drops the update and logs a diagnostic.

The app drains up to 500 files per pass on launch, change signals and its five-second timer, off the main thread. If the app is closed, run:

```sh
hookfeed drain
```

This moves queued updates into SQLite and reports how many were inserted. Files are deleted only after commit; replaying a file is deduplicated. Updates retain the time they were queued, while inbox order follows arrival sequence. Invalid/unreadable files move to `spool/rejected/` for inspection. There is no background daemon.

If updates seem missing, open HookFeed or run `hookfeed drain`, then inspect `spool/`, `spool/rejected/` and `~/Library/Logs/HookFeed/hook.log` (or `HOOKFEED_LOG_PATH`). Check disk space and directory permissions. The 450 ms local / 5.6 s remote hook watchdogs remain unchanged, and hooks always exit 0 without stdout; an unavailable filesystem or exhausted queue can still prevent delivery. Only local hooks spool. `send`, `run`, MCP and the remote receiver continue to report storage errors to their callers.

The app coalesces change signals over 150 ms and merges newly arrived rows; local edits, activation and reopening force a full reload. Eligible notifications collect for one second: more than five updates produce one summary, otherwise the latest update per thread is shown.

At 64 active connections, Remote responds with HTTP 503 and `Retry-After: 1`. The CLI retries connection failures and 503 responses up to three times using the same idempotency key (generating `retry:<uuid>` if needed). Delays are 0.5, 1 and 2 seconds, shortened by a smaller numeric `Retry-After`, with a five-second overall request budget. An unconfirmed remote send is never silently stored locally.

## Detect and connect agents

In **Settings → Integrations**, HookFeed detects Claude Code, Codex and Hermes from their config directories under HOME or executables on the login-shell PATH (with common binary-directory fallbacks). When installable agents need setup, choose **Review and connect…**, inspect **Show changes**, select the agents, then click **Connect N**. The welcome checklist also offers **Connect detected agents…**. Detection writes nothing.

Connect all installs selected agents one at a time and reports each result. JSON configs are backed up beside the original; unrelated settings remain. A moved HookFeed app's old command path is repaired in place. If a config changes after preview, reopen the review before applying. After connecting Codex, open `/hooks` and trust the HookFeed hooks.

Hermes currently stays **copy-only**, so it is not counted in Connect all and has no Install/Remove buttons. The 2026-10-26 gate found that Hermes v0.22.2 `mcp add` prompts for tool selection and cancels with closed stdin. Use **Copy setup prompt**, or `hookfeed prompt hermes`, instead. HookFeed never edits Hermes YAML. Future MCP Install support requires a verified non-interactive agent CLI; see [adding an integration](docs/guides/adding-an-integration.md).

## Setup prompts from the terminal

Run `hookfeed prompt hermes` and paste the output into Hermes to set up its stdio MCP server and when-to-send rules. The same prompts are available under **Settings → Integrations → Copy setup prompt**. Supported agents: `hermes`, `mcp`, `claude-code`, `codex`, `openclaw`, `antigravity`, `gemini-cli`, and `cursor`.

Use `hookfeed prompt hermes --rules-only` for just the rules, including source `"hermes"`. `--rules-only` works for every agent. Setup prompts resolve the running executable's symlinks, so configs use the actual bundled helper path. Printing a prompt does not change agent configuration.

## Claude Code hooks

Claude Code hooks use `~/.claude/settings.json`. Merge the following into the existing hooks object; keep other settings and hooks, and save a backup first. The build scripts themselves do not change integrations.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"/Applications/HookFeed.app/Contents/Helpers/hookfeed\" hook claude-code"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|elicitation_dialog|agent_needs_input",
        "hooks": [
          {
            "type": "command",
            "command": "\"/Applications/HookFeed.app/Contents/Helpers/hookfeed\" hook claude-code"
          }
        ]
      }
    ]
  }
}
```

The adapter consumes hook JSON on stdin, groups updates by session, and is designed to exit successfully without stdout even when a payload or store fails. Confirm one real completed turn, then one real attention prompt. Inspect the inbox and `hook.log`; fixture-based parsing alone is not live verification.

## Codex completions and approvals

Codex 0.164.0 has stable hooks enabled. The recommended Stop and PermissionRequest configuration for `~/.codex/hooks.json` is:

```json
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"/Applications/HookFeed.app/Contents/Helpers/hookfeed\" hook codex", "timeout": 1}]}
    ],
    "PermissionRequest": [
      {"hooks": [{"type": "command", "command": "\"/Applications/HookFeed.app/Contents/Helpers/hookfeed\" hook codex", "timeout": 1}]}
    ]
  }
}
```

Review and trust the definition through `/hooks` in Codex. This flow is documented in the [official hooks guide](https://learn.chatgpt.com/docs/hooks); real Stop and PermissionRequest payloads were captured in an isolated test; trusting your own hooks remains a user step.

The legacy alternative was demonstrated with a real Codex session under the read-only sandbox. Put this at the top level of `~/.codex/config.toml`:

```toml
notify = ["/Applications/HookFeed.app/Contents/Helpers/hookfeed", "hook", "codex"]
```

Reconcile any existing notify command before changing it. Use Stop **or** notify for a session to avoid duplicates. Legacy notify supports completions only; approval requests require the hooks above. See the [official notify documentation](https://learn.chatgpt.com/docs/config-file/config-advanced).

### Approval event verification (2026-10-26)

Codex 0.164.0 emits [`PermissionRequest`](https://learn.chatgpt.com/docs/hooks#permissionrequest) before asking permission. HookFeed records it as `needs_attention`, with the tool command/name and input, in the same session thread as Stop. It emits no approval decision. Identical retries within a turn deduplicate; different request content is retained. Reinstall through Settings to add the event to an existing Stop-only configuration, then review both hooks through `/hooks`.

Captured with the real Codex app-server and a deterministic local Responses test server in a temporary `CODEX_HOME`: the test requested escalation for `printf hookfeed-approval-capture`, received an approval request, declined it, and captured the subsequent Stop. Only the temporary capture hooks were trusted. No real account, real `~/.codex` configuration, or approved command was used. Redacted fixtures and their provenance are in `Tests/HookFeedCLITests/Fixtures/README.md`.

This covers permission requests, not arbitrary questions or `request_user_input`; no standalone input-wait hook was demonstrated. Verify a real interactive approval prompt and menu-bar update in your own installation. Legacy `notify`'s `agent-turn-complete` and terminal-only `tui.notifications` are not approval-hook substitutes.

### Copy resume command (verified 2026-10-26)

Installed `codex --version` and npm's latest stable `@openai/codex` both report **0.164.0**. `codex resume --help` accepts `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`. HookFeed keeps `codex resume '<session-id>'`: the Stop hook's `session_id` and legacy notify's `thread-id` are both session identifiers, not turn IDs. The adapter preserves them as `Message.sessionID`; tests pin that mapping and shell quoting for Codex and Claude Code.

An explicit session ID can be resumed from another directory. Codex asks which working directory to use when it differs from the saved one (unless `tui.resume_cwd` selects it); `--cd` overrides that choice. No `cd` prefix is required, so the copy-only command is unchanged. See the [resume reference](https://learn.chatgpt.com/docs/developer-commands#codex-resume), [hook fields](https://learn.chatgpt.com/docs/hooks#common-input-fields), and [legacy notify fields](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications). This verifies syntax and field contracts, not a real resumed session.

To check your installation, finish a real Stop-hook session, copy its resume command in HookFeed, paste it into a terminal in a different folder, choose the saved directory, and confirm the exact conversation. Repeat for a legacy-notify session if still used; do not enable both delivery routes for the same session. A Claude Code resume remains a separate sanity check.

## Other MCP clients

For clients using an `mcpServers` JSON configuration, merge this local stdio server entry:

```json
{
  "mcpServers": {
    "hookfeed": {
      "command": "/Applications/HookFeed.app/Contents/Helpers/hookfeed",
      "args": ["mcp"]
    }
  }
}
```

For Codex's TOML MCP configuration, the equivalent entry is:

```toml
[mcp_servers.hookfeed]
command = "/Applications/HookFeed.app/Contents/Helpers/hookfeed"
args = ["mcp"]
```

The client launches the helper; no HTTP endpoint or app-hosted MCP daemon is involved. Confirm discovery and one real `send_message` call in your client. Only `title` is required; include `project`, `workdir`, and a stable `thread_key` when available. MCP is agent-initiated and does not guarantee automatic delivery. Prefer hooks for an agent already connected that way to avoid posting twice.

## Scripts and manual checks

```sh
hookfeed run --project HookFeed -- /usr/bin/true
hookfeed run --project HookFeed -- /usr/bin/false
# The second command returns 1 and should save a failed update.
hookfeed list --unread --limit 20 --json
hookfeed send "Review ready" --source script --project HookFeed \
  --kind needs_attention --workdir "$PWD" --thread hookfeed-manual-test \
  --body "The local build is ready to review."
```

`run` executes the command directly, inherits stdin/stdout and streams stderr through a capture pipe, and returns its exit status even if storing an update fails. Failed updates retain the last 20 stderr lines (up to 8 KiB). Stderr is no longer a TTY for the child; automatic coloring may differ. Use `--only-failures` to suppress successful updates. Listing does not mark messages read. Finish acceptance with a real agent session, MCP send, banner click, app-quit send/relaunch, and update latency check; do not treat these examples as recorded test results.

## Remote: Tailscale IP

In Settings → Remote, enable Remote and create a Tailscale IP connection. Use its displayed URL and token from the second tailnet machine. The app binds only loopback and the detected Tailscale IPv4 when an IP-route connection exists. Loopback uses Network.framework; the Tailscale address uses a POSIX listener to avoid the reproduced same-Mac Network.framework connection failure. Remote stays authenticated and send-only.

See the [remote access guide](docs/guides/app-guide.md#remote-access) for REST and MCP examples. To verify your route, send an update from a second tailnet machine, confirm the inbox receipt, then check that disabling Remote or revoking the connection refuses further sends. Automated same-Mac tests do not prove delivery across your tailnet or verify Tailscale HTTPS configuration.
