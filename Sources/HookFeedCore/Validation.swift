import Foundation

public enum HookFeedError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput(field: String, reason: String)
    case idempotencyConflict(source: String, key: String)
    case newerSchema(path: String)
    case migrationLockTimeout(path: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInput(field, reason):
            return "Invalid \(field): \(reason)"
        case let .idempotencyConflict(source, key):
            return "Idempotency key '\(key)' for source '\(source)' already belongs to a different message. Use a new key for new content."
        case let .newerSchema(path):
            return "The inbox at \(path) uses a newer schema. Use the CLI bundled with the installed HookFeed app."
        case let .migrationLockTimeout(path):
            return "Timed out waiting to initialize the inbox at \(path). Try again after the other writer finishes."
        }
    }
}

extension MessageDraft {
    func normalizedAndValidated() throws -> MessageDraft {
        func nfc(_ value: String) -> String { value.precomposedStringWithCanonicalMapping }
        let bot = bot.map { nfc($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let result = MessageDraft(
            title: nfc(title).trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.map(nfc), source: nfc(source), origin: origin, project: project.map(nfc),
            bot: bot?.isEmpty == true ? nil : bot, kind: kind, url: url.map(nfc), workdir: workdir.map(nfc),
            sessionID: sessionID.map(nfc), threadKey: threadKey.map(nfc),
            idempotencyKey: idempotencyKey.map(nfc)
        )

        try Self.check(result.title, field: "title", maximum: 200, required: true)
        try Self.check(result.source, field: "source", maximum: 80, required: true)
        try Self.check(result.project, field: "project", maximum: 80)
        try Self.check(result.bot, field: "bot", maximum: 80)
        try Self.check(result.url, field: "url", maximum: 2_048)
        try Self.check(result.workdir, field: "workdir", maximum: 1_024)
        try Self.check(result.sessionID, field: "session_id", maximum: 200)
        try Self.check(result.threadKey, field: "thread_key", maximum: 200)
        try Self.check(result.idempotencyKey, field: "idempotency_key", maximum: 200)
        if let body = result.body, body.utf8.count > 32 * 1_024 {
            throw HookFeedError.invalidInput(field: "body", reason: "must be at most 32 KiB of UTF-8 text.")
        }

        if let url = result.url {
            // Foundation can repair malformed URL strings; reject those repairs.
            guard !url.isEmpty,
                  !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  let parsed = URL(string: url, encodingInvalidCharacters: false),
                  let scheme = parsed.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = parsed.host, !host.isEmpty else {
                throw HookFeedError.invalidInput(field: "url", reason: "must be a valid absolute HTTP or HTTPS link; other schemes are not supported.")
            }
        }
        if let workdir = result.workdir {
            guard workdir.hasPrefix("/"), !workdir.utf8.contains(0) else {
                throw HookFeedError.invalidInput(field: "workdir", reason: "must be an absolute local path, such as /Users/you/Code/project.")
            }
        }
        return result
    }

    private static func check(_ value: String?, field: String, maximum: Int, required: Bool = false) throws {
        guard let value else { return }
        if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HookFeedError.invalidInput(field: field, reason: "must not be empty.")
        }
        guard value.count <= maximum else {
            throw HookFeedError.invalidInput(field: field, reason: "must be at most \(maximum) characters.")
        }
        // NUL is not meaningful message metadata and is unsafe in C path APIs.
        guard !value.utf8.contains(0) else {
            throw HookFeedError.invalidInput(field: field, reason: "must not contain a NUL character.")
        }
    }
}
