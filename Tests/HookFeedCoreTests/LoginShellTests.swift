import XCTest
@testable import HookFeedCore

final class LoginShellTests: XCTestCase {
    func testIgnoresStartupBannersAndPreservesPathContents() throws {
        let output = "Welcome to this Mac\nLast login: today\n__HOOKFEED_PATH_BEGIN__\n/opt/homebrew/bin:/Users/Test User/bin:/usr/bin\n__HOOKFEED_PATH_END__\nGoodbye\n"
        XCTAssertEqual(try LoginShell.parsePath(output), "/opt/homebrew/bin:/Users/Test User/bin:/usr/bin")
        XCTAssertEqual(try LoginShell.parsePath("__HOOKFEED_PATH_BEGIN__\n\n__HOOKFEED_PATH_END__\n"), "")
    }

    func testRequiresCompleteMarkers() {
        for output in ["/usr/bin", "__HOOKFEED_PATH_BEGIN__\n/usr/bin", "__HOOKFEED_PATH_END__\n"] {
            XCTAssertThrowsError(try LoginShell.parsePath(output))
        }
    }
}
