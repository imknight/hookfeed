import XCTest
@testable import HookFeedCore
@testable import HookFeedApp

final class RemoteTokenSheetTests: XCTestCase {
    func testHermesProfileChangesCommandWithoutChangingYAML() throws {
        let plain = RemoteTokenSheetModel(url: "http://127.0.0.1:47321", token: "test-token")
        let profiled = RemoteTokenSheetModel(url: "http://127.0.0.1:47321", token: "test-token", hermesProfile: "helena")
        let original = try XCTUnwrap(plain.examples.first { $0.id == "hermes" })
        let updated = try XCTUnwrap(profiled.examples.first { $0.id == "hermes" })
        XCTAssertEqual(original.setupCommand, "hermes mcp add hookfeed --url 'http://127.0.0.1:47321/mcp' --auth header")
        XCTAssertEqual(updated.setupCommand, "hermes -p 'helena' mcp add hookfeed --url 'http://127.0.0.1:47321/mcp' --auth header")
        XCTAssertEqual(original.text, updated.text)
        XCTAssertTrue(plain.examples.filter { $0.id != "hermes" }.allSatisfy { $0.setupCommand == nil })
    }

    func testEveryRegisteredRemoteSnippetAppearsWithConnectionValues() {
        let url = "https://mac.tailnet.ts.net"
        let token = "test-token"
        let model = RemoteTokenSheetModel(url: url, token: token)
        let registered = Integration.all.filter { $0.remoteSnippet != nil }
        XCTAssertEqual(model.examples.dropFirst(3).dropLast().map(\.id), registered.map(\.id))
        for integration in registered {
            let example = model.examples.first { $0.id == integration.id }
            XCTAssertEqual(example?.text, integration.remoteSnippet?.text(url, token))
            XCTAssertEqual(example?.note, integration.remoteSnippet?.note)
            XCTAssertEqual(example?.title, "\(integration.name) (MCP)")
            XCTAssertEqual(example?.collapsible, true)
        }
    }

    func testTokenAndCommandLineCannotBeCollapsed() {
        let model = RemoteTokenSheetModel(url: "http://localhost:8787", token: "test-token")
        XCTAssertEqual(model.examples.filter { !$0.collapsible }.map(\.id), ["token", "command-line"])
        XCTAssertEqual(model.examples.first?.text, "test-token")
        XCTAssertTrue(model.examples[1].text.contains("HOOKFEED_TOKEN='test-token'"))
        XCTAssertTrue(model.examples[1].text.contains("HOOKFEED_URL='http://localhost:8787'"))
    }

    func testNewRegistryEntryNeedsNoSheetChange() {
        var integration = Integration.all[0]
        integration.remoteSnippet = .init(note: "Future client setup", text: { "\($0) \($1)" })
        let model = RemoteTokenSheetModel(url: "test-url", token: "test-token", integrations: [integration])
        XCTAssertEqual(model.examples[3].text, "test-url test-token")
        XCTAssertEqual(model.examples[3].note, "Future client setup")
        integration.remoteSnippet = nil
        XCTAssertEqual(RemoteTokenSheetModel(url: "", token: "", integrations: [integration]).examples.map(\.id),
                       ["token", "command-line", "http-api", "other-mcp"])
    }
}
