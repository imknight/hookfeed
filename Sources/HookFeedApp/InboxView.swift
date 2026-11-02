import AppKit
import HookFeedCore
import SwiftUI

struct InboxView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var showWelcome = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } content: {
            InboxThreadList(model: model, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            if let error = model.storageError {
                StorageErrorView(model: model, error: error)
            } else if let thread = model.selectedThread {
                ThreadDetail(model: model, thread: thread)
            } else {
                ContentUnavailableView {
                    Label("Your agents. One inbox.", systemImage: "tray")
                } description: {
                    Text(model.threads.isEmpty ? "Connect an agent or send a test message to get started." : "Select a thread to see its updates and get back to work.")
                }
            }
        }
        .navigationTitle("HookFeed")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.settingsTab = .integrations; openSettings() } label: { Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted") }
                    .labelStyle(.titleAndIcon)
                    .help("Connect an agent")
            }
        }
        .onAppear {
            AppNavigation.showInbox = { openWindow(id: "inbox") }
            showWelcome = !onboardingComplete
        }
        .onChange(of: model.searchRequested) { _, _ in searchFocused = true }
        .sheet(isPresented: $showWelcome) {
            WelcomeView(model: model) {
                onboardingComplete = true
                showWelcome = false
            }
        }
        .alert("Delete this thread?", isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
            Button("Delete thread", role: .destructive) { if let id = model.pendingDelete { model.deleteThread(id) } }
        } message: {
            Text("All updates in this thread will be permanently removed from your inbox.")
        }
        .alert("HookFeed", isPresented: Binding(get: { model.actionError != nil && !showWelcome }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
    }

    var sidebar: some View {
        List(selection: Binding<InboxFilter?>(get: { model.filter }, set: { if let value = $0 { model.filter = value } })) {
            Section {
                SidebarRow(title: "Needs attention", symbol: "exclamationmark.triangle", count: model.attentionCount, emphasized: true).tag(InboxFilter.attention)
                SidebarRow(title: "Unread", symbol: "circle.fill", count: model.unreadCount).tag(InboxFilter.unread)
                SidebarRow(title: "All", symbol: "tray", count: model.threads.count).tag(InboxFilter.all)
            }
            if !model.projects.isEmpty {
                Section("Projects") {
                    ForEach(model.projects, id: \.self) { project in
                        SidebarRow(title: project, symbol: "folder", count: model.projectUnreadCount(project))
                            .tag(InboxFilter.project(project))
                            .contextMenu {
                                if model.projects.count > 1 {
                                    Menu("Merge into…") {
                                        ForEach(model.projects.filter { $0 != project }, id: \.self) { target in
                                            Button(target) { model.mergeProject(project, into: target) }
                                        }
                                    }
                                }
                            }
                    }
                }
            }
            if !model.bots.isEmpty {
                Section("Bots") {
                    ForEach(model.bots, id: \.self) { bot in
                        SidebarRow(title: bot, symbol: "person.crop.circle", count: model.threads.filter { $0.isUnread && $0.messages.contains { $0.bot == bot } }.count)
                            .tag(InboxFilter.bot(bot))
                    }
                }
            }
            if !model.sources.isEmpty {
                Section("Sources") {
                    ForEach(model.sources, id: \.self) { source in
                        SidebarRow(title: source, symbol: "chevron.left.forwardslash.chevron.right", count: model.threads.filter { $0.isUnread && $0.messages.contains { $0.source == source } }.count, monospace: true)
                            .tag(InboxFilter.source(source))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text("Stored on this Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
            }.padding(12)
        }
    }

}

struct InboxThreadList: View {
    @ObservedObject var model: InboxModel
    @FocusState.Binding var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.filter.title).font(.title2.bold())
                    Spacer()
                    let visibleUnread = model.filteredThreads.filter(\.isUnread).count
                    Text("\(visibleUnread) unread").font(.caption).foregroundStyle(.secondary)
                    if visibleUnread > 0 {
                        Button("Mark visible read") { model.markAllRead() }.font(.caption)
                            .help("Mark all threads matching this view and search read")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search title, body, bot, project, source", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search updates")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }.padding(16)
            Divider()
            if model.storageError != nil {
                ContentUnavailableView("Inbox unavailable", systemImage: "exclamationmark.triangle", description: Text("Check the storage error for details."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredThreads.isEmpty {
                // Fill the column so the header stays at the top.
                emptyList.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    ForEach(model.filteredThreads) { thread in
                        ThreadRow(thread: thread)
                            .tag(thread.id)
                            .contextMenu {
                                Button(thread.isUnread ? "Mark read" : "Mark unread") {
                                    if thread.isUnread { model.select(thread.id) }
                                    else { model.markUnread(thread.id) }
                                }
                                if thread.latest.existingDirectory != nil {
                                    Button("Reveal in Finder") { model.reveal(thread.latest) }
                                }
                                if thread.latest.resumeCommand != nil {
                                    Button("Copy resume command") { model.copyResume(thread.latest) }
                                }
                                if thread.latest.canCopyCommand {
                                    Button("Copy command") { model.copyCommand(thread.latest) }
                                }
                                Divider()
                                Button("Delete thread…", role: .destructive) {
                                    model.requestDelete(thread.id)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .onDeleteCommand { model.requestDeleteSelected() }
            }
        }
    }

    @ViewBuilder private var emptyList: some View {
        if !model.query.isEmpty {
            ContentUnavailableView {
                Label("No matching updates", systemImage: "magnifyingglass")
            } description: { Text("Nothing matches “\(model.query)”.") }
            actions: { Button("Clear search") { model.query = "" } }
        } else if model.filter == .attention {
            ContentUnavailableView("Nothing needs you right now", systemImage: "checkmark.circle")
        } else if model.filter == .unread {
            ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle")
        } else if model.threads.isEmpty {
            ContentUnavailableView {
                Label("Your agents' updates will appear here", systemImage: "tray")
            } description: {
                Text("hookfeed send \"Hello from HookFeed\"").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } actions: {
                Button("Send test message") { model.sendTestMessage() }.buttonStyle(.borderedProminent)
                Button("Integrations…") { model.settingsTab = .integrations; openSettings() }
            }
        } else {
            ContentUnavailableView("No updates here yet", systemImage: "tray")
        }
    }
}

struct SidebarRow: View {
    var title: String
    var symbol: String
    var count: Int
    var emphasized = false
    var monospace = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(emphasized ? Color.orange : Color.secondary)
                .font(symbol == "circle.fill" ? .system(size: 7) : .body)
            Text(title).font(monospace ? .system(.body, design: .monospaced) : .body).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.caption.monospacedDigit())
                    // Dark text on orange keeps the badge above 4.5:1; white measured about 2:1.
                    .foregroundStyle(emphasized ? Color.black.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, emphasized ? 6 : 0).padding(.vertical, emphasized ? 2 : 0)
                    .background(emphasized ? Color.orange : .clear, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ThreadRow: View {
    let thread: MessageThread
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(thread.isUnread ? Color.accentColor : .clear).frame(width: 6, height: 6).padding(.top, 7)
            Image(systemName: thread.kind.symbol).font(.system(size: 17)).foregroundStyle(thread.kind.color).frame(width: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.latest.displayTitle).fontWeight(thread.isUnread ? .semibold : .regular).lineLimit(compact ? 2 : 1)
                    Spacer(minLength: 4)
                    RelativeTimestamp(date: thread.latest.receivedAt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    Text(thread.latest.context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if thread.updateCount > 1 {
                        Text("\(thread.updateCount) updates").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .frame(height: compact ? nil : 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.kind.label): \(thread.latest.displayTitle), \(thread.latest.context), \(thread.latest.receivedAt.formatted(date: .abbreviated, time: .shortened)), \(thread.isUnread ? "unread" : "read"), \(thread.updateCount) updates")
    }
}

struct RelativeTimestamp: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(at: context.date))
                .help(date.formatted(date: .complete, time: .standard))
        }
    }
    private func label(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct ThreadDetail: View {
    @ObservedObject var model: InboxModel
    let thread: MessageThread

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    Divider()
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(thread.messages) { message in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: message.kind.symbol)
                                    .font(.system(size: 18)).foregroundStyle(message.kind.color)
                                    .frame(width: 20)
                                    .accessibilityLabel(message.kind.label)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        if message.id != thread.latest.id || message.displayTitle != thread.latest.displayTitle {
                                            Text(message.displayTitle).fontWeight(.semibold).textSelection(.enabled)
                                            Spacer(minLength: 8)
                                        }
                                        Text(message.receivedAt, format: .dateTime.year().month().day().hour().minute().second())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if case let blocks = model.bodyBlocks(for: message), !blocks.isEmpty {
                                        MarkdownBody(blocks: blocks).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(14)
                                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .background(alignment: .topLeading) {
                                // The rail joins this update's symbol to the next (older) one.
                                if message.id != thread.messages.last?.id {
                                    Rectangle().fill(.quaternary).frame(width: 1)
                                        .padding(.top, 26).padding(.bottom, -22).padding(.leading, 9.5)
                                }
                            }
                            .contextMenu {
                                Button("Copy message") { Clipboard.copy([message.title, message.body].compactMap { $0 }.joined(separator: "\n\n")) }
                                Button("Delete update", role: .destructive) { model.deleteMessage(message.id) }
                            }
                        }
                    }
                }.padding(26)
            }
            Divider()
            HStack {
                Text("Received \(thread.latest.receivedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(thread.isUnread ? "Mark read" : "Mark unread") {
                    if thread.isUnread { model.select(thread.id) } else { model.markUnread(thread.id) }
                }
                // Bordered macOS buttons ignore role styling, so the label carries the red.
                Button(role: .destructive) { model.requestDeleteSelected() } label: { Text("Delete thread…").foregroundStyle(.red) }
            }.padding(16)
        }
        .id(thread.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(thread.kind.label, systemImage: thread.kind.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(thread.kind.color)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(thread.kind.color.opacity(0.1), in: Capsule())
                Text("\(thread.latest.context) · \(thread.updateCount) \(thread.updateCount == 1 ? "update" : "updates")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(thread.latest.displayTitle).font(.title2.bold()).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
            if let folder = thread.latest.workdir {
                contextLine("Folder", value: folder)
                if thread.latest.existingDirectory == nil {
                    Label("Folder not found", systemImage: "folder.badge.questionmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let resume = thread.latest.resumeCommand { contextLine("Resume", value: resume) }
            if let url = thread.latest.url { contextLine("Link", value: url) }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        // A failed run with no folder still gets a way back to the work.
        if thread.latest.existingDirectory == nil { copyCommandButton }
        if thread.latest.existingDirectory != nil {
            if model.editorURL != nil {
                Button { model.openEditor() } label: { Label("Open in \(model.editorName)", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .buttonStyle(.borderedProminent)
            }
            Button { model.reveal() } label: { Label("Reveal in Finder", systemImage: "folder") }
        }
        if thread.latest.resumeCommand != nil {
            Button { model.copyResume() } label: { Label(model.resumeCopied ? "Copied" : "Copy resume command", systemImage: model.resumeCopied ? "checkmark" : "doc.on.doc") }
        }
        if thread.latest.url != nil {
            Button { model.openSource(thread.latest) } label: { Label("Open source", systemImage: "arrow.up.right.square") }
        }
        if thread.latest.existingDirectory != nil { copyCommandButton }
    }
    @ViewBuilder private var copyCommandButton: some View {
        if thread.latest.canCopyCommand {
            Button { model.copyCommand() } label: { Label(model.commandCopied ? "Copied" : "Copy command", systemImage: model.commandCopied ? "checkmark" : "terminal") }
        }
        if thread.latest.isCommandTruncated {
            Label("Command truncated…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func contextLine(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.font(.caption)
    }
}

struct StorageErrorView: View {
    @ObservedObject var model: InboxModel
    let error: String
    var body: some View {
        ContentUnavailableView {
            Label("HookFeed can't open its inbox", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(StorageFailure.summary(for: error))
            Text(model.storePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            DisclosureGroup("Details") {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: 420, alignment: .leading)
            }.frame(maxWidth: 420)
        } actions: {
            Button("Try again") { model.reopenStore() }.buttonStyle(.borderedProminent)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.storePath).deletingLastPathComponent()]) }
        }
    }
}
