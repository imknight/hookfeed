import Foundation
import XCTest
@testable import HookFeedCore
@testable import HookFeedCLI

final class GeminiHookPayloadTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    func testCapturedCompletionAndPermissionShareThread() throws {
        let completion = try XCTUnwrap(HookPayload.draft(data: fixture("gemini-after-agent-captured"), agent: .geminiCLI, project: nil, bot: nil))
        XCTAssertEqual(completion.title, "HookFeed Gemini completion acceptance passed.")
        XCTAssertEqual(completion.body, completion.title)
        XCTAssertEqual(completion.kind, .completed)
        XCTAssertEqual(completion.source, "gemini-cli")
        XCTAssertEqual(completion.project, "hookfeed")
        XCTAssertEqual(completion.workdir, "/Users/example/Projects/hookfeed")
        XCTAssertEqual(completion.threadKey, "gemini-cli:gemini-session-captured")
        let permission = try XCTUnwrap(HookPayload.draft(data: fixture("gemini-permission-captured"), agent: .geminiCLI, project: "override", bot: "Gemini"))
        XCTAssertEqual(permission.title, "Tool Confirm Shell Command requires execution")
        XCTAssertEqual(permission.body, permission.title)
        XCTAssertEqual(permission.kind, .needsAttention)
        XCTAssertEqual(permission.threadKey, completion.threadKey)
        XCTAssertEqual(permission.sessionID, completion.sessionID)
        XCTAssertEqual(permission.project, "override")
        XCTAssertEqual(permission.bot, "Gemini")
    }

    func testUnknownNotificationsAreIgnoredAndMalformedEventsRejected() throws {
        var object = try HookConfiguration.parse(fixture("gemini-permission-captured"))
        object["notification_type"] = "Other"
        XCTAssertNil(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil))
        object["hook_event_name"] = "Stop"
        XCTAssertThrowsError(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil))
        object = try HookConfiguration.parse(fixture("gemini-after-agent-captured"))
        object["prompt_response"] = 42
        XCTAssertThrowsError(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil))
        object["session_id"] = ""
        XCTAssertThrowsError(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil))
    }

    func testEmptyResponseAndPermissionFallbackTitles() throws {
        var object = try HookConfiguration.parse(fixture("gemini-after-agent-captured"))
        object["prompt_response"] = ""
        XCTAssertEqual(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil)?.title, "Turn finished")
        object = try HookConfiguration.parse(fixture("gemini-permission-captured"))
        object["message"] = "  "
        XCTAssertEqual(try HookPayload.draft(data: JSONSerialization.data(withJSONObject: object), agent: .geminiCLI, project: nil, bot: nil)?.title, "Gemini CLI needs your permission")
    }

    func testCapturedPayloadsReachInboxThroughCLIWithoutStdout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("inbox.sqlite").path
        for name in ["gemini-permission-captured", "gemini-after-agent-captured"] {
            let process = Process()
            process.executableURL = root.appendingPathComponent(".build/debug/hookfeed")
            process.arguments = ["hook", "gemini-cli"]
            var environment = ProcessInfo.processInfo.environment
            environment["HOOKFEED_STORE_PATH"] = database
            environment["HOOKFEED_LOG_PATH"] = directory.appendingPathComponent("hook.log").path
            environment.removeValue(forKey: "HOOKFEED_URL")
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = error
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: fixture(name))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        let messages = try InboxStore(path: database).messages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages.map(\.kind)), [.completed, .needsAttention])
        XCTAssertEqual(Set(messages.compactMap(\.threadKey)), ["gemini-cli:gemini-session-captured"])
    }
}
