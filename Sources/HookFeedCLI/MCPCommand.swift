import ArgumentParser
import Foundation
import HookFeedCore
import MCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve local MCP stdio tools (protocol-only stdout).")
    @Flag(help: "Allow read-only queries of every project in the inbox.") var readAll = false

    mutating func run() async throws {
        let readAll = readAll
        let defaultBot = ProcessInfo.processInfo.environment["HOOKFEED_BOT"]
        var instructions = "HookFeed stores updates in a local human inbox. A receipt means stored, not seen. Clients already using HookFeed hooks should use their hook adapter to avoid double posting."
        if readAll {
            instructions += " --read-all is enabled: list_messages allows reading every project without marking messages read."
        }
        let server = Server(
            name: "hookfeed", version: "0.1.0", instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPTools.definitions(readAll: readAll))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            try MCPTools.call(parameters.name, arguments: parameters.arguments ?? [:], readAll: readAll,
                              defaultBot: defaultBot, store: { try InboxStore() })
        }
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await server.stop()
    }
}
