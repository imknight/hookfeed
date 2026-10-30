import Foundation
import HookFeedCore
import SwiftUI

@MainActor
final class ConnectAllModel: ObservableObject {
    struct Item: Identifiable {
        let integration: Integration
        let state: ConnectionState
        let plan: InstallPlan?
        var selected: Bool
        var id: String { integration.id }
    }
    enum Outcome: Equatable { case connected(detail: String), failed(String) }
    @Published private(set) var states: [String: ConnectionState] = [:]
    @Published private(set) var items: [Item] = []
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published private(set) var errors: [String] = []
    @Published private(set) var applying = false
    @Published private(set) var refreshing = false
    private let home: URL
    private let searchPath: () async throws -> String
    private let cliPath: String
    private let providedRunner: CommandRunner?
    private var runner: CommandRunner?
    private let configPath: (HookAgent) -> URL
    private let integrations: [Integration]
    private let fallbackDirectories: [String]

    init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path),
         searchPath: @escaping () async throws -> String = LoginShell.path, cliPath: String = IntegrationSnippets.cliPath,
         runner: CommandRunner? = nil, configPath: @escaping (HookAgent) -> URL = HookInstaller.path,
         integrations: [Integration] = Integration.all, fallbackDirectories: [String] = IntegrationDetection.fallbackDirectories) {
        self.home = home; self.searchPath = searchPath; self.cliPath = cliPath; self.providedRunner = runner
        self.configPath = configPath; self.integrations = integrations; self.fallbackDirectories = fallbackDirectories
    }

    func refresh() async {
        guard !applying, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        states = [:]; items = []; outcomes = [:]; errors = []
        do {
            let path = try await searchPath()
            let runner = providedRunner ?? ProcessCommandRunner(environmentPath: path)
            self.runner = runner
            for integration in integrations {
                let detection = IntegrationDetection.detect(integration, home: home, searchPath: path, fallbackDirectories: fallbackDirectories)
                let state = await IntegrationStatus.state(for: integration, detection: detection, cliPath: cliPath, runner: runner, configPath: configPath)
                states[integration.id] = state
                if case .error(let error) = state { errors.append("\(integration.name): \(error)") }
                guard state == .detected || state == .needsUpdate else { continue }
                do {
                    let plan: InstallPlan
                    switch integration.route {
                    case .hooks(let agent):
                        plan = .hooks(try HookInstaller.preview(agent: agent, path: configPath(agent), cliPath: cliPath))
                    case .mcp:
                        guard integration.mcpCommand != nil, let executable = detection.executable else { continue }
                        plan = .command(try await CommandInstallPlan.make(integration, executable: executable, cliPath: cliPath, removing: false, runner: runner))
                    }
                    items.append(Item(integration: integration, state: state, plan: plan, selected: true))
                } catch { errors.append("\(integration.name): \(error.localizedDescription)") }
            }
        } catch { errors.append(error.localizedDescription) }
    }

    func select(_ id: String, selected: Bool) {
        guard !applying, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].selected = selected
    }

    func apply() async {
        guard !applying, !refreshing, let runner else { return }
        applying = true
        defer { applying = false }
        for item in items where item.selected && outcomes[item.id] == nil {
            do {
                let detail: String
                switch item.plan {
                case .hooks(let plan):
                    detail = try plan.apply().map { "Saved. Backup: \($0.path)" } ?? "Saved new configuration."
                case .command(let plan): detail = try await plan.apply(runner: runner)
                case nil: continue
                }
                outcomes[item.id] = .connected(detail: detail)
            } catch { outcomes[item.id] = .failed(error.localizedDescription) }
        }
    }
}

struct ConnectAllSheet: View {
    @ObservedObject var model: ConnectAllModel
    @Environment(\.dismiss) private var dismiss
    private var selectedCount: Int { model.items.filter { $0.selected && model.outcomes[$0.id] == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your agents").font(.title2.bold())
            Text("Review each change before connecting. Existing hook files are backed up beside the original.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(get: { item.selected }, set: { model.select(item.id, selected: $0) })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.integration.name).font(.headline)
                                    Text(item.integration.promise).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(model.applying || model.outcomes[item.id] != nil)
                            DisclosureGroup("Show changes") {
                                switch item.plan {
                                case .hooks(let plan):
                                    Text(plan.path.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(String(decoding: plan.updated, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                                case .command(let plan):
                                    Text(plan.displayCommand).font(.caption.monospaced()).textSelection(.enabled)
                                    Text("HookFeed runs this command; \(item.integration.name) writes its own config.").font(.caption)
                                case nil: EmptyView()
                                }
                            }
                            if let outcome = model.outcomes[item.id] {
                                switch outcome {
                                case .connected(let detail):
                                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text(detail).font(.caption).textSelection(.enabled)
                                    if item.id == "codex" { Text("Open /hooks in Codex and trust the HookFeed hooks.").font(.caption) }
                                    if let command = item.integration.mcpCommand {
                                        Text(command.afterInstall).font(.caption)
                                        CopyButton(label: "Copy rules only", text: IntegrationPrompts.rules(source: item.integration.rulesSource))
                                    }
                                case .failed(let error): Text(error).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(model.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            HStack {
                Button(model.outcomes.isEmpty ? "Cancel" : "Done") { dismiss() }.disabled(model.applying)
                Spacer()
                if model.applying { ProgressView().controlSize(.small) }
                Button("Connect \(selectedCount)") { Task { await model.apply() } }
                    .buttonStyle(.borderedProminent).disabled(selectedCount == 0 || model.applying || model.refreshing)
            }
        }.padding(24).frame(width: 560, height: 520).interactiveDismissDisabled(model.applying)
    }
}
