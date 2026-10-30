import XCTest
@testable import HookFeedCore

final class ThreadQueryTests: XCTestCase {
    private func thread(_ id: String, kind: MessageKind, read: Bool, title: String = "t", seq: Int64 = 1) -> MessageThread {
        MessageThread.group([Message(id: id, seq: seq, title: title, kind: kind, threadKey: id, readAt: read ? Date() : nil)])[0]
    }

    func testBotScopeMatchesAnyMessageInThread() {
        let threads = MessageThread.group([
            Message(id: "old", seq: 1, title: "Older", bot: "Charname", threadKey: "shared"),
            Message(id: "new", seq: 2, title: "Latest", threadKey: "shared"),
            Message(id: "other", seq: 3, title: "Unlabelled"),
        ])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .bot("Charname"), search: "", pinned: nil).map(\.id), ["thread:shared"])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .bot("Other"), search: "", pinned: nil).map(\.id), [])
    }

    func testSearchMatchesBot() {
        let threads = MessageThread.group([
            Message(id: "old", seq: 1, title: "Older", bot: "Chárname", threadKey: "shared"),
            Message(id: "new", seq: 2, title: "Latest", threadKey: "shared"),
        ])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .all, search: "CHARN", pinned: nil).map(\.id), ["thread:shared"])
    }

    func testAttentionScopeHidesReadThreads() {
        let threads = [thread("a", kind: .failed, read: true), thread("b", kind: .failed, read: false, seq: 2)]
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .attention, search: "", pinned: nil).map(\.id), ["thread:b"])
    }

    func testPinnedThreadSurvivesNewReadState() {
        let threads = [thread("a", kind: .failed, read: true)]
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .attention, search: "", pinned: "thread:a").map(\.id), ["thread:a"])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .unread, search: "", pinned: "thread:a").map(\.id), ["thread:a"])
    }

    func testSearchIsNeverWaivedForPinned() {
        let threads = [thread("a", kind: .info, read: false, title: "Design review")]
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .all, search: "checklist", pinned: "thread:a").map(\.id), [])
    }

    func testPinnedIDNotInThreadsIsIgnored() {
        XCTAssertEqual(ThreadQuery.visible([], scope: .attention, search: "", pinned: "thread:gone").map(\.id), [])
    }

    func testSearchMatchesBodyProjectSourceCaseAndDiacriticInsensitive() {
        let threads = MessageThread.group([Message(id: "x", seq: 1, title: "t", body: "Résumé ready", source: "codex", project: "Web", threadKey: "x")])
        for needle in ["resume", "CODEX", "web"] {
            XCTAssertEqual(ThreadQuery.visible(threads, scope: .all, search: needle, pinned: nil).count, 1, needle)
        }
    }

    func testProjectAndSourceScopes() {
        let threads = MessageThread.group([
            Message(id: "p", seq: 1, title: "t", source: "run", project: "Web", threadKey: "p"),
            Message(id: "q", seq: 2, title: "t", source: "codex", project: "App", threadKey: "q"),
        ])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .project("Web"), search: "", pinned: nil).map(\.id), ["thread:p"])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .source("codex"), search: "", pinned: nil).map(\.id), ["thread:q"])
    }
}
