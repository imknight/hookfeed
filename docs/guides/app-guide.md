# HookFeed app guide

Version 0.2.0 · macOS 14 or later · 7 November 2026

HookFeed brings updates from local agents and scripts into one native Mac inbox. Use it to notice completed work, failures, and requests for input, then return to the relevant project or terminal session. Messages are stored locally in SQLite; no account, API key, or model inference is required.

## Get started

Open HookFeed, review the welcome checklist, and choose **Open Inbox**. In **Settings → Integrations**, send a test message, then choose **Install…** for Claude Code or Codex. Review the destination and before/after JSON, then confirm **Install**. Existing configurations get a timestamped backup beside the original; other hooks and settings are kept. Repeating installation does nothing. **Remove…** removes HookFeed hooks only. Invalid JSON is left intact with an error. For Codex, review and trust the hook through `/hooks`; the installer uses `~/.codex/hooks.json` and leaves legacy `config.toml` alone. Each integration shows **Last update** or **Waiting for first update**. Agent cards start collapsed: the name, promise, connection status and setup actions remain visible. Expand **Setup details** to read and copy configuration manually. In the Command-line tool card, choose **Install for me** to put the bundled CLI at `~/.local/bin/hookfeed`. Once configured, send an update with:

```sh
hookfeed send "Build complete" --project MyProject --kind completed
```

## Connect detected agents

Open **Settings → Integrations → Review and connect…**, or **Connect detected agents…** in the welcome checklist. HookFeed looks for agent config directories and executables on your login-shell PATH. Review each selected agent's **Show changes**, then click **Connect N**. Detection itself writes nothing. Agents are connected one at a time, with individual results; one failure does not block the others. Existing hook files are backed up, and stale paths from moving HookFeed are repaired. If a file changes after preview, close and reopen the review. Trust Codex's new hooks through `/hooks` afterward.

Hermes remains copy-only: its tested CLI prompts during MCP installation, so it cannot safely use Connect all or an Install button yet. Use **Copy setup prompt** or `hookfeed prompt hermes`. HookFeed never writes Hermes YAML. The two-agent automated sheet snapshot exercises a synthetic MCP command; production Connect all currently offers detected Claude Code and Codex installations.

### Hermes setup command and profiles

Create a connection in **Settings → Remote**, then expand **Hermes Agent (MCP)** in its token sheet. Enter a profile name if needed and copy the setup command:

```sh
hermes -p 'helena' mcp add hookfeed --url 'https://your-mac.example/mcp' --auth header
```

An empty profile omits `-p` and uses Hermes's active profile. Confirm authentication, paste this connection's token at the **API key / Bearer token** prompt, and enable the discovered tool. If a credential already exists, replace it with this connection's token. Run `/reload-mcp` in the same profile. Hermes saves the bearer header and credential in that profile; the command does not embed the token. Existing YAML and setup prompts remain available and must target the same profile's config.

The URL command is offered only in the Remote token sheet because local setup normally uses stdio. A localhost connection works only when Hermes runs on the same Mac; use the selected Tailscale connection URL for another machine. Both use the `/mcp` endpoint and `Authorization: Bearer` authentication.

Checked on 7 November 2026 with Hermes **0.22.5 (2026.9.24)**, commit `bf0203a794a0`, against its installed help/source, [MCP guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp), and [profile reference](https://hermes-agent.nousresearch.com/docs/reference/profile-commands). This version has no token/header flag: `--auth header` prompts and persists the token in the active profile. Isolated acceptance verified installation with and without `-p`, profile-scoped token persistence, and two stored messages sent through the installed Hermes MCP handler. Live Tailscale delivery and an interactive `/reload-mcp` session were not exercised.

## Setup prompts from the terminal

Run `hookfeed prompt hermes` and paste the output into Hermes to set up its stdio MCP server and when-to-send rules. The same prompts are available under **Settings → Integrations → Copy setup prompt**. Supported agents: `hermes`, `mcp`, `claude-code`, `codex`, `openclaw`, `antigravity`, and `cursor`.

Use `hookfeed prompt hermes --rules-only` for just the rules, including source `"hermes"`. `--rules-only` works for every agent. Setup prompts resolve the running executable's symlinks, so configs use the actual bundled helper path. Printing a prompt does not change agent configuration.

## Read and organize updates

The sidebar offers **Needs attention**, **Unread**, **All**, projects, bots, and sources. **Bots** appears after Projects when any update has a bot name; choosing a bot includes threads where even an older update has that name. Search matches message titles, bodies, projects, bots, and sources within the active filter. Project spellings that differ only by case, hyphens, underscores or spaces share one sidebar entry; “HookFeed” and “HookFeedApp” stay separate. To combine them deliberately, right-click a project and choose **Merge into…**. The alias is stored with this inbox and applies to project filters, unread thread counts and searches for either project name. Original message metadata is preserved. Messages use four kinds: info, completed, needs attention, and failed. Related updates appear together in a thread, newest first. Opening a thread marks its updates read; unread failures and attention requests drive the attention count. Use **Mark unread** or **Mark visible read** (`⇧⌘K`) to manage the queue. Mark visible read affects only the current filter and search results; other projects, bots and sources keep their unread state. The menu bar’s explicitly named **Mark Inbox Read** clears the whole inbox. The thread you open stays in its filtered list until you change the filter or search; choosing the same view again keeps your place. Deleting another thread from its context menu does not change your selection. The newest update does not repeat the detail header title; older updates keep their own titles. Titles skip marker-only opening lines. Agent Markdown is shown as formatted text, with backtick or tilde code fences and tables in monospace.

## Return to work and connect tools

Thread details can open an existing project folder in your chosen editor, reveal it in Finder, copy a supported agent resume command, or open a supplied source link. Updates recorded by the current `hookfeed run` offer **Copy command** (`⌥⌘C`) to rerun the wrapped command; **Copy resume command** remains `⇧⌘C`. Failed runs include the last 20 stderr lines (up to 8 KiB) verbatim. All stderr still streams to the terminal; stdin and stdout keep their terminal descriptors, while stderr uses a pipe, which may affect automatic color/TTY detection. Commands that exceed the 32 KiB body budget show **Command truncated…**; review them before copying. Older run updates remain readable, but Copy command is hidden because old records have no CLI-written origin marker. A self-declared `run` source is insufficient; the marker prevents accidental source spoofing, not tampering with the local database. Run copied commands in your terminal. Claude Code hooks report completions and selected permission or input requests; Codex Stop and PermissionRequest hooks report completions and approval requests; legacy notify reports completions only. Reinstall and review both hooks through `/hooks` when upgrading a Stop-only setup. Arbitrary input questions are not covered. Other MCP clients send when the agent calls the tool. Scripts can use `hookfeed send` or wrap a command with `hookfeed run --project MyProject -- make test`. Choose one delivery route per agent to avoid duplicate updates.

## Antigravity CLI (`agy`)

The Antigravity integration uses `Stop` hooks in `~/.gemini/config/hooks.json` to report completions and failures once `fullyIdle` is true. It does not report permission or input requests. Remote MCP configuration goes in `~/.gemini/config/mcp_config.json`, with `serverUrl` pointing to the connection URL plus `/mcp` and an `Authorization: Bearer …` header.

The old Gemini CLI card and `hook gemini-cli` command have been removed. Before starting an `agy` session, open **Settings → Integrations → Antigravity CLI (agy)** and install or update its hooks. Imported `hook gemini-cli` handlers in the global hooks file show **Needs update**; installation backs up that file, removes only those retired HookFeed handlers, and installs the current `Stop` hook while preserving other hooks. There is no compatibility alias. Hooks left in the old Gemini settings file are not loaded by current Antigravity CLI; workspace and plugin hook files must be updated separately if you added HookFeed there manually.

Checked on 7 November 2026 against installed `agy 1.5.2` and Google's [hooks documentation](https://antigravity.google/docs/hooks), [MCP documentation](https://antigravity.google/docs/mcp), and [migration guide](https://antigravity.google/docs/cli/gcli-migration/). The documented lifecycle events still have no dedicated permission/input event. A real no-tools `agy` session delivered a `fullyIdle=true` completion into a disposable HookFeed inbox using the rebuilt CLI; user hooks and credentials were unchanged.

## Settings and local storage

**General** controls notifications, Dock visibility, menu bar badge counts, and the editor. Defaults are all-update notifications, sound off, and an attention-only badge. Enable notification permission explicitly; macOS settings and Focus govern delivery. Banners show the title and source while bodies remain in the inbox. Expand their actions to copy an available resume command, open an existing project folder in your editor (or Finder), or mark the thread read. Clicking the banner opens its thread. **Storage** shows message and thread counts and the database location. The normal store is `~/Library/Application Support/HookFeed/inbox.sqlite`. Sends persist while the app is closed. The menu bar offers a compact inbox. Deleting a thread permanently removes its updates after confirmation.

See the [README](../../README.md) and [setup instructions](../../SETUP.md) for building and configuring HookFeed.

## Queued updates and bursts

HookFeed uses WAL for concurrent inbox reads and writes. Busy local hooks save normalized updates in the private `spool/` folder beside the database. The app drains up to 500 files per pass on launch, signals and its five-second timer, without blocking the UI. When the app is closed, `hookfeed drain` empties the queue. Local CLI delivery does not require the app or the optional remote background receiver.

Queued updates keep their original queued time and are deduplicated if replayed after a crash. Invalid files move to `spool/rejected/`. If an update is missing, run `hookfeed drain` and check that folder, disk space, permissions and the hook log. The queue holds at most 10,000 files; if it cannot accept an update, the hook logs the failure and still exits promptly with no stdout. `HOOKFEED_STORE_PATH` and `HOOKFEED_LOG_PATH` allow isolated stores and logs.

Notifications collect for one second: more than five eligible updates produce one summary banner; smaller bursts show the latest update per thread. Remote senders retry temporary connection failures and capacity responses with a stable idempotency key and a bounded overall timeout. Remote sends never fall back to the local queue.

## Message fields

`bot` is an optional bot name, distinct from `source` (how the update arrived)
and `project` (what it belongs to). Names are Unicode NFC-normalized, trimmed and
limited to 80 characters; a blank name means no bot. Bot never changes thread
grouping. Retrying an idempotency key with a different bot is a conflict.
Existing messages keep no bot when the inbox upgrades to schema v4.

Use `hookfeed send "Done" --source grokbot --bot Charname --project A` to name
a bot. `send`, `run` and both hook adapters accept `--bot`; the MCP
`send_message` tool accepts `bot`. Each falls back to `HOOKFEED_BOT` when
omitted; an explicit value takes precedence (a blank value clears the bot).
CLI text lists show `kind · source · bot · project · title`, skipping absent
bot and project fields. Invalid hook bot names are diagnosed without
blocking the agent (the hook still exits 0).

Rows and thread headers show **bot · source · project**, skipping missing fields. Bot filters and search inspect every update; the row and header describe the latest update.

## Query messages from the command line

`hookfeed list --project A --source grokbot --bot Charname --search cafe --unread --limit 20 --json`
combines filters and returns newest messages first without marking them read.
Project, source and bot filters match the stored value exactly (project aliases
are a sidebar feature). Search matches literal text in title, body, project or
bot, ignoring case and diacritics: `cafe` finds `Café`; `%` and `_` are ordinary
characters. The limit defaults to 20 and must be 1–100.

## Agents reading the inbox

Start `hookfeed mcp --read-all` to opt into the read-only `list_messages` tool.
**This lets the agent read every project**, regardless of its working directory.
Without `--read-all`, only `send_message` is listed, and reading is refused.
Reading never marks messages read; no MCP tool marks, deletes or edits updates.

`list_messages` accepts `project`, `source`, `bot`, `unread_only`, `search` and
`limit` (1–100, default 20), using the same filtering rules as `hookfeed list`.
It returns `{ "messages": [...] }` with newest messages first and UTC timestamps.
When sending over stdio, `HOOKFEED_BOT` supplies the default bot name when the
argument is omitted.

## Install the terminal command

In **Settings → Integrations → Command-line tool**, choose **Install for me**.
The link points into this app bundle, so app updates also update the command.
Keep the app in its intended location before installing; if you move it, install
from the new copy and confirm replacement of the old link.

An existing regular file or a link to another app is shown before replacement;
choose **Replace…** and confirm only if you want to replace that command.
**Remove** removes only the link to this app. Hook and MCP configurations keep
using the absolute helper path and do not depend on your terminal PATH.

If the card shows PATH instructions, copy the line into the indicated shell
startup file (`~/.zshrc` for zsh) and open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
hookfeed --version
```

The version should be `0.2.0`. Installation is for the current user only.

To run from the menu bar, turn off **Settings → General → Show in Dock**. The
choice is saved and applies immediately. Use **Open Inbox** in the menu bar to
open the main window; it does not bring the Dock icon back.

## Remote access

Open **Settings → Remote**, turn on **Enable remote access**, choose how to reach
this Mac, and create a named connection such as “Home server”. Remote is off by
default. Turn on **Receive while HookFeed is closed** to register the bundled
`hookfeed serve --managed` LaunchAgent with macOS. Allow it in System Settings →
General → Login Items if prompted. It starts at login and stores HTTP/MCP updates
without the app UI. With this option off, HookFeed must stay open.

The app and helper share a listener lock so only one owns port 47321. Switching
remote access off closes the app listener immediately; the managed helper picks
up the setting within a quarter second. Listener takeover waits up to three seconds
for the helper to release its lock. Quitting the app leaves an enabled helper
running. Background storage does not display notification banners while the UI
is closed; open the inbox to read the stored updates.

Enabling the helper authorizes the bundled CLI in the existing Keychain item's
access list. macOS may ask you to allow this change. Token hashes stay in
Keychain; no raw tokens are copied to files or launch arguments. The helper
fails closed without interactive Keychain prompts if access is denied or the
Keychain is locked. A managed helper stays alive and retries Keychain loading
with a backoff of up to 30 seconds. The app renews helper authorization at launch
when background receiving is registered, including after an ad-hoc build update.
New or recreated Keychain items include helper access. Coordinated token changes
invalidate the other process's cached connections immediately; unchanged reads
do not reload Keychain. Health checks allow startup time before reporting a
receiver failure. This is a per-user
LaunchAgent, so reception requires a logged-in session and an awake Mac.

For manual foreground operation, run `hookfeed serve` (or `hookfeed serve --port
47321`) after authorizing the bundled helper through Settings. Stop it with
Control-C. The same authentication and loopback/Tailscale restrictions apply.

Choose **This machine** for `http://127.0.0.1:47321`, or **Tailscale IP** for this
Mac's `http://100.x.y.z:47321` address. The Tailscale IP listener exists only while
at least one connection uses that route. There is no local-network or public
route. Unavailable routes are disabled with a reason; use **Refresh Tailscale**
after starting Tailscale.

For **Tailscale HTTPS**, HookFeed shows the `.ts.net` hostname reported by the
local Tailscale CLI, searching the login-shell PATH, Homebrew directories, then
the Tailscale app. Choose **Set up Tailscale HTTPS…** and confirm to run:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:47321
```

The tab shows the command's output. Setup changes this Mac's HTTPS mapping on
port 443 and may replace an existing mapping. **Reset Tailscale Serve…** requires
separate confirmation and removes all Serve mappings on this Mac, including
other apps' mappings. A displayed hostname alone does not verify that Serve is
configured. The detected MagicDNS host accepts forwarded TCP ports for MCP Host
validation; browser Origin restrictions remain unchanged. This route remains
within your tailnet; public/Funnel access is not supported.

Save the connection token when it appears: it is shown only once. The app stores
only its SHA-256 hash in Keychain. All bots on that connection share the token
and can use any bot name. Revoke the connection to cut off that token, or create
a new connection if the token is lost. The list shows the last successful send
(best effort if Keychain cannot save that timestamp).

On the sending machine, set the URL for your chosen route and the token:

```sh
export HOOKFEED_URL='http://100.101.2.3:47321'
export HOOKFEED_TOKEN='hf_REPLACE_WITH_YOUR_CONNECTION_TOKEN'
hookfeed send 'Build finished' --bot Charname --project A
HOOKFEED_BOT=Grokbot hookfeed run -- make test
```

`send`, `run`, and the hook adapters use remote delivery when `HOOKFEED_URL` is
set. A token is required. A failure reports a diagnostic without writing to the
sending machine's inbox. Delivery has a 5-second timeout; hooks still exit 0
within 6 seconds, and `run` preserves the wrapped command's exit status even if
delivery fails. If your agent's hook configuration imposes its own timeout, allow
at least 6 seconds for remote hooks (the local integration snippets use 1 second).
Base URLs cannot include credentials, a path, query, or fragment. HTTP redirects
are refused so credentials cannot be forwarded to another host.

You can also send JSON directly:

```sh
curl "$HOOKFEED_URL/v1/messages" \
  -H "Authorization: Bearer $HOOKFEED_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Build finished","bot":"Charname","project":"A"}'
```

The API accepts the existing `send_message` fields: `title` (required), `body`,
`source`, `project`, `bot`, `kind`, `url`, `workdir`, `session_id`, `thread_key`,
and `idempotency_key`. `source` defaults to `remote`. Omitting `bot` leaves it
unset; the receiving app's `HOOKFEED_BOT` does not supply a name. CLI invocations
still apply their own explicit `--bot` or `HOOKFEED_BOT` before sending.

A successful send returns HTTP 201 with a storage receipt. Invalid fields or
JSON return 400, missing/wrong/revoked tokens 401, oversized bodies 413, oversized
headers 431, and incomplete requests time out after 10 seconds. Request limits
are 16 KiB headers and 64 KiB JSON, with message bodies still limited to 32 KiB
UTF-8. The health endpoint `GET /v1/health` returns only `{"ok":true}` without
a token. Connection tokens allow sending only: no remote reads are exposed.

Remote `run` updates preserve the command body, status and stderr diagnostics,
but cannot supply the trusted local `origin` marker, so **Copy command** is
unavailable.
OAuth, public cloud connectors, pairing links and QR codes are held for later.

### Connect an agent over the web

The same connection token works at `<route base>/mcp`. For Claude Code, use the
URL for your chosen route and the token you saved when creating the connection:

```sh
claude mcp add --transport http hookfeed "$HOOKFEED_URL/mcp" \
  --header "Authorization: Bearer $HOOKFEED_TOKEN"
```

The token sheet includes copyable examples for Command line, HTTP API, Claude
Code, Codex, Hermes Agent, and Other MCP clients (streamable HTTP). The token
and Command line stay expanded; the other examples start collapsed. Use their
header Copy buttons without expanding, or open a disclosure to read the example.
Disclosure controls support keyboard focus and expand/collapse.

For Codex, merge the following into `~/.codex/config.toml` on the remote
machine, replacing the URL and token with your connection values:

```toml
[mcp_servers.hookfeed]
url = "https://mac.tailnet.ts.net/mcp"
http_headers = { Authorization = "Bearer YOUR_CONNECTION_TOKEN" }
```

[Codex's MCP configuration](https://developers.openai.com/codex/mcp#streamable-http-servers)
supports `url`, static `http_headers`, and `bearer_token_env_var`. The sheet uses
an inline header to match the Hermes example and avoid a separate environment
setup step. Keep this config private.

For other MCP clients, choose streamable HTTP and enter these connection facts
using that client's configuration format:

```text
URL:     https://mac.tailnet.ts.net/mcp
Header:  Authorization: Bearer YOUR_CONNECTION_TOKEN
```

Web MCP exposes exactly one tool, `send_message`. Pass `bot: "Claude"` to name
the bot; omitting it stores no bot name, even if the receiving app has
`HOOKFEED_BOT` set. `source` defaults to `mcp`. The other fields and validation
are shared with local MCP. A receipt means the message was stored, not seen.
Remote connections cannot list, read, mark or delete inbox messages; the local
`--read-all` option does not grant remote access.

Clients initialize a session, send `notifications/initialized`, and retain the
returned `Mcp-Session-Id` header on later requests. Every request still needs
`Authorization: Bearer …`. POST requests require `Content-Type: application/json`
and `Accept: application/json, text/event-stream`; HookFeed streams JSON-RPC
responses as SSE. Clients should send their negotiated `MCP-Protocol-Version`.
GET streaming is not supported (405); DELETE closes the MCP session.
Missing, wrong and revoked tokens receive 401 with `WWW-Authenticate: Bearer`.
Disabling Remote or restarting its listener ends all sessions.

Sessions are limited to 128 requests or 15 minutes, with at most 32 sessions and
8 concurrent requests per session. Clients must initialize again after a session
expires (404); capacity limits return 429, and overlapping use of the same
JSON-RPC ID returns 409. Responses have a 10-second write deadline. A cancelled
or failed response closes that session, so retries should use `idempotency_key`.

**ChatGPT and claude.ai web cannot connect yet.** Their cloud connectors need
OAuth and a public HTTPS route, which are not supported.
There is no unauthenticated mode or token-in-URL alternative.
