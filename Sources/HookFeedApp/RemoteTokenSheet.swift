import HookFeedCore
import SwiftUI

struct RemoteTokenSheetModel {
    struct Example: Identifiable {
        let id: String
        let title: String
        let text: String
        var note: String? = nil
        var setupCommand: String? = nil
        var collapsible = true
    }
    let examples: [Example]

    init(url: String, token: String, hermesProfile: String = "", integrations: [Integration] = Integration.all) {
        examples = [
            Example(id: "token", title: "Connection token", text: token, collapsible: false),
            Example(id: "command-line", title: "Command line",
                    text: "export HOOKFEED_URL=\(ShellText.quote(url))\nexport HOOKFEED_TOKEN=\(ShellText.quote(token))\nhookfeed send 'Done' --bot MyBot", collapsible: false),
            Example(id: "http-api", title: "HTTP API",
                    text: "curl \(ShellText.quote(url + "/v1/messages")) \\\n  -H \(ShellText.quote("Authorization: Bearer " + token)) \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"title\":\"Done\",\"bot\":\"MyBot\"}'")
        ] + integrations.compactMap { integration in
            integration.remoteSnippet.map {
                Example(id: integration.id, title: "\(integration.name) (MCP)", text: $0.text(url, token), note: $0.note,
                        setupCommand: integration.id == "hermes" ? IntegrationPrompts.hermesAddCommand(url: url, profile: hermesProfile) : nil)
            }
        } + [Example(id: "other-mcp", title: "Other MCP clients (streamable HTTP)",
                     text: IntegrationPrompts.mcpRemote(url: url, token: token))]
    }
}

struct RemoteTokenSheet: View {
    let url: String
    let token: String
    let done: () -> Void
    @State private var expanded: Set<String>
    @State private var hermesProfile = ""

    var model: RemoteTokenSheetModel { RemoteTokenSheetModel(url: url, token: token, hermesProfile: hermesProfile) }

    init(url: String, token: String, expanded: Set<String> = [], done: @escaping () -> Void) {
        self.url = url
        self.token = token
        self.done = done
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Save your connection token").font(.title2.bold())
                    Text("Shown only once. Keep it private. Revoke this connection if you lose the token.")
                        .foregroundStyle(.secondary)
                    ForEach(model.examples) { example in
                        if example.collapsible {
                            DisclosureGroup(isExpanded: Binding(
                                get: { expanded.contains(example.id) },
                                set: { if $0 { expanded.insert(example.id) } else { expanded.remove(example.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let command = example.setupCommand {
                                        TextField("Hermes profile (optional)", text: $hermesProfile)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityLabel("Hermes profile (optional)")
                                        CopyableCode(text: command, noun: "Hermes setup command")
                                        Text("Confirm authentication, paste this connection's token when asked for API key / Bearer token, then enable the discovered tool. Use the token for this connection if Hermes offers a saved credential.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let note = example.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                    CopyableCode(text: example.text, noun: example.title)
                                }.padding(.top, 8)
                            } label: {
                                HStack {
                                    Text(example.title).font(.headline)
                                    Spacer()
                                    CopyButton(label: "Copy", text: example.text, accessibility: "Copy \(example.title)")
                                }
                            }
                            .focusable()
                            .onKeyPress(.space) {
                                if expanded.contains(example.id) { expanded.remove(example.id) } else { expanded.insert(example.id) }
                                return .handled
                            }
                            .accessibilityIdentifier("remote-example-\(example.id)")
                        } else {
                            Text(example.title).font(.headline)
                            CopyableCode(text: example.text, noun: example.title)
                        }
                    }
                }.padding(24)
            }
            Divider()
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }.padding(16)
        }.frame(width: 620, height: 640)
    }
}
