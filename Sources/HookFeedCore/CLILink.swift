import Darwin
import Foundation

public enum CLILinkState: Equatable {
    case missing, linked, linkedElsewhere(String), blockedByFile
}

public enum CLILink {
    public static func state(at link: URL, target: URL) -> CLILinkState {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return resolved == target.standardizedFileURL ? .linked : .linkedElsewhere(resolved.path)
        }
        return FileManager.default.fileExists(atPath: link.path) ? .blockedByFile : .missing
    }

    public static func install(at link: URL, target: URL, replacing: Bool) throws {
        let current = state(at: link, target: target)
        if current == .linked { return }
        guard current == .missing || replacing else {
            throw HookFeedError.invalidInput(field: "command path", reason: "An existing command occupies \(link.path). Choose Replace to replace it.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !replacing {
            try manager.createSymbolicLink(at: link, withDestinationURL: target)
            return
        }
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".hookfeed-" + UUID().uuidString)
        try manager.createSymbolicLink(at: temporary, withDestinationURL: target)
        defer { try? manager.removeItem(at: temporary) }
        // Atomic replacement preserves the existing command if installation fails.
        guard rename(temporary.path, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func uninstall(at link: URL, target: URL) throws {
        if state(at: link, target: target) == .linked { try FileManager.default.removeItem(at: link) }
    }

    public static func userDirectory(home: URL) -> URL { home.appendingPathComponent(".local/bin") }

    public static func isOnPath(_ directory: URL, path: String) -> Bool {
        path.split(separator: ":").contains {
            URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath).standardizedFileURL == directory.standardizedFileURL
        }
    }
}
