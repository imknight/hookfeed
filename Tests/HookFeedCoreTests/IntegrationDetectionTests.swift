import Foundation
import XCTest
@testable import HookFeedCore

final class IntegrationDetectionTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func testGrokBotOnlyDetectsExecutableWithoutAssumingConfigLocation() throws {
        XCTAssertFalse(detect("grokbot").found)
        let file = try executable("bin/grokbot")
        XCTAssertEqual(detect("grokbot", path: file.deletingLastPathComponent().path).executable, file)
        XCTAssertFalse(detect("grokbot").configDirectory)
    }
    func testCursorExecutablesAndFallback() throws {
        for name in ["cursor-agent", "cursor"] {
            let file = try executable("bin/" + name)
            XCTAssertEqual(detect("cursor", path: file.deletingLastPathComponent().path).executable, file)
            try FileManager.default.removeItem(at: file)
            let fallback = try executable(".local/bin/" + name)
            XCTAssertEqual(detect("cursor").executable, fallback)
            try FileManager.default.removeItem(at: fallback)
        }
    }

    func testCursorConfigAndAppWithoutCLI() throws {
        let config = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertTrue(detect("cursor").configDirectory)
        try FileManager.default.removeItem(at: config)
        let app = home.appendingPathComponent("Applications/Cursor.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(detect("cursor").application)
        XCTAssertTrue(detect("cursor").found)
        XCTAssertNil(detect("cursor").executable)
        try FileManager.default.removeItem(at: app)
        XCTAssertFalse(detect("cursor").found)
    }

    func testAntigravityPathFallbackAndConfigDetection() throws {
        XCTAssertFalse(detect("antigravity").found)
        let path = try executable("bin/agy")
        XCTAssertEqual(detect("antigravity", path: path.deletingLastPathComponent().path).executable, path)
        for directory in [".local/bin", "homebrew/bin", "usr/local/bin"] {
            let file = try executable(directory + "/agy")
            if directory == ".local/bin" { XCTAssertEqual(detect("antigravity").executable, file) }
            let result = IntegrationDetection.detect(Integration.named("antigravity")!, home: home, searchPath: "",
                                                     fallbackDirectories: [file.deletingLastPathComponent().path])
            XCTAssertEqual(result.executable, file)
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/agy"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity"), withIntermediateDirectories: true)
        XCTAssertTrue(detect("antigravity").configDirectory)
        XCTAssertNil(detect("antigravity").executable)
    }

    func testLegacySettingsAndExecutableDoNotDetectAntigravity() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".gemini/settings.json"))
        XCTAssertFalse(detect("antigravity").found)
        _ = try executable(".local/bin/gemini")
        XCTAssertFalse(detect("antigravity").found)
        XCTAssertTrue(Integration.all.allSatisfy { !detect($0.id).found })
    }

    func detect(_ id: String, path: String = "") -> Detection {
        IntegrationDetection.detect(Integration.named(id)!, home: home, searchPath: path, fallbackDirectories: ["~/.local/bin"], applicationDirectories: [home.appendingPathComponent("Applications").path])
    }
    func executable(_ relative: String, mode: Int = 0o755) throws -> URL {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
    func testConfigDirectoryOnly() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let result = detect("codex")
        XCTAssertTrue(result.configDirectory)
        XCTAssertNil(result.executable)
        XCTAssertTrue(result.found)
    }
    func testDetectsExecutableOnLoginShellPath() throws {
        let file = try executable("bin/hermes")
        _ = try executable(".local/bin/hermes")
        XCTAssertEqual(detect("hermes", path: "/nonexistent:\(file.deletingLastPathComponent().path)").executable, file)
    }
    func testFallbackDirectories() throws {
        let file = try executable(".local/bin/hermes")
        XCTAssertEqual(detect("hermes").executable, file)
    }
    func testNonExecutableAndDirectoryIgnored() throws {
        let file = try executable("bin/hermes", mode: 0o644)
        let path = file.deletingLastPathComponent().path
        XCTAssertNil(detect("hermes", path: path).executable)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertNil(detect("hermes", path: path).executable)
    }
    func testExecutableSymlinksFollowRegularFileTargets() throws {
        let target = try executable("versions/hermes")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("hermes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(detect("hermes", path: bin.path).executable, link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        XCTAssertNil(detect("hermes", path: bin.path).executable)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("missing"))
        XCTAssertNil(detect("hermes", path: bin.path).executable)
    }

    func testOpenClawExecutableOnPath() throws {
        let file = try executable("bin/openclaw")
        XCTAssertEqual(detect("openclaw", path: file.deletingLastPathComponent().path).executable, file)
    }
    func testOpenClawFallbackDirectory() throws {
        let file = try executable(".local/bin/openclaw")
        XCTAssertEqual(detect("openclaw").executable, file)
    }
    func testOpenClawConfigDirectoryOnly() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".openclaw"), withIntermediateDirectories: true)
        let result = detect("openclaw")
        XCTAssertTrue(result.found)
        XCTAssertTrue(result.configDirectory)
        XCTAssertNil(result.executable)
    }

    func testNothingFound() {
        for integration in Integration.all { XCTAssertFalse(detect(integration.id, path: ":relative:").found) }
    }
}
