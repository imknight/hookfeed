import AppKit
import Foundation
import HookFeedCore
import ServiceManagement

@MainActor
final class RemoteAccessModel: ObservableObject {
    static let shared = RemoteAccessModel()
    @Published private(set) var enabled = false
    @Published private(set) var listening = false
    @Published private(set) var connections: [RemoteConnection] = []
    @Published private(set) var addresses: ReachAddresses
    @Published private(set) var tailscaleReason: String? = "Checking Tailscale…"
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var configuringTailscale = false
    @Published private(set) var tailscaleResult: String?
    @Published private(set) var backgroundStatus: SMAppService.Status = .notRegistered
    @Published private(set) var changingBackground = false
    private var backgroundMonitor: Task<Void, Never>?
    private var backgroundService: SMAppService { .agent(plistName: "app.hookfeed.receiver.plist") }
    private var registry: RemoteConnections?
    private var server: RemoteServer?
    private var preferences: UserDefaults?
    private var started = false
    private var generation = 0
    let now: () -> Date
    private(set) var port = 47321
    #if DEBUG
    private var debugMode = false
    private var debugInput: DispatchSourceRead?
    private var debugBuffer = Data()
    private var debugSecrets: KeychainSecretStore?
    #endif

    init(connections: RemoteConnections? = nil,
         addresses: ReachAddresses = ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), now: @escaping () -> Date = Date.init) {
        registry = connections
        self.connections = connections?.all ?? []
        self.addresses = addresses
        self.now = now
        if connections != nil { tailscaleReason = nil }
    }

    var bindAddresses: [String] {
        var result = ["127.0.0.1"]
        if registry?.all.contains(where: { $0.route == .tailscaleIP }) == true,
           let ip = addresses.tailscaleIP, ReachAddresses.isTailscaleIP(ip) { result.append(ip) }
        return result
    }

    var canCreate: Bool { registry != nil }
    var backgroundEnabled: Bool { backgroundStatus == .enabled || backgroundStatus == .requiresApproval }

    func activate() {
        guard !started else { return }
        started = true
        do {
            #if DEBUG
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--debug-remote-") }) {
                try activateDebug()
                return
            }
            #endif
            let store = try InboxStore()
            let registry = try RemoteConnections(store: KeychainSecretStore(), coordinationPath: RemotePreferences.connectionsLockPath)
            self.registry = registry
            connections = registry.all
            preferences = UserDefaults(suiteName: RemotePreferences.domain)
            enabled = preferences?.bool(forKey: "enabled") ?? false
            server = RemoteServer(connections: registry, store: store, lockPath: RemotePreferences.listenerLockPath)
            backgroundStatus = backgroundService.status
            if enabled { restart() }
            Task { await refreshAddresses() }
            backgroundMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshBackgroundStatus()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            self.error = error.localizedDescription
            #if DEBUG
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--debug-remote-") }) {
                let data = try! JSONEncoder().encode(["event": "failed", "error": error.localizedDescription])
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            #endif
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        preferences?.set(value, forKey: "enabled")
        preferences?.synchronize()
        restart()
    }

    func setBackgroundEnabled(_ value: Bool) async {
        guard !changingBackground else { return }
        changingBackground = true
        defer { changingBackground = false }
        do {
            if value {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hookfeed")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw ConfigurationError("Build and install HookFeed.app before enabling its background receiver.")
                }
                stop()
                try KeychainSecretStore().authorizeHelper(at: helper.path)
                if backgroundService.status != .enabled { try backgroundService.register() }
            } else { try await backgroundService.unregister() }
            backgroundStatus = backgroundService.status
            restart()
        } catch {
            backgroundStatus = backgroundService.status
            restart()
            self.error = error.localizedDescription
        }
    }

    private func refreshBackgroundStatus() async {
        guard !changingBackground else { return }
        let status = backgroundService.status
        if status != backgroundStatus {
            backgroundStatus = status
            restart()
        }
        guard status == .enabled, enabled else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
        request.timeoutInterval = 1
        let response = try? await URLSession.shared.data(for: request)
        guard backgroundStatus == .enabled, enabled else { return }
        listening = (response?.1 as? HTTPURLResponse)?.statusCode == 200
        error = listening ? nil : "Background receiver is not responding. Check Login Items and Keychain access, or turn off background receiving to use the app listener."
        connections = registry?.all ?? []
    }

    func stop() {
        generation += 1
        server?.stop()
        listening = false
    }

    func create(name: String, route: ReachRoute) throws -> String {
        guard let registry, addresses.baseURL(for: route, port: port) != nil else {
            throw HookFeedError.invalidInput(field: "route", reason: "this route is unavailable.")
        }
        let created = try registry.create(name: name, route: route, now: now())
        connections = registry.all
        if enabled { restart() }
        return created.token
    }

    func revoke(_ id: String) {
        do {
            try registry?.revoke(id: id)
            connections = registry?.all ?? []
            if enabled { restart() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshAddresses() async {
        #if DEBUG
        if debugMode { return }
        #endif
        guard !refreshing else { return }
        refreshing = true
        let status = await TailscaleStatus.detect()
        refreshing = false
        let changed = addresses != status.addresses
        addresses = status.addresses
        tailscaleReason = status.reason
        if changed, enabled { restart() }
    }

    func configureTailscale(reset: Bool) async {
        guard !configuringTailscale else { return }
        configuringTailscale = true
        defer { configuringTailscale = false }
        do {
            guard let executable = await TailscaleStatus.executable() else { throw ConfigurationError("Tailscale CLI not found.") }
            let result = try await ProcessCommandRunner(environmentPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
                .run(executable, TailscaleStatus.serveArguments(port: port, reset: reset), timeout: 30)
            let output = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            tailscaleResult = "\(result.status == 0 ? "Succeeded" : "Failed (exit \(result.status))")\(output.isEmpty ? "" : ":\n" + output)"
            await refreshAddresses()
        } catch { tailscaleResult = error.localizedDescription }
    }

    private func restart() {
        stop()
        guard enabled, backgroundStatus != .enabled, let server else { return }
        error = nil
        let current = generation
        do {
            try server.start(addresses: bindAddresses, port: port, reachAddresses: addresses, state: { [weak self] error in
                guard let self, current == self.generation, self.enabled else { return }
                self.error = error
                self.listening = error == nil
                #if DEBUG
                if self.debugMode { self.debugEvent(error == nil ? "ready" : "failed") }
                #endif
            }, didStore: { [weak self] in
                guard let self else { return }
                self.connections = self.registry?.all ?? []
            })
        } catch { self.error = error.localizedDescription }
    }

    #if DEBUG
    private func activateDebug() throws {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? "/").resolvingSymlinksInPath().path
        let storePath = URL(fileURLWithPath: env["HOOKFEED_STORE_PATH"] ?? "/").resolvingSymlinksInPath().path
        let temporaryRoots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
            .map { $0.resolvingSymlinksInPath().path }
        guard temporaryRoots.contains(where: { home.hasPrefix($0 + "/") }),
              env["HOME"] == env["CFFIXED_USER_HOME"], storePath.hasPrefix(home + "/"),
              let service = env["HOOKFEED_KEYCHAIN_SERVICE"], service.hasPrefix("app.hookfeed.test."),
              UUID(uuidString: String(service.dropFirst("app.hookfeed.test.".count))) != nil else {
            throw HookFeedError.invalidInput(field: "debug remote", reason: "requires temporary HOME/CFFIXED_USER_HOME and store, and a unique app.hookfeed.test.* Keychain service.")
        }
        func argument(_ flag: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        if let raw = argument("--debug-remote-port") {
            guard let value = Int(raw), (1...65535).contains(value) else {
                throw HookFeedError.invalidInput(field: "port", reason: "invalid debug port.")
            }
            port = value
        }
        debugMode = true
        addresses = ReachAddresses(tailscaleIP: nil, tailscaleHost: nil)
        tailscaleReason = "Tailscale is disabled in the loopback debug harness."
        let secrets = try KeychainSecretStore.isolatedTestStore(home: home, service: service, helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hookfeed").path)
        debugSecrets = secrets
        let store = try InboxStore(path: storePath)
        let registry = try RemoteConnections(store: secrets, coordinationPath: RemotePreferences.connectionsLockPath)
        self.registry = registry
        server = RemoteServer(connections: registry, store: store, lockPath: RemotePreferences.listenerLockPath)
        if let id = argument("--debug-remote-revoke") { try registry.revoke(id: id) }
        if let name = argument("--debug-remote-create") {
            let created = try registry.create(name: name, route: .thisMachine, now: now())
            debugEvent("created", fields: ["id": created.connection.id, "token": created.token])
        }
        connections = registry.all
        setEnabled(CommandLine.arguments.contains("--debug-remote-start"))
        if !enabled { debugEvent("disabled") }
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            guard count > 0 else { self.debugInput?.cancel(); self.debugInput = nil; return }
            self.debugBuffer.append(contentsOf: bytes.prefix(count))
            guard self.debugBuffer.count <= 4096 else { self.debugInput?.cancel(); self.debugInput = nil; return }
            while let newline = self.debugBuffer.firstIndex(of: 10) {
                let command = String(decoding: self.debugBuffer[..<newline], as: UTF8.self)
                self.debugBuffer.removeSubrange(...newline)
                if command == "disable" { self.setEnabled(false); self.debugEvent("disabled") }
                else if command == "enable" { self.setEnabled(true) }
                else if command.hasPrefix("revoke ") { self.revoke(String(command.dropFirst(7))); self.debugEvent("revoked") }
                else if command == "status" {
                    self.debugEvent("status", fields: ["accepted": String(self.server?.activeConnectionCount ?? 0)])
                }
                else if command == "inspect" {
                    do {
                        let data = try JSONEncoder().encode(self.debugSecrets!.load())
                        self.debugEvent("connections", fields: ["stored": String(decoding: data, as: UTF8.self)])
                    } catch { self.debugEvent("failed", fields: ["error": "Could not inspect test Keychain."]) }
                }
                else if command == "quit" { self.stop(); self.debugEvent("stopped"); NSApp.terminate(nil) }
            }
        }
        debugInput = source
        source.resume()
    }

    private func debugEvent(_ event: String, fields: [String: String] = [:]) {
        guard debugMode else { return }
        let data = try! JSONEncoder().encode(fields.merging(["event": event]) { _, new in new })
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    #endif
}
