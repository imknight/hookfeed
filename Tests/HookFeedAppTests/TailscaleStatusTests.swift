@testable import HookFeedCore
import XCTest
@testable import HookFeedApp

final class TailscaleStatusTests: XCTestCase {
    func testFinderSearchIncludesLoginPathAndHomebrewBeforeApp() {
        XCTAssertEqual(TailscaleStatus.cliPaths(loginPath: "/custom/bin", environmentPath: "/usr/bin:/bin"), [
            "/custom/bin/tailscale", "/usr/bin/tailscale", "/bin/tailscale",
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ])
    }

    func testServeArguments() {
        XCTAssertEqual(TailscaleStatus.serveArguments(port: 47321, reset: false),
                       ["serve", "--bg", "--https=443", "http://127.0.0.1:47321"])
        XCTAssertEqual(TailscaleStatus.serveArguments(port: 47321, reset: true), ["serve", "reset"])
    }
}
