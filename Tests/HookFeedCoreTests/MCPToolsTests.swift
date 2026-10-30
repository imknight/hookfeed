import Foundation
import XCTest
@testable import HookFeedCore

final class MCPToolsTests: XCTestCase {
    func testDefaultBotIsExplicitAndNeverReadFromEnvironment() throws {
        let previous = ProcessInfo.processInfo.environment["HOOKFEED_BOT"]
        setenv("HOOKFEED_BOT", "InheritedBot", 1)
        defer {
            if let previous { setenv("HOOKFEED_BOT", previous, 1) }
            else { unsetenv("HOOKFEED_BOT") }
        }
        let store = try InboxStore(path: ":memory:")
        _ = try MCPTools.call("send_message", arguments: ["title": "No bot"], store: { store })
        XCTAssertNil(try store.messages().first?.bot)
        _ = try MCPTools.call("send_message", arguments: ["title": "Default"], defaultBot: "DefaultBot", store: { store })
        XCTAssertEqual(try store.messages().first?.bot, "DefaultBot")
        _ = try MCPTools.call("send_message", arguments: ["title": "Explicit", "bot": "ExplicitBot"], defaultBot: "DefaultBot", store: { store })
        XCTAssertEqual(try store.messages().first?.bot, "ExplicitBot")
        _ = try MCPTools.call("send_message", arguments: ["title": "Blank", "bot": "  "], defaultBot: "DefaultBot", store: { store })
        XCTAssertNil(try store.messages().first?.bot)
    }

    func testReadRequiresOptInBeforeOpeningStore() throws {
        let denied = try MCPTools.call("list_messages", arguments: [:], store: {
            XCTFail("Denied reads must not open the inbox")
            return try InboxStore(path: ":memory:")
        })
        XCTAssertEqual(denied.isError, true)
        XCTAssertEqual(MCPTools.definitions().map(\.name), ["send_message"])
        XCTAssertEqual(MCPTools.definitions(readAll: true).map(\.name), ["send_message", "list_messages"])
    }
}
