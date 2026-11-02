import AppKit
import HookFeedCore
import SwiftUI
import XCTest
@testable import HookFeedApp

final class ThreadRowTests: XCTestCase {
    @MainActor
    func testRowHeightStaysFixedWhenExistingThreadMovesToTop() throws {
        let store = try InboxStore(path: ":memory:")
        _ = try store.send(.init(title: "First", threadKey: "first"))
        _ = try store.send(.init(title: "Second", threadKey: "second"))
        let model = InboxModel(store: store, observesChanges: false)
        model.select("thread:first")
        let before = try XCTUnwrap(model.threads.last)
        let row = NSHostingView(rootView: ThreadRow(thread: before).frame(width: 360))
        XCTAssertEqual(row.fittingSize.height, 64)
        _ = try store.send(.init(title: String(repeating: "Long title ", count: 15), source: "grokbot", bot: "A bot", threadKey: "first"))
        model.refresh(skipNotifications: true)
        let after = try XCTUnwrap(model.threads.first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.updateCount, 2)
        XCTAssertNotEqual(after.latest.id, before.latest.id)
        XCTAssertEqual(model.selection, "thread:first")
        row.rootView = ThreadRow(thread: after).frame(width: 360)
        XCTAssertEqual(row.fittingSize.height, 64)
    }
}
