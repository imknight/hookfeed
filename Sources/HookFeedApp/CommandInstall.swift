import Foundation
import HookFeedCore

struct CommandInstallPlan: Identifiable {
    let id = UUID()
    let integration: Integration
    let executable: URL
    let arguments: [String]
    let removing: Bool
    let hasChanges: Bool

    var displayCommand: String {
        ([executable.lastPathComponent] + arguments).map {
            $0.range(of: #"^[a-zA-Z0-9_./-]+$"#, options: .regularExpression) != nil ? $0 : ShellText.quote($0)
        }.joined(separator: " ")
    }

    func apply(runner: CommandRunner) async throws -> String {
        guard hasChanges else { return "No changes needed." }
        let result = try await runner.run(executable, arguments, timeout: 30)
        guard result.status == 0 else { throw ConfigurationError(result.stderr) }
        if removing { return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let test = try await runner.run(executable, integration.mcpCommand!.test, timeout: 30)
        guard test.status == 0 else { throw ConfigurationError(test.stderr) }
        return test.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func make(_ integration: Integration, executable: URL, cliPath: String, removing: Bool,
                     runner: CommandRunner) async throws -> CommandInstallPlan {
        let command = integration.mcpCommand!
        let result = try await runner.run(executable, command.list, timeout: 10)
        guard result.status == 0 else { throw ConfigurationError(result.stderr) }
        let listed = command.isListed(result.stdout)
        return CommandInstallPlan(integration: integration, executable: executable, arguments: removing ? command.remove : command.add(cliPath),
                                  removing: removing, hasChanges: removing ? listed : !listed)
    }
}

enum InstallPlan: Identifiable {
    case hooks(HookInstallPlan), command(CommandInstallPlan)
    var id: UUID {
        switch self { case .hooks(let plan): return plan.id; case .command(let plan): return plan.id }
    }
}
