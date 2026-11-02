import Foundation

public struct Integration: Identifiable, Sendable {
    public enum Route: Sendable { case hooks(HookAgent), mcp }
    public struct Snippet: Sendable {
        public let noun: String
        public let note: String?
        public let text: @Sendable (String) -> String
    }
    public struct RemoteSnippet: Sendable {
        public let note: String?
        public let text: @Sendable (_ url: String, _ token: String) -> String
    }
    public let id: String
    public let name: String
    public let summary: String
    public let promise: String
    public let route: Route
    public let configDirectory: String?
    public let executable: String
    public var alternateExecutables: [String] = []
    public var applicationName: String? = nil
    public let rulesSource: String?
    public var mcpCommand: MCPCommand? = nil
    public var remoteSnippet: RemoteSnippet? = nil
    public let snippets: [Snippet]
    let prompt: @Sendable (String) -> String

    public func setupPrompt(cliPath: String) -> String { prompt(cliPath) }
    public static func named(_ id: String) -> Integration? { all.first { $0.id == id } }

    public static let all: [Integration] = [
        Integration(id: "claude-code", name: "Claude Code",
                    summary: "Merge into ~/.claude/settings.json. Stop updates a session thread; Notification reports permission and input requests.",
                    promise: "Automatic", route: .hooks(.claudeCode), configDirectory: ".claude", executable: "claude", rulesSource: nil,
                    remoteSnippet: .init(note: nil, text: { IntegrationPrompts.claudeRemote(url: $0, token: $1) }),
                    snippets: [.init(noun: "configuration", note: nil, text: { IntegrationPrompts.claude(cliPath: $0) })],
                    prompt: { IntegrationPrompts.claudePrompt(cliPath: $0) }),
        Integration(id: "codex", name: "Codex",
                    summary: "Merge these Stop and PermissionRequest hooks into ~/.codex/hooks.json, then review and trust them through /hooks in Codex. Choose one delivery route per session.",
                    promise: "Completions + approvals", route: .hooks(.codex), configDirectory: ".codex", executable: "codex", rulesSource: nil,
                    remoteSnippet: .init(note: "Merge into ~/.codex/config.toml on the remote machine.", text: { IntegrationPrompts.codexRemote(url: $0, token: $1) }),
                    snippets: [
                        .init(noun: "configuration", note: "Legacy alternative: config.toml accepts one top-level notify value. Reconcile or replace an existing value; adding a second key prevents Codex from starting. This reports completions only; use it instead of the hooks.", text: { IntegrationPrompts.codexHooks(cliPath: $0) }),
                        .init(noun: "configuration", note: nil, text: { IntegrationPrompts.codexNotify(cliPath: $0) })
                    ], prompt: { IntegrationPrompts.codexPrompt(cliPath: $0) }),
        Integration(id: "hermes", name: "Hermes Agent",
                    summary: "Paste the setup prompt into Hermes. It adds HookFeed under mcp_servers in ~/.hermes/config.yaml, asks you to run /reload-mcp, sends a test, and saves when-to-send rules to its memory.",
                    promise: "Agent decides when to send", route: .mcp, configDirectory: ".hermes", executable: "hermes", rulesSource: "hermes",
                    remoteSnippet: .init(note: "Merge into ~/.hermes/config.yaml on the remote machine, run /reload-mcp, then paste the rules from Settings › Integrations › Hermes Agent.", text: { IntegrationPrompts.hermesRemote(url: $0, token: $1) }),
                    snippets: [
                        .init(noun: "configuration", note: nil, text: { IntegrationPrompts.hermes(cliPath: $0) }),
                        .init(noun: "example message", note: "Hermes on another Mac or server? Create a connection in Remote; the token sheet shows the url and headers version.", text: { _ in IntegrationPrompts.hermesSample })
                    ], prompt: { IntegrationPrompts.hermesPrompt(cliPath: $0) }),
        Integration(id: "openclaw", name: "OpenClaw",
                    summary: "Connect through MCP in ~/.openclaw/openclaw.json, then save the when-to-send rules in your agent workspace. For another machine or server, use Settings → Remote.",
                    promise: "Agent decides when to send", route: .mcp, configDirectory: ".openclaw", executable: "openclaw", rulesSource: "openclaw",
                    mcpCommand: MCPCommand(executable: "openclaw",
                                           add: { ["mcp", "add", "hookfeed", "--command", $0, "--arg", "mcp"] },
                                           remove: ["mcp", "unset", "hookfeed"], list: ["mcp", "list"], test: ["mcp", "probe", "hookfeed"],
                                           afterInstall: "Start a new OpenClaw session and save the when-to-send rules in your agent workspace's AGENTS.md."),
                    remoteSnippet: .init(note: "Merge under mcp.servers in ~/.openclaw/openclaw.json on the OpenClaw host, start a new session, then save the rules from Settings › Integrations › OpenClaw.", text: { IntegrationPrompts.openclawRemote(url: $0, token: $1) }),
                    snippets: [.init(noun: "configuration", note: "This stdio configuration is for OpenClaw on this Mac. For remote delivery, create a connection in Settings → Remote and use its URL and bearer token on the OpenClaw host.", text: { IntegrationPrompts.openclaw(cliPath: $0) })],
                    prompt: { IntegrationPrompts.openclawPrompt(cliPath: $0) }),
        Integration(id: "grokbot", name: "Grok Bot",
                    summary: "Generic MCP setup; Grok Bot's config location and format are unverified. Copy the setup prompt for local stdio or use Settings → Remote for another machine.",
                    promise: "Agent decides when to send", route: .mcp, configDirectory: nil, executable: "grokbot", rulesSource: "grokbot",
                    remoteSnippet: .init(note: "Generic Streamable HTTP MCP setup. Use your Grok Bot client's documented config format and save the when-to-send rules with source grokbot.", text: { IntegrationPrompts.mcpRemote(url: $0, token: $1) }),
                    snippets: [.init(noun: "MCP configuration", note: "Generic example; adapt to your client's documented MCP format.", text: { IntegrationPrompts.mcp(cliPath: $0) })],
                    prompt: { IntegrationPrompts.grokbotPrompt(cliPath: $0) }),
        Integration(id: "antigravity", name: "Google Antigravity",
                    summary: "Merge into ~/.gemini/config/hooks.json. Stop reports completed runs and failures once background tasks finish. Permission and input requests are not reported.",
                    promise: "Completions + failures", route: .hooks(.antigravity), configDirectory: ".gemini/antigravity", executable: "agy", rulesSource: nil,
                    remoteSnippet: .init(note: "Add to the Antigravity MCP config on the remote machine. Remote MCP sends only when the agent decides to; completion hooks need HookFeed on the same Mac.", text: { IntegrationPrompts.antigravityRemote(url: $0, token: $1) }),
                    snippets: [.init(noun: "configuration", note: nil, text: { IntegrationPrompts.antigravity(cliPath: $0) })],
                    prompt: { IntegrationPrompts.antigravityPrompt(cliPath: $0) }),
        Integration(id: "gemini-cli", name: "Gemini CLI",
                    summary: "Merge into ~/.gemini/settings.json. AfterAgent updates a session thread; Notification reports tool permission requests.",
                    promise: "Completions + approvals", route: .hooks(.geminiCLI), configDirectory: ".gemini", executable: "gemini", rulesSource: nil,
                    remoteSnippet: .init(note: "Merge under mcpServers in ~/.gemini/settings.json on the remote machine. Remote MCP sends only when the agent decides to; completion hooks need HookFeed on the same Mac.", text: { IntegrationPrompts.geminiRemote(url: $0, token: $1) }),
                    snippets: [.init(noun: "configuration", note: nil, text: { IntegrationPrompts.gemini(cliPath: $0) })],
                    prompt: { IntegrationPrompts.geminiPrompt(cliPath: $0) }),
        Integration(id: "cursor", name: "Cursor",
                    summary: "Merge stop hooks into ~/.cursor/hooks.json for local completions. Use MCP for agent-requested updates; cloud agents need separate setup.",
                    promise: "Completions", route: .hooks(.cursor), configDirectory: ".cursor", executable: "cursor-agent",
                    alternateExecutables: ["cursor"], applicationName: "Cursor.app", rulesSource: "cursor",
                    remoteSnippet: .init(note: "Merge under mcpServers in ~/.cursor/mcp.json on the remote machine, then add the when-to-send rules from Settings › Integrations › Cursor.", text: { IntegrationPrompts.cursorRemote(url: $0, token: $1) }),
                    snippets: [
                        .init(noun: "configuration", note: nil, text: { IntegrationPrompts.cursorHooks(cliPath: $0) }),
                        .init(noun: "MCP fallback", note: "Merge into ~/.cursor/mcp.json and add when-to-send rules. Choose one delivery route per session.", text: { IntegrationPrompts.mcp(cliPath: $0) })
                    ], prompt: { IntegrationPrompts.cursorPrompt(cliPath: $0) })
    ]
}

extension HookAgent {
    public var hookEvents: [(event: String, matcher: String)] {
        switch self {
        case .claudeCode: return [("Stop", ""), ("Notification", "permission_prompt|elicitation_dialog|agent_needs_input")]
        case .codex: return [("Stop", ""), ("PermissionRequest", "")]
        case .antigravity: return [("Stop", "")]
        case .geminiCLI: return [("AfterAgent", ""), ("Notification", "ToolPermission")]
        case .cursor: return [("stop", "")]
        }
    }
}
