import Foundation

public struct MessageThread: Identifiable, Sendable {
    public let id: String
    /// Always nonempty and ordered by descending sequence.
    public let messages: [Message]

    public var latest: Message { messages[0] }
    public var isUnread: Bool { messages.contains { $0.readAt == nil } }
    public var unreadCount: Int { messages.filter { $0.readAt == nil }.count }
    public var updateCount: Int { messages.count }
    public var isAttention: Bool { unreadAttention != nil }
    public var kind: MessageKind { unreadAttention?.kind ?? latest.kind }

    private var unreadAttention: Message? {
        messages.first { $0.readAt == nil && ($0.kind == .needsAttention || $0.kind == .failed) }
    }

    public static func group(_ messages: [Message]) -> [MessageThread] {
        Dictionary(grouping: messages, by: \.threadID).map { id, messages in
            MessageThread(id: id, messages: messages.sorted(by: newestFirst))
        }.sorted { newestFirst($0.latest, $1.latest) }
    }

    private static func newestFirst(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.seq == rhs.seq ? lhs.id > rhs.id : lhs.seq > rhs.seq
    }
}
