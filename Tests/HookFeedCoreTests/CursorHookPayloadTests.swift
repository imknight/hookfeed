import Foundation
import XCTest
@testable import HookFeedCore

final class CursorHookPayloadTests: XCTestCase {
    func testDocumentedStopFixtures() throws {
        for (status, title, kind) in [("completed", "Cursor turn finished", MessageKind.completed),
                                      ("error", "Cursor turn failed", .failed), ("aborted", "Cursor turn aborted", .info)] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "cursor-stop-" + status, withExtension: "json", subdirectory: "Fixtures"))
            let draft = try CursorHookPayload.draft(data: Data(contentsOf: url))
            XCTAssertEqual(draft.title, title)
            XCTAssertEqual(draft.body, "Cursor agent stopped with status: \(status).")
            XCTAssertEqual(draft.kind, kind)
            XCTAssertNotEqual(draft.kind, .needsAttention)
            XCTAssertEqual(draft.threadKey, "cursor:cursor-conversation-1")
            XCTAssertEqual(draft.sessionID, "cursor-conversation-1")
            XCTAssertEqual(draft.workdir, "/Users/example/Projects/demo")
            XCTAssertEqual(draft.project, "demo")
            XCTAssertEqual(draft.source, "cursor")
            let overridden = try CursorHookPayload.draft(data: Data(contentsOf: url), project: "Override", bot: "Cursor")
            XCTAssertEqual(overridden.project, "Override")
            XCTAssertEqual(overridden.bot, "Cursor")
        }
    }

    func testRejectsMalformedAndNonStopEvents() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cursor-stop-completed", withExtension: "json", subdirectory: "Fixtures"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (key, value): (String, Any) in [("hook_event_name", "beforeShellExecution"), ("status", "unknown"),
                                           ("conversation_id", ""), ("workspace_roots", []), ("workspace_roots", ["relative"])] {
            var payload = original
            payload[key] = value
            XCTAssertThrowsError(try CursorHookPayload.draft(data: JSONSerialization.data(withJSONObject: payload)))
        }
        XCTAssertThrowsError(try CursorHookPayload.draft(data: Data("{".utf8)))
        XCTAssertThrowsError(try CursorHookPayload.draft(data: Data(repeating: 32, count: 1024 * 1024 + 1)))
    }
}
