import AppKit
import HookFeedCore
import SwiftUI

struct HookFeedSettings: View {
    @ObservedObject var model: InboxModel
    @EnvironmentObject private var updates: AppUpdater
    @StateObject private var connectAll = ConnectAllModel()
    @State private var showingConnectAll = false
    @State private var installPlan: InstallPlan?
    @State private var commandRunning = false
    @State private var loginPath = ""
    @State private var detectedExecutables: [String: URL] = [:]
    @State private var installedMCP: Integration?
    @State private var installStatus: String?
    @State private var installError: String?
    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.tabItem { Label("General", systemImage: "sun.max") }.tag(SettingsTab.general)
            integrations.tabItem { Label("Integrations", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(SettingsTab.integrations)
            RemoteAccessView(model: RemoteAccessModel.shared).tabItem { Label("Remote", systemImage: "network") }.tag(SettingsTab.remote)
            storage.tabItem { Label("Storage", systemImage: "externaldrive") }.tag(SettingsTab.storage)
        }
        .frame(width: 720, height: 590)
        .task { await model.updateAuthorization() }
        .sheet(isPresented: $showingConnectAll, onDismiss: { Task { await connectAll.refresh() } }) { ConnectAllSheet(model: connectAll) }
        .sheet(item: $installPlan, onDismiss: { Task { await connectAll.refresh() } }) { install in
            switch install {
            case .hooks(let plan):
            VStack(alignment: .leading, spacing: 16) {
                Text(plan.removing ? "Remove HookFeed hooks" : "Install HookFeed hooks").font(.title2.bold())
                Text(plan.path.path).font(.caption.monospaced()).textSelection(.enabled)
                Text(plan.hasChanges ? "Only HookFeed hook entries change. Existing files are backed up beside the original before saving. JSON formatting may change." : "No changes needed.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Before").font(.headline)
                        Text(plan.original.flatMap { String(data: $0, encoding: .utf8) } ?? "File does not exist").font(.caption.monospaced()).textSelection(.enabled)
                        Divider()
                        Text("After").font(.headline)
                        Text(String(decoding: plan.updated, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { installPlan = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(plan.removing ? "Remove" : "Install") {
                        do {
                            let backup = try plan.apply()
                            installStatus = backup.map { "Saved. Backup: \($0.path)" } ?? "Saved new configuration."
                            installPlan = nil
                        } catch { installError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(!plan.hasChanges)
                }
                if let installError { Text(installError).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(24).frame(width: 640, height: 540)
            case .command(let plan):
                VStack(alignment: .leading, spacing: 16) {
                    Text(plan.removing ? "Remove HookFeed from \(plan.integration.name)" : "Connect \(plan.integration.name)").font(.title2.bold())
                    Text(plan.displayCommand).font(.caption.monospaced()).textSelection(.enabled)
                    Text("HookFeed runs this command; \(plan.integration.name) writes its own config.")
                    if !plan.hasChanges { Text("No changes needed.") }
                    if let installError { Text(installError).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        Button("Cancel") { installPlan = nil }.disabled(commandRunning)
                        Spacer()
                        Button(plan.removing ? "Remove" : "Install") {
                            commandRunning = true
                            Task {
                                defer { commandRunning = false }
                                do {
                                    installStatus = try await plan.apply(runner: ProcessCommandRunner(environmentPath: loginPath))
                                    installedMCP = plan.removing ? nil : plan.integration
                                    installPlan = nil
                                } catch { installError = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).disabled(commandRunning || !plan.hasChanges)
                    }
                }.padding(24).frame(width: 640).interactiveDismissDisabled(commandRunning)
            }
        }
        .alert("Integration configuration", isPresented: Binding(get: { installError != nil && installPlan == nil }, set: { if !$0 { installError = nil } })) {
            Button("OK") { installError = nil }
        } message: { Text(installError ?? "") }
    }

    private var general: some View {
        Form {
            Section("Notifications") {
                Picker("Notify me about", selection: $model.notificationMode) {
                    ForEach(NotificationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Text("Permission")
                    Spacer()
                    Text(model.permissionLabel).foregroundStyle(.secondary)
                    if model.authorizationStatus == .notDetermined {
                        Button("Enable notifications") { model.enableNotifications() }
                    } else if model.authorizationStatus == .denied {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?app.hookfeed.HookFeed") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Text("Banners show the title and source. Message bodies stay in your inbox. Sounds are off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                if updates.isAvailable {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                } else {
                    Text("Updates are available for official builds from hookfeed.app")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Menu bar") {
                Picker("Badge counts", selection: $model.badgeMode) {
                    ForEach(BadgeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Continue your work") {
                Picker("Open folders in", selection: $model.editorBundleID) {
                    Text("Cursor").tag("com.todesktop.230313mzl4w4u92")
                    Text("Visual Studio Code").tag("com.microsoft.VSCode")
                    Text("Zed").tag("dev.zed.Zed")
                    Text("Xcode").tag("com.apple.dt.Xcode")
                    Text("Other…").tag("custom")
                }
                if model.editorBundleID == "custom" {
                    HStack {
                        TextField("Application path", text: $model.customEditorPath)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.applicationBundle]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let url = panel.url { model.customEditorPath = url.path }
                        }
                    }
                }
                if model.editorURL == nil {
                    Text("Choose an installed editor to show the Open in editor action.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Resume commands are copied to your clipboard. Run them in your terminal when you're ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var integrations: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !connectAll.items.isEmpty {
                    HStack {
                        Text("Found \(connectAll.items.count) agents that aren't connected.")
                        Spacer()
                        Button("Review and connect…") { showingConnectAll = true }.buttonStyle(.borderedProminent)
                    }
                }
                ForEach(connectAll.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let installStatus { Text(installStatus).font(.caption).textSelection(.enabled) }
                if let installedMCP, let command = installedMCP.mcpCommand {
                    Text(command.afterInstall).font(.caption)
                    CopyButton(label: "Copy rules only", text: IntegrationPrompts.rules(source: installedMCP.rulesSource))
                }
                Text("Hooks report automatically. MCP agents send only when their instructions say so, so copy the setup prompt into the agent and it configures itself. Use one route per agent to avoid duplicate updates.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                IntegrationCard(title: "Command-line tool", subtitle: "Send updates from any local script.", initiallyExpanded: true) {
                    HStack {
                        Text(IntegrationSnippets.cliPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Send test message") { model.sendTestMessage() }.buttonStyle(.borderedProminent)
                    }
                    CLIInstallView()
                }
                ForEach(Integration.all) { integration in
                    switch integration.route {
                    case .hooks(let agent):
                        IntegrationCardView(integration: integration, cliPath: IntegrationSnippets.cliPath,
                                            lastUpdate: lastUpdate(integration.id),
                                            install: { previewInstall(agent) }, remove: { previewInstall(agent, removing: true) },
                                            status: connectAll.states[integration.id])
                    case .mcp:
                        IntegrationCardView(integration: integration, cliPath: IntegrationSnippets.cliPath,
                                            lastUpdate: lastUpdate(integration.id),
                                            install: integration.mcpCommand != nil && detectedExecutables[integration.id] != nil ? { previewCommand(integration) } : nil,
                                            remove: integration.mcpCommand != nil && detectedExecutables[integration.id] != nil ? { previewCommand(integration, removing: true) } : nil,
                                            status: connectAll.states[integration.id])
                    }
                }
                IntegrationCard(title: "Other MCP clients", subtitle: "Cursor, Claude Desktop and other stdio MCP clients. Paste the setup prompt into the agent, or add the server yourself and paste the rules into AGENTS.md or CLAUDE.md. Hooked agents should use their hook instead.", promise: "Agent decides when to send", lastUpdate: lastUpdate("mcp")) {
                    HStack { CopyButton(label: "Copy setup prompt", text: IntegrationSnippets.mcpPrompt, prominent: true); CopyButton(label: "Copy rules only", text: IntegrationSnippets.rules(source: nil)) }
                    CopyableCode(text: IntegrationSnippets.mcp, collapsible: true)
                }
                IntegrationCard(title: "Scripts", subtitle: "The wrapper records completion or failure and returns your command's exit status.", promise: "Automatic for wrapped commands", lastUpdate: lastUpdate("run")) {
                    CopyableCode(text: "\(ShellText.quote(IntegrationSnippets.cliPath)) run --project MyProject -- make test")
                }
            }.padding(20)
        }.task {
            await connectAll.refresh()
            do {
                loginPath = try await LoginShell.path()
                let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
                for integration in Integration.all {
                    detectedExecutables[integration.id] = IntegrationDetection.detect(integration, home: home, searchPath: loginPath).executable
                }
            } catch { installError = error.localizedDescription }
        }
    }

    private var storage: some View {
        Form {
            Section("Local inbox") {
                LabeledContent("Messages", value: "\(model.messages.count)")
                LabeledContent("Threads", value: "\(model.threads.count)")
                LabeledContent("Database") {
                    Text(model.storePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.storePath)])
                }
                Text("Your updates stay on this Mac. HookFeed has no account, telemetry, or model API.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.storageError {
                Section("Storage error") {
                    Text(error).textSelection(.enabled)
                    Button("Try again") { model.reopenStore() }
                }
            }
        }.formStyle(.grouped)
    }

    private func previewInstall(_ agent: HookAgent, removing: Bool = false) {
        installError = nil
        do { installPlan = .hooks(try HookInstaller.preview(agent: agent, removing: removing)) }
        catch { installError = error.localizedDescription }
    }

    private func previewCommand(_ integration: Integration, removing: Bool = false) {
        guard let executable = detectedExecutables[integration.id] else { return }
        installError = nil
        Task {
            do {
                installPlan = .command(try await CommandInstallPlan.make(integration, executable: executable, cliPath: IntegrationSnippets.cliPath,
                                                                        removing: removing, runner: ProcessCommandRunner(environmentPath: loginPath)))
            } catch { installError = error.localizedDescription }
        }
    }

    private func lastUpdate(_ source: String) -> Date? { model.messages.first { $0.source == source }?.receivedAt }
}

private struct CLIInstallView: View {
    @State private var state: CLILinkState = .missing
    @State private var error: String?
    @State private var replacing = false
    @State private var shellPath: String?

    private var target: URL { URL(fileURLWithPath: IntegrationSnippets.cliPath) }
    private var directory: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return CLILink.userDirectory(home: home)
    }
    private var link: URL { directory.appendingPathComponent("hookfeed") }
    private var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }
    private var shellFile: String {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh": return "~/.zshrc"
        case "bash": return "~/.bash_profile"
        default: return "your shell's startup file"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status).font(.callout).textSelection(.enabled)
                Spacer()
                switch state {
                case .linked:
                    Button("Remove") { change { try CLILink.uninstall(at: link, target: target) } }
                case .missing:
                    Button("Install for me") { change { try CLILink.install(at: link, target: target, replacing: false) } }
                case .linkedElsewhere, .blockedByFile:
                    Button("Replace…") { replacing = true }
                }
            }
            Text(link.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let shellPath, !CLILink.isOnPath(directory, path: shellPath) {
                Text("Add this to \(shellFile), then open a new terminal:").font(.caption).foregroundStyle(.secondary)
                CopyableCode(text: "export PATH=\"$HOME/.local/bin:$PATH\"")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task {
            refresh()
            do { shellPath = try await LoginShell.path()
            } catch { self.error = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("Replace existing command?", isPresented: $replacing) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { change { try CLILink.install(at: link, target: target, replacing: true) } }
        } message: { Text("\(status)\n\(link.path) will be replaced with a link to this HookFeed app's bundled command.") }
    }

    private var status: String {
        switch state {
        case .missing: return "Not installed for this user"
        case .linked: return "Installed for this user"
        case .linkedElsewhere(let path): return "Links to another command: \(path)"
        case .blockedByFile: return "An existing file occupies this command path"
        }
    }
    private func refresh() { state = CLILink.state(at: link, target: target) }
    private func change(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
        refresh()
    }
}

struct IntegrationCard<Content: View>: View {
    let title: String
    let subtitle: String
    var promise: String? = nil
    var lastUpdate: Date? = nil
    var status: String? = nil
    @State private var expanded: Bool
    @FocusState private var headerFocused: Bool
    let content: Content

    init(title: String, subtitle: String, promise: String? = nil, lastUpdate: Date? = nil,
         status: String? = nil, initiallyExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.promise = promise
        self.lastUpdate = lastUpdate
        self.status = status
        _expanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                content
            }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if headerFocused { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).accessibilityHidden(true) }
                    if let promise { Text(promise).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                    Spacer()
                    if let lastUpdate {
                        HStack(spacing: 4) { Text("Last update"); RelativeTimestamp(date: lastUpdate) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    else if promise != nil { Text("Waiting for first update").font(.caption).foregroundStyle(.secondary) }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .focusable()
            .focused($headerFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) { expanded.toggle(); return .handled }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

struct CopyableCode: View {
    let text: String
    /// Long configuration stays behind a disclosure; Copy works without expanding it.
    var collapsible = false
    var noun = "configuration"
    @State private var expanded = false

    var body: some View {
        if collapsible {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { expanded.toggle() } label: {
                        Label(expanded ? "Hide \(noun)" : "Show \(noun)", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    CopyButton(label: "Copy", text: text, accessibility: "Copy \(noun)")
                }
                if expanded { code }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                code
                CopyButton(label: "Copy", text: text, accessibility: "Copy \(noun)")
            }
        }
    }

    private var code: some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

}

struct CopyButton: View {
    let label: String
    let text: String
    var prominent = false
    var accessibility: String? = nil
    @State private var copied = false

    var body: some View {
        let button = Button(copied ? "Copied" : label) {
            Clipboard.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        }.accessibilityLabel(copied ? "Copied" : (accessibility ?? label))
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
}

enum IntegrationSnippets {
    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hookfeed").path
    }
    static var claude: String { IntegrationPrompts.claude(cliPath: cliPath) }
    static var codexHooks: String { IntegrationPrompts.codexHooks(cliPath: cliPath) }
    static var codexNotify: String { IntegrationPrompts.codexNotify(cliPath: cliPath) }
    static var mcp: String { IntegrationPrompts.mcp(cliPath: cliPath) }
    static var hermes: String { IntegrationPrompts.hermes(cliPath: cliPath) }
    static var hermesSample: String { IntegrationPrompts.hermesSample }
    static var hermesPrompt: String { IntegrationPrompts.hermesPrompt(cliPath: cliPath) }
    static var mcpPrompt: String { IntegrationPrompts.mcpPrompt(cliPath: cliPath) }
    static var claudePrompt: String { IntegrationPrompts.claudePrompt(cliPath: cliPath) }
    static var codexPrompt: String { IntegrationPrompts.codexPrompt(cliPath: cliPath) }
    static func rules(source: String?) -> String { IntegrationPrompts.rules(source: source) }
    static func hermesRemote(url: String, token: String) -> String { IntegrationPrompts.hermesRemote(url: url, token: token) }
    static func codexRemote(url: String, token: String) -> String { IntegrationPrompts.codexRemote(url: url, token: token) }
    static func mcpRemote(url: String, token: String) -> String { IntegrationPrompts.mcpRemote(url: url, token: token) }
}
