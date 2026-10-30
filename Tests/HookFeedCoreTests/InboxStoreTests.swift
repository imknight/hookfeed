import Darwin
import Foundation
import GRDB
import XCTest
@testable import HookFeedCore

final class InboxStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var path: String { temporaryDirectory.appendingPathComponent("private/inbox.sqlite").path }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hookfeed-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testQueryFiltersByProjectSourceBotUnread() throws {
        let store = try InboxStore(path: path)
        for draft in [
            MessageDraft(title: "one", source: "s1", project: "A", bot: "X"),
            .init(title: "two", source: "s2", project: "A", bot: "Y"),
            .init(title: "three", source: "s1", project: "B", bot: "X"),
            .init(title: "four", source: "s1", project: "A", bot: "X"),
            .init(title: "five", source: "s2", project: "B"),
            .init(title: "six", source: "s1", bot: "Y"),
        ] { _ = try store.send(draft) }
        let before = try store.messages()
        try store.markThreadRead(before.first { $0.title == "one" }!.threadID)
        XCTAssertEqual(try store.messages(matching: .init(project: "A")).map(\.title), ["four", "two", "one"])
        XCTAssertEqual(try store.messages(matching: .init(source: "s1")).map(\.title), ["six", "four", "three", "one"])
        XCTAssertEqual(try store.messages(matching: .init(bot: "X")).map(\.title), ["four", "three", "one"])
        XCTAssertEqual(try store.messages(matching: .init(unreadOnly: true)).map(\.title), ["six", "five", "four", "three", "two"])
        XCTAssertEqual(try store.messages(matching: .init(project: "A", source: "s1", bot: "X", unreadOnly: true)).map(\.title), ["four"])
        XCTAssertEqual(try store.messages(matching: .init(project: "' OR 1=1 --")), [])
        XCTAssertEqual(try store.messages(unreadOnly: true).count, 5)
    }

    func testQuerySearchIsCaseAndDiacriticInsensitive() throws {
        let store = try InboxStore(path: path)
        _ = try store.send(.init(title: "Café"))
        _ = try store.send(.init(title: "Body", body: "Résumé"))
        _ = try store.send(.init(title: "Project", project: "Naïve"))
        _ = try store.send(.init(title: "Bot", bot: "José"))
        _ = try store.send(.init(title: "CAFÉ latest"))
        for _ in 0..<25 { _ = try store.send(.init(title: "Unrelated newer message")) }
        let reopened = try InboxStore(path: path)
        XCTAssertEqual(try reopened.messages(matching: .init(search: "cafe", limit: 1)).map(\.title), ["CAFÉ latest"])
        XCTAssertEqual(try reopened.messages(matching: .init(search: "CAFE")).map(\.title), ["CAFÉ latest", "Café"])
        for (needle, title) in [("resume", "Body"), ("naive", "Project"), ("JOSE", "Bot")] {
            XCTAssertEqual(try reopened.messages(matching: .init(search: needle)).map(\.title), [title])
        }
    }

    func testQuerySearchTreatsSQLWildcardsAndQuotesLiterally() throws {
        let store = try InboxStore(path: path)
        for title in ["100% done", "under_score", "back\\slash", "' OR 1=1 --", "ordinary"] {
            _ = try store.send(.init(title: title))
        }
        for (needle, title) in [("%", "100% done"), ("_", "under_score"), ("\\", "back\\slash"), ("' OR 1=1 --", "' OR 1=1 --")] {
            XCTAssertEqual(try store.messages(matching: .init(search: needle)).map(\.title), [title])
        }
    }

    func testWorkdirPrefixMatchesFolderBoundaries() throws {
        let store = try InboxStore(path: path)
        for directory: String? in ["/a/proj", "/a/proj/sub", "/a/project2", nil, "/a/proj_%/sub", "/a/projXY/sub", "/a/proj'quote/sub"] {
            _ = try store.send(.init(title: directory ?? "No directory", workdir: directory))
        }
        for prefix in ["/a/proj", "/a/proj/"] {
            XCTAssertEqual(try store.messages(matching: .init(workdirPrefix: prefix)).map(\.workdir), ["/a/proj/sub", "/a/proj"])
        }
        XCTAssertEqual(try store.messages(matching: .init(workdirPrefix: "/a/proj_%")).map(\.workdir), ["/a/proj_%/sub"])
        XCTAssertEqual(try store.messages(matching: .init(workdirPrefix: "/a/proj'quote")).count, 1)
        XCTAssertEqual(try store.messages(matching: .init(workdirPrefix: "/")).count, 6)
    }

    func testQueryLimitBounds() throws {
        let store = try InboxStore(path: path)
        for invalid in [0, 101] {
            XCTAssertThrowsError(try store.messages(matching: .init(limit: invalid))) { error in
                guard case .invalidInput(field: "limit", reason: _) = error as? HookFeedError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        for _ in 0..<105 { _ = try store.send(.init(title: "Done")) }
        XCTAssertEqual(try store.messages(matching: .init()).count, 20)
        XCTAssertEqual(try store.messages(matching: .init(limit: 1)).map(\.seq), [105])
        XCTAssertEqual(try store.messages(matching: .init(limit: 100)).count, 100)
    }

    func testThreadReturnsOldestFirst() throws {
        let store = try InboxStore(path: path)
        let key = "shared:' OR 1=1 --"
        let first = try store.send(.init(title: "one", bot: "A", threadKey: key))
        let standalone = try store.send(.init(title: "two"))
        let last = try store.send(.init(title: "three", bot: "B", threadKey: key))
        XCTAssertEqual(try store.thread("thread:" + key).map(\.id), [first.id, last.id])
        XCTAssertEqual(try store.thread("message:" + standalone.id).map(\.id), [standalone.id])
        XCTAssertEqual(try store.thread("message:" + first.id), [])
        XCTAssertEqual(try store.thread("thread:unknown"), [])
        XCTAssertEqual(try store.thread("message:" + UUID().uuidString.lowercased()), [])
        for invalid in ["", "wrong:id", "unprefixed"] {
            XCTAssertThrowsError(try store.thread(invalid)) { error in
                guard case .invalidInput(field: "thread ID", reason: _) = error as? HookFeedError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertEqual(try store.messages(unreadOnly: true).count, 3)
    }

    func testSendStoresBot() throws {
        let store = try InboxStore(path: path)
        _ = try store.send(.init(title: "Done", source: "grokbot", project: "A", bot: "Charname"))
        let message = try XCTUnwrap(InboxStore(path: path).messages().first)
        XCTAssertEqual(message.bot, "Charname")
        XCTAssertEqual(message.source, "grokbot")
        XCTAssertEqual(message.project, "A")
    }

    func testBotIsValidated() throws {
        let store = try InboxStore(path: path)
        XCTAssertThrowsError(try store.send(.init(title: "Done", bot: String(repeating: "x", count: 81)))) { error in
            guard case .invalidInput(field: "bot", reason: _) = error as? HookFeedError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.send(.init(title: "Done", bot: "bad\0bot")))
        _ = try store.send(.init(title: "Done", bot: " \t\n"))
        XCTAssertNil(try store.messages().first?.bot)
        _ = try store.send(.init(title: "Done", bot: "  Cafe\u{301} \n"))
        XCTAssertEqual(Array(try XCTUnwrap(store.messages().first?.bot).utf8), Array("Café".utf8))
        _ = try store.send(.init(title: "Done", bot: String(repeating: "🐱", count: 80)))
        XCTAssertEqual(try store.messages().first?.bot?.count, 80)
    }

    func testIdempotencyConflictsOnDifferentBot() throws {
        let store = try InboxStore(path: path)
        let draft = MessageDraft(title: "Done", source: "bot", bot: "A", threadKey: "shared", idempotencyKey: "key")
        let receipt = try store.send(draft)
        XCTAssertTrue(try store.send(draft).duplicate)
        var other = draft
        other.bot = "B"
        XCTAssertThrowsError(try store.send(other)) { error in
            XCTAssertEqual(error as? HookFeedError, .idempotencyConflict(source: "bot", key: "key"))
        }
        other.idempotencyKey = nil
        _ = try store.send(other)
        XCTAssertEqual(MessageThread.group(try store.messages()).count, 1)
        XCTAssertEqual(try store.messages().last?.id, receipt.id)
        XCTAssertEqual(try store.messages().map(\.threadID), ["thread:shared", "thread:shared"])
    }

    func testMigratesV3DatabaseAddingNullBot() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL, body TEXT, source TEXT NOT NULL, project TEXT,
                    kind TEXT NOT NULL CHECK (kind IN ('info', 'completed', 'needs_attention', 'failed')),
                    url TEXT, workdir TEXT, session_id TEXT, thread_key TEXT, idempotency_key TEXT,
                    received_at REAL NOT NULL, read_at REAL
                );
                CREATE UNIQUE INDEX messages_source_idempotency ON messages(source, idempotency_key) WHERE idempotency_key IS NOT NULL;
                CREATE INDEX messages_thread ON messages(thread_key, seq DESC);
                CREATE INDEX messages_unread ON messages(seq DESC) WHERE read_at IS NULL;
                ALTER TABLE messages ADD COLUMN origin TEXT;
                CREATE TABLE project_aliases (alias TEXT PRIMARY KEY, project TEXT NOT NULL);
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1_create_messages'), ('v2_run_origin'), ('v3_project_aliases');
                INSERT INTO project_aliases VALUES ('old', 'New');
                INSERT INTO messages (id, title, source, project, kind, thread_key, received_at, read_at, origin)
                    VALUES ('legacy', 'Old message', 'run', 'Old', 'completed', 'shared', 100, 101, 'legacy-origin');
                PRAGMA user_version = 3;
                """)
        }
        let store = try InboxStore(path: path)
        let message = try XCTUnwrap(store.messages().first)
        XCTAssertNil(message.bot)
        XCTAssertEqual(message.id, "legacy")
        XCTAssertEqual(message.title, "Old message")
        XCTAssertEqual(message.origin, "legacy-origin")
        XCTAssertEqual(message.threadID, "thread:shared")
        XCTAssertEqual(message.readAt, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(try store.projectAliases(), ["old": "New"])
        XCTAssertEqual(try raw.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 4)
        XCTAssertEqual(try raw.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") },
                       ["v1_create_messages", "v2_run_origin", "v3_project_aliases", "v4_add_bot"])
        _ = try store.send(.init(title: "New message", bot: "Bot"))
        XCTAssertEqual(try InboxStore(path: path).messages().map(\.seq), [2, 1])
    }

    func testFreshMigrationPersistsEveryFieldAndPrivateDirectory() throws {
        let store = try InboxStore(path: path)
        XCTAssertEqual(store.path, path)
        XCTAssertEqual(try store.maxSequence(), 0)
        XCTAssertEqual(try store.messages(), [])
        let permissions = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let draft = MessageDraft(title: " \nRésumé 🐱 ", body: "quoted \"body\"\nsecond line\n第三行",
                                 source: "mcp", project: "项目", kind: .needsAttention,
                                 url: "https://example.com/?q=%22test%22", workdir: "/Users/example/Code/项目",
                                 sessionID: "session", threadKey: "mcp:session", idempotencyKey: "key")
        let receipt = try store.send(draft)
        XCTAssertFalse(receipt.duplicate)
        XCTAssertEqual(receipt.status, "stored")
        XCTAssertNotNil(UUID(uuidString: receipt.id))
        let reopened = try InboxStore(path: path)
        let message = try XCTUnwrap(reopened.messages().first)
        XCTAssertEqual(message.id, receipt.id)
        XCTAssertEqual(message.seq, 1)
        XCTAssertEqual(message.title, "Résumé 🐱")
        XCTAssertEqual(message.body, draft.body)
        XCTAssertEqual(message.source, draft.source)
        XCTAssertEqual(message.project, draft.project)
        XCTAssertEqual(message.kind, draft.kind)
        XCTAssertEqual(message.url, draft.url)
        XCTAssertEqual(message.workdir, draft.workdir)
        XCTAssertEqual(message.sessionID, draft.sessionID)
        XCTAssertEqual(message.threadKey, draft.threadKey)
        XCTAssertEqual(message.idempotencyKey, draft.idempotencyKey)
        XCTAssertNil(message.readAt)
        XCTAssertLessThan(abs(message.receivedAt.timeIntervalSinceNow), 5)
        XCTAssertEqual(try reopened.maxSequence(), 1)
    }

    func testUpgradeFromV1PreservesLegacyMessagesAndAddsAliasesAndOrigin() throws {
        let legacyBody = "Exit code: 1\nDuration: 0.010 s\nCommand: 'false'"
        let receipt = try InboxStore(path: path).send(.init(title: "old run", body: legacyBody, source: "run", project: "Old"))
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: """
                ALTER TABLE messages DROP COLUMN origin;
                ALTER TABLE messages DROP COLUMN bot;
                DROP TABLE project_aliases;
                DELETE FROM grdb_migrations WHERE identifier IN ('v2_run_origin', 'v3_project_aliases', 'v4_add_bot');
                PRAGMA user_version = 1;
                """)
        }
        let upgraded = try InboxStore(path: path)
        let message = try XCTUnwrap(upgraded.messages().first)
        XCTAssertEqual(message.id, receipt.id)
        XCTAssertEqual(message.body, legacyBody)
        XCTAssertEqual(message.recordedCommand, "'false'")
        XCTAssertFalse(message.canCopyCommand)
        try upgraded.mergeProject("Old", into: "New")
        XCTAssertEqual(try upgraded.projectAliases(), ["old": "New"])
        let body = RunRecord.body(status: 0, seconds: 0, command: "'true'", stderr: "")
        _ = try upgraded.send(.init(title: "new run", body: body, source: "run", origin: RunRecord.origin))
        XCTAssertTrue(try XCTUnwrap(upgraded.messages().first).canCopyCommand)
    }

    func testNFCIdempotentRetryDoesNotChangeReadStateOrSequence() throws {
        let store = try InboxStore(path: path)
        let draft = MessageDraft(title: " Café ", body: "Résumé\n", source: "é", project: "é", kind: .completed,
                                 workdir: "/tmp/é", sessionID: "é", threadKey: "é", idempotencyKey: "é")
        let first = try store.send(draft)
        try store.markThreadRead("thread:é")
        let before = try XCTUnwrap(store.messages().first)
        let retry = try store.send(.init(title: "\nCafe\u{301}\t", body: "Re\u{301}sume\u{301}\n", source: "e\u{301}",
                                        project: "e\u{301}", kind: .completed, workdir: "/tmp/e\u{301}", sessionID: "e\u{301}",
                                        threadKey: "e\u{301}", idempotencyKey: "e\u{301}"))
        XCTAssertEqual(retry.id, first.id)
        XCTAssertTrue(retry.duplicate)
        XCTAssertEqual(try store.messages(), [before])
        XCTAssertEqual(try store.maxSequence(), 1)
    }

    func testChangeVersionDetectsExternalWritesReadChangesAndDeletes() throws {
        let observer = try InboxStore(path: path)
        let writer = try InboxStore(path: path)
        var version = try observer.changeVersion()
        _ = try writer.send(.init(title: "External update", threadKey: "external"))
        XCTAssertNotEqual(try observer.changeVersion(), version)
        version = try observer.changeVersion()
        try writer.markThreadRead("thread:external")
        XCTAssertNotEqual(try observer.changeVersion(), version)
        version = try observer.changeVersion()
        try writer.deleteThread("thread:external")
        XCTAssertNotEqual(try observer.changeVersion(), version)
    }

    func testDedupeComparesAllContractFieldsAndScopesBySource() throws {
        let store = try InboxStore(path: path)
        let baseline = MessageDraft(title: "title", body: "body", source: "source", project: "project", kind: .completed,
                                    url: "https://example.com", workdir: "/tmp", sessionID: "session", threadKey: "thread", idempotencyKey: "key")
        _ = try store.send(baseline)
        let changes: [(inout MessageDraft) -> Void] = [
            { $0.title = "other" }, { $0.body = "other" }, { $0.project = "other" }, { $0.kind = .info },
            { $0.url = "http://example.com" }, { $0.workdir = "/elsewhere" }, { $0.sessionID = "other" }, { $0.threadKey = "other" },
        ]
        for change in changes {
            var draft = baseline
            change(&draft)
            XCTAssertThrowsError(try store.send(draft)) { error in
                XCTAssertEqual(error as? HookFeedError, .idempotencyConflict(source: "source", key: "key"))
            }
        }
        XCTAssertEqual(try store.messages().count, 1)
        var differentSource = baseline
        differentSource.source = "another"
        XCTAssertFalse(try store.send(differentSource).duplicate)
        let noKey = MessageDraft(title: "no key")
        XCTAssertNotEqual(try store.send(noKey).id, try store.send(noKey).id)
        _ = try store.send(.init(title: "nil body", idempotencyKey: "nil"))
        XCTAssertThrowsError(try store.send(.init(title: "nil body", body: "", idempotencyKey: "nil")))
    }

    func testQueriesReadUnreadAndDeletesUseStableSequences() throws {
        let store = try InboxStore(path: path)
        let standalone = try store.send(.init(title: "one"))
        let threadKey = "session:' OR 1=1 --"
        _ = try store.send(.init(title: "two", kind: .failed, threadKey: threadKey))
        let latest = try store.send(.init(title: "three", kind: .completed, threadKey: threadKey))
        XCTAssertEqual(try store.messages().map(\.seq), [3, 2, 1])
        XCTAssertEqual(try store.messages(limit: 1).map(\.id), [latest.id])
        XCTAssertEqual(try store.messages(limit: 0), [])
        XCTAssertThrowsError(try store.messages(limit: -1))
        XCTAssertEqual(try store.messages(after: 1).map(\.seq), [2, 3])
        try store.markThreadRead("thread:" + threadKey)
        XCTAssertEqual(try store.messages(unreadOnly: true).map(\.id), [standalone.id])
        XCTAssertFalse(MessageThread.group(try store.messages())[0].isAttention)
        try store.markThreadUnread("thread:" + threadKey)
        XCTAssertEqual(try store.messages(unreadOnly: true).count, 3)
        XCTAssertTrue(MessageThread.group(try store.messages())[0].isAttention)
        // A singleton-style ID may not operate on a message that belongs to a thread.
        try store.markThreadRead("message:" + latest.id)
        XCTAssertEqual(try store.messages(unreadOnly: true).count, 3)
        try store.markAllRead()
        XCTAssertEqual(try store.messages(unreadOnly: true), [])
        try store.markThreadUnread("message:" + standalone.id)
        XCTAssertEqual(try store.messages(unreadOnly: true).count, 1)
        try store.deleteMessage(latest.id)
        XCTAssertEqual(try store.maxSequence(), 3)
        try store.deleteThread("thread:" + threadKey)
        XCTAssertEqual(try store.messages().map(\.id), [standalone.id])
        try store.deleteThread("message:" + standalone.id)
        XCTAssertEqual(try store.messages(), [])
        XCTAssertEqual(try store.maxSequence(), 3)
        _ = try store.send(.init(title: "next"))
        XCTAssertEqual(try store.messages(after: 3).map(\.seq), [4])
        XCTAssertThrowsError(try store.deleteThread("invalid"))
    }

    func testInvalidSendsCannotLeavePartialRows() throws {
        let store = try InboxStore(path: path)
        for draft in [MessageDraft(title: ""), .init(title: "valid", body: String(repeating: "x", count: 32_769)),
                      .init(title: "valid", url: "javascript:bad"), .init(title: "valid", workdir: "relative")] {
            XCTAssertThrowsError(try store.send(draft))
        }
        XCTAssertEqual(try store.messages(), [])
        XCTAssertEqual(try store.maxSequence(), 0)
    }

    func testNewerMigrationAndUserVersionAreRefusedWithoutErasingData() throws {
        var store: InboxStore? = try InboxStore(path: path)
        let receipt = try store!.send(.init(title: "keep me"))
        store = nil
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v2_future')")
        }
        XCTAssertThrowsError(try InboxStore(path: path)) { error in
            XCTAssertEqual(error as? HookFeedError, .newerSchema(path: self.path))
            XCTAssertTrue(error.localizedDescription.contains("bundled"))
        }
        XCTAssertEqual(try raw.read { try String.fetchOne($0, sql: "SELECT id FROM messages") }, receipt.id)
        try raw.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2_future'; PRAGMA user_version = 99")
        }
        XCTAssertThrowsError(try InboxStore(path: path)) { error in
            XCTAssertEqual(error as? HookFeedError, .newerSchema(path: self.path))
        }
        XCTAssertEqual(try raw.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 99)
    }

    func testNewStoreUsesWAL() throws {
        XCTAssertEqual(try InboxStore(path: path).journalMode(), "wal")
        XCTAssertEqual(try InboxStore(path: ":memory:").journalMode(), "memory")
    }

    func testExistingRollbackStoreIsConverted() throws {
        do { _ = try InboxStore(path: path).send(.init(title: "existing")) }
        let raw = try DatabaseQueue(path: path)
        try raw.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=delete") }
        let reopened = try InboxStore(path: path)
        XCTAssertEqual(try reopened.journalMode(), "wal")
        XCTAssertEqual(try reopened.messages().map(\.title), ["existing"])
    }

    func testWALConversionSkippedWhileLockedThenApplied() throws {
        do { _ = try InboxStore(path: path).send(.init(title: "existing")) }
        let raw = try DatabaseQueue(path: path)
        try raw.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=delete")
            try db.execute(sql: "BEGIN")
            defer { try? db.execute(sql: "ROLLBACK") }
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")
            let reopened = try InboxStore(path: path, busyTimeout: 0.25)
            XCTAssertEqual(try reopened.journalMode(), "delete")
        }
        XCTAssertEqual(try InboxStore(path: path).journalMode(), "wal")
    }

    func testBusyTimeoutIsBoundedAndDoesNotWriteOnFailure() throws {
        let store = try InboxStore(path: path)
        let contender = try InboxStore(path: path, busyTimeout: 0.05)
        let lock = try DatabaseQueue(path: path)
        try lock.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            defer { try? db.execute(sql: "ROLLBACK") }
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try contender.send(.init(title: "locked")))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
        XCTAssertEqual(try store.messages(), [])
        for invalid in [-1.0, Double.infinity, Double.nan, 61.0] {
            XCTAssertThrowsError(try InboxStore(path: path, busyTimeout: invalid))
        }
    }

    func testMigrationLockHonorsTimeout() throws {
        _ = try InboxStore(path: path)
        let fd = open(path + ".migration.lock", O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try InboxStore(path: path, busyTimeout: 0.03)) { error in
            guard case .migrationLockTimeout = error as? HookFeedError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testDefaultPathHonorsEnvironmentOverride() {
        let old = ProcessInfo.processInfo.environment["HOOKFEED_STORE_PATH"]
        defer {
            if let old { setenv("HOOKFEED_STORE_PATH", old, 1) }
            else { unsetenv("HOOKFEED_STORE_PATH") }
        }
        setenv("HOOKFEED_STORE_PATH", "/tmp/custom-hookfeed.sqlite", 1)
        XCTAssertEqual(InboxStore.defaultPath, "/tmp/custom-hookfeed.sqlite")
        unsetenv("HOOKFEED_STORE_PATH")
        XCTAssertEqual(InboxStore.defaultPath, FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HookFeed/inbox.sqlite").path)
    }
}
