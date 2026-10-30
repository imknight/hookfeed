import Foundation
import HookFeedCore

struct HookInstallPlan: Identifiable {
    let id = UUID()
    let agent: HookAgent
    let path: URL
    let original: Data?
    let updated: Data
    let removing: Bool
    let hasChanges: Bool

    func apply() throws -> URL? {
        guard hasChanges else { return nil }
        guard try HookInstaller.read(path) == original else {
            throw ConfigurationError("The configuration changed after this preview. Preview it again before applying.")
        }
        let manager = FileManager.default
        var backup: URL?
        var permissions: NSNumber?
        if original != nil {
            permissions = try manager.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSSSSS"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let destination = URL(fileURLWithPath: path.path + ".hookfeed-" + formatter.string(from: Date()) + "-" + UUID().uuidString + ".bak")
            try manager.copyItem(at: path, to: destination)
            backup = destination
        }
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions ?? NSNumber(value: 0o600)], ofItemAtPath: path.path)
        return backup
    }
}

enum HookInstaller {
    static func path(for agent: HookAgent) -> URL {
        let key: String
        switch agent {
        case .claudeCode: key = "HOOKFEED_CLAUDE_CONFIG_PATH"
        case .codex: key = "HOOKFEED_CODEX_CONFIG_PATH"
        case .antigravity: key = "HOOKFEED_ANTIGRAVITY_CONFIG_PATH"
        case .geminiCLI: key = "HOOKFEED_GEMINI_CONFIG_PATH"
        case .cursor: key = "HOOKFEED_CURSOR_CONFIG_PATH"
        }
        if let path = ProcessInfo.processInfo.environment[key] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(agent.relativeConfigPath)
    }

    static func preview(agent: HookAgent, removing: Bool = false, path: URL? = nil, cliPath: String = IntegrationSnippets.cliPath) throws -> HookInstallPlan {
        let path = path ?? self.path(for: agent)
        let original = try read(path)
        let object = try HookConfiguration.parse(original)
        let command = "\(ShellText.quote(cliPath)) hook \(agent.rawValue)"
        let merged = try HookConfiguration.merge(object, agent: agent, command: command, removing: removing)
        let updated = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return HookInstallPlan(agent: agent, path: path, original: original, updated: updated, removing: removing,
                               hasChanges: (object as NSDictionary) != (merged as NSDictionary))
    }

    static func read(_ path: URL) throws -> Data? {
        do { return try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
