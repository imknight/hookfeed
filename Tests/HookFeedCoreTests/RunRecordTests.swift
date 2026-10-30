import Foundation
import XCTest
@testable import HookFeedCore

final class RunRecordTests: XCTestCase {
    func testFormattingPreservesMultilineCommandAndStderrVerbatim() {
        let command = "'printf' 'a\nCommand: not a field\nb'"
        let stderr = "**error**\nCommand: also not a field\n~~~"
        let body = RunRecord.body(status: 3, seconds: 1.25, command: command, stderr: stderr)
        let message = Message(id: "r", seq: 1, title: "failed", body: body, source: "run", origin: RunRecord.origin)
        XCTAssertEqual(message.recordedCommand, command)
        XCTAssertFalse(message.isCommandTruncated)
        XCTAssertTrue(message.canCopyCommand)
        XCTAssertTrue(body.contains("Exit code: 3\nDuration: 1.250 s"))
        XCTAssertTrue(body.contains(stderr))
        XCTAssertEqual(message.bodyBlocks, [.code(body)])
    }

    func testSourceLabelAloneCannotEnableCopyAndLegacyParsingSurvives() {
        let body = "Exit code: 1\nDuration: 0.010 s\nCommand: '/usr/bin/false'"
        let legacy = Message(id: "old", seq: 1, title: "failed", body: body, source: "run")
        XCTAssertEqual(legacy.recordedCommand, "'/usr/bin/false'")
        XCTAssertFalse(legacy.canCopyCommand)
        let spoof = Message(id: "s", seq: 2, title: "spoof", body: "Command: 'false'", source: "run")
        XCTAssertFalse(spoof.canCopyCommand)
    }

    func testLongCommandHasTruncationHintAndValidBoundedUTF8() {
        let body = RunRecord.body(status: 1, seconds: 0, command: String(repeating: "🐱", count: 20_000), stderr: String(repeating: "e", count: 8192))
        let message = Message(id: "r", seq: 1, title: "failed", body: body, source: "run", origin: RunRecord.origin)
        XCTAssertLessThanOrEqual(body.utf8.count, 32 * 1024)
        XCTAssertTrue(message.isCommandTruncated)
        XCTAssertTrue(body.contains("Command truncated: yes"))
        XCTAssertFalse(message.recordedCommand?.contains("�") ?? true)
        XCTAssertNotNil(message.recordedCommand)
    }

    func testOriginAndCommandSurviveStoreNormalizationAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("inbox.sqlite").path
        let command = "'echo' 'Cafe\u{301}'"
        let body = RunRecord.body(status: 1, seconds: 0, command: command, stderr: "Cafe\u{301}")
        _ = try InboxStore(path: path).send(MessageDraft(title: "failed", body: body, source: "run", origin: RunRecord.origin))
        let stored = try XCTUnwrap(InboxStore(path: path).messages().first)
        XCTAssertTrue(stored.canCopyCommand)
        XCTAssertEqual(stored.recordedCommand, command.precomposedStringWithCanonicalMapping)
    }

    func testTailKeepsLastTwentyLinesAndAtMostEightKiB() {
        var tail = RunOutputTail()
        for n in 1...30 { tail.append(Data("line \(n)\n".utf8)) }
        XCTAssertEqual(tail.text, (11...30).map { "line \($0)" }.joined(separator: "\n"))
        tail.append(Data(String(repeating: "🐱", count: 5000).utf8))
        XCTAssertLessThanOrEqual(tail.text.utf8.count, 8192)
        XCTAssertFalse(tail.text.contains("�"))
        XCTAssertTrue(tail.text.hasSuffix("🐱"))
    }
}
