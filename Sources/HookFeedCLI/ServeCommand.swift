import ArgumentParser
import Darwin
import Foundation
import HookFeedCore
import Security

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Receive remote HTTP and MCP messages without the app UI.")
    @Option(help: "Loopback and optional Tailscale TCP port (1–65535).") var port = 47321
    @Flag(help: "Follow the app's Enable remote access setting (for the LaunchAgent).") var managed = false
    #if DEBUG
    @Flag(help: .hidden) var testKeychain = false
    #endif

    func validate() throws {
        guard (1...65535).contains(port) else { throw ValidationError("--port must be between 1 and 65535.") }
    }

    mutating func run() async throws { try await receive() }

    @MainActor
    private func receive() async throws {
        SecKeychainSetUserInteractionAllowed(false)
        let store = try InboxStore()
        var secrets = KeychainSecretStore(allowInteraction: false)
        var isolated = false
        #if DEBUG
        if testKeychain {
            let env = ProcessInfo.processInfo.environment
            let home = URL(fileURLWithPath: env["HOME"] ?? "/").resolvingSymlinksInPath().path
            let temporary = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")].map { $0.resolvingSymlinksInPath().path }
            let service = KeychainSecretStore.service
            guard temporary.contains(where: { home.hasPrefix($0 + "/") }), env["HOME"] == env["CFFIXED_USER_HOME"],
                  store.path.hasPrefix(home + "/"), service.hasPrefix("app.hookfeed.test."),
                  UUID(uuidString: String(service.dropFirst("app.hookfeed.test.".count))) != nil else {
                throw ValidationError("Test serving requires temporary HOME/CFFIXED_USER_HOME, an isolated store and a UUID Keychain service.")
            }
            secrets = try KeychainSecretStore.isolatedTestStore(home: home, service: service, password: env["HOOKFEED_TEST_KEYCHAIN_PASSWORD"] ?? UUID().uuidString)
            isolated = true
        }
        #endif
        var connections: RemoteConnections?
        var server: RemoteServer?
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { server?.stop(); Darwin.exit(0) }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() }; server?.stop() }
        var addresses = ReachAddresses(tailscaleIP: nil, tailscaleHost: nil)
        var bound: [String] = []
        var configuredAddresses: ReachAddresses?
        var listening = false
        var generation = 0
        var nextTailscaleCheck = Date.distantPast
        var nextKeychainAttempt = Date.distantPast
        var keychainDelay = 1.0
        var nextListenerAttempt = Date.distantPast
        while !Task.isCancelled {
            let enabled = !managed || RemotePreferences.enabled
            guard enabled else {
                if !bound.isEmpty {
                    generation += 1
                    server?.stop()
                    bound = []
                    listening = false
                }
                nextKeychainAttempt = .distantPast
                nextListenerAttempt = .distantPast
                keychainDelay = 1
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            if connections == nil {
                if Date() >= nextKeychainAttempt {
                    do {
                        let loaded = try RemoteConnections(store: secrets, coordinationPath: RemotePreferences.connectionsLockPath)
                        connections = loaded
                        server = RemoteServer(connections: loaded, store: store, lockPath: RemotePreferences.listenerLockPath)
                        keychainDelay = 1
                    } catch {
                        if !managed { throw error }
                        CLIOutput.error("Waiting for Keychain access: \(error.localizedDescription)")
                        nextKeychainAttempt = Date().addingTimeInterval(keychainDelay)
                        keychainDelay = min(keychainDelay * 2, 30)
                    }
                }
                if connections == nil {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
            }
            guard let connections, let server else { continue }
            if Date() >= nextTailscaleCheck, !isolated {
                addresses = await TailscaleStatus.detect().addresses
                nextTailscaleCheck = Date().addingTimeInterval(30)
            }
            var desired = ["127.0.0.1"]
            if connections.all.contains(where: { $0.route == .tailscaleIP }), let ip = addresses.tailscaleIP { desired.append(ip) }
            if desired != bound || configuredAddresses != addresses || (!listening && Date() >= nextListenerAttempt) {
                generation += 1
                let current = generation
                server.stop()
                listening = false
                bound = desired
                configuredAddresses = addresses
                nextListenerAttempt = Date().addingTimeInterval(1)
                do {
                    try server.start(addresses: desired, port: port, reachAddresses: addresses, state: { error in
                        guard current == generation else { return }
                        listening = error == nil
                        if let error { CLIOutput.error(error) }
                        else { CLIOutput.error("Listening on port \(port).") }
                    }, didStore: {})
                } catch {
                    if !managed { throw error }
                    CLIOutput.error("Waiting for the remote listener: \(error.localizedDescription)")
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
