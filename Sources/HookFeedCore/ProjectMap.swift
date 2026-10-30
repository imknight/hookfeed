import Foundation

public struct ProjectMap {
    private var aliases: [String: String]
    private var names: [String: String] = [:]
    public private(set) var projects: [String]

    public init(projects: [String] = [], aliases: [String: String] = [:]) {
        self.aliases = [:]
        self.projects = []
        for key in aliases.keys.sorted() { self.aliases[Self.normalize(key)] = aliases[key] }
        for project in projects.sorted() {
            let key = key(for: project)
            if names[key] == nil { names[key] = resolved(project).name }
        }
        for target in aliases.values.sorted() where self.aliases[Self.normalize(target)] == nil {
            if names[key(for: target)] != nil { names[key(for: target)] = target }
        }
        self.projects = names.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func normalize(_ name: String) -> String {
        let lower = name.lowercased()
        let key = lower.filter { $0 != " " && $0 != "-" && $0 != "_" }
        return key.isEmpty ? lower : key
    }

    public func key(for name: String) -> String { resolved(name).key }
    public func name(for name: String) -> String { names[key(for: name)] ?? resolved(name).name }

    private func resolved(_ name: String) -> (key: String, name: String) {
        var current = name
        var visited: [String] = []
        while true {
            let key = Self.normalize(current)
            if let start = visited.firstIndex(of: key) {
                let root = visited[start...].min()!
                return (root, root)
            }
            visited.append(key)
            guard let next = aliases[key] else { return (key, current) }
            current = next
        }
    }
}
