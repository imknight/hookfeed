import Foundation
import GRDB
import XCTest
import HookFeedCore
@testable import HookFeedApp

final class InboxModelTests: XCTestCase {
    @MainActor
    func testBlockedDrainDoesNotBlockMainActorReads() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        try Spool(storePath: store.path).enqueue(.init(title: "queued"))
        let model = InboxModel(store: store, observesChanges: false)
        model.refreshCoalesceInterval = 0.01
        let writer = try DatabaseQueue(path: store.path)
        let locked = expectation(description: "External writer holds lock")
        let released = expectation(description: "External writer released")
        DispatchQueue.global().async {
            defer { released.fulfill() }
            do {
                try writer.writeWithoutTransaction { db in
                    try db.execute(sql: "BEGIN IMMEDIATE")
                    defer { try? db.execute(sql: "ROLLBACK") }
                    locked.fulfill()
                    Thread.sleep(forTimeInterval: 0.6)
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        await fulfillment(of: [locked], timeout: 2)
        let draining = expectation(description: "Drain starts")
        let drain = model.drainSpool
        model.drainSpool = { store in draining.fulfill(); return try drain(store) }
        model.scheduleRefresh()
        await fulfillment(of: [draining], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        model.refresh(skipNotifications: true, force: true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        await fulfillment(of: [released], timeout: 2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.messages.count, 1)
    }

    @MainActor
    func testBurstOfSignalsCoalescesToOneRefresh() async throws {
        let model = InboxModel(store: try InboxStore(path: ":memory:"), observesChanges: false)
        model.refreshCoalesceInterval = 0.05
        let before = model.refreshCount
        for _ in 0..<50 { model.scheduleRefresh() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.refreshCount, before + 1)
    }

    @MainActor
    func testIncrementalRefreshMatchesFullReload() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("inbox.sqlite").path
        let store = try InboxStore(path: path)
        let model = InboxModel(store: store, observesChanges: false)
        let writer = try InboxStore(path: path)
        for index in 0..<30 { _ = try writer.send(.init(title: "row \(index)", threadKey: "thread-\(index % 5)")) }
        model.refresh(skipNotifications: true)
        XCTAssertEqual(model.messages, try store.messages())
        XCTAssertEqual(model.threads.map(\.messages), MessageThread.group(try store.messages()).map(\.messages))
    }

    @MainActor
    func testExternalInsertDoesNotFullReload() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("inbox.sqlite").path
        let store = try InboxStore(path: path)
        _ = try store.send(.init(title: "existing"))
        let model = InboxModel(store: store, observesChanges: false)
        var fullReads = 0
        model.onFullRead = { fullReads += 1 }
        _ = try InboxStore(path: path).send(.init(title: "new"))
        model.refresh(skipNotifications: true)
        XCTAssertEqual(fullReads, 0)
        XCTAssertEqual(model.messages.map(\.title), ["new", "existing"])
        model.refresh(skipNotifications: true, force: true)
        XCTAssertEqual(fullReads, 1)
    }

    @MainActor
    func testDrainRunsOffMainActor() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try InboxStore(path: home.appendingPathComponent("inbox.sqlite").path)
        for index in 0..<3 { try Spool(storePath: store.path).enqueue(.init(title: "queued \(index)")) }
        let model = InboxModel(store: store, observesChanges: false)
        model.refreshCoalesceInterval = 0.01
        model.drainSpool = { store in
            XCTAssertFalse(Thread.isMainThread)
            return try Spool(storePath: store.path).drain(into: store)
        }
        model.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.messages.count, 3)
    }

    func testResumeCommandsUseExplicitSessionIDsAndShellQuoting() {
        let session = "session 'with spaces' $(touch /tmp/not-run)"
        let codex = Message(id: "c", seq: 1, title: "Done", source: "codex", workdir: "/tmp/Other 'folder'", sessionID: session)
        let claude = Message(id: "a", seq: 2, title: "Done", source: "claude-code", sessionID: session)
        XCTAssertEqual(codex.resumeCommand, "codex resume 'session '\\''with spaces'\\'' $(touch /tmp/not-run)'")
        XCTAssertEqual(claude.resumeCommand, "claude --resume 'session '\\''with spaces'\\'' $(touch /tmp/not-run)'")
        for source in ["codex", "claude-code"] {
            XCTAssertNil(Message(id: "x", seq: 1, title: "Done", source: source).resumeCommand)
            XCTAssertNil(Message(id: "x", seq: 1, title: "Done", source: source, sessionID: "").resumeCommand)
        }
        XCTAssertNil(Message(id: "x", seq: 1, title: "Done", source: "mcp", sessionID: session).resumeCommand)
    }

    @MainActor
    func testMarkAllReadOnlyChangesThreadsVisibleInEveryScopeAndSearch() throws {
        for scope: ThreadScope in [.all, .attention, .unread, .project("One"), .source("codex"), .bot("Charname")] {
            for query in ["", "Match"] {
                let store = try InboxStore(path: ":memory:")
                _ = try store.send(MessageDraft(title: "Match approval", source: "claude-code", project: "One", bot: "Charname", kind: .needsAttention, threadKey: "a"))
                _ = try store.send(MessageDraft(title: "Other failure", source: "codex", project: "Two", kind: .failed, threadKey: "b"))
                _ = try store.send(MessageDraft(title: "Match finished", source: "run", project: "One", kind: .completed, threadKey: "c"))
                let model = InboxModel(store: store, observesChanges: false)
                model.filter = scope
                model.query = query
                let visible = Set(model.filteredThreads.map(\.id))
                model.markAllRead()
                for thread in model.threads {
                    XCTAssertEqual(thread.isUnread, !visible.contains(thread.id), "\(scope), search \(query), thread \(thread.id)")
                }
            }
        }
    }

    @MainActor
    func testBotsAreDistinctSortedAndMetadataSkipsMissingFields() throws {
        let store = try InboxStore(path: ":memory:")
        let model = InboxModel(store: store, observesChanges: false)
        XCTAssertEqual(model.bots, [])
        for bot in ["Bot10", "Charname", "Bot2", "Charname"] {
            _ = try store.send(.init(title: "Done", source: "grokbot", project: "A", bot: bot))
        }
        _ = try store.send(.init(title: "No bot"))
        model.refresh(skipNotifications: true, force: true)
        XCTAssertEqual(model.bots, ["Bot2", "Bot10", "Charname"])
        XCTAssertEqual(ThreadScope.bot("Charname").title, "Charname")
        XCTAssertEqual(model.messages.first { $0.bot == "Charname" }?.context, "Charname · grokbot · A")
        XCTAssertEqual(Message(id: "x", seq: 1, title: "t", source: "cli").context, "cli")
        XCTAssertEqual(Message(id: "x", seq: 1, title: "t", source: "cli", project: "A").context, "cli · A")
    }

    @MainActor
    func testChoosingSameFilterOrQueryKeepsPinnedSelection() throws {
        let store = try InboxStore(path: ":memory:")
        _ = try store.send(MessageDraft(title: "one", kind: .failed, threadKey: "one"))
        let model = InboxModel(store: store, observesChanges: false)
        model.filter = .attention
        model.select("thread:one")
        model.filter = .attention
        XCTAssertEqual(model.selection, "thread:one")
        model.query = ""
        XCTAssertEqual(model.selection, "thread:one")
        XCTAssertEqual(model.filteredThreads.map(\.id), ["thread:one"])
        model.query = "unrelated"
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testDeletingPinnedThreadOrLastUpdateDoesNotPinReusedThreadKey() throws {
        for deleteUpdate in [false, true] {
            let store = try InboxStore(path: ":memory:")
            let receipt = try store.send(MessageDraft(title: "one", threadKey: "one"))
            let model = InboxModel(store: store, observesChanges: false)
            model.filter = .unread
            model.select("thread:one")
            if deleteUpdate { model.deleteMessage(receipt.id) }
            else { model.deleteThread("thread:one") }
            XCTAssertNil(model.selection)
            _ = try store.send(MessageDraft(title: "replacement", threadKey: "one"))
            try store.markThreadRead("thread:one")
            model.refresh(skipNotifications: true, force: true)
            XCTAssertTrue(model.filteredThreads.isEmpty)
        }
    }

    @MainActor
    func testContextDeleteDoesNotSelectOrReadAnotherThread() throws {
        let store = try InboxStore(path: ":memory:")
        _ = try store.send(MessageDraft(title: "one", threadKey: "one"))
        _ = try store.send(MessageDraft(title: "two", threadKey: "two"))
        _ = try store.send(MessageDraft(title: "two again", threadKey: "two"))
        let model = InboxModel(store: store, observesChanges: false)
        model.filter = .unread
        model.select("thread:one")
        model.requestDelete("thread:two")
        XCTAssertEqual(model.pendingDelete, "thread:two")
        XCTAssertEqual(model.selection, "thread:one")
        XCTAssertTrue(try XCTUnwrap(model.threads.first { $0.id == "thread:two" }).isUnread)
        model.deleteThread("thread:two")
        XCTAssertEqual(model.selection, "thread:one")
        XCTAssertEqual(model.filteredThreads.map(\.id), ["thread:one"])
    }
}
