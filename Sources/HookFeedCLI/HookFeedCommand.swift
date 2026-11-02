import ArgumentParser
import Darwin
import Foundation
import HookFeedCore

@main
struct HookFeedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hookfeed",
        abstract: "A local inbox for agent updates.",
        version: "0.1.0",
        subcommands: [Send.self, List.self, Run.self, Hook.self, MCPCommand.self, Prompt.self, Drain.self, Serve.self]
    )

    // ArgumentParser normally uses EX_USAGE (64). HookFeed's public contract uses 2.
    // Handle hooks here too: even a misspelled option must never block an agent.
    static func main() async {
        let isHook = CommandLine.arguments.dropFirst().first == "hook"
        let watchdog = isHook ? HookIO.startWatchdog() : nil
        defer { watchdog?.cancel() }
        do {
            var command = try parseAsRoot()
            if var asynchronous = command as? any AsyncParsableCommand {
                try await asynchronous.run()
            } else {
                try command.run()
            }
        } catch {
            if isHook {
                HookIO.diagnose(fullMessage(for: error))
                Darwin.exit(0)
            }
            if let wrapped = error as? WrappedExit {
                Darwin.exit(wrapped.status)
            }
            if let coreError = error as? HookFeedError {
                switch coreError {
                case .invalidInput, .idempotencyConflict:
                    CLIOutput.error(coreError.localizedDescription)
                    Darwin.exit(2)
                default: break
                }
            }
            let code = exitCode(for: error).rawValue
            let message = fullMessage(for: error)
            if code == 0 {
                print(message, terminator: message.hasSuffix("\n") ? "" : "\n")
            } else {
                CLIOutput.error(message)
            }
            Darwin.exit(code == 64 ? 2 : code)
        }
    }
}

struct Send: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a message locally.")

    @Argument(help: "Message title (1–200 characters).") var title: String
    @Option(help: "Plain-text body, up to 32 KiB UTF-8.") var body: String?
    @Option(help: "Read the body from a UTF-8 file, or - for stdin.") var bodyFile: String?
    @Option(help: "Self-declared source label.") var source = "cli"
    @Option var project: String?
    @Option(help: "Bot name; defaults to HOOKFEED_BOT.") var bot: String?
    @Option(help: "info, completed, needs_attention, or failed.") var kind = "info"
    @Option var url: String?
    @Option(help: "Absolute folder path; . resolves to the current directory.") var workdir: String?
    @Option(name: .customLong("thread")) var threadKey: String?
    @Option var sessionID: String?
    @Option(name: .customLong("key")) var idempotencyKey: String?
    @Flag(help: "Print the storage receipt as JSON.") var json = false

    mutating func validate() throws {
        guard body == nil || bodyFile == nil else {
            throw ValidationError("--body and --body-file are mutually exclusive.")
        }
        guard MessageKind(rawValue: kind) != nil else {
            throw ValidationError("--kind must be info, completed, needs_attention, or failed.")
        }
    }

    mutating func run() throws {
        let text = try bodyFile.map { try CLIInput.body(path: $0) } ?? body
        let draft = MessageDraft(
            title: title, body: text, source: source, project: project,
            bot: bot ?? ProcessInfo.processInfo.environment["HOOKFEED_BOT"],
            kind: MessageKind(rawValue: kind)!, url: url,
            workdir: workdir.map(CLIInput.absolutePath), sessionID: sessionID,
            threadKey: threadKey, idempotencyKey: idempotencyKey
        )
        let receipt = try CLIStorage.send(draft)
        if json { try CLIOutput.json(receipt) }
        else { print("Stored \(receipt.id)\(receipt.duplicate ? " (duplicate)" : "")") }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List newest messages without marking them read.")
    @Flag var unread = false
    @Option(help: "Match the stored project exactly.") var project: String?
    @Option(help: "Match the source exactly.") var source: String?
    @Option(help: "Match the bot name exactly.") var bot: String?
    @Option(help: "Find literal text in title, body, project or bot, ignoring case and diacritics.") var search: String?
    @Option(help: "Number of messages (1–100).") var limit = 20
    @Flag(help: "Print messages as a JSON array with UTC timestamps.") var json = false

    mutating func validate() throws {
        guard (1...100).contains(limit) else { throw ValidationError("--limit must be between 1 and 100.") }
    }

    mutating func run() throws {
        let messages = try InboxStore().messages(matching: MessageQuery(project: project, source: source, bot: bot,
                                                                      unreadOnly: unread, search: search, limit: limit))
        if json { try CLIOutput.json(messages) }
        else {
            for message in messages {
                let bot = message.bot.map { " · \($0)" } ?? ""
                let project = message.project.map { " · \($0)" } ?? ""
                print(CLIOutput.terminalSafe("\(message.readAt == nil ? "●" : "○") \(message.kind.rawValue) · \(message.source)\(bot)\(project) · \(message.title) [\(message.id)]"))
            }
        }
    }
}

enum CLIOutput {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func json<T: Encodable>(_ value: T) throws {
        var data = try encoded(value)
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    static func error(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((terminalSafe(text) + "\n").utf8))
    }

    static func description(_ error: any Error) -> String {
        (error as? ValidationError)?.description ?? error.localizedDescription
    }

    static func terminalSafe(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" { return "�" }
            return Character(scalar)
        })
    }
}

enum CLIInput {
    static let bodyLimit = 32 * 1024

    static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func body(path: String) throws -> String {
        let descriptor: Int32
        if path == "-" { descriptor = STDIN_FILENO }
        else {
            descriptor = Darwin.open((path as NSString).expandingTildeInPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ValidationError("Cannot read --body-file: \(String(cString: strerror(errno)))")
            }
        }
        defer { if path != "-" { Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ValidationError("Cannot inspect --body-file.") }
        if path != "-", (info.st_mode & S_IFMT) != S_IFREG {
            throw ValidationError("--body-file must be a regular file; use - to read a pipe on stdin.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, bodyLimit + 1 - data.count))
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ValidationError("Cannot read --body-file: \(String(cString: strerror(errno)))")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= bodyLimit else { throw ValidationError("Body exceeds 32 KiB UTF-8.") }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("--body-file must contain valid UTF-8.")
        }
        return text
    }

    static func truncateUTF8(_ string: String, bytes: Int = bodyLimit) -> String {
        guard string.utf8.count > bytes else { return string }
        var prefix = Data(string.utf8.prefix(bytes))
        while let last = prefix.last {
            if let text = String(data: prefix, encoding: .utf8) { return text }
            prefix.removeLast()
            if last < 0x80 { break }
        }
        return String(data: prefix, encoding: .utf8) ?? ""
    }
}

enum CLIStorage {
    static func send(_ draft: MessageDraft, busyTimeout: TimeInterval = 5) throws -> SendReceipt {
        if let base = ProcessInfo.processInfo.environment["HOOKFEED_URL"] {
            return try RemoteSender.send(draft, base: base, token: ProcessInfo.processInfo.environment["HOOKFEED_TOKEN"])
        }
        return try InboxStore(busyTimeout: busyTimeout).send(draft)
    }
}

struct WrappedExit: Error { let status: Int32 }
