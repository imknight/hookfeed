import Foundation
import XCTest
@testable import HookFeedCore

final class CLILinkTests: XCTestCase {
    private var folder: URL!
    private var link: URL { CLILink.userDirectory(home: folder).appendingPathComponent("hookfeed") }
    private var target: URL { folder.appendingPathComponent("HookFeed.app/Contents/Helpers/hookfeed") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: target)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testStateMissingThenLinked() throws {
        XCTAssertEqual(CLILink.state(at: link, target: target), .missing)
        try CLILink.install(at: link, target: target, replacing: false)
        XCTAssertEqual(CLILink.state(at: link, target: target), .linked)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        try CLILink.install(at: link, target: target, replacing: false)
        try CLILink.uninstall(at: link, target: target)
        XCTAssertEqual(CLILink.state(at: link, target: target), .missing)
    }

    func testDetectsLinkToOtherApp() throws {
        let other = folder.appendingPathComponent("Other.app/hookfeed")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertEqual(CLILink.state(at: link, target: target), .linkedElsewhere(other.path))
        XCTAssertThrowsError(try CLILink.install(at: link, target: target, replacing: false))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), other.path)
        try CLILink.install(at: link, target: target, replacing: true)
        XCTAssertEqual(CLILink.state(at: link, target: target), .linked)
    }

    func testRefusesRegularFileUnlessReplacing() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("my existing command".utf8)
        try original.write(to: link)
        XCTAssertEqual(CLILink.state(at: link, target: target), .blockedByFile)
        XCTAssertThrowsError(try CLILink.install(at: link, target: target, replacing: false))
        XCTAssertEqual(try Data(contentsOf: link), original)
        try CLILink.install(at: link, target: target, replacing: true)
        XCTAssertEqual(CLILink.state(at: link, target: target), .linked)
    }

    func testUninstallLeavesForeignLinkAlone() throws {
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try CLILink.uninstall(at: link, target: target)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), other.path)
        try FileManager.default.removeItem(at: link)
        try Data("file".utf8).write(to: link)
        try CLILink.uninstall(at: link, target: target)
        XCTAssertEqual(try Data(contentsOf: link), Data("file".utf8))
    }

    func testIsOnPathHandlesTildeAndTrailingSlash() {
        let directory = CLILink.userDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(CLILink.isOnPath(directory, path: "/bin:~/.local/bin/:/usr/bin"))
        XCTAssertTrue(CLILink.isOnPath(directory, path: directory.path + "/"))
        XCTAssertFalse(CLILink.isOnPath(directory, path: "/bin:" + directory.path + "-other"))
        XCTAssertEqual(CLILink.userDirectory(home: folder).path, folder.appendingPathComponent(".local/bin").path)
    }

    func testReplacementDoesNotRemoveDirectoryContents() throws {
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let file = link.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try CLILink.install(at: link, target: target, replacing: true))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }
}
