import AppKit
import Combine
import Darwin
import HookFeedCore
import SwiftUI
import UserNotifications

// notify.h is not exported by the Swift Darwin module.
@_silgen_name("notify_register_dispatch")
private func registerInboxSignal(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>, _ queue: DispatchQueue, _ handler: @escaping @convention(block) (Int32) -> Void) -> UInt32

typealias InboxFilter = ThreadScope

extension ThreadScope {
    var title: String {
        switch self {
        case .attention: return "Needs attention"
        case .unread: return "Unread"
        case .all: return "All"
        case .project(let name), .source(let name), .bot(let name): return name
        }
    }
}

enum SettingsTab: Hashable { case general, integrations, remote, storage }
enum NotificationMode: String, CaseIterable {
    case all = "All updates", attention = "Attention only", off = "Off"
}
enum BadgeMode: String, CaseIterable { case attention = "Attention only", all = "All unread" }

@MainActor
final class InboxModel: ObservableObject {
    static let shared = InboxModel()
    @Published private(set) var messages: [Message] = []
    @Published private(set) var projectAliases: [String: String] = [:]
    @Published private(set) var threads: [MessageThread] = []
    @Published var filter: InboxFilter = .all { didSet { if oldValue != filter { scopeChanged() } } }
    @Published var query = "" { didSet { if oldValue != query { scopeChanged() } } }
    @Published var selection: String?
    @Published var storageError: String?
    @Published var actionError: String?
    @Published var pendingDelete: String?
    @Published var searchRequested = false
    @Published var settingsTab: SettingsTab = .general
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var resumeCopied = false
    @Published var commandCopied = false
    @Published var notificationMode: NotificationMode {
        didSet { UserDefaults.standard.set(notificationMode.rawValue, forKey: "notificationMode") }
    }
    @Published var badgeMode: BadgeMode {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: "badgeMode") }
    }
    @Published var editorBundleID: String {
        didSet { UserDefaults.standard.set(editorBundleID, forKey: "editorBundleID") }
    }
    @Published var customEditorPath: String {
        didSet { UserDefaults.standard.set(customEditorPath, forKey: "customEditorPath") }
    }
    /// The opened thread stays visible in its filter until the filter or search changes.
    private var pinnedThreadID: String?
    private var parsedBodies: [String: [MarkdownBlock]] = [:]
    private var store: InboxStore?
    private let observesChanges: Bool
    private var cursor: Int64 = 0
    private var observedVersion: Int64?
    private var signalToken: Int32 = 0
    private var registeredSignal = false
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    var refreshCoalesceInterval: TimeInterval = 0.15
    private(set) var refreshCount = 0
    var onFullRead: (() -> Void)?
    var drainSpool: @Sendable (InboxStore) throws -> DrainResult = { store in
        store.path == ":memory:" ? DrainResult() : try Spool(storePath: store.path).drain(into: InboxStore(path: store.path))
    }
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationBatcher = NotificationBatcher()
    private var notificationDelegate: InboxNotificationDelegate?

    init(store: InboxStore? = nil, observesChanges: Bool = true) {
        self.observesChanges = observesChanges
        let defaults = UserDefaults.standard
        notificationMode = NotificationMode(rawValue: defaults.string(forKey: "notificationMode") ?? "") ?? .all
        badgeMode = BadgeMode(rawValue: defaults.string(forKey: "badgeMode") ?? "") ?? .attention
        let installedEditor = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode"]
            .first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        editorBundleID = defaults.string(forKey: "editorBundleID") ?? installedEditor ?? "com.apple.dt.Xcode"
        customEditorPath = defaults.string(forKey: "customEditorPath") ?? ""
        if let store {
            self.store = store
            refresh(skipNotifications: true, force: true)
        }
        guard observesChanges else { return }
        notificationDelegate = InboxNotificationDelegate { [weak self] action, threadID, messageID, completion in
            Task { @MainActor in
                self?.handleNotificationAction(action, threadID: threadID, messageID: messageID)
                completion()
            }
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = notificationDelegate
        notificationCenter.setNotificationCategories(NotificationActions.categories)
        if store == nil { reopenStore() }
        registeredSignal = registerInboxSignal("app.hookfeed.inbox.changed", &signalToken, .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        } == 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
                await self?.updateAuthorization()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(skipNotifications: true, force: true) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                self?.refresh(force: true)
                await self?.updateAuthorization()
            }
        })
        scheduleRefresh()
        Task { await updateAuthorization() }
    }

    var storePath: String { store?.path ?? InboxStore.defaultPath }
    var unreadCount: Int { threads.filter(\.isUnread).count }
    var attentionCount: Int { threads.filter(\.isAttention).count }
    var badgeCount: Int { badgeMode == .attention ? attentionCount : unreadCount }
    var projectMap: ProjectMap { ProjectMap(projects: messages.compactMap(\.project), aliases: projectAliases) }
    var projects: [String] { projectMap.projects }
    func projectUnreadCount(_ project: String) -> Int {
        ThreadQuery.visible(threads, scope: .project(project), search: "", pinned: nil, projects: projectMap).filter(\.isUnread).count
    }
    var bots: [String] { Array(Set(messages.compactMap(\.bot))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var sources: [String] { Array(Set(messages.map(\.source))).sorted() }
    var selectedThread: MessageThread? { threads.first { $0.id == selection } }
    var filteredThreads: [MessageThread] {
        ThreadQuery.visible(threads, scope: filter, search: query, pinned: pinnedThreadID, projects: projectMap)
    }
    var editorName: String {
        switch editorBundleID {
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.microsoft.VSCode": return "VS Code"
        case "dev.zed.Zed": return "Zed"
        case "com.apple.dt.Xcode": return "Xcode"
        default: return customEditorPath.isEmpty ? "Editor" : URL(fileURLWithPath: customEditorPath).deletingPathExtension().lastPathComponent
        }
    }
    var editorURL: URL? {
        if editorBundleID == "custom" {
            guard !customEditorPath.isEmpty, FileManager.default.fileExists(atPath: customEditorPath) else { return nil }
            return URL(fileURLWithPath: customEditorPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID)
    }

    func reopenStore() {
        do {
            store = try InboxStore()
            observedVersion = nil
            cursor = try store?.maxSequence() ?? 0
            refresh(skipNotifications: true, force: true)
            scheduleRefresh()
        } catch { storageError = error.localizedDescription }
    }

    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let interval = self?.refreshCoalesceInterval else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard let store = self.store else { return }
            let drain = self.drainSpool
            do {
                let result = try await Task.detached { try drain(store) }.value
                if result.inserted > 0 { self.observedVersion = nil }
                self.refresh()
            } catch {
                self.refresh()
                self.storageError = error.localizedDescription
            }
        }
    }

    func refresh(skipNotifications: Bool = false, force: Bool = false) {
        guard let store else { return }
        refreshCount += 1
        do {
            if force { objectWillChange.send() }
            // Read the invalidation token before either query. A commit racing
            // these reads will then invalidate the next refresh too.
            let version = try store.changeVersion()
            if !force, !skipNotifications, storageError == nil, observedVersion == version { return }
            let incoming = try store.messages(after: cursor)
            let current: [Message]
            if force {
                onFullRead?()
                current = try store.messages()
            } else {
                let incomingIDs = Set(incoming.map(\.id))
                current = Array(incoming.reversed()) + messages.filter { !incomingIDs.contains($0.id) }
            }
            let aliases = try store.projectAliases()
            if projectAliases != aliases { projectAliases = aliases }
            if current != messages {
                messages = current
                threads = MessageThread.group(current)
                let retained = Set(current.map(\.id))
                parsedBodies = parsedBodies.filter { retained.contains($0.key) }
            }
            // Only acknowledge rows from the incremental read. A row committed
            // between the two queries still needs its banner on the next pass.
            cursor = max(cursor, incoming.last?.seq ?? 0)
            observedVersion = version
            if storageError != nil { storageError = nil }
            if let pinnedThreadID, !threads.contains(where: { $0.id == pinnedThreadID }) { self.pinnedThreadID = nil }
            dropHiddenSelection()
            if observesChanges, !skipNotifications, !incoming.isEmpty {
                Task {
                    await updateAuthorization()
                    postNotifications(incoming)
                }
            }
        } catch { storageError = error.localizedDescription }
    }

    func bodyBlocks(for message: Message) -> [MarkdownBlock] {
        if let blocks = parsedBodies[message.id] { return blocks }
        let blocks = message.bodyBlocks
        parsedBodies[message.id] = blocks
        return blocks
    }

    func select(_ id: String?) {
        pinnedThreadID = id
        selection = id
        guard let id else { return }
        perform { try $0.markThreadRead(id) }
    }

    func navigate(to id: String) {
        filter = .all
        query = ""
        refresh()
        select(id)
    }

    private func scopeChanged() {
        pinnedThreadID = nil
        dropHiddenSelection()
    }
    private func dropHiddenSelection() {
        if let selection, !filteredThreads.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func mergeProject(_ source: String, into target: String) {
        perform { try $0.mergeProject(source, into: target) }
        if actionError == nil { filter = .project(projectMap.name(for: target)) }
    }

    func markAllRead() {
        let visible = filteredThreads.filter(\.isUnread).map(\.id)
        perform { store in
            for id in visible { try store.markThreadRead(id) }
        }
    }
    func markEntireInboxRead() { perform { try $0.markAllRead() } }
    func markUnread(_ id: String) { perform { try $0.markThreadUnread(id) } }
    func toggleSelectedUnread() {
        guard let thread = selectedThread else { return }
        if thread.isUnread { perform { try $0.markThreadRead(thread.id) } }
        else { markUnread(thread.id) }
    }
    func requestDeleteSelected() {
        guard let selection else { return }
        requestDelete(selection)
    }
    func requestDelete(_ id: String) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        if thread.updateCount > 1 { pendingDelete = thread.id }
        else { deleteThread(thread.id) }
    }
    func deleteThread(_ id: String) {
        perform {
            try $0.deleteThread(id)
            if pinnedThreadID == id { pinnedThreadID = nil }
        }
        pendingDelete = nil
    }
    func deleteMessage(_ id: String) { perform { try $0.deleteMessage(id) } }

    func sendTestMessage() {
        perform { store in
            _ = try store.send(MessageDraft(title: "Hello from HookFeed", body: "Your inbox is ready. Connect an agent in Settings → Integrations, or wrap a script with hookfeed run -- <command>.", source: "hookfeed", project: "HookFeed", kind: .completed, threadKey: "hookfeed:welcome"))
        }
        filter = .all
    }

    private func perform(_ operation: (InboxStore) throws -> Void) {
        guard let store else { actionError = storageError ?? "The inbox is unavailable."; return }
        do { try operation(store); refresh(force: true) }
        catch { actionError = error.localizedDescription }
    }

    func reveal(_ message: Message? = nil) {
        guard let directory = (message ?? selectedThread?.latest)?.existingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
    func openEditor(_ message: Message? = nil) {
        guard let directory = (message ?? selectedThread?.latest)?.existingDirectory, let editorURL else { return }
        NSWorkspace.shared.open([directory], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.actionError = error.localizedDescription } }
        }
    }
    func openSource(_ message: Message) {
        guard let raw = message.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func copyResume(_ message: Message? = nil) {
        guard let command = (message ?? selectedThread?.latest)?.resumeCommand else { return }
        Clipboard.copy(command)
        resumeCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            resumeCopied = false
        }
    }

    func copyCommand(_ message: Message? = nil) {
        guard let message = message ?? selectedThread?.latest, message.canCopyCommand, let command = message.recordedCommand else { return }
        Clipboard.copy(command)
        commandCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            commandCopied = false
        }
    }

    func handleNotificationAction(_ action: String, threadID: String?, messageID: String?) {
        refresh()
        let message = messages.first { $0.id == messageID }
        switch action {
        case NotificationActions.copyResume:
            if let message { copyResume(message) }
        case NotificationActions.openFolder:
            if let message {
                if editorURL != nil { openEditor(message) }
                else { reveal(message) }
            }
        case NotificationActions.markRead:
            if let threadID { perform { try $0.markThreadRead(threadID) } }
        case UNNotificationDefaultActionIdentifier:
            if let threadID { navigate(to: threadID) }
            AppNavigation.openInbox()
        default: break
        }
    }

    func updateAuthorization() async {
        let current = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorizationStatus != current { authorizationStatus = current }
    }
    func enableNotifications() {
        Task {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) }
            catch { actionError = error.localizedDescription }
            await updateAuthorization()
        }
    }
    var permissionLabel: String {
        switch authorizationStatus {
        case .authorized: return "Enabled"
        case .denied: return "Denied in System Settings"
        case .notDetermined: return "Not enabled yet"
        case .provisional: return "Delivering quietly"
        default: return "Unavailable"
        }
    }
    private func postNotifications(_ incoming: [Message]) {
        guard notificationMode != .off, authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        let eligible = incoming.filter { notificationMode == .all || $0.kind == .failed || $0.kind == .needsAttention }
        guard let deadline = notificationBatcher.add(eligible, now: Date()) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, let delivery = self.notificationBatcher.flush() else { return }
            self.deliverNotifications(delivery)
        }
    }

    private func deliverNotifications(_ delivery: NotificationBatcher.Delivery) {
        let center = UNUserNotificationCenter.current()
        switch delivery {
        case .summary(let count):
            let content = UNMutableNotificationContent()
            content.title = "\(count) new updates"
            content.subtitle = "HookFeed"
            center.add(UNNotificationRequest(identifier: "hookfeed:burst", content: content, trigger: nil))
        case .perThread(let latest):
            for message in latest {
                let content = UNMutableNotificationContent()
                content.title = message.project.map { "\($0) — \(message.displayTitle)" } ?? message.displayTitle
                content.subtitle = message.source
                content.threadIdentifier = message.threadKey ?? message.id
                content.userInfo = ["threadID": message.threadID, "messageID": message.id]
                content.categoryIdentifier = NotificationActions.category(for: message)
                let identifier = message.threadKey ?? message.id
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            }
        }
    }
}

final class InboxNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let handle: (String, String?, String?, @escaping () -> Void) -> Void
    init(handle: @escaping (String, String?, String?, @escaping () -> Void) -> Void) { self.handle = handle }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        handle(response.actionIdentifier, info["threadID"] as? String, info["messageID"] as? String, completionHandler)
    }
}

enum Clipboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

extension Message {
    var existingDirectory: URL? {
        guard let workdir else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workdir, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: workdir, isDirectory: true)
    }
    var resumeCommand: String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        switch source {
        case "claude-code": return "claude --resume \(ShellText.quote(sessionID))"
        case "codex": return "codex resume \(ShellText.quote(sessionID))"
        default: return nil
        }
    }
    var context: String { [bot, source, project].compactMap { $0 }.joined(separator: " · ") }
    var displayTitle: String { MarkdownText.plainTitle(title) }
}


extension MessageKind {
    var label: String {
        switch self { case .info: return "Info"; case .completed: return "Completed"; case .failed: return "Failed"; case .needsAttention: return "Needs attention" }
    }
    var symbol: String {
        switch self { case .info: return "info.circle"; case .completed: return "checkmark.circle"; case .failed: return "xmark.octagon"; case .needsAttention: return "exclamationmark.triangle" }
    }
    var color: Color {
        switch self { case .info: return .secondary; case .completed: return .green; case .failed: return .red; case .needsAttention: return .orange }
    }
}
