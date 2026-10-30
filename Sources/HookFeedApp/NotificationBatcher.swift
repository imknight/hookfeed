import Foundation
import HookFeedCore

struct NotificationBatcher {
    static let window: TimeInterval = 1
    static let summaryThreshold = 5
    enum Delivery: Equatable { case summary(count: Int), perThread([Message]) }
    private var messages: [Message] = []

    mutating func add(_ incoming: [Message], now: Date) -> Date? {
        guard !incoming.isEmpty else { return nil }
        let deadline = messages.isEmpty ? now.addingTimeInterval(Self.window) : nil
        messages.append(contentsOf: incoming)
        return deadline
    }

    mutating func flush() -> Delivery? {
        guard !messages.isEmpty else { return nil }
        defer { messages = [] }
        if messages.count > Self.summaryThreshold { return .summary(count: messages.count) }
        let latest = Dictionary(grouping: messages, by: \.threadID).values.compactMap { $0.max { $0.seq < $1.seq } }
        return .perThread(latest.sorted { $0.seq > $1.seq })
    }
}
