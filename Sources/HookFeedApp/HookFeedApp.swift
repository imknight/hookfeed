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

final class HookFeedAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let pid = SingleInstance.existingPID(in: running.map(\.processIdentifier), current: ProcessInfo.processInfo.processIdentifier),
               let existing = running.first(where: { $0.processIdentifier == pid }) {
                existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }
        }
        RemoteAccessModel.shared.activate()
        DockVisibility.apply()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { RemoteAccessModel.shared.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppNavigation.openInbox() }
        return true
    }
}

enum SingleInstance {
    static func existingPID(in running: [Int32], current: Int32) -> Int32? {
        running.first { $0 != current }
    }
}

enum DockVisibility {
    static let key = "showInDock"

    static func activationPolicy(defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        defaults.object(forKey: key) as? Bool == false ? .accessory : .regular
    }

    @MainActor
    static func apply(defaults: UserDefaults = .standard) {
        NSApp.setActivationPolicy(activationPolicy(defaults: defaults))
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
