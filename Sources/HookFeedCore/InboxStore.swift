import Darwin
import Foundation
import GRDB

/// All access is serialized by GRDB; separate processes coordinate through SQLite.
public final class InboxStore: @unchecked Sendable {
    public let path: String
    private let database: DatabaseQueue
    private static let schemaVersion = 4

    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["HOOKFEED_STORE_PATH"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HookFeed/inbox.sqlite").path
    }

    /// The timeout is finite, in seconds, and must be in 0...60.
    public init(path: String? = nil, busyTimeout: TimeInterval = 5) throws {
        guard busyTimeout.isFinite, (0...60).contains(busyTimeout) else {
            throw HookFeedError.invalidInput(field: "busyTimeout", reason: "must be a finite number of seconds between 0 and 60.")
        }
        let requestedPath = path ?? Self.defaultPath
        guard !requestedPath.isEmpty, !requestedPath.utf8.contains(0) else {
            throw HookFeedError.invalidInput(field: "store path", reason: "must be a nonempty local file path.")
        }
        let resolvedPath = requestedPath == ":memory:" ? requestedPath :
            URL(fileURLWithPath: (requestedPath as NSString).expandingTildeInPath).standardizedFileURL.path
        self.path = resolvedPath

        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeout)
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("hookfeed_fold", argumentCount: 1, pure: true) { values in
                String.fromDatabaseValue(values[0])?.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                            locale: Locale(identifier: "en_US_POSIX"))
            })
        }
        // GRDB 7 uses IMMEDIATE transactions for DatabaseQueue.write, acquiring
        // the SQLite write lock before reading the idempotency key.

        if resolvedPath == ":memory:" {
            database = try DatabaseQueue(configuration: configuration)
            try Self.migrate(database, path: resolvedPath)
        } else {
            try Self.prepareDirectory(for: resolvedPath)
            // DatabaseMigrator checks migration state before starting its transaction.
            // Serialize initialization across processes, including an entirely fresh DB.
            let lock = try MigrationLock(path: resolvedPath + ".migration.lock", timeout: busyTimeout)
            defer { lock.unlock() }
            database = try DatabaseQueue(path: resolvedPath, configuration: configuration)
            try Self.migrate(database, path: resolvedPath)
            do {
                try database.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL") }
            } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {}
        }
    }

    public func journalMode() throws -> String {
        try database.read { try String.fetchOne($0, sql: "PRAGMA journal_mode")! }
    }

    public func send(_ draft: MessageDraft) throws -> SendReceipt { try send(draft, receivedAt: Date()) }

    public func send(_ draft: MessageDraft, receivedAt: Date) throws -> SendReceipt {
        let draft = try draft.normalizedAndValidated()
        let receipt = try database.write { try Self.insert(draft, receivedAt: receivedAt, into: $0) }
        if !receipt.duplicate { Signal.post() }
        return receipt
    }

    func insertSpooled(_ messages: [SpooledMessage]) throws -> [Bool] {
        try database.write { db in
            try messages.map { message in
                var draft = message.draft
                draft.idempotencyKey = message.key
                do { return try Self.insert(draft, receivedAt: message.receivedAt, into: db).duplicate }
                catch HookFeedError.idempotencyConflict { return true }
            }
        }
    }

    private static func insert(_ draft: MessageDraft, receivedAt: Date, into db: Database) throws -> SendReceipt {
        if let key = draft.idempotencyKey,
           let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE source = ? AND idempotency_key = ?", arguments: [draft.source, key]) {
            let existing = try Self.message(row)
            guard existing.title == draft.title, existing.body == draft.body, existing.origin == draft.origin,
                  existing.project == draft.project, existing.bot == draft.bot, existing.kind == draft.kind,
                  existing.url == draft.url, existing.workdir == draft.workdir,
                  existing.sessionID == draft.sessionID, existing.threadKey == draft.threadKey else {
                throw HookFeedError.idempotencyConflict(source: draft.source, key: key)
            }
            return SendReceipt(id: existing.id, duplicate: true)
        }

        let id = UUID().uuidString.lowercased()
        try db.execute(sql: """
            INSERT INTO messages
            (id, title, body, source, origin, project, bot, kind, url, workdir, session_id,
             thread_key, idempotency_key, received_at, read_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """, arguments: [
                id, draft.title, draft.body, draft.source, draft.origin, draft.project, draft.bot,
                draft.kind.rawValue, draft.url, draft.workdir, draft.sessionID,
                draft.threadKey, draft.idempotencyKey, receivedAt.timeIntervalSince1970,
            ])
        return SendReceipt(id: id, duplicate: false)
    }

    public func messages(unreadOnly: Bool = false, limit: Int? = nil) throws -> [Message] {
        if let limit, limit < 0 {
            throw HookFeedError.invalidInput(field: "limit", reason: "must be zero or greater.")
        }
        return try database.read { db in
            var sql = "SELECT * FROM messages"
            if unreadOnly { sql += " WHERE read_at IS NULL" }
            sql += " ORDER BY seq DESC"
            let rows: [Row]
            if let limit {
                rows = try Row.fetchAll(db, sql: sql + " LIMIT ?", arguments: [limit])
            } else {
                rows = try Row.fetchAll(db, sql: sql)
            }
            return try rows.map(Self.message)
        }
    }

    public func messages(matching query: MessageQuery) throws -> [Message] {
        guard (1...100).contains(query.limit) else {
            throw HookFeedError.invalidInput(field: "limit", reason: "must be between 1 and 100.")
        }
        return try database.read { db in
            var predicates: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            for (column, value) in [("project", query.project), ("source", query.source), ("bot", query.bot)] {
                if let value {
                    predicates.append("\(column) = ?")
                    arguments.append(value)
                }
            }
            if query.unreadOnly { predicates.append("read_at IS NULL") }
            if let search = query.search, !search.isEmpty {
                // Fold before matching and limiting; raw LIKE would discard diacritic matches.
                let columns = ["title", "body", "project", "bot"]
                predicates.append("(" + columns.map { "instr(hookfeed_fold(\($0)), hookfeed_fold(?)) > 0" }.joined(separator: " OR ") + ")")
                arguments.append(contentsOf: columns.map { _ in search })
            }
            if var prefix = query.workdirPrefix {
                while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
                let children = prefix == "/" ? "/" : prefix + "/"
                predicates.append("(workdir = ? OR instr(workdir, ?) = 1)")
                arguments.append(contentsOf: [prefix, children])
            }
            let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
            arguments.append(query.limit)
            return try Row.fetchAll(db, sql: "SELECT * FROM messages" + filter + " ORDER BY seq DESC LIMIT ?",
                                    arguments: StatementArguments(arguments)).map(Self.message)
        }
    }

    public func thread(_ threadID: String) throws -> [Message] {
        let predicate = try Self.threadPredicate(threadID)
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE \(predicate.sql) ORDER BY seq ASC",
                             arguments: [predicate.value]).map(Self.message)
        }
    }

    public func messages(after sequence: Int64) throws -> [Message] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE seq > ? ORDER BY seq ASC", arguments: [sequence]).map(Self.message)
        }
    }

    public func maxSequence() throws -> Int64 {
        try database.read { db in
            // Preserve the cursor even after deleting the newest (or every) row.
            try Int64.fetchOne(db, sql: "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'messages'), 0)") ?? 0
        }
    }

    /// A cheap invalidation token for commits from other connections. Local
    /// mutations must still refresh explicitly: SQLite does not advance this
    /// connection's data_version for its own commits.
    public func changeVersion() throws -> Int64 {
        try database.read { db in try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0 }
    }

    public func projectAliases() throws -> [String: String] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT alias, project FROM project_aliases").map { ($0["alias"] as String, $0["project"] as String) })
        }
    }

    public func mergeProject(_ source: String, into target: String) throws {
        let changed = try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT alias, project FROM project_aliases")
            let aliases = Dictionary(uniqueKeysWithValues: rows.map { ($0["alias"] as String, $0["project"] as String) })
            let map = ProjectMap(aliases: aliases)
            let key = map.key(for: source)
            guard key != map.key(for: target) else { return false }
            try db.execute(sql: "INSERT OR REPLACE INTO project_aliases (alias, project) VALUES (?, ?)", arguments: [key, map.name(for: target)])
            return true
        }
        if changed { Signal.post() }
    }

    public func markThreadRead(_ threadID: String) throws {
        let predicate = try Self.threadPredicate(threadID)
        try change(sql: "UPDATE messages SET read_at = ? WHERE \(predicate.sql) AND read_at IS NULL",
                   arguments: [Date().timeIntervalSince1970, predicate.value])
    }

    public func markThreadUnread(_ threadID: String) throws {
        let predicate = try Self.threadPredicate(threadID)
        try change(sql: "UPDATE messages SET read_at = NULL WHERE \(predicate.sql) AND read_at IS NOT NULL",
                   arguments: [predicate.value])
    }

    public func markAllRead() throws {
        try change(sql: "UPDATE messages SET read_at = ? WHERE read_at IS NULL", arguments: [Date().timeIntervalSince1970])
    }

    public func deleteThread(_ threadID: String) throws {
        let predicate = try Self.threadPredicate(threadID)
        try change(sql: "DELETE FROM messages WHERE \(predicate.sql)", arguments: [predicate.value])
    }

    public func deleteMessage(_ id: String) throws {
        try change(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
    }

    private func change(sql: String, arguments: StatementArguments) throws {
        let changed = try database.write { db in
            try db.execute(sql: sql, arguments: arguments)
            return db.changesCount > 0
        }
        if changed { Signal.post() }
    }

    private static func threadPredicate(_ threadID: String) throws -> (sql: String, value: String) {
        if threadID.hasPrefix("thread:") {
            return ("thread_key = ?", String(threadID.dropFirst("thread:".count)))
        }
        if threadID.hasPrefix("message:") {
            return ("id = ? AND thread_key IS NULL", String(threadID.dropFirst("message:".count)))
        }
        throw HookFeedError.invalidInput(field: "thread ID", reason: "must start with thread: or message:.")
    }

    private static func message(_ row: Row) throws -> Message {
        let rawKind: String = row["kind"]
        guard let kind = MessageKind(rawValue: rawKind) else {
            throw HookFeedError.invalidInput(field: "stored kind", reason: "unrecognized value '\(rawKind)'.")
        }
        let receivedAt: Double = row["received_at"]
        let readAt: Double? = row["read_at"]
        return Message(
            id: row["id"], seq: row["seq"], title: row["title"], body: row["body"],
            source: row["source"], origin: row["origin"], project: row["project"], bot: row["bot"], kind: kind,
            url: row["url"], workdir: row["workdir"], sessionID: row["session_id"],
            threadKey: row["thread_key"], idempotencyKey: row["idempotency_key"],
            receivedAt: Date(timeIntervalSince1970: receivedAt),
            readAt: readAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func prepareDirectory(for path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Do not change permissions of unrelated existing override directories.
        let appDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HookFeed").standardizedFileURL
        if parent.standardizedFileURL == appDirectory {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
    }

    private static func migrate(_ queue: DatabaseQueue, path: String) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_messages") { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    body TEXT,
                    source TEXT NOT NULL,
                    project TEXT,
                    kind TEXT NOT NULL CHECK (kind IN ('info', 'completed', 'needs_attention', 'failed')),
                    url TEXT,
                    workdir TEXT,
                    session_id TEXT,
                    thread_key TEXT,
                    idempotency_key TEXT,
                    received_at REAL NOT NULL,
                    read_at REAL
                );
                CREATE UNIQUE INDEX messages_source_idempotency ON messages(source, idempotency_key)
                    WHERE idempotency_key IS NOT NULL;
                CREATE INDEX messages_thread ON messages(thread_key, seq DESC);
                CREATE INDEX messages_unread ON messages(seq DESC) WHERE read_at IS NULL;
                PRAGMA user_version = 1;
                """)
        }
        migrator.registerMigration("v2_run_origin") { db in
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN origin TEXT; PRAGMA user_version = 2;")
        }
        migrator.registerMigration("v3_project_aliases") { db in
            try db.execute(sql: "CREATE TABLE project_aliases (alias TEXT PRIMARY KEY, project TEXT NOT NULL); PRAGMA user_version = 3;")
        }
        migrator.registerMigration("v4_add_bot") { db in
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN bot TEXT; PRAGMA user_version = 4;")
        }
        let superseded = try queue.read { db in
            try migrator.hasBeenSuperseded(db) || (Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) > schemaVersion
        }
        guard !superseded else { throw HookFeedError.newerSchema(path: path) }
        try migrator.migrate(queue)
    }
}

private final class MigrationLock {
    private var descriptor: Int32

    init(path: String, timeout: TimeInterval) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                close(descriptor)
                descriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                close(descriptor)
                descriptor = -1
                throw HookFeedError.migrationLockTimeout(path: path)
            }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
    }

    func unlock() {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { unlock() }
}
