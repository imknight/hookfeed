import Foundation
import HookFeedCore

enum ConnectionState: Equatable {
    case notDetected, detected, connected, needsUpdate, error(String)

    var label: String {
        switch self {
        case .notDetected: return "Not detected"
        case .detected: return "Detected · ready to connect"
        case .connected: return "Connected"
        case .needsUpdate: return "Needs update"
        case .error(let message): return "Could not check connection: \(message)"
        }
    }
}

protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

struct CommandResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum IntegrationStatus {
    static func state(for integration: Integration, detection: Detection, cliPath: String, runner: CommandRunner,
                      configPath: (HookAgent) -> URL = HookInstaller.path) async -> ConnectionState {
        guard detection.found else { return .notDetected }
        do {
            switch integration.route {
            case .hooks(let agent):
                let plan = try HookInstaller.preview(agent: agent, path: configPath(agent), cliPath: cliPath)
                if !plan.hasChanges { return .connected }
                let removal = try HookInstaller.preview(agent: agent, removing: true, path: configPath(agent), cliPath: cliPath)
                return removal.hasChanges ? .needsUpdate : .detected
            case .mcp:
                guard let command = integration.mcpCommand, let executable = detection.executable else { return .detected }
                let result = try await runner.run(executable, command.list, timeout: 10)
                guard result.status == 0 else { throw ConfigurationError(result.stderr) }
                return command.isListed(result.stdout) ? .connected : .detected
            }
        } catch { return .error(error.localizedDescription) }
    }
}
