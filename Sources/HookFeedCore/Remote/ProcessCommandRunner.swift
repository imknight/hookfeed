import Darwin
import Foundation

public struct ProcessCommandRunner: CommandRunner {
    let environmentPath: String
    var environment: [String: String] = ProcessInfo.processInfo.environment

    public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await Task.detached { try execute(executable, arguments, timeout: timeout) }.value
    }

    public init(environmentPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environmentPath = environmentPath
        self.environment = environment
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


public protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}
