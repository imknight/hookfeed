import XCTest
@testable import HookFeedCore

final class StorageFailureTests: XCTestCase {
    func testSummaryExplainsKnownSQLiteFailures() {
        XCTAssertEqual(StorageFailure.summary(for: "SQLite error 26: file is not a database - while executing `SELECT * FROM sqlite_master LIMIT 1`"),
                       "The inbox file isn't a readable HookFeed database.")
        XCTAssertEqual(StorageFailure.summary(for: "SQLite error 23: authorization denied"),
                       "HookFeed doesn't have permission to open the inbox file.")
        XCTAssertEqual(StorageFailure.summary(for: "SQLite error 5: Database is locked"),
                       "The inbox file is locked by another process.")
    }

    func testSummaryFallsBackForUnknownErrors() {
        XCTAssertEqual(StorageFailure.summary(for: "Something odd happened"), "HookFeed couldn't read the inbox file.")
        XCTAssertEqual(StorageFailure.summary(for: "SQLite error 50: unrelated"), "HookFeed couldn't read the inbox file.")
    }
}
