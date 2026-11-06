import Foundation

public enum IntegrationPrompts {
    public static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
    public static func claude(cliPath: String) -> String {
        let hook: [String: Any] = ["type": "command", "command": "\(ShellText.quote(cliPath)) hook claude-code", "timeout": 1]
        return json(["hooks": ["Stop": [["hooks": [hook]]], "Notification": [["matcher": "permission_prompt|elicitation_dialog|agent_needs_input", "hooks": [hook]]]]])
    }
    public static func antigravity(cliPath: String) -> String {
        json(["hookfeed": ["enabled": true, "Stop": [["type": "command", "command": "\(ShellText.quote(cliPath)) hook antigravity", "timeout": 1]]]])
    }
    public static func antigravityRemote(url: String, token: String) -> String {
        json(["mcpServers": ["hookfeed": ["serverUrl": url + "/mcp", "headers": ["Authorization": "Bearer " + token]]]])
    }
    public static func antigravityPrompt(cliPath: String) -> String {
        hookPrompt(agent: "Antigravity CLI (agy)", file: "~/.gemini/config/hooks.json", config: antigravity(cliPath: cliPath),
                   after: "Before starting a new agy session, reconnect Antigravity in HookFeed Settings to remove retired HookFeed handlers from its hooks.json. Then check /hooks. Send a completion only when Stop reports fullyIdle; report errors as failures. These hooks do not report permission or input requests.")
    }

    public static func codexHooks(cliPath: String) -> String {
        let hook: [String: Any] = ["type": "command", "command": "\(ShellText.quote(cliPath)) hook codex", "timeout": 1]
        return json(["hooks": ["Stop": [["hooks": [hook]]], "PermissionRequest": [["hooks": [hook]]]]])
    }
    public static func cursorHooks(cliPath: String) -> String {
        json(["version": 1, "hooks": ["stop": [["command": "\(ShellText.quote(cliPath)) hook cursor"]]]])
    }
    public static func cursorRemote(url: String, token: String) -> String {
        json(["mcpServers": ["hookfeed": ["url": url + "/mcp", "headers": ["Authorization": "Bearer " + token]]]])
    }
    public static func cursorPrompt(cliPath: String) -> String {
        hookPrompt(agent: "Cursor", file: "~/.cursor/hooks.json", config: cursorHooks(cliPath: cliPath),
                   after: "Cursor reloads hooks automatically. Verify a local completion reaches HookFeed. These hooks do not report permission requests. CLI delivery is unverified; cloud agents do not load your local user hooks.") + """


        If hooks are unavailable, use MCP instead: back up and merge this into ~/.cursor/mcp.json, keeping other servers. Reload MCP, then call HookFeed's send_message with title "Cursor connected to HookFeed", kind "info", source "cursor" and bot "Cursor". Disable HookFeed's stop hook when using MCP for completions. Save these rules in a Cursor rule that always applies:

        \(mcp(cliPath: cliPath))

        \(rules(source: "cursor"))
        """
    }
    public static func codexNotify(cliPath: String) -> String {
        "notify = [\(jsonString(cliPath)), \"hook\", \"codex\"]"
    }
    public static func mcp(cliPath: String) -> String {
        json(["mcpServers": ["hookfeed": ["command": cliPath, "args": ["mcp"]]]])
    }
    /// JSON strings are valid YAML double-quoted scalars, so paths with spaces stay intact.
    public static func hermes(cliPath: String) -> String {
        "mcp_servers:\n  hookfeed:\n    command: \(jsonString(cliPath))\n    args: [\"mcp\"]"
    }
    public static func hermesRemote(url: String, token: String) -> String {
        "mcp_servers:\n  hookfeed:\n    url: \(jsonString(url + "/mcp"))\n    headers:\n      Authorization: \(jsonString("Bearer " + token))"
    }
    public static func hermesAddCommand(url: String, profile: String = "") -> String {
        let profileArgument = profile.isEmpty ? "" : " -p \(ShellText.quote(profile))"
        return "hermes\(profileArgument) mcp add hookfeed --url \(ShellText.quote(url + "/mcp")) --auth header"
    }
    public static func claudeRemote(url: String, token: String) -> String {
        "claude mcp add --transport http hookfeed \(ShellText.quote(url + "/mcp")) \\\n  --header \(ShellText.quote("Authorization: Bearer " + token))"
    }
    public static func openclaw(cliPath: String) -> String {
        json(["mcp": ["servers": ["hookfeed": ["command": cliPath, "args": ["mcp"]]]]])
    }
    public static func openclawRemote(url: String, token: String) -> String {
        json(["mcp": ["servers": ["hookfeed": [
            "url": url + "/mcp", "transport": "streamable-http",
            "headers": ["Authorization": "Bearer " + token],
        ]]]])
    }

    public static func openclawPrompt(cliPath: String) -> String {
        """
        Connect yourself to HookFeed, my Mac inbox for agent updates.
        1. If you run on another machine or server, ask me to create a connection in HookFeed Settings → Remote and provide its URL and bearer token privately. On the OpenClaw host, configure mcp.servers.hookfeed with url set to that URL plus /mcp, transport "streamable-http", and headers.Authorization set to "Bearer " plus the token. Do not use the Mac's local executable path remotely.
        2. For OpenClaw on the same Mac only, use this stdio configuration:

        \(openclaw(cliPath: cliPath))

        3. Back up your active OpenClaw config (normally ~/.openclaw/openclaw.json; respect OPENCLAW_CONFIG_PATH), then merge the chosen server under mcp.servers. Preserve every other setting and server. The file accepts JSON5; do not discard comments or rewrite it as plain JSON.
        4. Run openclaw mcp probe hookfeed. Ask me to start a new session with /new or /reset and wait until I confirm.
        5. Call the HookFeed send_message tool with title "OpenClaw connected to HookFeed", kind "info", source "openclaw" and bot set to your name. Confirm it appears in my HookFeed inbox; a successful probe alone is not delivery proof.
        6. Add these rules to AGENTS.md in your active agent workspace, preserving existing instructions:

        \(rules(source: "openclaw"))
        """
    }

    public static func grokbotPrompt(cliPath: String) -> String {
        """
        Connect yourself to HookFeed, my Mac inbox for agent updates. Grok Bot's config location and format are unverified; this assumes your client supports MCP. Find its documented MCP configuration before editing anything, back it up, and preserve existing settings and servers.
        1. On this Mac, add this generic stdio MCP server using your client's documented format:

        \(mcp(cliPath: cliPath))

        2. On another machine, ask me privately for a connection from HookFeed Settings → Remote. Use Streamable HTTP with the URL plus /mcp and an Authorization header of "Bearer " plus the token. Do not use this Mac's executable path remotely.
        3. Reload MCP using your client's documented procedure. Call send_message with title "Grok Bot connected to HookFeed", kind "info", source "grokbot" and bot set to your name. Confirm the update appears in HookFeed.
        4. If MCP is unavailable on this Mac, send through the CLI: \(ShellText.quote(cliPath)) send "Grok Bot connected to HookFeed" --source grokbot --bot "Grok Bot". Remote scripts can use the same send command with HOOKFEED_URL and HOOKFEED_TOKEN set privately.
        5. Save these rules in your persistent agent instructions:

        \(rules(source: "grokbot"))
        """
    }

    public static func codexRemote(url: String, token: String) -> String {
        """
        [mcp_servers.hookfeed]
        url = \(tomlString(url + "/mcp"))
        http_headers = { Authorization = \(tomlString("Bearer " + token)) }
        """
    }
    public static func mcpRemote(url: String, token: String) -> String {
        "URL:     \(url)/mcp\nHeader:  Authorization: Bearer \(token)"
    }

    private static func tomlString(_ string: String) -> String {
        var escaped = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F: escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    public static var hermesSample: String {
        json([
            "title": "Daily SEO digest is ready", "kind": "completed", "source": "hermes", "bot": "Hermes",
            "project": "eli5-sg", "workdir": "/Users/you/Code/eli5-sg", "thread_key": "hermes:seo-digest",
            "body": "3 explainers gained clicks; 1 dropped out of the top 10.",
        ])
    }

    /// When-to-send rules: MCP agents only call send_message if their instructions tell them to.
    public static func rules(source: String?) -> String {
        let sourceRule = source.map { " Set source to \"\($0)\"." } ?? ""
        return """
        Use HookFeed's send_message tool to keep me posted. HookFeed is my local Mac inbox for agent updates.
        - When you finish a task: kind "completed", a one-line title, and a short summary of what changed in body.
        - When you're blocked or need a decision from me: kind "needs_attention", with the question as the title.
        - When something fails and you can't recover: kind "failed", with the error in body.
        Always set bot to your name, project to the repo or job name, and workdir to the absolute folder path.\(sourceRule) Reuse one thread_key per task so its updates group into one thread. Don't send routine progress updates.
        """
    }

    public static func hermesPrompt(cliPath: String) -> String {
        """
        Connect yourself to HookFeed, my local Mac inbox for agent updates.
        1. Back up your active Hermes profile's config.yaml (default: ~/.hermes/config.yaml), then merge this into it. Profiles keep their own config; use the profile you run. Keep every other setting and MCP server:

        \(hermes(cliPath: cliPath))

        2. Ask me to run /reload-mcp and wait until I confirm.
        3. Call mcp__hookfeed__send_message with title "Hermes connected to HookFeed", kind "info", source "hermes" and bot set to your name.
        4. Save these rules to your persistent memory so you follow them in every session:

        \(rules(source: "hermes"))
        """
    }

    public static func mcpPrompt(cliPath: String) -> String {
        """
        Connect yourself to HookFeed, my local Mac inbox for agent updates.
        1. Back up your MCP config, then add this stdio server. Keep every other server:

        \(mcp(cliPath: cliPath))

        2. Tell me if I need to reload MCP servers or restart, and wait until I confirm.
        3. Call the hookfeed send_message tool with title "Connected to HookFeed", kind "info" and bot set to your name.
        4. Add these rules to your persistent instructions (AGENTS.md, CLAUDE.md or your memory):

        \(rules(source: nil))
        """
    }

    public static func claudePrompt(cliPath: String) -> String { hookPrompt(agent: "Claude Code", file: "~/.claude/settings.json", config: claude(cliPath: cliPath), after: "The hooks apply to new Claude Code sessions.") }
    public static func codexPrompt(cliPath: String) -> String { hookPrompt(agent: "Codex", file: "~/.codex/hooks.json", config: codexHooks(cliPath: cliPath), after: "Then tell me to open /hooks in Codex and trust the HookFeed hook.") }

    private static func hookPrompt(agent: String, file: String, config: String, after: String) -> String {
        """
        Set up HookFeed hooks for \(agent). HookFeed is my local Mac inbox for agent updates.
        1. If \(file) exists, copy it to a timestamped backup beside the original.
        2. Merge the hooks below into it. Keep every existing setting and hook, and don't add HookFeed entries twice.
        3. Check the file is still valid JSON and show me what changed.
        4. \(after)

        \(config)
        """
    }

    public static func jsonString(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes])
        let encoded = String(data: data, encoding: .utf8)!
        return String(encoded.dropFirst().dropLast())
    }
}
