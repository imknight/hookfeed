import Darwin
import Foundation
import HookFeedCore
import MCP
import XCTest
@testable import HookFeedApp

final class RemoteServerTests: XCTestCase {
    func testAtCapReturns503RetryAfter() async throws {
        let probe = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, size) == 0 && getsockname(probe, $0, &size) == 0
            }
        }
        Darwin.close(probe)
        XCTAssertTrue(bound)
        let store = try InboxStore(path: ":memory:")
        let server = RemoteServer(connections: try RemoteConnections(store: MemoryRemoteSecrets()), store: store)
        defer { server.stop() }
        let ready = expectation(description: "Listener ready")
        try server.start(addresses: ["127.0.0.1"], port: Int(UInt16(bigEndian: address.sin_port)), state: { error in
            XCTAssertNil(error); ready.fulfill()
        }, didStore: { XCTFail("Capacity response must not store") })
        await fulfillment(of: [ready], timeout: 3)
        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        func connectClient() throws -> Int32 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            clients.append(fd)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
            }
            guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
            return fd
        }
        for _ in 0..<64 { _ = try connectClient() }
        let deadline = Date().addingTimeInterval(2)
        while server.activeConnectionCount < 64 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.activeConnectionCount, 64)
        let extra = try connectClient()
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(extra, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let response = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503"), response)
        XCTAssertTrue(response.contains("Retry-After: 1"), response)
        let body = response.components(separatedBy: "\r\n\r\n").last ?? ""
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(body.utf8)))
        XCTAssertTrue(try store.messages().isEmpty)
    }

    func testTailscaleRouteRESTAndMCPWhenRequested() async throws {
        guard let host = ProcessInfo.processInfo.environment["HOOKFEED_TEST_TAILSCALE_IP"] else {
            throw XCTSkip("Set HOOKFEED_TEST_TAILSCALE_IP to this Mac's Tailscale IPv4 for the opt-in local route check.")
        }
        _ = try RemoteServer.endpoint(address: host, port: 47321)
        let probe = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr(host)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, size) == 0 && getsockname(probe, $0, &size) == 0
            }
        }
        Darwin.close(probe)
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let created = try connections.create(name: "Local Tailscale test", route: .tailscaleIP, now: Date())
        let store = try InboxStore(path: ":memory:")
        let server = RemoteServer(connections: connections, store: store)
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for iteration in 0..<2 {
            let ready = expectation(description: "Tailscale and loopback ready")
            try server.start(addresses: ["127.0.0.1", host], port: port,
                             reachAddresses: ReachAddresses(tailscaleIP: host, tailscaleHost: nil), state: { error in
                XCTAssertNil(error)
                ready.fulfill()
            }, didStore: {})
            await fulfillment(of: [ready], timeout: 3)
            let lsof = Process()
            let output = Pipe()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-nP", "-a", "-p", String(getpid()), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
            lsof.standardOutput = output
            try lsof.run()
            let bindings = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            lsof.waitUntilExit()
            let names = Set(bindings.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
            XCTAssertEqual(names, ["127.0.0.1:\(port)", "\(host):\(port)"])
            print("Verified listener binds: \(names.sorted())")
            var request = URLRequest(url: URL(string: "http://\(host):\(port)/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"title\":\"Tailnet REST \(iteration)\"}".utf8)
            for (token, status) in [("invalid", 401), (created.token, 201)] {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (_, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            }
            let client = MCP.Client(name: "hookfeed-tailnet-test", version: "1")
            let transport = HTTPClientTransport(endpoint: URL(string: "http://\(host):\(port)/mcp")!, configuration: configuration, requestModifier: { request in
                var request = request
                request.setValue("Bearer " + created.token, forHTTPHeaderField: "Authorization")
                return request
            })
            do {
                _ = try await client.connect(transport: transport)
                let tools = try await client.listTools()
                XCTAssertEqual(tools.tools.map(\.name), ["send_message"])
                let sent = try await client.callTool(name: "send_message", arguments: ["title": "Tailnet MCP", "bot": "Test"])
                XCTAssertEqual(sent.isError, false)
                await client.disconnect()
            } catch { await client.disconnect(); throw error }
            XCTAssertEqual(try store.messages(matching: MessageQuery()).count, (iteration + 1) * 2)
            server.stop()
        }
        try connections.revoke(id: created.connection.id)
        let ready = expectation(description: "Restart for revoked token")
        try server.start(addresses: [host], port: port, state: { error in XCTAssertNil(error); ready.fulfill() }, didStore: {})
        await fulfillment(of: [ready], timeout: 3)
        for path in ["/v1/messages", "/mcp"] {
            var request = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer " + created.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
        XCTAssertEqual(try store.messages(matching: MessageQuery()).count, 4)
    }

    func testSDKHTTPClientInitializesListsAndSendsOverProductionListener() async throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, size) == 0 && getsockname(socket, $0, &size) == 0
            }
        }
        Darwin.close(socket)
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "SDK client", route: .thisMachine, now: Date()).token
        let store = try InboxStore(path: ":memory:")
        let server = RemoteServer(connections: connections, store: store)
        defer { server.stop() }
        let ready = expectation(description: "Loopback listener ready")
        let stored = expectation(description: "Successful receipt callback")
        try server.start(addresses: ["127.0.0.1"], port: port, state: { error in
            XCTAssertNil(error)
            ready.fulfill()
        }, didStore: { stored.fulfill() })
        await fulfillment(of: [ready], timeout: 3)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let get = expectation(description: "SDK attempts optional GET stream")
        get.assertForOverFulfill = false
        let initialized = expectation(description: "SDK sends initialized with session and negotiated protocol")
        let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, configuration: configuration, requestModifier: { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if request.httpMethod == "GET" { get.fulfill() }
            if let body = request.httpBody, let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               message["method"] as? String == "notifications/initialized" {
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), Version.latest)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
                initialized.fulfill()
            }
            return request
        })
        let client = MCP.Client(name: "hookfeed-sdk-test", version: "1")
        do {
            let result = try await client.connect(transport: transport)
            XCTAssertEqual(result.protocolVersion, Version.latest)
            let tools = try await client.listTools()
            XCTAssertEqual(tools.tools.map(\.name), ["send_message"])
            let sent = try await client.callTool(name: "send_message", arguments: ["title": "SDK send", "bot": "Claude"])
            XCTAssertEqual(sent.isError, false)
            await fulfillment(of: [get, initialized, stored], timeout: 3)
            let messages = try store.messages(matching: MessageQuery())
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages[0].bot, "Claude")
            XCTAssertEqual(messages[0].source, "mcp")
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func testListenerRestartsAfterAcceptedHTTPResponse() async throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, size) == 0 && getsockname(socket, $0, &size) == 0
            }
        }
        Darwin.close(socket)
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let server = RemoteServer(connections: connections, store: try InboxStore(path: ":memory:"))
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<3 {
            let ready = expectation(description: "Listener ready after restart")
            var failure: String?
            try server.start(addresses: ["127.0.0.1"], port: port, state: { error in
                failure = error
                ready.fulfill()
            }, didStore: {})
            await fulfillment(of: [ready], timeout: 3)
            XCTAssertNil(failure)
            guard failure == nil else { return }
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            server.stop()
        }
    }

    func testIncrementalReadAndExactLimits() throws {
        var reader = HTTPRequestReader()
        XCTAssertNil(try reader.append(Data("POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{".utf8)))
        let request = try XCTUnwrap(reader.append(Data("}".utf8)))
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertEqual(request.path, "/v1/messages")
        XCTAssertEqual(request.headers["host"], "localhost")
        var exact = HTTPRequestReader()
        let start = "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65536\r\nX-Pad: "
        let headers = start + String(repeating: "x", count: 16384 - start.utf8.count - 4) + "\r\n\r\n"
        XCTAssertNil(try exact.append(Data(headers.utf8)))
        XCTAssertEqual(try exact.append(Data(repeating: 32, count: 65536))?.body.count, 65536)
    }

    func testRejectsMalformedFramingAndBoundedBuffer() {
        let requests = [
            ("GET / HTTP/1.1\r\nHost: x\r\nX: " + String(repeating: "x", count: 16384), 431),
            ("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 65537\r\n\r\n", 413),
            ("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx", 400),
            ("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
            ("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +2\r\n\r\n{}", 400),
            ("GET / HTTP/1.1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: x\r\n folded: x\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: x\r\n\r\nextra", 400),
        ]
        for (raw, status) in requests {
            var reader = HTTPRequestReader()
            XCTAssertThrowsError(try reader.append(Data(raw.utf8))) { error in
                XCTAssertEqual((error as? HTTPRequestReader.Failure)?.status, status, raw)
            }
        }
    }

    func testBindAddressesAreCanonicalNumericLoopbackOrTailscaleOnly() throws {
        for address in ["127.0.0.1", "100.64.0.1", "100.101.2.3", "100.127.255.255"] {
            XCTAssertNoThrow(try RemoteServer.endpoint(address: address, port: 47321))
        }
        for address in ["0.0.0.0", "::1", "127.0.0.2", "localhost", "192.168.0.2", "100.63.0.1", "100.128.0.1", "100.064.0.1", "0100.100.1.2", "100.100.1.2.example", "2130706433"] {
            XCTAssertThrowsError(try RemoteServer.endpoint(address: address, port: 47321), address)
        }
        XCTAssertThrowsError(try RemoteServer.endpoint(address: "127.0.0.1", port: 0))
    }

    @MainActor
    func testTailscaleListenerRequiresConnectionForThatRoute() throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let model = RemoteAccessModel(connections: connections, addresses: ReachAddresses(tailscaleIP: "100.101.2.3", tailscaleHost: "mac.tail.ts.net"))
        XCTAssertEqual(model.bindAddresses, ["127.0.0.1"])
        _ = try connections.create(name: "HTTPS", route: .tailscaleHTTPS, now: Date())
        XCTAssertEqual(model.bindAddresses, ["127.0.0.1"])
        let ip = try connections.create(name: "IP", route: .tailscaleIP, now: Date())
        XCTAssertEqual(model.bindAddresses, ["127.0.0.1", "100.101.2.3"])
        try connections.revoke(id: ip.connection.id)
        XCTAssertEqual(model.bindAddresses, ["127.0.0.1"])
    }

    func testTailscaleStatusAndBoundedCLIProcess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("tailscale")
        func script(_ text: String) throws {
            try Data(("#!/bin/sh\n" + text).utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try script("printf '%s' '{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"mac.tail.ts.net.\",\"TailscaleIPs\":[\"100.101.2.3\",\"fd7a::1\"]}}'")
        let status = TailscaleStatus.detect(executable: cli)
        XCTAssertEqual(status.addresses.tailscaleIP, "100.101.2.3")
        XCTAssertEqual(status.addresses.tailscaleHost, "mac.tail.ts.net")
        try script("printf '%s' '{\"BackendState\":\"Stopped\",\"Self\":{\"TailscaleIPs\":[\"100.101.2.3\"]}}'")
        XCTAssertNil(TailscaleStatus.detect(executable: cli).addresses.tailscaleIP)
        try script("exec /bin/sleep 10")
        let start = Date()
        XCTAssertNil(TailscaleStatus.detect(executable: cli).addresses.tailscaleIP)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

final class MemoryRemoteSecrets: RemoteSecretStore {
    var values: [RemoteConnection] = []
    func load() throws -> [RemoteConnection] { values }
    func save(_ connections: [RemoteConnection]) throws { values = connections }
}
