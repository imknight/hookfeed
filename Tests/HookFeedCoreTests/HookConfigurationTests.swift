import Foundation
import XCTest
@testable import HookFeedCore

final class HookConfigurationTests: XCTestCase {
    private let command = "'/Applications/HookFeed.app/Contents/Helpers/hookfeed' hook claude-code"

    func testCursorFlatHooksMergeUpdateRemoveAndIdempotence() throws {
        let command = "'/new/hookfeed' hook cursor"
        let original = try HookConfiguration.parse(Data(#"{"version":1,"custom":true,"hooks":{"afterFileEdit":[{"command":"format"}],"stop":[{"command":"keep"},{"command":"'/old/hookfeed' hook cursor","timeout":5}]}}"#.utf8))
        let merged = try HookConfiguration.merge(original, agent: .cursor, command: command)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(merged["custom"] as? Bool, true)
        XCTAssertEqual(merged["version"] as? Int, 1)
        XCTAssertEqual(hooks["afterFileEdit"]?.first?["command"] as? String, "format")
        XCTAssertEqual(hooks["stop"]?.compactMap { $0["command"] as? String }, ["keep", command])
        XCTAssertEqual(hooks["stop"]?.last?["timeout"] as? Int, 5)
        XCTAssertEqual(try HookConfiguration.merge(merged, agent: .cursor, command: command) as NSDictionary, merged as NSDictionary)
        let removed = try HookConfiguration.merge(merged, agent: .cursor, command: command, removing: true)
        XCTAssertEqual(((removed["hooks"] as? [String: [[String: Any]]])?["stop"]?.first?["command"]) as? String, "keep")
        XCTAssertEqual(((removed["hooks"] as? [String: [[String: Any]]])?["stop"])?.count, 1)
        let empty = try HookConfiguration.merge([:], agent: .cursor, command: command)
        XCTAssertEqual(empty as NSDictionary, ["version": 1, "hooks": ["stop": [["command": command]]]] as NSDictionary)
        XCTAssertEqual(try HookConfiguration.merge([:], agent: .cursor, command: command, removing: true) as NSDictionary, [:] as NSDictionary)
        XCTAssertThrowsError(try HookConfiguration.merge(["version": 2], agent: .cursor, command: command))
        XCTAssertThrowsError(try HookConfiguration.merge(["hooks": ["stop": "bad"]], agent: .cursor, command: command))
    }

    func testAntigravityNamedDefinitionMergeAndRemoval() throws {
        let command = "'/new/hookfeed' hook antigravity"
        let empty = try HookConfiguration.merge([:], agent: .antigravity, command: command)
        XCTAssertEqual(empty as NSDictionary, try HookConfiguration.parse(Data(IntegrationPrompts.antigravity(cliPath: "/new/hookfeed").utf8)) as NSDictionary)
        let other: [String: Any] = ["Stop": [["command": "keep"]]]
        let original: [String: Any] = ["other": other, "hookfeed": ["enabled": false, "SessionStart": [["command": "keep-start"]],
            "Stop": [["command": "'/old/hookfeed' hook antigravity"], ["command": "keep-stop"]]]]
        let merged = try HookConfiguration.merge(original, agent: .antigravity, command: command)
        XCTAssertEqual(merged["other"] as? NSDictionary, other as NSDictionary)
        let definition = try XCTUnwrap(merged["hookfeed"] as? [String: Any])
        XCTAssertEqual(definition["enabled"] as? Bool, true)
        XCTAssertEqual((definition["Stop"] as? [[String: Any]])?.compactMap { $0["command"] as? String }, ["keep-stop", command])
        XCTAssertEqual(definition["SessionStart"] as? NSArray, [["command": "keep-start"]] as NSArray)
        XCTAssertEqual(try HookConfiguration.merge(merged, agent: .antigravity, command: command) as NSDictionary, merged as NSDictionary)
        let removed = try HookConfiguration.merge(merged, agent: .antigravity, command: command, removing: true)
        XCTAssertEqual(((removed["hookfeed"] as? [String: Any])?["Stop"] as? [[String: String]])?.first?["command"], "keep-stop")
        XCTAssertEqual(try HookConfiguration.merge(empty, agent: .antigravity, command: command, removing: true) as NSDictionary, [:] as NSDictionary)
        for invalid: [String: Any] in [["hookfeed": "bad"], ["hookfeed": ["Stop": "bad"]]] {
            XCTAssertThrowsError(try HookConfiguration.merge(invalid, agent: .antigravity, command: command))
        }
    }

    func testMissingAndEmptyFilesInstallHooks() throws {
        for data in [nil, Data(), Data("{}".utf8)] as [Data?] {
            let original = try HookConfiguration.parse(data)
            let merged = try HookConfiguration.merge(original, agent: .claudeCode, command: command)
            let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
            XCTAssertEqual(Set(hooks.keys), ["Stop", "Notification"])
        }
    }

    func testMergePreservesUnrelatedJSONAndNestedHooks() throws {
        let original = try HookConfiguration.parse(Data(#"{"env":{"KEEP":"yes"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"other"}]}],"Stop":[{"matcher":"","custom":true,"hooks":[{"type":"command","command":"keep"}]}]}}"#.utf8))
        let merged = try HookConfiguration.merge(original, agent: .claudeCode, command: command)
        XCTAssertEqual(merged["env"] as? NSDictionary, original["env"] as? NSDictionary)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let before = try XCTUnwrap(original["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["SessionStart"] as? NSArray, before["SessionStart"] as? NSArray)
        XCTAssertEqual((hooks["Stop"] as? [NSDictionary])?.first, (before["Stop"] as? [NSDictionary])?.first)
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2)
    }

    func testInstallIsIdempotentIncludingExistingDoubleQuotedEntry() throws {
        let original = try HookConfiguration.parse(Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/Applications/HookFeed.app/Contents/Helpers/hookfeed\" hook codex"}]}]}}"#.utf8))
        let merged = try HookConfiguration.merge(original, agent: .codex, command: "'/new/hookfeed' hook codex")
        XCTAssertEqual((((merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "'/new/hookfeed' hook codex")
        XCTAssertNotNil((merged["hooks"] as? NSDictionary)?["PermissionRequest"])
        XCTAssertEqual(try HookConfiguration.merge(merged, agent: .codex, command: "'/new/hookfeed' hook codex") as NSDictionary, merged as NSDictionary)
        let installed = try HookConfiguration.merge([:], agent: .claudeCode, command: command)
        XCTAssertEqual(try HookConfiguration.merge(installed, agent: .claudeCode, command: command) as NSDictionary, installed as NSDictionary)
    }

    func testShellEscapedApostrophePathRemainsIdempotentAndRemovable() throws {
        let command = "'/Applications/Knight'\\''s Apps/HookFeed.app/Contents/Helpers/hookfeed' hook codex"
        let installed = try HookConfiguration.merge([:], agent: .codex, command: command)
        XCTAssertEqual(try HookConfiguration.merge(installed, agent: .codex, command: command) as NSDictionary, installed as NSDictionary)
        let removed = try HookConfiguration.merge(installed, agent: .codex, command: command, removing: true)
        XCTAssertEqual(removed["hooks"] as? NSDictionary, [:] as NSDictionary)
    }

    func testRemoveOnlyHookFeedCommandsAndKeepSharedGroup() throws {
        let original: [String: Any] = ["theme": "dark", "hooks": ["Stop": [["hooks": [["type": "command", "command": command], ["type": "command", "command": "keep"]]]]]]
        let removed = try HookConfiguration.merge(original, agent: .claudeCode, command: command, removing: true)
        let hooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual((groups[0]["hooks"] as? [[String: String]])?.map { $0["command"] }, ["keep"])
        XCTAssertEqual(removed["theme"] as? String, "dark")
        XCTAssertEqual(try HookConfiguration.merge([:], agent: .codex, command: command, removing: true) as NSDictionary, [:] as NSDictionary)
    }

    func testStalePathIsRewrittenNotDuplicated() throws {
        for path in ["/Users/x/Applications/HookFeed.app/Contents/Helpers/hookfeed", "/Users/x/Knight's Apps/HookFeed.app/Contents/Helpers/hookfeed"] {
            let old = "\(ShellText.quote(path)) hook codex"
            let new = "'/Applications/HookFeed.app/Contents/Helpers/hookfeed' hook codex"
            let entries: [[String: Any]] = [["type": "command", "command": old, "timeout": 1], ["type": "command", "command": "keep"]]
            let original: [String: Any] = ["hooks": ["Stop": [["hooks": entries]], "PermissionRequest": [["hooks": entries]]]]
            let merged = try HookConfiguration.merge(original, agent: .codex, command: new)
            let events = try XCTUnwrap(merged["hooks"] as? [String: [[String: Any]]])
            for event in ["Stop", "PermissionRequest"] {
                XCTAssertEqual(events[event]?.count, 1)
                let hooks = try XCTUnwrap(events[event]?.first?["hooks"] as? [[String: Any]])
                XCTAssertEqual(hooks.compactMap { $0["command"] as? String }, [new, "keep"])
                XCTAssertEqual(hooks.first?["timeout"] as? Int, 1)
            }
            XCTAssertEqual(try HookConfiguration.merge(merged, agent: .codex, command: new) as NSDictionary, merged as NSDictionary)
        }
    }

    func testMalformedJSONOrHookShapeIsRejected() {
        for text in ["{", "[]", "null", "not JSON"] {
            XCTAssertThrowsError(try HookConfiguration.parse(Data(text.utf8)))
        }
        for value: [String: Any] in [["hooks": "bad"], ["hooks": ["Stop": "bad"]], ["hooks": ["Stop": [["hooks": "bad"]]]]] {
            XCTAssertThrowsError(try HookConfiguration.merge(value, agent: .claudeCode, command: command))
        }
    }
    func testAntigravityRemovesRetiredHandlersWithoutChangingOtherHooks() throws {
        let command = "'/new/hookfeed' hook antigravity"
        let original: [String: Any] = [
            "imported": ["enabled": true,
                         "Stop": [["command": "'/old/Knight'\\''s Apps/hookfeed' hook gemini-cli"],
                                  ["command": "echo hookfeed hook gemini-cli"],
                                  ["command": "hookfeed hook gemini-cli && keep"]],
                         "PreToolUse": [["matcher": "run_command", "hooks": [
                            ["type": "command", "command": "hookfeed hook gemini-cli"],
                            ["type": "command", "command": "keep"]]]]],
            "obsolete": ["enabled": true, "Stop": [["command": "hookfeed hook gemini-cli"]]],
            "hooks": ["AfterAgent": [["hooks": [["type": "command", "command": "hookfeed hook gemini-cli"]]]]],
            "unrelated": ["Stop": [["command": "other"]]]
        ]
        let merged = try HookConfiguration.merge(original, agent: .antigravity, command: command)
        let imported = try XCTUnwrap(merged["imported"] as? [String: Any])
        XCTAssertEqual((imported["Stop"] as? [[String: String]])?.map { $0["command"] },
                       ["echo hookfeed hook gemini-cli", "hookfeed hook gemini-cli && keep"])
        let preToolUse = try XCTUnwrap(imported["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual((preToolUse[0]["hooks"] as? [[String: String]])?.first?["command"], "keep")
        XCTAssertEqual((preToolUse[0]["hooks"] as? [Any])?.count, 1)
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "run_command")
        XCTAssertNil(merged["obsolete"])
        XCTAssertNil(merged["hooks"])
        XCTAssertEqual(merged["unrelated"] as? NSDictionary, original["unrelated"] as? NSDictionary)
        XCTAssertEqual(try HookConfiguration.merge(merged, agent: .antigravity, command: command) as NSDictionary, merged as NSDictionary)
        let removed = try HookConfiguration.merge(original, agent: .antigravity, command: command, removing: true)
        XCTAssertNil(removed["obsolete"])
        XCTAssertNil(removed["hookfeed"])
    }

}
