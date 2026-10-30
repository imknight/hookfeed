import Foundation
import XCTest
@testable import HookFeedCore

final class IntegrationRegistryTests: XCTestCase {
    let path = "/Applications/HookFeed.app/Contents/Helpers/hookfeed"

    func testCursorRegistry() throws {
        let cursor = try XCTUnwrap(Integration.named("cursor"))
        XCTAssertEqual(Set(Integration.all.map(\.id)).count, Integration.all.count)
        guard case .hooks(.cursor) = cursor.route else { return XCTFail("Expected Cursor hooks") }
        XCTAssertEqual(cursor.configDirectory, ".cursor")
        XCTAssertEqual(cursor.executable, "cursor-agent")
        XCTAssertEqual(cursor.alternateExecutables, ["cursor"])
        XCTAssertEqual(cursor.applicationName, "Cursor.app")
        XCTAssertEqual(HookAgent.cursor.relativeConfigPath, ".cursor/hooks.json")
        XCTAssertEqual(HookAgent.cursor.hookEvents.map(\.event), ["stop"])
        XCTAssertEqual(cursor.snippets.map { $0.text(path) }, [IntegrationPrompts.cursorHooks(cliPath: path), IntegrationPrompts.mcp(cliPath: path)])
    }

    func testAntigravityRegistry() throws {
        let integration = try XCTUnwrap(Integration.named("antigravity"))
        XCTAssertEqual(Set(Integration.all.map(\.id)).count, Integration.all.count)
        guard case .hooks(.antigravity) = integration.route else { return XCTFail("Expected hooks") }
        XCTAssertEqual(integration.configDirectory, ".gemini/antigravity")
        XCTAssertEqual(integration.executable, "agy")
        XCTAssertEqual(HookAgent.antigravity.relativeConfigPath, ".gemini/config/hooks.json")
        XCTAssertEqual(HookAgent.antigravity.hookEvents.map(\.event), ["Stop"])
        XCTAssertEqual(integration.snippets.map { $0.text(path) }, [IntegrationPrompts.antigravity(cliPath: path)])
    }

    func testOrderAndIDs() {
        XCTAssertEqual(Integration.all.map(\.id), ["claude-code", "codex", "hermes", "openclaw", "antigravity", "gemini-cli", "cursor"])
        XCTAssertEqual(Integration.named("codex")?.name, "Codex")
        XCTAssertNil(Integration.named("nope"))
    }

    func testCardTextMatchesCurrentSettings() {
        XCTAssertEqual(Integration.all.map(\.name), ["Claude Code", "Codex", "Hermes Agent", "OpenClaw", "Google Antigravity", "Gemini CLI", "Cursor"])
        XCTAssertEqual(Integration.all.map(\.promise), ["Automatic", "Completions + approvals", "Agent decides when to send", "Agent decides when to send", "Completions + failures", "Completions + approvals", "Completions"])
        XCTAssertEqual(Integration.all.map(\.summary), [
            "Merge into ~/.claude/settings.json. Stop updates a session thread; Notification reports permission and input requests.",
            "Merge these Stop and PermissionRequest hooks into ~/.codex/hooks.json, then review and trust them through /hooks in Codex. Choose one delivery route per session.",
            "Paste the setup prompt into Hermes. It adds HookFeed under mcp_servers in ~/.hermes/config.yaml, asks you to run /reload-mcp, sends a test, and saves when-to-send rules to its memory.",
            "Connect through MCP in ~/.openclaw/openclaw.json, then save the when-to-send rules in your agent workspace. For another machine or server, use Settings → Remote.",
            "Merge into ~/.gemini/config/hooks.json. Stop reports completed runs and failures once background tasks finish. Permission and input requests are not reported.",
            "Merge into ~/.gemini/settings.json. AfterAgent updates a session thread; Notification reports tool permission requests.",
            "Merge stop hooks into ~/.cursor/hooks.json for local completions. Use MCP for agent-requested updates; cloud agents need separate setup."
        ])
    }

    func testPromptsMatchFixture() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("HookFeedCLITests/Fixtures/setup-prompts.json")
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        for integration in Integration.all { XCTAssertEqual(integration.setupPrompt(cliPath: path), fixture[integration.id]) }
    }

    func testOpenClawRegistry() throws {
        let integration = try XCTUnwrap(Integration.named("openclaw"))
        XCTAssertEqual(Set(Integration.all.map(\.id)).count, Integration.all.count)
        guard case .mcp = integration.route else { return XCTFail("Expected MCP") }
        XCTAssertEqual(integration.configDirectory, ".openclaw")
        XCTAssertEqual(integration.executable, "openclaw")
        XCTAssertEqual(integration.rulesSource, "openclaw")
        XCTAssertEqual(integration.snippets.map { $0.text(path) }, [IntegrationPrompts.openclaw(cliPath: path)])
        XCTAssertTrue(integration.snippets[0].note!.contains("Settings → Remote"))
    }

    func testRulesSource() {
        XCTAssertNil(Integration.named("claude-code")?.rulesSource)
        XCTAssertNil(Integration.named("codex")?.rulesSource)
        XCTAssertEqual(Integration.named("hermes")?.rulesSource, "hermes")
    }

    func testHookEvents() {
        XCTAssertEqual(HookAgent.claudeCode.hookEvents.map(\.event), ["Stop", "Notification"])
        XCTAssertEqual(HookAgent.claudeCode.hookEvents.map(\.matcher), ["", "permission_prompt|elicitation_dialog|agent_needs_input"])
        XCTAssertEqual(HookAgent.codex.hookEvents.map(\.event), ["Stop", "PermissionRequest"])
        XCTAssertEqual(HookAgent.codex.hookEvents.map(\.matcher), ["", ""])
    }

    func testSnippetsMatchCurrentCards() throws {
        let codex = try XCTUnwrap(Integration.named("codex"))
        XCTAssertEqual(codex.snippets.map { $0.text(path) }, [IntegrationPrompts.codexHooks(cliPath: path), IntegrationPrompts.codexNotify(cliPath: path)])
        XCTAssertEqual(codex.snippets.compactMap(\.note), ["Legacy alternative: config.toml accepts one top-level notify value. Reconcile or replace an existing value; adding a second key prevents Codex from starting. This reports completions only; use it instead of the hooks."])
        let hermes = try XCTUnwrap(Integration.named("hermes"))
        XCTAssertEqual(hermes.snippets.map { $0.text(path) }, [IntegrationPrompts.hermes(cliPath: path), IntegrationPrompts.hermesSample])
        XCTAssertEqual(hermes.snippets.map(\.noun), ["configuration", "example message"])
    }
    func testGeminiRegistry() throws {
        let integration = try XCTUnwrap(Integration.named("gemini-cli"))
        XCTAssertEqual(Set(Integration.all.map(\.id)).count, Integration.all.count)
        guard case .hooks(.geminiCLI) = integration.route else { return XCTFail("Expected hooks") }
        XCTAssertEqual(integration.configDirectory, ".gemini")
        XCTAssertEqual(integration.executable, "gemini")
        XCTAssertEqual(HookAgent.geminiCLI.relativeConfigPath, ".gemini/settings.json")
        XCTAssertEqual(HookAgent.geminiCLI.hookEvents.map(\.event), ["AfterAgent", "Notification"])
        XCTAssertEqual(HookAgent.geminiCLI.hookEvents.map(\.matcher), ["", "ToolPermission"])
    }

}
