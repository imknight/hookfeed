import HookFeedCore
import UserNotifications

enum NotificationActions {
    static let copyResume = "hookfeed.copy-resume"
    static let openFolder = "hookfeed.open-folder"
    static let markRead = "hookfeed.mark-read"

    static func category(for message: Message) -> String {
        identifier(resume: message.resumeCommand != nil, folder: message.existingDirectory != nil)
    }

    static var categories: Set<UNNotificationCategory> {
        var result = Set<UNNotificationCategory>()
        for resume in [false, true] {
            for folder in [false, true] {
                var actions: [UNNotificationAction] = []
                if resume { actions.append(UNNotificationAction(identifier: copyResume, title: "Copy resume command")) }
                if folder { actions.append(UNNotificationAction(identifier: openFolder, title: "Open in editor/folder", options: .foreground)) }
                actions.append(UNNotificationAction(identifier: markRead, title: "Mark read"))
                result.insert(UNNotificationCategory(identifier: identifier(resume: resume, folder: folder), actions: actions, intentIdentifiers: []))
            }
        }
        return result
    }

    private static func identifier(resume: Bool, folder: Bool) -> String {
        "hookfeed.actions.\(resume ? 1 : 0).\(folder ? 1 : 0)"
    }
}
