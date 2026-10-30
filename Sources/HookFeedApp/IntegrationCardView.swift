import HookFeedCore
import SwiftUI

struct IntegrationCardView: View {
    let integration: Integration
    let cliPath: String
    let lastUpdate: Date?
    var install: (() -> Void)?
    var remove: (() -> Void)?
    var status: ConnectionState? = nil
    var initiallyExpanded = false
    @State private var showingDetails = false

    var body: some View {
        IntegrationCard(title: integration.name, subtitle: "", promise: integration.promise, lastUpdate: lastUpdate,
                        status: status?.label, initiallyExpanded: initiallyExpanded) {
            HStack {
                if let install { Button("Install…", action: install) }
                if let remove { Button("Remove…", action: remove) }
                switch integration.route {
                case .hooks:
                    Spacer()
                    CopyButton(label: "Copy setup prompt", text: integration.setupPrompt(cliPath: cliPath))
                case .mcp:
                    CopyButton(label: "Copy setup prompt", text: integration.setupPrompt(cliPath: cliPath), prominent: true)
                    CopyButton(label: "Copy rules only", text: IntegrationPrompts.rules(source: integration.rulesSource))
                }
            }
            Button("Setup details…") { showingDetails = true }
                .accessibilityLabel("Setup details for \(integration.name)")
        }
        .sheet(isPresented: $showingDetails) {
            IntegrationSetupDetails(integration: integration, cliPath: cliPath) { showingDetails = false }
        }
    }
}

struct IntegrationSetupDetails: View {
    let integration: Integration
    let cliPath: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup details for \(integration.name)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(integration.summary).font(.callout).foregroundStyle(.secondary)
                    ForEach(integration.snippets.indices, id: \.self) { index in
                        let snippet = integration.snippets[index]
                        CopyableCode(text: snippet.text(cliPath), noun: snippet.noun)
                        if let note = snippet.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 640, height: 540)
    }
}
