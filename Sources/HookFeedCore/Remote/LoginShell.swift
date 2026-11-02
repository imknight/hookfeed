import Foundation

public enum LoginShell {
    public static func path() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
        let result = try await ProcessCommandRunner(environmentPath: environment["PATH"] ?? "").run(executable, ["-lc", "printf '\\n__HOOKFEED_PATH_BEGIN__\\n%s\\n__HOOKFEED_PATH_END__\\n' \"$PATH\""], timeout: 5)
        guard result.status == 0 else { throw ConfigurationError("Could not read the login shell PATH.") }
        return try parsePath(result.stdout)
    }

    static func parsePath(_ output: String) throws -> String {
        guard let start = output.range(of: "__HOOKFEED_PATH_BEGIN__\n"),
              let end = output.range(of: "\n__HOOKFEED_PATH_END__", range: start.upperBound..<output.endIndex) else {
            throw ConfigurationError("Could not read the login shell PATH.")
        }
        return String(output[start.upperBound..<end.lowerBound])
    }
}
