import Foundation
import XCTest
@testable import HookFeedCore

final class ProjectMapTests: XCTestCase {
    func testNormalizationOnlyMergesCaseAndSafeSeparators() {
        let map = ProjectMap(projects: ["HookFeed", "hook-feed", "HOOK_FEED", "Hook Feed", "hookfeedapp", "hook.feed"])
        XCTAssertEqual(map.projects.count, 3)
        XCTAssertEqual(map.key(for: "HookFeed"), map.key(for: "hook_feed"))
        XCTAssertNotEqual(map.key(for: "HookFeed"), map.key(for: "hookfeedapp"))
        XCTAssertNotEqual(map.key(for: "hook.feed"), map.key(for: "HookFeed"))
        XCTAssertNotEqual(map.key(for: "-"), map.key(for: "_"))
    }

    func testAliasChainsResolveAndCyclesTerminateConsistently() {
        let map = ProjectMap(projects: ["Old", "Intermediate", "New"], aliases: ["old": "Intermediate", "intermediate": "New"])
        XCTAssertEqual(map.projects, ["New"])
        XCTAssertEqual(map.name(for: "OLD"), "New")
        let cyclic = ProjectMap(projects: ["A", "B"], aliases: ["a": "B", "b": "A"])
        XCTAssertEqual(cyclic.key(for: "A"), cyclic.key(for: "B"))
    }

    func testAliasesRespectFiltersSearchAndThreadCounts() {
        let map = ProjectMap(projects: ["HookFeed", "HookFeedApp", "Other"], aliases: ["hookfeedapp": "HookFeed"])
        let threads = MessageThread.group([
            Message(id: "a", seq: 1, title: "one", project: "HookFeedApp", threadKey: "a"),
            Message(id: "b", seq: 2, title: "two", project: "hook_feed", threadKey: "b"),
            Message(id: "c", seq: 3, title: "three", project: "Other", threadKey: "c"),
        ])
        XCTAssertEqual(ThreadQuery.visible(threads, scope: .project("HookFeed"), search: "", pinned: nil, projects: map).count, 2)
        for query in ["HookFeed", "HookFeedApp", "hook_feed"] {
            XCTAssertEqual(ThreadQuery.visible(threads, scope: .all, search: query, pinned: nil, projects: map).count, 2)
        }
    }

    func testStorePersistsAliasesWithoutChangingMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("inbox.sqlite").path
        let store = try InboxStore(path: path)
        _ = try store.send(MessageDraft(title: "one", project: "Old"))
        try store.mergeProject("Old", into: "Intermediate")
        try store.mergeProject("Intermediate", into: "New")
        try store.mergeProject("New", into: "Old")
        let reopened = try InboxStore(path: path)
        let map = ProjectMap(projects: ["Old"], aliases: try reopened.projectAliases())
        XCTAssertEqual(map.name(for: "Old"), "New")
        XCTAssertEqual(try reopened.messages().first?.project, "Old")
    }
}
