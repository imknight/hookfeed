import Foundation

public struct Detection: Equatable, Sendable {
    public let configDirectory: Bool
    public let executable: URL?
    public var application: Bool = false
    public var found: Bool { configDirectory || executable != nil || application }
}

public enum IntegrationDetection {
    public static let fallbackDirectories = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    public static func detect(_ integration: Integration, home: URL, searchPath: String, fileManager: FileManager = .default,
                              fallbackDirectories: [String] = fallbackDirectories, applicationDirectories: [String] = ["/Applications", "~/Applications"]) -> Detection {
        var isDirectory: ObjCBool = false
        var hasConfig = integration.configDirectory.map { fileManager.fileExists(atPath: home.appendingPathComponent($0).path, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
        if integration.id == "gemini-cli" {
            hasConfig = (try? home.appendingPathComponent(".gemini/settings.json").resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let directories = searchPath.components(separatedBy: ":") + fallbackDirectories.map {
            $0.hasPrefix("~/") ? home.appendingPathComponent(String($0.dropFirst(2))).path : $0
        }
        let executable = directories.flatMap { directory in
            ([integration.executable] + integration.alternateExecutables).map { (directory, $0) }
        }.filter { $0.0.hasPrefix("/") }.lazy.compactMap { directory, name -> URL? in
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: url.path),
                  (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }.first
        let application = integration.applicationName.map { name in
            applicationDirectories.contains { directory in
                let root = directory.hasPrefix("~/") ? home.appendingPathComponent(String(directory.dropFirst(2))).path : directory
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        } ?? false
        return Detection(configDirectory: hasConfig, executable: executable, application: application)
    }
}
