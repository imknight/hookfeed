import Foundation
import XCTest
@testable import HookFeedCore

final class MCPCommandTests: XCTestCase {
    func testIsListed() throws {
        let command = MCPCommand(executable: "test-agent", add: { ["add", $0] }, remove: ["remove"], list: ["list"], test: ["test"], afterInstall: "")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for name in ["hermes-mcp-list-empty", "hermes-mcp-list-hookfeed"] {
            XCTAssertFalse(command.isListed(try String(contentsOf: fixtures.appendingPathComponent(name + ".txt"))))
        }
        XCTAssertTrue(command.isListed("  hookfeed (stdio)\n    command: /Applications/HookFeed.app/Contents/Helpers/hookfeed"))
        XCTAssertFalse(command.isListed("  hookfeed-old (stdio)"))
        XCTAssertNil(Integration.named("hermes")!.mcpCommand)
    }
}
