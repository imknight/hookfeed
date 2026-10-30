import Foundation

public enum AntigravityHookPayload {
    public static func draft(data: Data, project: String? = nil, bot: String? = nil) throws -> MessageDraft? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.fullyIdle else { return nil }
        guard !payload.conversationId.isEmpty, let cwd = payload.workspacePaths.first, cwd.hasPrefix("/") else {
            throw ConfigurationError("Antigravity hook needs a conversation identifier and absolute workspace path; ignored.")
        }
        let failed = !(payload.error ?? "").isEmpty || ["error", "max_steps_exceeded"].contains(payload.terminationReason.lowercased())
        return MessageDraft(title: failed ? "Antigravity run failed" : "Antigravity run finished",
                            body: failed ? (payload.error.flatMap { $0.isEmpty ? nil : $0 } ?? payload.terminationReason) : "Antigravity finished its run.",
                            source: "antigravity", project: project ?? String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(80)),
                            bot: bot, kind: failed ? .failed : .completed, workdir: cwd,
                            sessionID: payload.conversationId, threadKey: "antigravity:\(payload.conversationId)")
    }

    private struct Payload: Decodable {
        let conversationId: String
        let workspacePaths: [String]
        let fullyIdle: Bool
        let terminationReason: String
        let error: String?
    }
}
