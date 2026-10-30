import Foundation
import XCTest
@testable import HookFeedCore

final class AntigravityHookPayloadTests: XCTestCase {
    func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/antigravity-stop-captured.json"))
    }
    func testCapturedCompletion() throws {
        let draft = try XCTUnwrap(AntigravityHookPayload.draft(data: fixture()))
        XCTAssertEqual(draft.title, "Antigravity run finished")
        XCTAssertEqual(draft.body, "Antigravity finished its run.")
        XCTAssertEqual(draft.kind, .completed)
        XCTAssertEqual(draft.source, "antigravity")
        XCTAssertEqual(draft.project, "hookfeed")
        XCTAssertEqual(draft.workdir, "/workspace/hookfeed")
        XCTAssertEqual(draft.sessionID, "antigravity-captured-session")
        XCTAssertEqual(draft.threadKey, "antigravity:antigravity-captured-session")
    }
    func testBackgroundWorkErrorsAndMalformedPayloads() throws {
        var payload = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        payload["fullyIdle"] = false
        XCTAssertNil(try AntigravityHookPayload.draft(data: JSONSerialization.data(withJSONObject: payload)))
        payload["fullyIdle"] = true
        payload["error"] = "Request failed"
        payload["terminationReason"] = "error"
        let failed = try XCTUnwrap(AntigravityHookPayload.draft(data: JSONSerialization.data(withJSONObject: payload), project: "override", bot: "Antigravity"))
        XCTAssertEqual(failed.title, "Antigravity run failed")
        XCTAssertEqual(failed.body, "Request failed")
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertEqual(failed.project, "override")
        XCTAssertEqual(failed.bot, "Antigravity")
        payload["error"] = ""
        payload["terminationReason"] = "max_steps_exceeded"
        XCTAssertEqual(try AntigravityHookPayload.draft(data: JSONSerialization.data(withJSONObject: payload))?.kind, .failed)
        payload["workspacePaths"] = ["relative"]
        XCTAssertThrowsError(try AntigravityHookPayload.draft(data: JSONSerialization.data(withJSONObject: payload)))
        for invalid in ["{}", "[]", "null", "{"] {
            XCTAssertThrowsError(try AntigravityHookPayload.draft(data: Data(invalid.utf8)))
        }
    }
}
