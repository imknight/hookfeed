import Foundation

public enum StorageFailure {
    /// A plain-language cause for a storage error; the raw text stays available as details.
    public static func summary(for error: String) -> String {
        func has(_ pattern: String) -> Bool {
            error.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if has(#"\berror 26\b|not a database"#) { return "The inbox file isn't a readable HookFeed database." }
        if has(#"\berror 23\b|authorization denied|permission denied"#) { return "HookFeed doesn't have permission to open the inbox file." }
        if has(#"\berror 5\b|database is locked"#) { return "The inbox file is locked by another process." }
        return "HookFeed couldn't read the inbox file."
    }
}
