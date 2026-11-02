import Foundation

public enum LoginShell {
    public static func path() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
        let result = try await ProcessCommandRunner(environmentPath: environment["PATH"] ?? "").run(executable, ["-lc", "echo $PATH"], timeout: 5)
        guard result.status == 0 else { throw ConfigurationError("Could not read the login shell PATH.") }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
