import Foundation
import MCP

public enum MCPTools {
    public static func definitions(readAll: Bool = false) -> [Tool] {
        readAll ? [sendMessage, listMessages] : [sendMessage]
    }

    public static func call(_ name: String, arguments: [String: Value], readAll: Bool = false,
                            defaultBot: String? = nil, store: () throws -> InboxStore) throws -> CallTool.Result {
        guard name == "send_message" || name == "list_messages" else {
            throw MCPError.invalidParams("Unknown HookFeed tool: \(name).")
        }
        if name == "list_messages", !readAll {
            return failure("start hookfeed mcp with --read-all to allow reading")
        }
        do {
            if name == "send_message" {
                let draft = try messageDraft(arguments, defaultBot: defaultBot)
                return try result(store().send(draft))
            }
            let query = try messageQuery(arguments)
            return try result(Messages(messages: store().messages(matching: query)))
        } catch {
            let prefix = name == "send_message" ? "Message was not stored" : "Messages were not read"
            return failure("\(prefix): \(error.localizedDescription)")
        }
    }

    private static let lengths: [String: Int] = [
        "title": 200, "body": 32768, "source": 80, "project": 80, "bot": 80, "url": 2048,
        "workdir": 1024, "session_id": 200, "thread_key": 200, "idempotency_key": 200,
    ]

    private static var sendMessage: Tool {
        var properties = lengths.mapValues { maximum -> Value in
            .object(["type": .string("string"), "maxLength": .int(maximum)])
        }
        properties["title"] = .object(["type": "string", "minLength": 1, "maxLength": 200])
        properties["source"] = .object(["type": "string", "minLength": 1, "maxLength": 80, "default": "mcp"])
        properties["body"] = .object(["type": "string", "maxLength": 32768, "description": "Plain text, at most 32768 UTF-8 bytes."])
        properties["kind"] = .object([
            "type": "string", "enum": .array(MessageKind.allCases.map { .string($0.rawValue) }), "default": "info",
        ])
        return Tool(
            name: "send_message", description: "Store an update in HookFeed's local human inbox. Only title is required; source defaults to mcp. Include bot (the bot name), project, an absolute workdir, and a stable thread_key when known. Use idempotency_key for retries of the same content. Receipt means stored, not seen. Use hooks instead when your client already has a HookFeed hook adapter.",
            inputSchema: .object([
                "type": "object", "properties": .object(properties),
                "required": .array(["title"]), "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        )
    }

    private static var listMessages: Tool {
        Tool(
            name: "list_messages", description: "Read messages from every project in HookFeed, newest first, without marking them read. Project, source and bot filters match exactly. Search finds literal text in title, body, project and bot, ignoring case and diacritics.",
            inputSchema: .object([
                "type": "object", "additionalProperties": false,
                "properties": .object([
                    "project": .object(["type": "string"]),
                    "source": .object(["type": "string"]),
                    "bot": .object(["type": "string"]),
                    "unread_only": .object(["type": "boolean", "default": false]),
                    "search": .object(["type": "string"]),
                    "limit": .object(["type": "integer", "minimum": 1, "maximum": 100, "default": 20]),
                ]),
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        )
    }

    static func messageDraft(_ arguments: [String: Value], defaultBot: String? = nil, defaultSource: String = "mcp") throws -> MessageDraft {
        guard Set(arguments.keys).isSubset(of: Set(lengths.keys).union(["kind"])) else {
            throw HookFeedError.invalidInput(field: "arguments", reason: "Unknown send_message argument.")
        }
        guard let title = try text("title", arguments) else {
            throw HookFeedError.invalidInput(field: "title", reason: "is required.")
        }
        let rawKind = try text("kind", arguments) ?? "info"
        guard let kind = MessageKind(rawValue: rawKind) else {
            throw HookFeedError.invalidInput(field: "kind", reason: "use info, completed, needs_attention, or failed.")
        }
        return try MessageDraft(
            title: title, body: text("body", arguments), source: text("source", arguments) ?? defaultSource,
            project: text("project", arguments), bot: text("bot", arguments) ?? defaultBot,
            kind: kind, url: text("url", arguments), workdir: text("workdir", arguments),
            sessionID: text("session_id", arguments), threadKey: text("thread_key", arguments),
            idempotencyKey: text("idempotency_key", arguments)
        )
    }

    private static func messageQuery(_ arguments: [String: Value]) throws -> MessageQuery {
        guard Set(arguments.keys).isSubset(of: ["project", "source", "bot", "unread_only", "search", "limit"]) else {
            throw HookFeedError.invalidInput(field: "arguments", reason: "Unknown list_messages argument.")
        }
        var unreadOnly = false
        if let value = arguments["unread_only"] {
            guard case .bool(let flag) = value else {
                throw HookFeedError.invalidInput(field: "unread_only", reason: "must be a boolean.")
            }
            unreadOnly = flag
        }
        var limit = 20
        if let value = arguments["limit"] {
            guard case .int(let number) = value else {
                throw HookFeedError.invalidInput(field: "limit", reason: "must be an integer.")
            }
            limit = number
        }
        return try MessageQuery(project: text("project", arguments), source: text("source", arguments),
                                bot: text("bot", arguments), unreadOnly: unreadOnly,
                                search: text("search", arguments), limit: limit)
    }

    private static func text(_ key: String, _ arguments: [String: Value]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard case .string(let string) = value else {
            throw HookFeedError.invalidInput(field: key, reason: "must be a string.")
        }
        return string
    }

    private struct Messages: Encodable { let messages: [Message] }

    private static func result<T: Encodable>(_ payload: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let value = try JSONDecoder().decode(Value.self, from: data)
        return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                     structuredContent: .some(value), isError: false)
    }

    private static func failure(_ description: String) -> CallTool.Result {
        .init(content: [.text(text: description, annotations: nil, _meta: nil)], isError: true)
    }
}
