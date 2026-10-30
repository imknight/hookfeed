import AppKit
import Foundation
import XCTest
import HookFeedCore
import UserNotifications
@testable import HookFeedApp

final class NotificationActionsTests: XCTestCase {
    func testCategoriesOfferOnlyAvailableActions() throws {
        let directory = FileManager.default.temporaryDirectory
        for resume in [false, true] {
            for folder in [false, true] {
                let message = Message(id: "m", seq: 1, title: "t", source: resume ? "codex" : "cli",
                                      workdir: folder ? directory.path : "/does-not-exist-hookfeed", sessionID: "session")
                let category = try XCTUnwrap(NotificationActions.categories.first { $0.identifier == NotificationActions.category(for: message) })
                XCTAssertEqual(category.actions.map(\.identifier),
                               (resume ? [NotificationActions.copyResume] : []) + (folder ? [NotificationActions.openFolder] : []) + [NotificationActions.markRead])
            }
        }
    }

    @MainActor
    func testMarkReadActionTargetsThreadWithoutChangingSelection() throws {
        let store = try InboxStore(path: ":memory:")
        let receipt = try store.send(MessageDraft(title: "one", threadKey: "one"))
        _ = try store.send(MessageDraft(title: "two", threadKey: "two"))
        let model = InboxModel(store: store, observesChanges: false)
        model.handleNotificationAction(NotificationActions.markRead, threadID: "thread:one", messageID: receipt.id)
        XCTAssertFalse(try XCTUnwrap(model.threads.first { $0.id == "thread:one" }).isUnread)
        XCTAssertTrue(try XCTUnwrap(model.threads.first { $0.id == "thread:two" }).isUnread)
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testCopyActionsUseOriginAndNotificationMessageID() throws {
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(saved)
        }
        Clipboard.copy("hookfeed-test-sentinel")
        let store = try InboxStore(path: ":memory:")
        let receipt = try store.send(.init(title: "resume", source: "codex", sessionID: "session-one", threadKey: "one"))
        _ = try store.send(.init(title: "other", source: "codex", sessionID: "session-two", threadKey: "two"))
        let model = InboxModel(store: store, observesChanges: false)
        let body = RunRecord.body(status: 1, seconds: 0, command: "'make' 'test'", stderr: "failed")
        model.copyCommand(Message(id: "spoof", seq: 1, title: "fake", body: body, source: "run"))
        XCTAssertEqual(clipboard.string(forType: .string), "hookfeed-test-sentinel")
        model.copyCommand(Message(id: "real", seq: 2, title: "run", body: body, source: "run", origin: RunRecord.origin))
        XCTAssertEqual(clipboard.string(forType: .string), "'make' 'test'")
        model.select("thread:two")
        model.handleNotificationAction(NotificationActions.copyResume, threadID: "thread:one", messageID: receipt.id)
        XCTAssertEqual(clipboard.string(forType: .string), "codex resume 'session-one'")
        XCTAssertEqual(model.selection, "thread:two")
        XCTAssertTrue(try XCTUnwrap(model.threads.first { $0.id == "thread:one" }).isUnread)
    }

}
