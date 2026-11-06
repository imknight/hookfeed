import Foundation

public enum HookAgent: String, CaseIterable, Sendable {
    case claudeCode = "claude-code", codex, antigravity, cursor

    public var relativeConfigPath: String {
        switch self {
        case .claudeCode: return ".claude/settings.json"
        case .codex: return ".codex/hooks.json"
        case .antigravity: return ".gemini/config/hooks.json"
        case .cursor: return ".cursor/hooks.json"
        }
    }
}

public enum HookConfiguration {
    public static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError("The configuration must be a JSON object. No changes were made.")
        }
        return object
    }

    public static func merge(_ original: [String: Any], agent: HookAgent, command: String, removing: Bool = false) throws -> [String: Any] {
        if agent == .antigravity {
            return try mergeAntigravity(original, command: command, removing: removing)
        }
        var result = original
        guard original["hooks"] == nil || original["hooks"] is [String: Any] else {
            throw ConfigurationError("The hooks value must be a JSON object. No changes were made.")
        }
        var events = original["hooks"] as? [String: Any] ?? [:]
        if agent == .cursor, !removing {
            guard original["version"] == nil || (original["version"] as? Int) == 1 else {
                throw ConfigurationError("Unsupported Cursor hooks version. No changes were made.")
            }
            result["version"] = 1
        }
        for (event, matcher) in agent.hookEvents {
            guard events[event] == nil || events[event] is [[String: Any]] else {
                throw ConfigurationError("The \(event) hooks must be an array of objects. No changes were made.")
            }
            var groups = events[event] as? [[String: Any]] ?? []
            if agent == .cursor {
                let found = groups.contains { owns($0, agent: agent, installedCommand: command) }
                groups = groups.compactMap { entry in
                    guard owns(entry, agent: agent, installedCommand: command) else { return entry }
                    if removing { return nil }
                    var updated = entry
                    updated["command"] = command
                    return updated
                }
                if !removing, !found { groups.append(["command": command]) }
                if !groups.isEmpty { events[event] = groups }
                else { events.removeValue(forKey: event) }
                continue
            }
            var found = false
            groups = try groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    throw ConfigurationError("Each \(event) group must contain a hooks array. No changes were made.")
                }
                let owned = entries.filter { owns($0, agent: agent, installedCommand: command) }
                if (group["matcher"] as? String ?? "") == matcher, !owned.isEmpty { found = true }
                guard !owned.isEmpty else { return group }
                if !removing {
                    var updated = group
                    updated["hooks"] = entries.map { entry in
                        guard owns(entry, agent: agent, installedCommand: command) else { return entry }
                        var updated = entry
                        updated["command"] = command
                        return updated
                    }
                    return updated
                }
                var kept = group
                let remaining = entries.filter { !owns($0, agent: agent, installedCommand: command) }
                if remaining.isEmpty, Set(group.keys).isSubset(of: ["hooks", "matcher"]) { return nil }
                kept["hooks"] = remaining
                return kept
            }
            if !removing, !found {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 1]]]
                if !matcher.isEmpty { group["matcher"] = matcher }
                groups.append(group)
            }
            if !groups.isEmpty { events[event] = groups }
            else if events[event] != nil { events.removeValue(forKey: event) }
        }
        if !events.isEmpty { result["hooks"] = events }
        else if original["hooks"] != nil { result["hooks"] = events }
        return result
    }

    private static func mergeAntigravity(_ original: [String: Any], command: String, removing: Bool) throws -> [String: Any] {
        var result = removingRetiredHooks(original)
        guard original["hookfeed"] == nil || original["hookfeed"] is [String: Any] else {
            throw ConfigurationError("The hookfeed definition must be a JSON object. No changes were made.")
        }
        var definition = result["hookfeed"] as? [String: Any] ?? [:]
        guard definition["Stop"] == nil || definition["Stop"] is [[String: Any]] else {
            throw ConfigurationError("The Stop hooks must be an array of objects. No changes were made.")
        }
        var entries = definition["Stop"] as? [[String: Any]] ?? []
        entries.removeAll { owns($0, agent: .antigravity, installedCommand: command) }
        if !removing {
            entries.append(["type": "command", "command": command, "timeout": 1])
            definition["enabled"] = true
        }
        if entries.isEmpty { definition.removeValue(forKey: "Stop") }
        else { definition["Stop"] = entries }
        if removing, Set(definition.keys).isSubset(of: ["enabled"]) { result.removeValue(forKey: "hookfeed") }
        else if !definition.isEmpty { result["hookfeed"] = definition }
        return result
    }

    private static func removingRetiredHooks(_ original: [String: Any]) -> [String: Any] {
        var result = original
        for (name, value) in original {
            guard var definition = value as? [String: Any] else { continue }
            var changed = false
            for (event, value) in definition {
                guard let entries = value as? [[String: Any]] else { continue }
                let remaining = entries.compactMap { entry -> [String: Any]? in
                    if let command = entry["command"] as? String,
                       (entry["type"] == nil || entry["type"] as? String == "command"),
                       matchesHookCommand(command, agent: "gemini-cli") { return nil }
                    guard let hooks = entry["hooks"] as? [[String: Any]] else { return entry }
                    let kept = hooks.filter { hook in
                        guard let command = hook["command"] as? String,
                              hook["type"] == nil || hook["type"] as? String == "command" else { return true }
                        return !matchesHookCommand(command, agent: "gemini-cli")
                    }
                    guard kept.count != hooks.count else { return entry }
                    if kept.isEmpty, Set(entry.keys).isSubset(of: ["hooks", "matcher"]) { return nil }
                    var updated = entry
                    updated["hooks"] = kept
                    return updated
                }
                guard (remaining as NSArray) != (entries as NSArray) else { continue }
                changed = true
                if remaining.isEmpty { definition.removeValue(forKey: event) }
                else { definition[event] = remaining }
            }
            if changed, Set(definition.keys).isSubset(of: ["enabled"]) { result.removeValue(forKey: name) }
            else { result[name] = definition }
        }
        return result
    }

    private static func owns(_ entry: [String: Any], agent: HookAgent, installedCommand: String) -> Bool {
        guard (entry["type"] as? String == "command" || ((agent == .antigravity || agent == .cursor) && entry["type"] == nil)), let command = entry["command"] as? String else { return false }
        if command == installedCommand { return true }
        return matchesHookCommand(command, agent: agent.rawValue)
    }

    private static func matchesHookCommand(_ command: String, agent: String) -> Bool {
        let executable = #"(?:'(?:[^']|'\\'')*/hookfeed'|"[^"]*/hookfeed"|[^\s'";|&]+/hookfeed|hookfeed)"#
        return command.range(of: "^" + executable + "\\s+hook\\s+" + agent + "\\s*$", options: .regularExpression) != nil
    }
}

public struct ConfigurationError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
