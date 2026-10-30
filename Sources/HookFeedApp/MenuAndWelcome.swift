import AppKit
import HookFeedCore
import SwiftUI

struct MenuInboxView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private var attention: [MessageThread] { Array(model.threads.filter(\.isAttention).prefix(5)) }
    private var recent: [MessageThread] {
        let shown = Set(attention.map(\.id))
        return Array(model.threads.filter { !shown.contains($0.id) }.prefix(10 - attention.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("HookFeed", systemImage: "tray").font(.headline)
                Spacer()
                Text("\(model.unreadCount) unread").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if let error = model.storageError {
                Text("Inbox unavailable: \(error)").font(.caption).foregroundStyle(.secondary).padding(16)
            } else if model.threads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your agents' updates will appear here.").font(.callout).foregroundStyle(.secondary)
                    Button("Send test message") { model.sendTestMessage() }
                }.frame(maxWidth: .infinity).padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !attention.isEmpty {
                            Text("NEEDS ATTENTION").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12).padding(.horizontal, 10)
                            ForEach(attention) { thread in menuRow(thread) }
                        }
                        if !recent.isEmpty {
                            Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12).padding(.horizontal, 10)
                            ForEach(recent) { thread in menuRow(thread) }
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 10)
                }.frame(maxHeight: 490)
            }
            Divider()
            HStack {
                Button("Open Inbox") { openInbox() }.buttonStyle(.borderedProminent)
                Button("Mark Inbox Read") { model.markEntireInboxRead() }.disabled(model.unreadCount == 0)
                Spacer(minLength: 0)
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }.controlSize(.small).padding(12)
        }
        .frame(width: 420)
        .onAppear { model.refresh() }
    }

    private func menuRow(_ thread: MessageThread) -> some View {
        MenuThreadRow(thread: thread, model: model, highlighted: thread.id == attention.first?.id) {
            model.navigate(to: thread.id)
            openInbox()
        }
    }
    private func openInbox() {
        if !AppNavigation.activateExistingInbox() { openWindow(id: "inbox") }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuThreadRow: View {
    let thread: MessageThread
    @ObservedObject var model: InboxModel
    var highlighted = false
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                ThreadRow(thread: thread, compact: true).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if hovering && thread.isAttention {
                if thread.latest.existingDirectory != nil {
                    Button { model.reveal(thread.latest) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
                }
                if thread.latest.resumeCommand != nil {
                    Button { model.copyResume(thread.latest) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy resume command").accessibilityLabel("Copy resume command")
                }
            }
        }
        .padding(.horizontal, 8)
        .background(hovering ? Color.accentColor.opacity(0.1) : (highlighted ? Color.orange.opacity(0.08) : .clear), in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.openSettings) private var openSettings
    let finish: () -> Void
    @State private var sentTest = false
    @StateObject private var connectAll = ConnectAllModel()
    @State private var showingConnectAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "tray.full").font(.system(size: 38)).foregroundStyle(.tint)
                Text("Your agents. One inbox.").font(.largeTitle.bold())
                Text("Keep up with your agents and scripts, then get back to the work that needs you.")
                    .foregroundStyle(.secondary)
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
            }
            VStack(spacing: 20) {
                checklist("Inbox ready", detail: model.storageError == nil ? "Private, durable storage on this Mac." : "The inbox needs attention. Open it to see the storage error.", done: model.storageError == nil) { EmptyView() }
                checklist("Enable notifications", detail: "Get a quiet banner when an update arrives.", done: model.authorizationStatus == .authorized || model.authorizationStatus == .provisional) {
                    if model.authorizationStatus == .notDetermined {
                        Button("Enable notifications") { model.enableNotifications() }
                    } else { Text(model.permissionLabel).font(.caption).foregroundStyle(.secondary) }
                }
                checklist("Connect an agent", detail: "Copy a hook or MCP configuration.", done: model.messages.contains { (Integration.all.map(\.id) + ["mcp"]).contains($0.source) }) {
                    if !connectAll.items.isEmpty {
                        Button("Connect detected agents…") { showingConnectAll = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Integrations…") { model.settingsTab = .integrations; openSettings() }
                    }
                }
                checklist("Send a test message", detail: "See your first update in the inbox.", done: sentTest) {
                    Button(sentTest ? "Send another" : "Send test message") { model.sendTestMessage(); sentTest = model.storageError == nil && model.actionError == nil }
                }
            }
            Divider()
            HStack {
                Text("Free. Local. No account or API key.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Inbox", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 570)
            .task { await connectAll.refresh() }
            .sheet(isPresented: $showingConnectAll, onDismiss: { Task { await connectAll.refresh() } }) { ConnectAllSheet(model: connectAll) }
    }

    private func checklist<Content: View>(_ title: String, detail: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            content()
        }
    }
}
