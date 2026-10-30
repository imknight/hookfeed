import Darwin
import Foundation
import HookFeedCore

struct ProcessCommandRunner: CommandRunner {
    let environmentPath: String
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await Task.detached { try execute(executable, arguments, timeout: timeout) }.value
    }

    private func execute(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout"), stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(["PATH": environmentPath]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ConfigurationError("\(executable.lastPathComponent) timed out.")
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: try String(contentsOf: stdout, encoding: .utf8),
                             stderr: try String(contentsOf: stderr, encoding: .utf8))
    }
}

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
