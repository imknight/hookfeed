import Foundation

public enum ThreadScope: Hashable, Sendable {
    case attention, unread, all, project(String), source(String), bot(String)
}

public enum ThreadQuery {
    /// Threads in `scope` that match `search`. The `pinned` thread (the one the user opened)
    /// stays in its scope after reading it, so it doesn't vanish mid-view; search still applies.
    public static func visible(_ threads: [MessageThread], scope: ThreadScope, search: String, pinned: String?, projects: ProjectMap = ProjectMap()) -> [MessageThread] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return threads.filter { thread in
            (thread.id == pinned || inScope(thread, scope, projects: projects)) && (needle.isEmpty || matches(thread, needle, projects: projects))
        }
    }

    private static func inScope(_ thread: MessageThread, _ scope: ThreadScope, projects: ProjectMap) -> Bool {
        switch scope {
        case .all: return true
        case .unread: return thread.isUnread
        case .attention: return thread.isAttention
        case .project(let value): return thread.messages.contains { $0.project.map { projects.key(for: $0) == projects.key(for: value) } ?? false }
        case .bot(let value): return thread.messages.contains { $0.bot == value }
        case .source(let value): return thread.messages.contains { $0.source == value }
        }
    }

    private static func matches(_ thread: MessageThread, _ needle: String, projects: ProjectMap) -> Bool {
        thread.messages.contains { message in
            if let project = message.project, projects.key(for: project) == projects.key(for: needle) { return true }
            return [message.title, message.body ?? "", message.source, message.bot ?? "", message.project ?? "", message.project.map { projects.name(for: $0) } ?? ""].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
