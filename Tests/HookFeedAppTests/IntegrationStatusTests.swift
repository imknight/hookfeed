import Foundation
import XCTest
@testable import HookFeedCore
@testable import HookFeedApp

struct StatusRunner: CommandRunner {
    var result = CommandResult(status: 0, stdout: "", stderr: "")
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult { result }
}

func syntheticMCPIntegration() -> Integration {
    var integration = Integration.named("hermes")!
    integration.mcpCommand = MCPCommand(executable: "hermes", add: { ["mcp", "add", "hookfeed", "--command", $0, "--args", "mcp"] },
                                        remove: ["mcp", "remove", "hookfeed"], list: ["mcp", "list"], test: ["mcp", "test", "hookfeed"],
                                        afterInstall: "Run /reload-mcp in any open Hermes chat.")
    return integration
}

final class IntegrationStatusTests: XCTestCase {
    var home: URL!
    let cli = "/Applications/HookFeed.app/Contents/Helpers/hookfeed"
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func state(_ integration: Integration, detected: Bool = true, runner: StatusRunner = StatusRunner()) async -> ConnectionState {
        await IntegrationStatus.state(for: integration, detection: Detection(configDirectory: detected, executable: detected ? URL(fileURLWithPath: "/fake/hermes") : nil),
                                      cliPath: cli, runner: runner, configPath: { _ in self.home.appendingPathComponent("hooks.json") })
    }
    func testAntigravityStaleHookNeedsUpdate() async throws {
        let integration = Integration.named("antigravity")!
        let path = home.appendingPathComponent("hooks.json")
        _ = try HookInstaller.preview(agent: .antigravity, path: path, cliPath: "/old/hookfeed").apply()
        let stale = await state(integration)
        XCTAssertEqual(stale, .needsUpdate)
        _ = try HookInstaller.preview(agent: .antigravity, path: path, cliPath: cli).apply()
        let connected = await state(integration)
        XCTAssertEqual(connected, .connected)
    }

    func testHookStates() async throws {
        let codex = Integration.named("codex")!
        var result = await state(codex, detected: false)
        XCTAssertEqual(result, .notDetected)
        result = await state(codex)
        XCTAssertEqual(result, .detected)
        let path = home.appendingPathComponent("hooks.json")
        _ = try HookInstaller.preview(agent: .codex, path: path, cliPath: cli).apply()
        result = await state(codex)
        XCTAssertEqual(result, .connected)
        _ = try HookInstaller.preview(agent: .codex, path: path, cliPath: "/old/hookfeed").apply()
        result = await state(codex)
        XCTAssertEqual(result, .needsUpdate)
        try Data("[]".utf8).write(to: path)
        result = await state(codex)
        XCTAssertEqual(result, .error("The configuration must be a JSON object. No changes were made."))
    }
    func testMCPStates() async {
        let integration = syntheticMCPIntegration()
        var result = await state(integration, runner: StatusRunner(result: .init(status: 0, stdout: "hookfeed (stdio)", stderr: "")))
        XCTAssertEqual(result, .connected)
        result = await state(integration, runner: StatusRunner(result: .init(status: 1, stdout: "", stderr: "boom")))
        if case .error(let error) = result { XCTAssertTrue(error.contains("boom")) } else { XCTFail("Expected error") }
        result = await state(Integration.named("hermes")!)
        XCTAssertEqual(result, .detected)
    }
}
