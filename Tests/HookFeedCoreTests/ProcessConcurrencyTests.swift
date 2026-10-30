import Foundation
import GRDB
import XCTest
@testable import HookFeedCore

final class ProcessConcurrencyTests: XCTestCase {
    func testWALProcessWriter() throws {
        guard let path = ProcessInfo.processInfo.environment["HOOKFEED_TEST_WAL_PATH"] else { return }
        _ = try InboxStore(path: path, busyTimeout: 0.25).send(.init(title: "while reading"))
    }

    func testReaderDoesNotBlockWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("inbox.sqlite").path
        let store = try InboxStore(path: path)
        let raw = try DatabaseQueue(path: path)
        try raw.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN")
            defer { try? db.execute(sql: "ROLLBACK") }
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "HookFeedCoreTests.ProcessConcurrencyTests/testWALProcessWriter", Bundle(for: Self.self).bundlePath]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOOKFEED_TEST_WAL_PATH": path, "HOOKFEED_STORE_PATH": path,
                                                                              "HOOKFEED_LOG_PATH": directory.appendingPathComponent("hook.log").path]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try store.messages().map(\.title), ["while reading"])
    }

    /// Invoked in a fresh XCTest process by the parent test below.
    func testProcessWriter() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HOOKFEED_TEST_WRITER_PATH"],
              let index = environment["HOOKFEED_TEST_WRITER_INDEX"].flatMap(Int.init) else { return }
        let store = try InboxStore(path: path)
        let unique = try store.send(.init(title: "writer \(index)", idempotencyKey: "unique-\(index)"))
        XCTAssertFalse(unique.duplicate)
        _ = try store.send(.init(title: "shared retry", idempotencyKey: "shared"))
        do {
            _ = try store.send(.init(title: "variant \(index % 2)", idempotencyKey: "conflict"))
        } catch HookFeedError.idempotencyConflict {
            // Exactly one content variant wins the atomic race.
        }
    }

    func testFiftyFreshProcessesMigrateAndWriteWithAtomicDedupe() throws {
        guard ProcessInfo.processInfo.environment["HOOKFEED_TEST_WRITER_PATH"] == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hookfeed-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fresh/inbox.sqlite").path
        let bundle = Bundle(for: ProcessConcurrencyTests.self).bundlePath
        var children: [(Process, URL, FileHandle)] = []
        defer {
            for (process, _, handle) in children {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                try? handle.close()
            }
        }
        for index in 0..<50 {
            let log = directory.appendingPathComponent("writer-\(index).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "HookFeedCoreTests.ProcessConcurrencyTests/testProcessWriter", bundle]
            var environment = ProcessInfo.processInfo.environment
            environment["HOOKFEED_TEST_WRITER_PATH"] = path
            environment["HOOKFEED_TEST_WRITER_INDEX"] = String(index)
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            children.append((process, log, output))
        }
        for (process, log, _) in children {
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                XCTFail("Writer failed: \(try String(contentsOf: log, encoding: .utf8))")
            }
        }
        let store = try InboxStore(path: path)
        let messages = try store.messages()
        XCTAssertEqual(messages.count, 52)
        XCTAssertEqual(Set(messages.map(\.id)).count, 52)
        XCTAssertEqual(Set(messages.map(\.seq)), Set(Int64(1)...Int64(52)))
        XCTAssertEqual(messages.filter { $0.idempotencyKey == "shared" }.count, 1)
        XCTAssertEqual(messages.filter { $0.idempotencyKey == "conflict" }.count, 1)
        XCTAssertEqual(messages.filter { $0.idempotencyKey?.hasPrefix("unique-") == true }.count, 50)
        XCTAssertEqual(try store.maxSequence(), 52)
    }
}
