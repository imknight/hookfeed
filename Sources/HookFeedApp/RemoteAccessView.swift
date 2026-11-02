import HookFeedCore
import SwiftUI

struct RemoteAccessView: View {
    @ObservedObject var model: RemoteAccessModel
    @State private var name = ""
    @State private var route: ReachRoute = .thisMachine
    @State private var createdToken: String?
    @State private var createdURL: String = ""
    @State private var creationError: String?
    @State private var showingTailscaleSetup = false
    @State private var showingTailscaleReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remote access").font(.title2.bold())
                        Text(model.listening ? "Listening · connections can send updates" : (model.enabled ? (model.error == nil ? "Starting listener…" : "Failed to listen") : "Off · no listeners running"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enable remote access", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                        .toggleStyle(.switch).labelsHidden().accessibilityLabel("Enable remote access")
                }
                Text("HookFeed must stay open to receive updates. Connections can only send; they cannot read your inbox.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Reach this Mac via").font(.headline)
                        Spacer()
                        Button("Refresh Tailscale") { Task { await model.refreshAddresses() } }.disabled(model.refreshing)
                    }
                    ForEach(ReachRoute.allCases, id: \.self) { choice in
                        routeRow(choice)
                    }
                    if let _ = model.addresses.baseURL(for: .tailscaleHTTPS, port: model.port) {
                        CopyableCode(text: "tailscale serve --bg --https=443 http://127.0.0.1:\(model.port)")
                        HStack {
                            Button("Set up Tailscale HTTPS…") { showingTailscaleSetup = true }
                            Button("Reset Tailscale Serve…", role: .destructive) { showingTailscaleReset = true }
                        }.disabled(model.configuringTailscale)
                    }
                    if let result = model.tailscaleResult { Text(result).font(.caption).textSelection(.enabled) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Create connection").font(.headline)
                    HStack {
                        TextField("Name, e.g. Home server", text: $name)
                        Button("Create connection") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canCreate || model.addresses.baseURL(for: route, port: model.port) == nil)
                    }
                    Text("One token per connection. Every bot on it shares the token and sends its own bot name.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let creationError { Text(creationError).font(.caption).foregroundStyle(.red) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connections").font(.headline)
                    if model.connections.isEmpty { Text("No connections yet.").foregroundStyle(.secondary) }
                    ForEach(model.connections) { connection in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connection.name).font(.body.weight(.medium))
                                Text("\(connection.route.title) · \(lastUsed(connection.lastUsedAt))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { model.revoke(connection.id) }
                        }
                    }
                }
            }.padding(24)
        }
        .alert("Set up Tailscale HTTPS?", isPresented: $showingTailscaleSetup) {
            Button("Cancel", role: .cancel) { }
            Button("Set up") { Task { await model.configureTailscale(reset: false) } }
        } message: {
            Text("This changes this Mac's Tailscale Serve HTTPS mapping on port 443 to HookFeed. It may replace an existing mapping. Tailscale may ask you to enable HTTPS for your tailnet.")
        }
        .alert("Reset Tailscale Serve?", isPresented: $showingTailscaleReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { Task { await model.configureTailscale(reset: true) } }
        } message: {
            Text("This runs tailscale serve reset and removes ALL Serve mappings on this Mac, including mappings for other apps.")
        }
        .sheet(isPresented: Binding(get: { createdToken != nil }, set: { if !$0 { createdToken = nil } })) {
            if let token = createdToken {
                RemoteTokenSheet(url: createdURL, token: token) { createdToken = nil }
            }
        }
    }

    private func routeRow(_ choice: ReachRoute) -> some View {
        let url = model.addresses.baseURL(for: choice, port: model.port)
        return Button { route = choice } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: route == choice ? "largecircle.fill.circle" : "circle").foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title).font(.body.weight(.medium))
                    Text(url?.absoluteString ?? (model.tailscaleReason ?? "Tailscale HTTPS name unavailable."))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(url == nil)
    }

    private func lastUsed(_ date: Date?) -> String {
        guard let date else { return "Never used" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last used " + formatter.localizedString(for: date, relativeTo: model.now())
    }

    private func create() {
        do {
            guard let url = model.addresses.baseURL(for: route, port: model.port) else {
                throw HookFeedError.invalidInput(field: "route", reason: "this route is unavailable. Select an available route.")
            }
            createdURL = url.absoluteString
            createdToken = try model.create(name: name, route: route)
            creationError = nil
            name = ""
        } catch { creationError = error.localizedDescription }
    }
}

private extension ReachRoute {
    var title: String {
        switch self {
        case .thisMachine: return "This machine"
        case .tailscaleIP: return "Tailscale IP"
        case .tailscaleHTTPS: return "Tailscale HTTPS"
        }
    }
}
