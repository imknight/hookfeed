import XCTest
@testable import HookFeedApp

final class SingleInstanceTests: XCTestCase {
    func testIgnoresOwnProcessAndChoosesExistingInstance() {
        XCTAssertNil(SingleInstance.existingPID(in: [42], current: 42))
        XCTAssertNil(SingleInstance.existingPID(in: [], current: 42))
        XCTAssertEqual(SingleInstance.existingPID(in: [42, 17], current: 42), 17)
        XCTAssertEqual(SingleInstance.existingPID(in: [17, 42], current: 42), 17)
    }
}
