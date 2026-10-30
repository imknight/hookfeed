import Foundation
import XCTest
@testable import HookFeedCore
@testable import HookFeedApp

actor RecordingRunner: CommandRunner {
    struct Call: Equatable { let executable: URL; let arguments: [String] }
    var calls: [Call] = []
    let listed: Bool
    let addStatus: Int32
    init(listed: Bool = false, addStatus: Int32 = 0) { self.listed = listed; self.addStatus = addStatus }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if arguments == ["mcp", "list"], executable.lastPathComponent == "openclaw" {
            return .init(status: 0, stdout: listed ? "OpenClaw-managed MCP servers (/home/agent/.openclaw/openclaw.json):\n- hookfeed\n" : "No OpenClaw-managed MCP servers configured.", stderr: "")
        }
        if arguments == ["mcp", "list"] { return .init(status: 0, stdout: listed ? "hookfeed (stdio)" : "", stderr: "") }
        if arguments.contains("add") { return .init(status: addStatus, stdout: "", stderr: addStatus == 0 ? "" : "boom") }
        return .init(status: 0, stdout: "  connected\n", stderr: "")
    }
}

final class CommandInstallTests: XCTestCase {
    let executable = URL(fileURLWithPath: "/fake/hermes")
    let cli = "/Applications/Knight's Apps/HookFeed.app/Contents/Helpers/hookfeed"
    func plan(_ runner: RecordingRunner, removing: Bool = false) async throws -> CommandInstallPlan {
        try await CommandInstallPlan.make(syntheticMCPIntegration(), executable: executable, cliPath: cli, removing: removing, runner: runner)
    }
    func testAddPassesPathAsSingleArgument() async throws {
        let plan = try await plan(RecordingRunner())
        XCTAssertEqual(plan.arguments, ["mcp", "add", "hookfeed", "--command", cli, "--args", "mcp"])
        XCTAssertEqual(plan.displayCommand, "hermes mcp add hookfeed --command '/Applications/Knight'\\''s Apps/HookFeed.app/Contents/Helpers/hookfeed' --args mcp")
    }
    func testAlreadyListedHasNoChanges() async throws {
        let runner = RecordingRunner(listed: true)
        let plan = try await plan(runner)
        XCTAssertFalse(plan.hasChanges)
        _ = try await plan.apply(runner: runner)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [["mcp", "list"]])
    }
    func testAddThenTest() async throws {
        let runner = RecordingRunner()
        let plan = try await plan(runner)
        let result = try await plan.apply(runner: runner)
        XCTAssertEqual(result, "connected")
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [["mcp", "list"], plan.arguments, ["mcp", "test", "hookfeed"]])
        XCTAssertTrue(calls.allSatisfy { $0.executable == executable })
    }
    func testNonZeroExitSurfacesStderr() async throws {
        let runner = RecordingRunner(addStatus: 2)
        let plan = try await plan(runner)
        do { _ = try await plan.apply(runner: runner); XCTFail("Expected error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("boom")) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }
    func testRemove() async throws {
        let runner = RecordingRunner(listed: true)
        let plan = try await plan(runner, removing: true)
        _ = try await plan.apply(runner: runner)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [["mcp", "list"], ["mcp", "remove", "hookfeed"]])
    }
    func testTimeoutTerminatesProcess() async throws {
        let start = Date()
        do { _ = try await ProcessCommandRunner(environmentPath: "/bin").run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.5); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testRepeatedShortLivedProcesses() async throws {
        for _ in 0..<20 {
            let result = try await ProcessCommandRunner(environmentPath: "/bin").run(URL(fileURLWithPath: "/bin/echo"), ["done"], timeout: 1)
            XCTAssertEqual(result.stdout, "done\n")
        }
    }
    func testStdinIsClosed() async throws {
        let result = try await ProcessCommandRunner(environmentPath: "/bin").run(URL(fileURLWithPath: "/bin/cat"), [], timeout: 1)
        XCTAssertEqual(result, CommandResult(status: 0, stdout: "", stderr: ""))
    }
    func testArgumentsNotShellExpanded() async throws {
        let result = try await ProcessCommandRunner(environmentPath: "/bin").run(URL(fileURLWithPath: "/bin/echo"), ["$HOME"], timeout: 1)
        XCTAssertEqual(result.stdout, "$HOME\n")
    }
}
