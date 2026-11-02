import Foundation
import MCP
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPRequestReader {
    struct Failure: Error { let status: Int }
    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], end: Int, length: Int)?

    mutating func append(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 16 * 1024 + RemoteRequest.bodyLimit - buffer.count else {
            throw Failure(status: head == nil ? 431 : 413)
        }
        buffer.append(data)
        if head == nil {
            guard let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count >= 16 * 1024 { throw Failure(status: 431) }
                return nil
            }
            let end = delimiter.upperBound
            guard end <= 16 * 1024 else { throw Failure(status: 431) }
            let bytes = buffer.prefix(delimiter.lowerBound)
            guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { throw Failure(status: 400) }
            let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
                  parts[1].hasPrefix("/"), !parts[1].contains("#"), parts[2] == "HTTP/1.1" else { throw Failure(status: 400) }
            var headers: [String: String] = [:]
            let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Failure(status: 400) }
                let name = String(line[..<colon])
                guard name.unicodeScalars.allSatisfy({ token.contains($0) }) else { throw Failure(status: 400) }
                let key = name.lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard headers[key] == nil, !value.contains("\r"), !value.contains("\n") else { throw Failure(status: 400) }
                headers[key] = value
            }
            guard let host = headers["host"], !host.isEmpty, headers["transfer-encoding"] == nil else { throw Failure(status: 400) }
            var length = 0
            if let raw = headers["content-length"] {
                guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw) else { throw Failure(status: 400) }
                length = count
            }
            guard length <= RemoteRequest.bodyLimit else { throw Failure(status: 413) }
            head = (String(parts[0]), String(parts[1]), headers, end, length)
        }
        let head = head!
        guard buffer.count <= head.end + head.length else { throw Failure(status: 400) }
        guard buffer.count == head.end + head.length else { return nil }
        return HTTPRequest(method: head.method, path: head.path, headers: head.headers,
                           body: buffer.subdata(in: head.end..<buffer.count))
    }
}

// Mutable listener/client state is confined to queue.
public final class RemoteServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.hookfeed.remote")
    private var listeners: [NWListener] = []
    private var socketListeners: [RemoteSocketListener] = []
    private let cancellations = DispatchGroup()
    private var generation = 0
    private var clients: [UUID: Client] = [:]
    private var mcp: RemoteMCP?
    private let connections: RemoteConnections
    private let store: InboxStore
    private let lockPath: String?
    private var listenerLock: RemoteFileLock?

    public init(connections: RemoteConnections, store: InboxStore, lockPath: String? = nil) {
        self.connections = connections
        self.store = store
        self.lockPath = lockPath
    }

    static func endpoint(address: String, port: Int) throws -> NWEndpoint {
        let canonical = address.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let byte = UInt8(part) else { return false }
            return String(byte) == part
        }
        guard canonical, address == "127.0.0.1" || ReachAddresses.isTailscaleIP(address),
              let ipv4 = IPv4Address(address), (1...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HookFeedError.invalidInput(field: "listener", reason: "use 127.0.0.1 or a canonical Tailscale IPv4 address and a valid port.")
        }
        return .hostPort(host: .ipv4(ipv4), port: port)
    }

    public func start(addresses: [String], port: Int, reachAddresses: ReachAddresses = ReachAddresses(tailscaleIP: nil, tailscaleHost: nil), ownership: RemoteFileLock? = nil, state: @escaping (String?) -> Void, didStore: @escaping () -> Void) throws {
        stop()
        let ownership = try ownership ?? lockPath.map { try RemoteFileLock(path: $0) }
        let endpoints = try addresses.map { try Self.endpoint(address: $0, port: port) }
        let pending = try zip(addresses, endpoints).filter { $0.0 == "127.0.0.1" }.map { _, endpoint -> NWListener in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = endpoint
            parameters.allowLocalEndpointReuse = true
            return try NWListener(using: parameters)
        }
        queue.sync {
            stopOnQueue()
            listenerLock = ownership
            let current = generation
            let mcp = RemoteMCP(connections: connections, store: store, port: port, addresses: reachAddresses,
                                didStore: { DispatchQueue.main.async(execute: didStore) })
            self.mcp = mcp
            cancellations.notify(queue: queue) { [self] in
                guard current == generation else { pending.forEach { $0.cancel() }; return }
                var ready = 0
                let accept: (any RemoteTCPConnection) -> Void = { [weak self] connection in
                    guard let self, current == self.generation else { connection.cancel(); return }
                    guard self.clients.count < 64 else {
                        Self.rejectAtCapacity(connection, on: self.queue)
                        return
                    }
                    let id = UUID()
                    let client = Client(connection: connection, queue: self.queue, handle: { [connections = self.connections, store = self.store, mcp] request in
                        if request.path == "/mcp" {
                            let reply = await mcp.handle(MCP.HTTPRequest(method: request.method, headers: request.headers,
                                                                         body: request.body, path: request.path))
                            return Response(reply)
                        }
                        return await withCheckedContinuation { continuation in
                            self.queue.async {
                                guard current == self.generation else {
                                    continuation.resume(returning: Response(RemoteRequest.failure(503, "Remote is disabled.")))
                                    return
                                }
                                let response = RemoteRequest.handle(method: request.method, path: request.path, headers: request.headers,
                                                                    body: request.body, connections: connections, store: store, now: Date())
                                if response.status == 201 { DispatchQueue.main.async(execute: didStore) }
                                continuation.resume(returning: Response(response))
                            }
                        }
                    }, finished: { [weak self] in self?.clients.removeValue(forKey: id) })
                    self.clients[id] = client
                    client.start()
                }
                func startSockets() {
                    do {
                        for address in addresses where address != "127.0.0.1" {
                            let listener = try RemoteSocketListener(address: address, port: port, queue: queue, accept: { accept($0) })
                            socketListeners.append(listener)
                        }
                        DispatchQueue.main.async { state(nil) }
                    } catch {
                        stopOnQueue()
                        DispatchQueue.main.async { state("Could not start Remote. The address may be unavailable or the port is in use.") }
                    }
                }
                if pending.isEmpty { startSockets() }
                for listener in pending {
                    listener.stateUpdateHandler = { [weak self, weak listener] update in
                        guard let self, let listener, self.listeners.contains(where: { $0 === listener }) else { return }
                        switch update {
                        case .ready:
                            ready += 1
                            if ready == pending.count { startSockets() }
                        case .failed:
                            self.stopOnQueue()
                            DispatchQueue.main.async { state("Could not start Remote. The address may be unavailable or the port is in use.") }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { accept($0) }
                    listeners.append(listener)
                    listener.start(queue: queue)
                }
            }
        }
    }

    public func stop() {
        queue.sync { stopOnQueue() }
        cancellations.wait()
        queue.sync { listenerLock = nil }
    }

    static func rejectAtCapacity(_ connection: any RemoteTCPConnection, on queue: DispatchQueue) {
        let body = RemoteRequest.failure(503, "Remote is at capacity.").json
        let head = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.start(on: queue, failed: { [weak connection] in connection?.cancel() })
        connection.write(Data(head.utf8) + body, final: false) { error in
            guard error == nil else { connection.cancel(); return }
            connection.write(nil, final: true) { _ in connection.cancel() }
        }
    }

    #if DEBUG
    public var activeConnectionCount: Int { queue.sync { clients.count } }
    #endif

    private func stopOnQueue() {
        generation += 1
        mcp?.stop(); mcp = nil
        let oldSockets = socketListeners
        socketListeners.removeAll()
        for listener in oldSockets {
            cancellations.enter()
            listener.cancel { [cancellations] in cancellations.leave() }
        }
        let oldListeners = listeners
        listeners.removeAll()
        for listener in oldListeners {
            cancellations.enter()
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [cancellations] state in
                if case .cancelled = state { cancellations.leave() }
            }
            listener.cancel()
        }
        let oldClients = Array(clients.values)
        clients.removeAll()
        oldClients.forEach { $0.cancel() }
    }

    private struct Response {
        let status: Int
        var headers: [String: String]
        let body: Data
        var stream: AsyncThrowingStream<Data, Error>?
        var finish: (Bool) -> Void = { _ in }

        init(_ response: (status: Int, json: Data)) {
            status = response.status
            headers = ["Content-Type": "application/json"]
            if status == 401 { headers["WWW-Authenticate"] = "Bearer" }
            body = response.json
        }

        init(_ reply: RemoteMCP.Reply) {
            status = reply.response.statusCode
            headers = reply.response.headers
            body = reply.response.bodyData ?? Data()
            if case .stream(let stream, _) = reply.response { self.stream = stream }
            finish = reply.finish
        }
    }

    // Only immutable connection/handler references are used outside queue.
    private final class Client: @unchecked Sendable {
        let connection: any RemoteTCPConnection
        let queue: DispatchQueue
        let handle: (HTTPRequest) async -> Response
        let finished: () -> Void
        var reader = HTTPRequestReader()
        var timer: DispatchSourceTimer?
        var task: Task<Void, Never>?
        var responding = false
        var cancelled = false

        init(connection: any RemoteTCPConnection, queue: DispatchQueue, handle: @escaping (HTTPRequest) async -> Response, finished: @escaping () -> Void) {
            self.connection = connection; self.queue = queue; self.handle = handle; self.finished = finished
        }

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 10)
            timer.setEventHandler { [weak self] in
                self?.respond { Response(RemoteRequest.failure(408, "Request read timed out.")) }
            }
            self.timer = timer
            timer.resume()
            connection.start(on: queue, failed: { [weak self] in self?.cancel() })
            receive()
        }

        func receive() {
            connection.read { [weak self] data, complete, error in
                guard let self, !self.cancelled, !self.responding else { return }
                do {
                    if let data, let request = try self.reader.append(data) {
                        self.respond { await self.handle(request) }; return
                    }
                    if error != nil { self.cancel() }
                    else if complete { self.respond { Response(RemoteRequest.failure(400, "Incomplete request.")) } }
                    else { self.receive() }
                } catch let error as HTTPRequestReader.Failure {
                    self.respond { Response(RemoteRequest.failure(error.status, "Invalid HTTP request.")) }
                } catch { self.respond { Response(RemoteRequest.failure(400, "Invalid HTTP request.")) } }
            }
        }

        func respond(_ response: @escaping () async -> Response) {
            guard !responding, !cancelled else { return }
            responding = true
            // Bound handler time and slow readers separately from the accept-based read deadline.
            timer?.schedule(deadline: .now() + 10)
            timer?.setEventHandler { [weak self] in self?.cancel() }
            task = Task {
                let response = await response()
                do {
                    try Task.checkCancellation()
                    var headers = response.headers.filter { !["connection", "content-length", "transfer-encoding"].contains($0.key.lowercased()) }
                    headers["Connection"] = "close"
                    if response.stream == nil { headers["Content-Length"] = String(response.body.count) }
                    let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
                    let head = "HTTP/1.1 \(response.status) \(reason)\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
                    try await send(Data(head.utf8))
                    if let stream = response.stream {
                        var remaining = 128 * 1024
                        for try await chunk in stream {
                            guard chunk.count <= remaining else { throw MCPError.internalError("Response too large") }
                            remaining -= chunk.count
                            // Finish each write before requesting the next SSE chunk.
                            try await send(chunk)
                        }
                    } else { try await send(response.body) }
                    try Task.checkCancellation()
                    try await send(nil, final: true)
                    response.finish(true)
                } catch { response.finish(false) }
                queue.async { self.cancel() }
            }
        }

        func send(_ data: Data?, final: Bool = false) async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.write(data, final: final) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            timer?.cancel(); timer = nil
            task?.cancel(); task = nil
            connection.cancel()
            finished()
        }
    }
}
