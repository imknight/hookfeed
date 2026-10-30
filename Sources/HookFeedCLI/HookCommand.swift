import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import HookFeedCore

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Agent hook adapters. Always exits 0 and never writes to stdout.",
        subcommands: [ClaudeCodeHook.self, CodexHook.self, AntigravityHook.self, GeminiCLIHook.self, CursorHook.self]
    )
}

struct ClaudeCodeHook: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "claude-code", abstract: "Accept a Claude Code Stop or Notification JSON object on stdin.")
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?
    @Flag(help: "Also store idle and other notifications as info.") var includeIdle = false

    mutating func run() {
        HookIO.perform {
            try HookPayload.draft(data: HookIO.read(), agent: .claudeCode, project: project, bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"], includeIdle: includeIdle)
        }
    }
}

struct CodexHook: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "codex", abstract: "Accept a Codex Stop hook on stdin, or legacy notify JSON as the last argument.")
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?
    @Argument(help: "Legacy notify JSON; omitted for Stop hooks on stdin.") var payload: String?

    mutating func run() {
        HookIO.perform {
            let data = payload.map { Data($0.utf8) }
            return try HookPayload.draft(data: data ?? HookIO.read(), agent: .codex, project: project, bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"])
        }
    }
}

struct AntigravityHook: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "antigravity", abstract: "Accept an Antigravity Stop hook on stdin.")
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?

    mutating func run() {
        HookIO.perform {
            try AntigravityHookPayload.draft(data: HookIO.read(), project: project, bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"])
        }
    }
}

struct GeminiCLIHook: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gemini-cli", abstract: "Accept a Gemini CLI AfterAgent or Notification JSON object on stdin.")
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?

    mutating func run() {
        HookIO.perform {
            try HookPayload.draft(data: HookIO.read(), agent: .geminiCLI, project: project, bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"])
        }
    }
}

struct CursorHook: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cursor", abstract: "Accept a Cursor stop JSON object on stdin.")
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?

    mutating func run() {
        HookIO.perform {
            try CursorHookPayload.draft(data: HookIO.read(), project: project,
                                        bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"])
        }
    }
}

enum HookPayload {
    enum Agent: String { case claudeCode = "claude-code", codex, geminiCLI = "gemini-cli" }
    static let maximumBytes = 1024 * 1024

    static func draft(data: Data, agent: Agent, project: String?, bot: String?, includeIdle: Bool = false) throws -> MessageDraft? {
        guard data.count <= maximumBytes else { throw HookFailure("Hook payload exceeds 1 MiB; ignored.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookFailure("Hook payload must be a JSON object; ignored.")
        }
        func text(_ key: String) throws -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let value = value as? String else { throw HookFailure("Hook field \(key) must be a string; ignored.") }
            return value
        }
        let legacy = agent == .codex && object["type"] != nil
        let event = try text(legacy ? "type" : "hook_event_name")
        let session = try text(legacy ? "thread-id" : "session_id")
        guard let session, !session.isEmpty else { throw HookFailure("Hook has no session identifier; ignored.") }
        let cwd = try text("cwd") ?? (legacy ? FileManager.default.currentDirectoryPath : nil)
        guard let cwd, cwd.hasPrefix("/") else { throw HookFailure("Hook cwd must be an absolute folder path; ignored.") }
        let body: String?
        let title: String
        let kind: MessageKind
        if (agent != .geminiCLI && event == "Stop") || (legacy && event == "agent-turn-complete") || (agent == .geminiCLI && event == "AfterAgent") {
            body = try text(agent == .geminiCLI ? "prompt_response" : (legacy ? "last-assistant-message" : "last_assistant_message"))
            let firstLine = body?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = firstLine.isEmpty ? "Turn finished" : String(firstLine.prefix(120))
            kind = .completed
        } else if agent == .codex && !legacy && event == "PermissionRequest" {
            guard let tool = try text("tool_name"), !tool.isEmpty,
                  let input = object["tool_input"], !(input is NSNull),
                  let turn = try text("turn_id"), !turn.isEmpty else {
                throw HookFailure("Codex approval needs tool_name, tool_input and turn_id; ignored.")
            }
            let encoded = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes])
            body = "Tool: \(tool)\n" + String(decoding: encoded, as: UTF8.self)
            let command = (input as? [String: Any])?["command"] as? String
            title = String("Approval needed: \(command.flatMap { $0.isEmpty ? nil : $0 } ?? tool)".prefix(200))
            kind = .needsAttention
        } else if agent == .geminiCLI && event == "Notification" {
            guard try text("notification_type") == "ToolPermission" else { return nil }
            body = try text("message")
            let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = trimmed.isEmpty ? "Gemini CLI needs your permission" : String(trimmed.prefix(200))
            kind = .needsAttention
        } else if agent == .claudeCode && event == "Notification" {
            let type = try text("notification_type")
            let attention = ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(type ?? "")
            guard attention || includeIdle else {
                if type != "idle_prompt" { HookIO.diagnose("Ignored Claude notification type outside the attention allowlist.") }
                return nil
            }
            body = try text("message")
            let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = trimmed.isEmpty ? (attention ? "Claude needs your input" : "Claude notification") : String(trimmed.prefix(200))
            kind = attention ? .needsAttention : .info
        } else {
            throw HookFailure("Unsupported hook event; ignored.")
        }
        let turn = try text(legacy ? "turn-id" : "turn_id")
        let normalizedBody = body.map { CLIInput.truncateUTF8($0.precomposedStringWithCanonicalMapping) }
        let resolvedProject = project ?? String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(80))
        var eventKey: String?
        if agent == .codex, let turn {
            // A Stop hook may continue a Codex turn and fire again with a new
            // response. Include the normalized content so each continuation is
            // saved, while a retry of that same event remains idempotent.
            var identity = ["session_id": session, "turn_id": turn, "workdir": cwd,
                            "project": resolvedProject, "title": title.trimmingCharacters(in: .whitespacesAndNewlines)]
                .mapValues { $0.precomposedStringWithCanonicalMapping }
            if let normalizedBody { identity["body"] = normalizedBody }
            let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            eventKey = (event == "PermissionRequest" ? "approval:" : "stop:") + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return MessageDraft(
            title: title, body: normalizedBody, source: agent.rawValue,
            project: resolvedProject, bot: bot, kind: kind,
            workdir: cwd, sessionID: session, threadKey: "\(agent.rawValue):\(session)",
            idempotencyKey: eventKey
        )
    }
}

struct HookFailure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

enum HookIO {
    static func startWatchdog() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let remote = ProcessInfo.processInfo.environment["HOOKFEED_URL"] != nil
        timer.schedule(deadline: .now() + .milliseconds(remote ? 5600 : 450), leeway: .milliseconds(1))
        timer.setEventHandler {
            // _exit also bounds stalled filesystem calls and blocked stderr/log output.
            _exit(0)
        }
        timer.resume()
        return timer
    }

    static func read() throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HookFailure("Cannot read hook stdin; ignored.")
        }
        defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw HookFailure("Hook stdin timed out; ignored.") }
            var item = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, (deadline - now) / 1_000_000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw HookFailure("Hook stdin timed out or failed; ignored.") }
            let count = Darwin.read(STDIN_FILENO, &bytes, min(bytes.count, HookPayload.maximumBytes + 1 - data.count))
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw HookFailure("Cannot read hook stdin; ignored.")
            }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= HookPayload.maximumBytes else { throw HookFailure("Hook payload exceeds 1 MiB; ignored.") }
        }
    }

    static func perform(_ parse: () throws -> MessageDraft?) {
        do {
            guard let draft = try parse() else { return }
            do { _ = try CLIStorage.send(draft, busyTimeout: 0.25) }
            catch where error.isStoreBusy && ProcessInfo.processInfo.environment["HOOKFEED_URL"] == nil {
                try Spool().enqueue(draft)
                Signal.post()
            }
        } catch {
            diagnose("hookfeed hook: \(CLIOutput.description(error))")
        }
    }

    static func diagnose(_ message: String) {
        // Never record the raw payload or transcript: logs contain diagnostics only.
        let line = CLIOutput.terminalSafe(String(message.prefix(1500))).replacingOccurrences(of: "\n", with: " ")
        CLIOutput.error(line)
        let file = ProcessInfo.processInfo.environment["HOOKFEED_LOG_PATH"]
            ?? NSHomeDirectory() + "/Library/Logs/HookFeed/hook.log"
        let directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(file, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        // Bound log growth. Truncation affects diagnostics only, never inbox data.
        if info.st_size > 1024 * 1024 { _ = ftruncate(fd, 0) }
        let record = Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)
        _ = record.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
