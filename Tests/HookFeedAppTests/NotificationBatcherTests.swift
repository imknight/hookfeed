import Foundation
import XCTest
import HookFeedCore
@testable import HookFeedApp

final class NotificationBatcherTests: XCTestCase {
    func message(_ seq: Int64, thread: String? = nil) -> Message {
        Message(id: String(seq), seq: seq, title: "Update", threadKey: thread, receivedAt: Date(timeIntervalSince1970: 0))
    }
    func testSeparateAddsFlushTogether() {
        var batcher = NotificationBatcher()
        let now = Date()
        for seq in 1...3 { _ = batcher.add([message(Int64(seq))], now: now.addingTimeInterval(Double(seq) / 10)) }
        XCTAssertEqual(batcher.flush(), .perThread([message(3), message(2), message(1)]))
    }
    func testMoreThanFiveUpdatesProduceSummary() {
        var batcher = NotificationBatcher()
        _ = batcher.add((1...8).map { message(Int64($0)) }, now: Date())
        XCTAssertEqual(batcher.flush(), .summary(count: 8))
    }
    func testLatestUpdateWinsWithinThread() {
        var batcher = NotificationBatcher()
        _ = batcher.add([message(4, thread: "same"), message(1, thread: "same"), message(3, thread: "same"), message(2, thread: "same")], now: Date())
        XCTAssertEqual(batcher.flush(), .perThread([message(4, thread: "same")]))
    }
    func testDeadlineOnlyOnWindowOpen() {
        var batcher = NotificationBatcher()
        let now = Date()
        XCTAssertEqual(batcher.add([message(1)], now: now), now.addingTimeInterval(1))
        XCTAssertNil(batcher.add([message(2)], now: now.addingTimeInterval(0.5)))
        _ = batcher.flush()
        XCTAssertEqual(batcher.add([message(3)], now: now.addingTimeInterval(2)), now.addingTimeInterval(3))
    }
    func testEmptyFlushDoesNothing() {
        var batcher = NotificationBatcher()
        XCTAssertNil(batcher.flush())
        XCTAssertNil(batcher.add([], now: Date()))
        XCTAssertNil(batcher.flush())
    }
}
