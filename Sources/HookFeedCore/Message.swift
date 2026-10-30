import Foundation

public enum MessageKind: String, Codable, CaseIterable, Sendable {
    case info
    case completed
    case needsAttention = "needs_attention"
    case failed
}

public struct MessageDraft: Codable, Sendable, Equatable {
    public var title: String
    public var body: String?
    public var source: String
    public var origin: String?
    public var project: String?
    public var bot: String?
    public var kind: MessageKind
    public var url: String?
    public var workdir: String?
    public var sessionID: String?
    public var threadKey: String?
    public var idempotencyKey: String?

    public init(
        title: String, body: String? = nil, source: String = "cli", origin: String? = nil,
        project: String? = nil, bot: String? = nil, kind: MessageKind = .info, url: String? = nil,
        workdir: String? = nil, sessionID: String? = nil,
        threadKey: String? = nil, idempotencyKey: String? = nil
    ) {
        self.title = title
        self.body = body
        self.source = source
        self.origin = origin
        self.project = project
        self.bot = bot
        self.kind = kind
        self.url = url
        self.workdir = workdir
        self.sessionID = sessionID
        self.threadKey = threadKey
        self.idempotencyKey = idempotencyKey
    }
}

public struct Message: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: Int64
    public let title: String
    public let body: String?
    public let source: String
    public let origin: String?
    public let project: String?
    public let bot: String?
    public let kind: MessageKind
    public let url: String?
    public let workdir: String?
    public let sessionID: String?
    public let threadKey: String?
    public let idempotencyKey: String?
    public let receivedAt: Date
    public let readAt: Date?

    public var threadID: String {
        threadKey.map { "thread:\($0)" } ?? "message:\(id)"
    }

    public init(
        id: String, seq: Int64, title: String, body: String? = nil,
        source: String = "cli", origin: String? = nil, project: String? = nil, bot: String? = nil, kind: MessageKind = .info,
        url: String? = nil, workdir: String? = nil, sessionID: String? = nil,
        threadKey: String? = nil, idempotencyKey: String? = nil,
        receivedAt: Date = Date(), readAt: Date? = nil
    ) {
        self.id = id
        self.seq = seq
        self.title = title
        self.body = body
        self.source = source
        self.origin = origin
        self.project = project
        self.bot = bot
        self.kind = kind
        self.url = url
        self.workdir = workdir
        self.sessionID = sessionID
        self.threadKey = threadKey
        self.idempotencyKey = idempotencyKey
        self.receivedAt = receivedAt
        self.readAt = readAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, seq, title, body, source, origin, project, bot, kind, url, workdir
        case sessionID = "session_id"
        case threadKey = "thread_key"
        case idempotencyKey = "idempotency_key"
        case receivedAt = "received_at"
        case readAt = "read_at"
    }
}

public extension Message {
    /// The command `hookfeed run` recorded on its final `Command:` line, through the end of the body.
    var recordedCommand: String? {
        guard source == "run", let body else { return nil }
        if origin == RunRecord.origin {
            let lines = body.components(separatedBy: "\n")
            guard lines.count > 3, lines[2].hasPrefix("Command bytes: "),
                  let count = Int(lines[2].dropFirst("Command bytes: ".count)), count > 0, count <= body.utf8.count else { return nil }
            return String(data: Data(body.utf8.suffix(count)), encoding: .utf8)
        }
        guard let range = body.range(of: "(^|\n)Command: ", options: .regularExpression) else { return nil }
        let command = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    var canCopyCommand: Bool { origin == RunRecord.origin && recordedCommand != nil }
    var isCommandTruncated: Bool {
        origin == RunRecord.origin && body?.components(separatedBy: "\n").dropFirst(3).first == "Command truncated: yes"
    }
}

public struct SendReceipt: Codable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let duplicate: Bool

    public init(id: String, status: String = "stored", duplicate: Bool) {
        self.id = id
        self.status = status
        self.duplicate = duplicate
    }
}
