import Foundation

public struct MCPCommand: Sendable {
    public let executable: String
    public let add: @Sendable (String) -> [String]
    public let remove: [String]
    public let list: [String]
    public let test: [String]
    public let afterInstall: String

    public func isListed(_ listOutput: String) -> Bool {
        if executable == "openclaw" {
            return listOutput.range(of: #"(?m)^- hookfeed(?:\s|$)"#, options: .regularExpression) != nil
        }
        return listOutput.range(of: #"(?m)^\s*hookfeed(?:\s|$)"#, options: .regularExpression) != nil
    }
}
