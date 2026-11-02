import XCTest
@testable import HookFeedApp

final class BackgroundHealthTests: XCTestCase {
    func testStartupGraceAndConsecutiveFailures() {
        let now = Date(timeIntervalSince1970: 100)
        var health = BackgroundHealth()
        health.reset(now: now)
        for offset in [1.0, 3, 5, 7] { XCTAssertFalse(health.record(success: false, now: now.addingTimeInterval(offset))) }
        XCTAssertFalse(health.record(success: false, now: now.addingTimeInterval(9)))
        XCTAssertFalse(health.record(success: false, now: now.addingTimeInterval(11)))
        XCTAssertTrue(health.record(success: false, now: now.addingTimeInterval(13)))
        XCTAssertFalse(health.record(success: true, now: now.addingTimeInterval(15)))
        XCTAssertFalse(health.record(success: false, now: now.addingTimeInterval(17)))
        health.reset(now: now.addingTimeInterval(18))
        XCTAssertFalse(health.record(success: false, now: now.addingTimeInterval(20)))
    }
}
