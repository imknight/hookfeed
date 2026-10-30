import ArgumentParser
import Darwin
import Foundation
import HookFeedCore

struct Prompt: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print an agent's HookFeed setup prompt.")

    @Argument var agent: String
    @Flag(help: "Print only the when-to-send rules.") var rulesOnly = false

    func run() throws {
        let integration = Integration.named(agent)
        guard integration != nil || agent == "mcp" else {
            throw ValidationError("Unknown agent. Choose one of: " + (Integration.all.map(\.id) + ["mcp"]).joined(separator: ", "))
        }
        if rulesOnly {
            print(IntegrationPrompts.rules(source: integration?.rulesSource))
            return
        }
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buffer, &size)
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        print(integration?.setupPrompt(cliPath: path) ?? IntegrationPrompts.mcpPrompt(cliPath: path))
    }
}
