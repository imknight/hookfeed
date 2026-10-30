import Foundation

public enum CursorHookPayload {
    public static func draft(data: Data, project: String? = nil, bot: String? = nil) throws -> MessageDraft {
        guard data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "stop",
              let conversation = object["conversation_id"] as? String, !conversation.isEmpty,
              let roots = object["workspace_roots"] as? [String],
              let workdir = roots.first, workdir.hasPrefix("/"),
              let status = object["status"] as? String else {
            throw ConfigurationError("Invalid Cursor stop payload; ignored.")
        }
        let title: String
        let kind: MessageKind
        switch status {
        case "completed": title = "Cursor turn finished"; kind = .completed
        case "error": title = "Cursor turn failed"; kind = .failed
        case "aborted": title = "Cursor turn aborted"; kind = .info
        default: throw ConfigurationError("Unsupported Cursor stop status; ignored.")
        }
        return MessageDraft(title: title, body: "Cursor agent stopped with status: \(status).",
                            source: "cursor", project: project ?? String(URL(fileURLWithPath: workdir).lastPathComponent.prefix(80)),
                            bot: bot, kind: kind, workdir: workdir, sessionID: conversation,
                            threadKey: "cursor:\(conversation)")
    }
}
