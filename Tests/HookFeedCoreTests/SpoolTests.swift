import Foundation
import GRDB
import XCTest
@testable import HookFeedCore

final class SpoolTests: XCTestCase {
    var home: URL!
    var spool: Spool { Spool(storePath: home.appendingPathComponent("inbox.sqlite").path) }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func testEnqueueWritesAtomicPrivateFile() throws {
        for key in [nil, "caller-key"] as [String?] {
            let draft = MessageDraft(title: "Done", source: "codex", idempotencyKey: key)
            let file = try spool.enqueue(draft)
            XCTAssertNotNil(file.lastPathComponent.range(of: #"^\d{13}-[0-9a-f-]{36}\.json$"#, options: .regularExpression))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: spool.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let message = try JSONDecoder().decode(SpooledMessage.self, from: Data(contentsOf: file))
            XCTAssertEqual(message.draft, draft)
            XCTAssertEqual(message.key, key ?? "spool:" + file.deletingPathExtension().lastPathComponent.dropFirst(14))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: spool.directory.path).contains { $0.hasSuffix(".tmp") })
    }
    func testPendingIsOldestFirstAndIgnoresTempAndRejected() throws {
        let newer = try spool.enqueue(.init(title: "new"), receivedAt: Date(timeIntervalSince1970: 1_793_000_002))
        let older = try spool.enqueue(.init(title: "old"), receivedAt: Date(timeIntervalSince1970: 1_793_000_001))
        try Data().write(to: spool.directory.appendingPathComponent("unfinished.tmp"))
        try FileManager.default.createDirectory(at: spool.directory.appendingPathComponent("rejected"), withIntermediateDirectories: true)
        XCTAssertEqual(try spool.pending(limit: 1).map(\.lastPathComponent), [older.lastPathComponent])
        XCTAssertEqual(try spool.pending(limit: 10).map(\.lastPathComponent), [older.lastPathComponent, newer.lastPathComponent])
    }
    func testCapReachedDropsAndLogs() throws {
        try FileManager.default.createDirectory(at: spool.directory, withIntermediateDirectories: true)
        for index in 0..<Spool.cap { try Data().write(to: spool.directory.appendingPathComponent("\(index).json")) }
        XCTAssertThrowsError(try spool.enqueue(.init(title: "full"))) { XCTAssertEqual($0 as? SpoolError, .full) }
    }
    func testDrainInsertsAndDeletesFiles() throws {
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        var keys: Set<String> = []
        for index in 0..<3 {
            let file = try spool.enqueue(.init(title: "update \(index)"))
            keys.insert(try JSONDecoder().decode(SpooledMessage.self, from: Data(contentsOf: file)).key)
        }
        let result = try spool.drain(into: store)
        XCTAssertEqual(result.inserted, 3)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertTrue(try spool.pending(limit: 10).isEmpty)
        XCTAssertEqual(Set(try store.messages().compactMap(\.idempotencyKey)), keys)
    }
    func testRedrainAfterCrashIsDuplicateNotNewRow() throws {
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        let file = try spool.enqueue(.init(title: "once"))
        let saved = try Data(contentsOf: file)
        _ = try spool.drain(into: store)
        try saved.write(to: file)
        let result = try spool.drain(into: store)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(try store.messages().count, 1)
    }
    func testReceivedAtPreserved() throws {
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z"))
        try spool.enqueue(.init(title: "earlier"), receivedAt: date)
        _ = try spool.drain(into: store)
        XCTAssertEqual(try store.messages().first?.receivedAt, date)
    }
    func testMalformedFileMovesToRejected() throws {
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        try spool.enqueue(.init(title: "valid"))
        let bad = spool.directory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: bad)
        let result = try spool.drain(into: store)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(try Data(contentsOf: spool.directory.appendingPathComponent("rejected/broken.json")), Data("broken".utf8))
    }
    func testDrainsInBoundedPasses() throws {
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        for index in 0..<1200 { try spool.enqueue(.init(title: "queued \(index)")) }
        for remaining in [700, 200, 0] { XCTAssertEqual(try spool.drain(into: store, limit: 500).remaining, remaining) }
        XCTAssertEqual(try store.messages().count, 1200)
    }

    func testIsStoreBusy() {
        XCTAssertTrue(DatabaseError(resultCode: .SQLITE_BUSY).isStoreBusy)
        XCTAssertTrue(DatabaseError(resultCode: .SQLITE_LOCKED).isStoreBusy)
        XCTAssertTrue(HookFeedError.migrationLockTimeout(path: "temp").isStoreBusy)
        XCTAssertFalse(HookFeedError.invalidInput(field: "title", reason: "empty").isStoreBusy)
    }
}
