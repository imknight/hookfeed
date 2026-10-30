import Foundation
import XCTest
@testable import HookFeedCore

final class MessageTests: XCTestCase {
    func testMessageJSONUsesBotKey() throws {
        let message = Message(id: "id", seq: 1, title: "Done", bot: "Charname")
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["bot"] as? String, "Charname")
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: data), message)
        let oldData = try JSONEncoder().encode(Message(id: "old", seq: 2, title: "No bot"))
        XCTAssertNil(try JSONDecoder().decode(Message.self, from: oldData).bot)
    }

    func testMachineCodingUsesSnakeCaseAndRoundTrips() throws {
        let message = Message(
            id: "id", seq: 42, title: "Hello", body: "line 1\n\"line 2\" 🐱",
            source: "agent", project: "project", kind: .needsAttention,
            url: "https://example.com", workdir: "/tmp/project", sessionID: "session",
            threadKey: "thread", idempotencyKey: "retry", receivedAt: Date(timeIntervalSince1970: 100),
            readAt: Date(timeIntervalSince1970: 101)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "session")
        XCTAssertEqual(object["thread_key"] as? String, "thread")
        XCTAssertEqual(object["idempotency_key"] as? String, "retry")
        XCTAssertEqual(object["kind"] as? String, "needs_attention")
        XCTAssertNotNil(object["received_at"])
        XCTAssertNotNil(object["read_at"])
        XCTAssertNil(object["threadID"])
        XCTAssertNil(object["sessionID"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Message.self, from: data), message)
        let receipt = SendReceipt(id: "id", duplicate: true)
        let receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
        XCTAssertEqual(receiptObject["status"] as? String, "stored")
        XCTAssertEqual(receiptObject["duplicate"] as? Bool, true)
        XCTAssertThrowsError(try JSONDecoder().decode(MessageKind.self, from: Data("\"unknown\"".utf8)))
    }

    func testLengthBoundariesCountCharactersAndUTF8BodyBytes() throws {
        let valid = MessageDraft(
            title: String(repeating: "👩🏽‍💻", count: 200), body: String(repeating: "🐱", count: 8_192),
            source: String(repeating: "s", count: 80), project: String(repeating: "p", count: 80),
            workdir: "/" + String(repeating: "x", count: 1_023), sessionID: String(repeating: "s", count: 200),
            threadKey: String(repeating: "t", count: 200), idempotencyKey: String(repeating: "k", count: 200)
        )
        XCTAssertNoThrow(try valid.normalizedAndValidated())
        var invalid = valid
        invalid.title += "!"
        XCTAssertThrowsError(try invalid.normalizedAndValidated())
        invalid = valid
        invalid.body! += "a"
        XCTAssertThrowsError(try invalid.normalizedAndValidated())
        let prefix = "https://example.com/"
        var urlDraft = MessageDraft(title: "title", url: prefix + String(repeating: "x", count: 2_048 - prefix.count))
        XCTAssertNoThrow(try urlDraft.normalizedAndValidated())
        urlDraft.url! += "x"
        XCTAssertThrowsError(try urlDraft.normalizedAndValidated())
    }

    func testValidationRejectsBadMetadataAndUnsafeLinks() throws {
        let invalid: [MessageDraft] = [
            .init(title: " \n\t "), .init(title: "title", source: ""),
            .init(title: "title", source: " \n"),
            .init(title: "title", source: String(repeating: "s", count: 81)),
            .init(title: "title", project: String(repeating: "p", count: 81)),
            .init(title: "title", sessionID: String(repeating: "s", count: 201)),
            .init(title: "title", threadKey: String(repeating: "t", count: 201)),
            .init(title: "title", idempotencyKey: String(repeating: "k", count: 201)),
            .init(title: "title", workdir: "relative/path"),
            .init(title: "title", workdir: "~/Code"),
            .init(title: "title", workdir: "/tmp/\0suffix"),
            .init(title: "title", workdir: "/" + String(repeating: "x", count: 1_024)),
        ]
        for draft in invalid {
            XCTAssertThrowsError(try draft.normalizedAndValidated(), "\(draft)") { error in
                XCTAssertTrue(error is HookFeedError)
            }
        }
        for url in ["", "https://", "https:example.com", "example.com", "//example.com", "javascript:alert(1)",
                    "file:///tmp/a", "vscode://file/tmp/a", "https://exa mple.com", "https://example.com/\n", "https://example.com/%ZZ"] {
            XCTAssertThrowsError(try MessageDraft(title: "title", url: url).normalizedAndValidated(), url)
        }
        for url in ["https://example.com/path?q=hello%20there#top", "http://localhost:8080/", "HTTPS://example.com", "https://[::1]/"] {
            XCTAssertNoThrow(try MessageDraft(title: "title", url: url).normalizedAndValidated(), url)
        }
    }

    func testNormalizationPreservesBodyAndOnlyTrimsTitle() throws {
        let draft = try MessageDraft(title: " \n Cafe\u{301} \t", body: " Cafe\u{301}\n\n", source: "source ",
                                     project: " project ").normalizedAndValidated()
        XCTAssertEqual(Array(draft.title.utf8), Array("Café".utf8))
        XCTAssertEqual(Array(try XCTUnwrap(draft.body).utf8), Array(" Café\n\n".utf8))
        XCTAssertEqual(draft.source, "source ")
        XCTAssertEqual(draft.project, " project ")
    }

    func testThreadGroupingPreservesUnreadAttentionUntilRead() {
        let messages = [
            Message(id: "1", seq: 1, title: "Needs input", source: "one", kind: .needsAttention, threadKey: "session"),
            Message(id: "3", seq: 3, title: "Latest", source: "two", kind: .completed, threadKey: "session", readAt: Date()),
            Message(id: "2", seq: 2, title: "Failed", kind: .failed, threadKey: "session"),
            Message(id: "5", seq: 5, title: "Standalone", kind: .info),
            Message(id: "4", seq: 4, title: "Another", kind: .failed, readAt: Date()),
        ]
        let threads = MessageThread.group(messages)
        XCTAssertEqual(threads.map(\.id), ["message:5", "message:4", "thread:session"])
        let thread = threads[2]
        XCTAssertEqual(thread.messages.map(\.seq), [3, 2, 1])
        XCTAssertEqual(thread.latest.id, "3")
        XCTAssertEqual(thread.kind, .failed) // The newest unread attention message wins.
        XCTAssertTrue(thread.isAttention)
        XCTAssertTrue(thread.isUnread)
        XCTAssertEqual(thread.unreadCount, 2)
        XCTAssertEqual(thread.updateCount, 3)
        XCTAssertFalse(threads[1].isAttention)
        XCTAssertEqual(threads[1].kind, .failed)
        XCTAssertTrue(MessageThread.group([]).isEmpty)

        let readMessages = messages.map { message in
            Message(id: message.id, seq: message.seq, title: message.title, kind: message.kind,
                    threadKey: message.threadKey, readAt: Date())
        }
        let readThread = MessageThread.group(readMessages)[2]
        XCTAssertEqual(readThread.kind, .completed)
        XCTAssertFalse(readThread.isAttention)
        XCTAssertFalse(readThread.isUnread)
    }

    func testRecordedCommandParsesRunBodies() {
        let run = Message(id: "r", seq: 1, title: "false failed (exit 1)", body: "Exit code: 1\nDuration: 0.010 s\nCommand: '/usr/bin/false'", source: "run")
        XCTAssertEqual(run.recordedCommand, "'/usr/bin/false'")
        let multi = Message(id: "m", seq: 2, title: "t", body: "Exit code: 1\nCommand: 'printf' 'a\nb'", source: "run")
        XCTAssertEqual(multi.recordedCommand, "'printf' 'a\nb'")
        XCTAssertNil(Message(id: "n", seq: 3, title: "t", body: "Exit code: 1", source: "run").recordedCommand)
        XCTAssertNil(Message(id: "c", seq: 4, title: "t", body: "Command: x", source: "cli").recordedCommand)
    }
}
