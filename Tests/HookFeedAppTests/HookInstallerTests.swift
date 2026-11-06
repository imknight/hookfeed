import Foundation
import XCTest
@testable import HookFeedCore
@testable import HookFeedApp

final class HookInstallerTests: XCTestCase {
    @MainActor
    func testCursorInstallStaleStatusBackupAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".cursor/hooks.json")
        let first = try HookInstaller.preview(agent: .cursor, path: path, cliPath: "/old/hookfeed")
        XCTAssertNil(try first.apply())
        XCTAssertFalse(try HookInstaller.preview(agent: .cursor, path: path, cliPath: "/old/hookfeed").hasChanges)
        let original = try Data(contentsOf: path)
        let state = await IntegrationStatus.state(for: Integration.named("cursor")!, detection: Detection(configDirectory: true, executable: nil),
                                                  cliPath: "/new/hookfeed", runner: RecordingRunner(), configPath: { _ in path })
        XCTAssertEqual(state, .needsUpdate)
        let plan = try HookInstaller.preview(agent: .cursor, path: path, cliPath: "/new/hookfeed")
        let backup = try XCTUnwrap(plan.apply())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertFalse(try HookInstaller.preview(agent: .cursor, path: path, cliPath: "/new/hookfeed").hasChanges)
        try FileManager.default.removeItem(at: backup)
        _ = try HookInstaller.preview(agent: .cursor, removing: true, path: path, cliPath: "/new/hookfeed").apply()
        XCTAssertEqual(try HookConfiguration.parse(Data(contentsOf: path))["hooks"] as? NSDictionary, [:] as NSDictionary)
    }

    func testAntigravityInstallBackupAndIdempotence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(HookAgent.antigravity.relativeConfigPath)
        XCTAssertNil(try HookInstaller.preview(agent: .antigravity, path: path).apply())
        XCTAssertFalse(try HookInstaller.preview(agent: .antigravity, path: path).hasChanges)
        let before = try Data(contentsOf: path)
        let backup = try XCTUnwrap(HookInstaller.preview(agent: .antigravity, path: path, cliPath: "/new/hookfeed").apply())
        XCTAssertEqual(try Data(contentsOf: backup), before)
        XCTAssertFalse(try HookInstaller.preview(agent: .antigravity, path: path, cliPath: "/new/hookfeed").hasChanges)
        let removalBackup = try XCTUnwrap(HookInstaller.preview(agent: .antigravity, removing: true, path: path, cliPath: "/new/hookfeed").apply())
        XCTAssertNotEqual(backup, removalBackup)
        XCTAssertEqual(try Data(contentsOf: backup), before)
        XCTAssertEqual(try HookConfiguration.parse(Data(contentsOf: path)) as NSDictionary, [:] as NSDictionary)
    }

    func testPreviewBackupIdempotenceRemoveAndMalformedRefusal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"env":{"KEEP":"yes"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]}}"#.utf8)
        try original.write(to: path)
        let plan = try HookInstaller.preview(agent: .claudeCode, path: path)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(plan.hasChanges)
        let backup = try XCTUnwrap(plan.apply())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let installed = try Data(contentsOf: path)
        let again = try HookInstaller.preview(agent: .claudeCode, path: path)
        XCTAssertFalse(again.hasChanges)
        XCTAssertNil(try again.apply())
        XCTAssertEqual(try Data(contentsOf: path), installed)
        let removal = try HookInstaller.preview(agent: .claudeCode, removing: true, path: path)
        XCTAssertTrue(removal.hasChanges)
        _ = try removal.apply()
        XCTAssertEqual(try HookConfiguration.parse(Data(contentsOf: path)) as NSDictionary, try HookConfiguration.parse(original) as NSDictionary)
        try Data("{".utf8).write(to: path)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertThrowsError(try HookInstaller.preview(agent: .claudeCode, path: path))
        XCTAssertEqual(try Data(contentsOf: path), Data("{".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }

    func testCodexApprovalInstallBackupRetryAndRemove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hooks.json")
        let original = Data(#"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"keep"}]}]}}"#.utf8)
        try original.write(to: path)
        let plan = try HookInstaller.preview(agent: .codex, path: path)
        let backup = try XCTUnwrap(plan.apply())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let hooks = try XCTUnwrap(try HookConfiguration.parse(Data(contentsOf: path))["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["Stop", "PermissionRequest"])
        XCTAssertEqual((hooks["PermissionRequest"] as? [Any])?.count, 2)
        XCTAssertFalse(try HookInstaller.preview(agent: .codex, path: path).hasChanges)
        _ = try HookInstaller.preview(agent: .codex, removing: true, path: path).apply()
        XCTAssertEqual(try HookConfiguration.parse(Data(contentsOf: path)) as NSDictionary, try HookConfiguration.parse(original) as NSDictionary)
    }

    func testMissingFileAndChangedSincePreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".codex/hooks.json")
        let plan = try HookInstaller.preview(agent: .codex, path: path)
        XCTAssertTrue(plan.hasChanges)
        XCTAssertNil(try plan.apply())
        let removal = try HookInstaller.preview(agent: .codex, removing: true, path: path)
        let modified = Data(#"{"changed":true}"#.utf8)
        try modified.write(to: path)
        XCTAssertThrowsError(try removal.apply())
        XCTAssertEqual(try Data(contentsOf: path), modified)
    }
    func testRetiredImportedHookNeedsUpdateAndIsBackedUpBeforeMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hooks.json")
        let original = Data(#"{"imported":{"Stop":[{"type":"command","command":"/old/hookfeed hook gemini-cli"}]},"other":{"Stop":[{"command":"keep"}]}}"#.utf8)
        try original.write(to: path)
        let state = await IntegrationStatus.state(for: Integration.named("antigravity")!, detection: Detection(configDirectory: true, executable: nil),
                                                  cliPath: "/new/hookfeed", runner: RecordingRunner(), configPath: { _ in path })
        XCTAssertEqual(state, .needsUpdate)
        let plan = try HookInstaller.preview(agent: .antigravity, path: path, cliPath: "/new/hookfeed")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(plan.apply())), original)
        let migrated = try HookConfiguration.parse(Data(contentsOf: path))
        XCTAssertNil(migrated["imported"])
        XCTAssertEqual(migrated["other"] as? NSDictionary, ["Stop": [["command": "keep"]]] as NSDictionary)
        XCTAssertFalse(try HookInstaller.preview(agent: .antigravity, path: path, cliPath: "/new/hookfeed").hasChanges)
        let connected = await IntegrationStatus.state(for: Integration.named("antigravity")!, detection: Detection(configDirectory: true, executable: nil),
                                                      cliPath: "/new/hookfeed", runner: RecordingRunner(), configPath: { _ in path })
        XCTAssertEqual(connected, .connected)
    }

}
