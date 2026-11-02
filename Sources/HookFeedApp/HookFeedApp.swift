import AppKit
import SwiftUI
import HookFeedCore

@main
struct HookFeedApp: App {
    @NSApplicationDelegateAdaptor(HookFeedAppDelegate.self) private var delegate
    @StateObject private var model = InboxModel.shared
    @StateObject private var updates = AppUpdater()

    var body: some Scene {
        WindowGroup("HookFeed", id: "inbox") {
            InboxView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1260, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Inbox") { AppNavigation.openInbox() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Inbox") {
                Button("Find Updates") { model.searchRequested.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Mark Visible Read") { model.markAllRead() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Toggle Unread") { model.toggleSelectedUnread() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.selectedThread == nil)
                Button("Delete Thread…") { model.requestDeleteSelected() }
                    .disabled(model.selectedThread == nil)
                Divider()
                Button("Open in Editor") { model.openEditor() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.selectedThread?.latest.existingDirectory == nil)
                Button("Copy Resume Command") { model.copyResume() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selectedThread?.latest.resumeCommand == nil)
                Button("Copy Command") { model.copyCommand() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.selectedThread?.latest.canCopyCommand != true)
                Divider()
                Button("Needs Attention") { model.filter = .attention }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Unread") { model.filter = .unread }
                    .keyboardShortcut("2", modifiers: .command)
                Button("All Updates") { model.filter = .all }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuInboxView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "tray")
                if model.badgeCount > 0 {
                    Text(model.badgeCount > 99 ? "99+" : "\(model.badgeCount)")
                } else if model.unreadCount > 0 {
                    Text("•")
                }
            }
            .accessibilityLabel("HookFeed, \(model.attentionCount) need attention, \(model.unreadCount) unread")
        }
        .menuBarExtraStyle(.window)

        Settings {
            HookFeedSettings(model: model)
                .environmentObject(updates)
        }
    }
}

@MainActor
final class HookFeedAppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: RemoteFileLock?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchTask = Task { @MainActor in
            let path = SingleInstance.lockPath
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                instanceLock = try await RemoteFileLock.acquire(path: path, timeout: 3)
                try Task.checkCancellation()
                DistributedNotificationCenter.default().addObserver(self, selector: #selector(openInbox), name: SingleInstance.openInbox, object: path)
                RemoteAccessModel.shared.activate()
                DockVisibility.apply()
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError { }
            catch {
                if let error = error as? POSIXError, error.code == .EWOULDBLOCK {
                    DistributedNotificationCenter.default().postNotificationName(SingleInstance.openInbox, object: path, userInfo: nil, deliverImmediately: true)
                    if let bundleID = Bundle.main.bundleIdentifier {
                        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        let pid = SingleInstance.existingPID(in: running.map { ($0.processIdentifier, $0.isTerminated) }, current: ProcessInfo.processInfo.processIdentifier)
                        running.first { $0.processIdentifier == pid }?.activate(options: [.activateAllWindows])
                    }
                } else { NSLog("Could not acquire HookFeed instance lock: %@", error.localizedDescription) }
                NSApp.terminate(nil)
            }
        }
    }

    @objc func openInbox(_ notification: Notification) { AppNavigation.openInbox() }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        if instanceLock != nil { RemoteAccessModel.shared.stop() }
        instanceLock = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppNavigation.openInbox() }
        return true
    }
}

enum SingleInstance {
    static let openInbox = Notification.Name("app.hookfeed.open-inbox")
    static var lockPath: String { InboxStore.defaultPath + ".app-instance.lock" }

    static func existingPID(in running: [(pid: Int32, terminated: Bool)], current: Int32) -> Int32? {
        running.first { $0.pid != current && !$0.terminated }?.pid
    }
}

enum DockVisibility {
    static let key = "showInDock"

    static func activationPolicy(defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        defaults.object(forKey: key) as? Bool == false ? .accessory : .regular
    }

    @MainActor
    static func apply(defaults: UserDefaults = .standard) {
        let policy = activationPolicy(defaults: defaults)
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        let keyWindow = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        if wasActive {
            NSApp.activate(ignoringOtherApps: true)
            keyWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
enum AppNavigation {
    static var showInbox: (() -> Void)?
    static func openInbox() {
        if !activateExistingInbox() { showInbox?() }
        NSApp.activate(ignoringOtherApps: true)
    }
    static func activateExistingInbox() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("inbox-") == true }) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
