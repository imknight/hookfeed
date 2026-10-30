import Foundation
import XCTest
@testable import HookFeedCore
@testable import HookFeedApp

@MainActor
final class ConnectAllTests: XCTestCase {
    var home: URL!
    let cli = "/Applications/HookFeed.app/Contents/Helpers/hookfeed"
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func testCursorConnectsWhenDetectedAndSkipsWhenAbsent() async throws {
        let home = home!
        let model = ConnectAllModel(home: home, searchPath: { "" }, cliPath: cli, runner: RecordingRunner(),
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) },
                                    integrations: [Integration.named("cursor")!], fallbackDirectories: [])
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["cursor"])
        await model.apply()
        XCTAssertEqual(model.outcomes["cursor"], .connected(detail: "Saved new configuration."))
        XCTAssertFalse(try HookInstaller.preview(agent: .cursor, path: home.appendingPathComponent(".cursor/hooks.json"), cliPath: cli).hasChanges)
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testAntigravityConnectsOnlyWhenDetected() async throws {
        let home = home!
        let model = ConnectAllModel(home: home, searchPath: { "" }, cliPath: cli, runner: RecordingRunner(),
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await model.refresh()
        await model.apply()
        XCTAssertNil(model.outcomes["antigravity"])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity"), withIntermediateDirectories: true)
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["antigravity"])
        await model.apply()
        XCTAssertEqual(model.outcomes["antigravity"], .connected(detail: "Saved new configuration."))
        XCTAssertFalse(try HookInstaller.preview(agent: .antigravity, path: home.appendingPathComponent(HookAgent.antigravity.relativeConfigPath), cliPath: cli).hasChanges)
    }

    func make(_ runner: RecordingRunner = RecordingRunner(), populated: Bool = true) throws -> ConnectAllModel {
        let home = home!
        if populated {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            _ = try HookInstaller.preview(agent: .claudeCode, path: home.appendingPathComponent(HookAgent.claudeCode.relativeConfigPath), cliPath: cli).apply()
            let bin = home.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("hermes")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return ConnectAllModel(home: home, searchPath: { home.appendingPathComponent("bin").path }, cliPath: cli, runner: runner,
                               configPath: { home.appendingPathComponent($0.relativeConfigPath) },
                               integrations: [Integration.all[0], Integration.all[1], syntheticMCPIntegration()], fallbackDirectories: [])
    }
    func testRefreshListsOnlyUnconnectedDetectedAgents() async throws {
        let model = try make()
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["codex", "hermes"])
        XCTAssertEqual(model.states, ["claude-code": .connected, "codex": .detected, "hermes": .detected])
        XCTAssertTrue(model.items.allSatisfy(\.selected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
    }
    func testApplyContinuesAfterFailure() async throws {
        let model = try make(RecordingRunner(addStatus: 1))
        await model.refresh()
        await model.apply()
        XCTAssertEqual(model.outcomes["codex"], .connected(detail: "Saved new configuration."))
        XCTAssertEqual(model.outcomes["hermes"], .failed("boom"))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".codex/hooks.json")).contains("PermissionRequest"))
    }
    func testDeselectedItemIsSkipped() async throws {
        let runner = RecordingRunner()
        let model = try make(runner)
        await model.refresh()
        model.select("hermes", selected: false)
        await model.apply()
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.arguments.contains("add") })
        XCTAssertNil(model.outcomes["hermes"])
    }
    func testChangedSincePreviewFailsThatItemOnly() async throws {
        let model = try make()
        await model.refresh()
        try Data("{}".utf8).write(to: home.appendingPathComponent(".codex/hooks.json"))
        await model.apply()
        XCTAssertEqual(model.outcomes["codex"], .failed("The configuration changed after this preview. Preview it again before applying."))
        XCTAssertEqual(model.outcomes["hermes"], .connected(detail: "connected"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex").path), ["hooks.json"])
    }
    func testNothingDetected() async throws {
        let model = try make(populated: false)
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.states, ["claude-code": .notDetected, "codex": .notDetected, "hermes": .notDetected])
    }
    func testProductionHermesRemainsCopyOnly() async throws {
        let home = home!
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".hermes"), withIntermediateDirectories: true)
        let model = ConnectAllModel(home: home, searchPath: { "" }, cliPath: cli, runner: RecordingRunner(),
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.states["hermes"], .detected)
    }
    func testOpenClawConnectAllAddsAndProbesDetectedExecutable() async throws {
        let home = home!
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("openclaw")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = RecordingRunner()
        let model = ConnectAllModel(home: home, searchPath: { bin.path }, cliPath: cli, runner: runner,
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["openclaw"])
        await model.apply()
        XCTAssertEqual(model.outcomes["openclaw"], .connected(detail: "connected"))
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [["mcp", "list"], ["mcp", "list"],
                        ["mcp", "add", "hookfeed", "--command", cli, "--arg", "mcp"], ["mcp", "probe", "hookfeed"]])
        XCTAssertTrue(calls.allSatisfy { $0.executable == executable })

        let connected = ConnectAllModel(home: home, searchPath: { bin.path }, cliPath: cli,
                                        runner: RecordingRunner(listed: true),
                                        configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await connected.refresh()
        XCTAssertTrue(connected.items.isEmpty)
    }

    func testOpenClawConnectAllSkipsMissingExecutable() async throws {
        let home = home!
        let runner = RecordingRunner()
        let model = ConnectAllModel(home: home, searchPath: { "" }, cliPath: cli, runner: runner,
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await model.refresh()
        await model.apply()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.outcomes["openclaw"])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".openclaw"), withIntermediateDirectories: true)
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testGeminiConnectsWhenDetectedAndSkipsWhenAbsent() async throws {
        let home = home!
        let model = ConnectAllModel(home: home, searchPath: { "" }, cliPath: cli, runner: RecordingRunner(),
                                    configPath: { home.appendingPathComponent($0.relativeConfigPath) }, fallbackDirectories: [])
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".gemini/settings.json"))
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), ["gemini-cli"])
        await model.apply()
        guard case .connected = model.outcomes["gemini-cli"] else { return XCTFail("Not connected") }
        XCTAssertFalse(try HookInstaller.preview(agent: .geminiCLI, path: home.appendingPathComponent(".gemini/settings.json"), cliPath: cli).hasChanges)
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
    }

}
