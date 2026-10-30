import Foundation
import HookFeedCore
import MCP

final class RemoteMCP: @unchecked Sendable {
    static let sessionLimit = 32
    static let requestLimit = 128

    struct Reply {
        let response: MCP.HTTPResponse
        var finish: (Bool) -> Void = { _ in }
    }

    private final class Session {
        let owner: String
        let createdAt = Date()
        let server = Server(name: "hookfeed", version: "0.1.0",
                            instructions: "Store updates in HookFeed's human inbox. Receipt means stored, not seen. Remote connections can only send; inbox reading is unavailable.",
                            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
        let transport: StatefulHTTPServerTransport
        var id: String?
        var initializing = true
        var active: Set<UUID> = []
        var rpcIDs: Set<String> = []
        var requests = 0

        init(owner: String, validation: StandardValidationPipeline) {
            self.owner = owner
            transport = StatefulHTTPServerTransport(validationPipeline: validation)
        }

        func stop() { Task { await server.stop(); await transport.disconnect() } }
    }

    private let connections: RemoteConnections
    private let store: InboxStore
    private let didStore: () -> Void
    private let validation: StandardValidationPipeline
    // Also gates storage: stop cannot return while a handler is writing to the inbox.
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var stopped = false

    init(connections: RemoteConnections, store: InboxStore, port: Int,
         addresses: ReachAddresses = ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), didStore: @escaping () -> Void) {
        self.connections = connections
        self.store = store
        self.didStore = didStore
        let local = OriginValidator.localhost(port: port)
        var hosts = local.allowedHosts
        var origins = local.allowedOrigins
        for route in [ReachRoute.tailscaleIP, .tailscaleHTTPS] {
            if let url = addresses.baseURL(for: route, port: port), let host = url.host {
                hosts.append(host + (url.port.map { ":\($0)" } ?? ""))
                origins.append(url.absoluteString)
            }
        }
        validation = StandardValidationPipeline(validators: [
            OriginValidator(allowedHosts: hosts, allowedOrigins: origins),
            AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(),
            ProtocolVersionValidator(), SessionValidator(),
        ])
    }

    func stop() {
        let old = lock.withLock {
            stopped = true
            let old = sessions
            sessions.removeAll()
            return old
        }
        old.forEach { $0.stop() }
    }

    func handle(_ request: MCP.HTTPRequest) async -> Reply {
        guard let owner = connections.authenticate(bearer: Self.bearer(request)) else {
            return Reply(response: .error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: ["WWW-Authenticate": "Bearer"]))
        }
        guard request.method == "POST" || request.method == "DELETE" else {
            return Reply(response: .error(statusCode: 405, .invalidRequest("Method not allowed"), extraHeaders: ["Allow": "POST, DELETE"]))
        }
        // Match the SDK's ID routing key (including numeric/string IDs with the same description).
        let envelope = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rpcID = (envelope?["id"] as? String) ?? (envelope?["id"] as? Int).map(String.init)
        let ticket = UUID()
        let selection: Result<Session, MCPSelectionError> = lock.withLock {
            guard !stopped else { return .failure(.init(status: 503, message: "Remote is disabled")) }
            let expired = sessions.filter { $0.active.isEmpty && (Date().timeIntervalSince($0.createdAt) >= 900 || $0.requests >= Self.requestLimit) }
            sessions.removeAll { session in expired.contains { $0 === session } }
            expired.forEach { $0.stop() }
            if let id = request.header("Mcp-Session-Id") {
                guard let session = sessions.first(where: { $0.id == id && $0.owner == owner.id }) else {
                    return .failure(.init(status: 404, message: "Session not found; initialize again"))
                }
                guard !session.initializing, rpcID.map({ !session.rpcIDs.contains($0) }) ?? true else {
                    return .failure(.init(status: 409, message: "Initialization or this request ID is already in progress"))
                }
                guard session.active.count < 8, session.requests < Self.requestLimit else {
                    return .failure(.init(status: 429, message: "MCP session request limit reached"))
                }
                session.active.insert(ticket)
                if let rpcID { session.rpcIDs.insert(rpcID) }
                session.requests += 1
                return .success(session)
            }
            guard sessions.count < Self.sessionLimit else { return .failure(.init(status: 429, message: "Too many MCP sessions")) }
            let session = Session(owner: owner.id, validation: validation)
            session.active.insert(ticket)
            if let rpcID { session.rpcIDs.insert(rpcID) }
            session.requests = 1
            sessions.append(session)
            return .success(session)
        }
        guard case .success(let session) = selection else {
            if case .failure(let error) = selection {
                return Reply(response: .error(statusCode: error.status, .invalidRequest(error.message)))
            }
            preconditionFailure()
        }
        if lock.withLock({ session.id == nil }) {
            await session.server.withMethodHandler(ListTools.self) { _ in .init(tools: MCPTools.definitions(readAll: false)) }
            await session.server.withMethodHandler(CallTool.self) { [weak self, weak session] parameters in
                guard let self, let session else { throw MCPError.connectionClosed }
                return try self.lock.withLock {
                    guard !self.stopped, self.sessions.contains(where: { $0 === session }),
                          !Task.isCancelled,
                          let context = Server.currentHandlerContext?.httpContext,
                          self.connections.authenticate(bearer: Self.bearer(context))?.id == session.owner else {
                        throw MCPError.invalidRequest("Connection is no longer authorized")
                    }
                    guard parameters.name == "send_message" else {
                        return .init(content: [.text(text: "Remote connections can only send messages; this tool is unavailable.", annotations: nil, _meta: nil)], isError: true)
                    }
                    let result = try MCPTools.call(parameters.name, arguments: parameters.arguments ?? [:], readAll: false,
                                                   defaultBot: nil, store: {
                        guard self.connections.authenticate(bearer: Self.bearer(context))?.id == session.owner else {
                            throw MCPError.invalidRequest("Connection is no longer authorized")
                        }
                        return self.store
                    })
                    if result.isError == false {
                        self.connections.markUsed(id: session.owner, now: Date())
                        self.didStore()
                    }
                    return result
                }
            }
            do { try await session.server.start(transport: session.transport) }
            catch {
                finish(session, ticket: ticket, rpcID: rpcID, keep: false)
                return Reply(response: .error(statusCode: 503, .internalError("Could not start MCP session")))
            }
        }
        guard lock.withLock({ !stopped && sessions.contains(where: { $0 === session }) }), !Task.isCancelled else {
            finish(session, ticket: ticket, rpcID: rpcID, keep: false)
            return Reply(response: .error(statusCode: 503, .invalidRequest("Remote is disabled")))
        }
        let response = await session.transport.handleRequest(request)
        lock.withLock { session.id = response.headers["MCP-Session-Id"] ?? session.id }
        return Reply(response: response, finish: { [self, session] completed in
            finish(session, ticket: ticket, rpcID: rpcID, keep: completed && !(request.method == "DELETE" && response.statusCode == 200))
        })
    }

    private func finish(_ session: Session, ticket: UUID, rpcID: String?, keep: Bool) {
        let removed = lock.withLock {
            if keep, session.id != nil, !stopped, sessions.contains(where: { $0 === session }) {
                session.active.remove(ticket)
                if let rpcID { session.rpcIDs.remove(rpcID) }
                session.initializing = false
                return false
            }
            sessions.removeAll { $0 === session }
            return true
        }
        if removed { session.stop() }
    }

    private static func bearer(_ request: MCP.HTTPRequest) -> String? {
        guard let header = request.header("Authorization") else { return nil }
        let parts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }

    private struct MCPSelectionError: Error {
        let status: Int
        let message: String
    }
}
