import Foundation
import XCTest
@testable import HookFeedCore

final class IntegrationPromptsTests: XCTestCase {
    func testGrokBotUsesGenericMCPAndExplicitSource() throws {
        let path = "/Applications/Knight's Apps/hookfeed"
        let integration = try XCTUnwrap(Integration.named("grokbot"))
        let prompt = integration.setupPrompt(cliPath: path)
        XCTAssertTrue(prompt.contains(IntegrationPrompts.mcp(cliPath: path)))
        XCTAssertTrue(prompt.contains("config location and format are unverified"))
        XCTAssertTrue(prompt.contains("URL plus /mcp"))
        XCTAssertTrue(prompt.contains("Bearer "))
        XCTAssertTrue(prompt.contains("--source grokbot"))
        XCTAssertTrue(prompt.contains(IntegrationPrompts.rules(source: "grokbot")))
        XCTAssertFalse(prompt.contains("~/.grok"))
    }
    func testCursorJSONEscapingAndExactText() throws {
        let path = #"/Apps/Knight's \ "Test"/hookfeed"#
        XCTAssertEqual(IntegrationPrompts.cursorHooks(cliPath: path), #"""
        {
          "hooks" : {
            "stop" : [
              {
                "command" : "'/Apps/Knight'\\''s \\ \"Test\"/hookfeed' hook cursor"
              }
            ]
          },
          "version" : 1
        }
        """#)
        let value = #"quote" space \ end"#
        XCTAssertEqual(IntegrationPrompts.cursorRemote(url: value, token: value), #"""
        {
          "mcpServers" : {
            "hookfeed" : {
              "headers" : {
                "Authorization" : "Bearer quote\" space \\ end"
              },
              "url" : "quote\" space \\ end/mcp"
            }
          }
        }
        """#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IntegrationPrompts.mcp(cliPath: path).utf8)) as? [String: [String: [String: Any]]])
        XCTAssertEqual(object["mcpServers"]?["hookfeed"]?["command"] as? String, path)
        XCTAssertTrue(IntegrationPrompts.cursorPrompt(cliPath: path).contains(IntegrationPrompts.cursorHooks(cliPath: path)))
        XCTAssertTrue(IntegrationPrompts.cursorPrompt(cliPath: path).contains(IntegrationPrompts.mcp(cliPath: path)))
    }

    func testAntigravityHookSnippetAndPrompt() throws {
        let path = "/Applications/Knight's Apps/HookFeed \"Test\"\\app/hookfeed"
        let snippet = IntegrationPrompts.antigravity(cliPath: path)
        let expectedCommand = "'/Applications/Knight'\\''s Apps/HookFeed \"Test\"\\app/hookfeed' hook antigravity"
        let object = try HookConfiguration.parse(Data(snippet.utf8))
        let definition = try XCTUnwrap(object["hookfeed"] as? [String: Any])
        XCTAssertEqual((definition["Stop"] as? [[String: Any]])?.first?["command"] as? String, expectedCommand)
        XCTAssertEqual(snippet, """
        {
          "hookfeed" : {
            "enabled" : true,
            "Stop" : [
              {
                "command" : \(IntegrationPrompts.jsonString(expectedCommand)),
                "timeout" : 1,
                "type" : "command"
              }
            ]
          }
        }
        """)
        XCTAssertTrue(IntegrationPrompts.antigravityPrompt(cliPath: path).hasSuffix(snippet))
    }

    func testAntigravityRemoteJSONEscaping() throws {
        let value = "quote\" space slash\\"
        let snippet = IntegrationPrompts.antigravityRemote(url: value, token: value)
        XCTAssertEqual(snippet, #"""
        {
          "mcpServers" : {
            "hookfeed" : {
              "headers" : {
                "Authorization" : "Bearer quote\" space slash\\"
              },
              "serverUrl" : "quote\" space slash\\/mcp"
            }
          }
        }
        """#)
        let root = try HookConfiguration.parse(Data(snippet.utf8))
        let server = try XCTUnwrap((root["mcpServers"] as? [String: [String: Any]])?["hookfeed"])
        XCTAssertEqual(server["serverUrl"] as? String, value + "/mcp")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer " + value)
    }

    func testPromptsPreserveAppWording() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HookFeedCLITests/Fixtures/setup-prompts.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        let path = "/Applications/HookFeed.app/Contents/Helpers/hookfeed"
        XCTAssertEqual(IntegrationPrompts.hermesPrompt(cliPath: path), expected["hermes"])
        XCTAssertEqual(IntegrationPrompts.mcpPrompt(cliPath: path), expected["mcp"])
        XCTAssertEqual(IntegrationPrompts.claudePrompt(cliPath: path), expected["claude-code"])
        XCTAssertEqual(IntegrationPrompts.codexPrompt(cliPath: path), expected["codex"])
        XCTAssertEqual(IntegrationPrompts.rules(source: nil), expected["rules"])
        XCTAssertEqual(IntegrationPrompts.rules(source: "hermes"), expected["hermes-rules"])
    }

    func testCodexRemoteConfiguration() {
        XCTAssertEqual(IntegrationPrompts.codexRemote(url: "https://mac.tailnet.ts.net", token: "test-token"), """
        [mcp_servers.hookfeed]
        url = "https://mac.tailnet.ts.net/mcp"
        http_headers = { Authorization = "Bearer test-token" }
        """)
    }

    func testCodexRemoteEscapesTOMLStrings() {
        let value = "quote\" slash\\ tab\t newline\n return\r café 🪝"
        let escaped = #"quote\" slash\\ tab\u0009 newline\u000A return\u000D café 🪝"#
        XCTAssertEqual(IntegrationPrompts.codexRemote(url: value, token: value), """
        [mcp_servers.hookfeed]
        url = "\(escaped)/mcp"
        http_headers = { Authorization = "Bearer \(escaped)" }
        """)
    }

    func testCodexRemoteEscapesEveryForbiddenTOMLControlCharacter() {
        for code in Array(UInt32(0)...UInt32(31)) + [127] {
            let value = String(UnicodeScalar(code)!)
            let escaped = String(format: "\\u%04X", code)
            XCTAssertEqual(IntegrationPrompts.codexRemote(url: value, token: value), """
            [mcp_servers.hookfeed]
            url = "\(escaped)/mcp"
            http_headers = { Authorization = "Bearer \(escaped)" }
            """)
        }
    }

    func testGenericRemoteMCPUsesPlainConnectionFacts() {
        XCTAssertEqual(IntegrationPrompts.mcpRemote(url: "http://100.101.2.3:8787", token: "test-token"), """
        URL:     http://100.101.2.3:8787/mcp
        Header:  Authorization: Bearer test-token
        """)
    }

    func testHermesYAMLUsesJSONQuotedPath() throws {
        let path = "/Applications/Knight's Apps/HookFeed \"Test\".app/Contents/Helpers/hookfeed"
        let yaml = IntegrationPrompts.hermes(cliPath: path)
        let line = try XCTUnwrap(yaml.split(separator: "\n").first { $0.contains("command:") })
        let encoded = String(line.dropFirst("    command: ".count))
        XCTAssertTrue(encoded.hasPrefix("\""))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)), path)
        XCTAssertTrue(IntegrationPrompts.hermesPrompt(cliPath: path).contains("source \"hermes\""))
    }

    func testHermesSetupCommandWithAndWithoutProfile() {
        XCTAssertEqual(IntegrationPrompts.hermesAddCommand(url: "http://127.0.0.1:47321"),
                       "hermes mcp add hookfeed --url 'http://127.0.0.1:47321/mcp' --auth header")
        XCTAssertEqual(IntegrationPrompts.hermesAddCommand(url: "https://mac.tailnet.ts.net", profile: "helena"),
                       "hermes -p 'helena' mcp add hookfeed --url 'https://mac.tailnet.ts.net/mcp' --auth header")
    }

    func testHermesSetupCommandQuotesProfileAndURL() {
        let value = #"Knight's "test" \ profile"#
        XCTAssertEqual(IntegrationPrompts.hermesAddCommand(url: value, profile: value),
                       #"hermes -p 'Knight'\''s "test" \ profile' mcp add hookfeed --url 'Knight'\''s "test" \ profile/mcp' --auth header"#)
    }

    func testHermesRemoteYAMLPreservesTokenAndProfileGuidance() throws {
        let value = #"Knight's "test" \ token"#
        let yaml = IntegrationPrompts.hermesRemote(url: value, token: value)
        let line = try XCTUnwrap(yaml.split(separator: "\n").first { $0.contains("Authorization:") })
        let encoded = String(line.dropFirst("      Authorization: ".count))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)), "Bearer " + value)
        XCTAssertTrue(IntegrationPrompts.hermesPrompt(cliPath: "/tmp/hookfeed").contains("Profiles keep their own config"))
    }
    func testOpenClawConfigurationsMatchDocFixtures() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        XCTAssertEqual(IntegrationPrompts.openclaw(cliPath: "/Applications/HookFeed.app/Contents/Helpers/hookfeed") + "\n",
                       try String(contentsOf: fixtures.appendingPathComponent("openclaw-local.json")))
        XCTAssertEqual(IntegrationPrompts.openclawRemote(url: "https://mac.tailnet.ts.net", token: "test-token") + "\n",
                       try String(contentsOf: fixtures.appendingPathComponent("openclaw-remote.json")))
    }

    func testOpenClawEscapesPathsURLsAndTokens() throws {
        let value = "quote\" space slash\\ newline\n"
        let escaped = #"quote\" space slash\\ newline\n"#
        let local = IntegrationPrompts.openclaw(cliPath: value)
        let remote = IntegrationPrompts.openclawRemote(url: value, token: value)
        XCTAssertTrue(local.contains("\"command\" : \"\(escaped)\""))
        XCTAssertTrue(remote.contains("\"url\" : \"\(escaped)/mcp\""))
        XCTAssertTrue(remote.contains("\"Authorization\" : \"Bearer \(escaped)\""))
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let expectedLocal = try String(contentsOf: fixtures.appendingPathComponent("openclaw-local.json"))
            .replacingOccurrences(of: "/Applications/HookFeed.app/Contents/Helpers/hookfeed", with: escaped)
        let expectedRemote = try String(contentsOf: fixtures.appendingPathComponent("openclaw-remote.json"))
            .replacingOccurrences(of: "https://mac.tailnet.ts.net", with: escaped)
            .replacingOccurrences(of: "test-token", with: escaped)
        XCTAssertEqual(local + "\n", expectedLocal)
        XCTAssertEqual(remote + "\n", expectedRemote)
        let decoded = try JSONSerialization.jsonObject(with: Data(remote.utf8)) as! [String: [String: [String: [String: Any]]]]
        XCTAssertEqual(decoded["mcp"]?["servers"]?["hookfeed"]?["url"] as? String, value + "/mcp")
        XCTAssertTrue(IntegrationPrompts.openclawPrompt(cliPath: value).contains(local))
    }

    func testOpenClawCommandsAndListFixture() throws {
        let command = try XCTUnwrap(Integration.named("openclaw")?.mcpCommand)
        let path = "/Applications/Knight's Apps/HookFeed \"Test\"\\.app/hookfeed"
        XCTAssertEqual(command.add(path), ["mcp", "add", "hookfeed", "--command", path, "--arg", "mcp"])
        XCTAssertEqual(command.list, ["mcp", "list"])
        XCTAssertEqual(command.remove, ["mcp", "unset", "hookfeed"])
        XCTAssertEqual(command.test, ["mcp", "probe", "hookfeed"])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/openclaw-list.txt")
        XCTAssertTrue(command.isListed(try String(contentsOf: fixture)))
        XCTAssertTrue(command.isListed("- hookfeed (1 connected principal)"))
        XCTAssertFalse(command.isListed("- hookfeed-other\n- docs"))
        XCTAssertFalse(command.isListed("No OpenClaw-managed MCP servers configured in /hookfeed/config."))
    }

}
