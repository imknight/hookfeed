import Foundation
import HookFeedCore
import MCP
import XCTest
@testable import HookFeedApp

final class RemoteMCPTests: XCTestCase {
    private let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
        "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]
    private let list: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]

    private func request(_ body: [String: Any], token: String, session: String? = nil, headers: [String: String] = [:]) throws -> MCP.HTTPRequest {
        var values = ["Host": "127.0.0.1:47321", "Authorization": "Bearer " + token,
                      "Accept": "application/json, text/event-stream", "Content-Type": "application/json",
                      "MCP-Protocol-Version": "2025-03-26"]
        values["Mcp-Session-Id"] = session
        values.merge(headers) { _, new in new }
        return MCP.HTTPRequest(method: "POST", headers: values, body: try JSONSerialization.data(withJSONObject: body), path: "/mcp")
    }

    private func consume(_ reply: RemoteMCP.Reply) async throws -> [String: Any] {
        defer { reply.finish(true) }
        var data = reply.response.bodyData ?? Data()
        if case .stream(let stream, _) = reply.response {
            for try await chunk in stream { data.append(chunk) }
            let line = try XCTUnwrap(String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                .first { $0.hasPrefix("data: {") })
            data = Data(line.dropFirst(6).utf8)
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func start(_ remote: RemoteMCP, token: String) async throws -> String {
        let reply = await remote.handle(try request(initialize, token: token))
        XCTAssertEqual(reply.response.statusCode, 200)
        let session = try XCTUnwrap(reply.response.headers["MCP-Session-Id"])
        _ = try await consume(reply)
        let ready = await remote.handle(try request(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token, session: session))
        XCTAssertEqual(ready.response.statusCode, 202)
        ready.finish(true)
        return session
    }

    func testSessionOwnershipAndAuthenticationPrecedeValidation() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let first = try connections.create(name: "First", route: .thisMachine, now: Date())
        let second = try connections.create(name: "Second", route: .thisMachine, now: Date())
        let remote = RemoteMCP(connections: connections, store: try InboxStore(path: ":memory:"), port: 47321, didStore: {})
        defer { remote.stop() }
        let session = try await start(remote, token: first.token)
        let stolen = await remote.handle(try request(list, token: second.token, session: session))
        XCTAssertEqual(stolen.response.statusCode, 404)
        let wrong = await remote.handle(try request(list, token: "wrong", session: "unknown", headers: ["Origin": "https://evil.example"]))
        XCTAssertEqual(wrong.response.statusCode, 401)
        XCTAssertEqual(wrong.response.headers["WWW-Authenticate"], "Bearer")
        try connections.revoke(id: first.connection.id)
        let revoked = await remote.handle(try request(list, token: first.token, session: session))
        XCTAssertEqual(revoked.response.statusCode, 401)
    }

    func testDistinctRequestsOverlapButDuplicateCannotReplaceSDKStream() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "Test", route: .thisMachine, now: Date()).token
        let store = try InboxStore(path: ":memory:")
        let remote = RemoteMCP(connections: connections, store: store, port: 47321, didStore: {})
        defer { remote.stop() }
        let session = try await start(remote, token: token)
        let first = await remote.handle(try request(list, token: token, session: session))
        let duplicate = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(duplicate.response.statusCode, 409)
        let sameSDKID = await remote.handle(try request(["jsonrpc": "2.0", "id": "2", "method": "tools/list"], token: token, session: session))
        XCTAssertEqual(sameSDKID.response.statusCode, 409)
        let otherList = await remote.handle(try request(["jsonrpc": "2.0", "id": 20, "method": "tools/list"], token: token, session: session))
        XCTAssertEqual(otherList.response.statusCode, 200)
        let send = await remote.handle(try request(["jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": [
            "name": "send_message", "arguments": ["title": "Parallel send", "bot": "Claude"]]], token: token, session: session))
        XCTAssertEqual(send.response.statusCode, 200)
        let sent = try await consume(send)
        XCTAssertEqual((sent["result"] as? [String: Any])?["isError"] as? Bool, false)
        _ = try await consume(otherList)
        XCTAssertEqual(try store.messages(matching: MessageQuery()).first?.bot, "Claude")
        let result = try await consume(first)
        XCTAssertNotNil(result["result"])
        let cancelled = await remote.handle(try request(list, token: token, session: session))
        cancelled.finish(false)
        let expired = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(expired.response.statusCode, 404)
    }

    func testSessionAndRequestBudgetsBoundSDKEventHistory() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "Test", route: .thisMachine, now: Date()).token
        let remote = RemoteMCP(connections: connections, store: try InboxStore(path: ":memory:"), port: 47321, didStore: {})
        defer { remote.stop() }
        let session = try await start(remote, token: token)
        for _ in 2..<RemoteMCP.requestLimit {
            _ = try await consume(await remote.handle(try request(list, token: token, session: session)))
        }
        let expired = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(expired.response.statusCode, 404)
        for _ in 0..<RemoteMCP.sessionLimit { _ = try await start(remote, token: token) }
        let full = await remote.handle(try request(initialize, token: token))
        XCTAssertEqual(full.response.statusCode, 429)
    }

    func testPerSessionConcurrencyIsBoundedAndDeleteClosesSession() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "Test", route: .thisMachine, now: Date()).token
        let remote = RemoteMCP(connections: connections, store: try InboxStore(path: ":memory:"), port: 47321, didStore: {})
        defer { remote.stop() }
        let session = try await start(remote, token: token)
        var pending: [RemoteMCP.Reply] = []
        for id in 10..<18 {
            let reply = await remote.handle(try request(["jsonrpc": "2.0", "id": id, "method": "tools/list"], token: token, session: session))
            XCTAssertEqual(reply.response.statusCode, 200)
            pending.append(reply)
        }
        let excess = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(excess.response.statusCode, 429)
        for reply in pending { _ = try await consume(reply) }
        let headers = try request(list, token: token, session: session).headers
        let deleted = await remote.handle(MCP.HTTPRequest(method: "DELETE", headers: headers, path: "/mcp"))
        XCTAssertEqual(deleted.response.statusCode, 200)
        deleted.finish(true)
        let expired = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(expired.response.statusCode, 404)
    }

    func testLastUseAndDidStoreOnlyFollowStorageReceipt() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "Test", route: .thisMachine, now: Date()).token
        let store = try InboxStore(path: ":memory:")
        var callbacks = 0
        let remote = RemoteMCP(connections: connections, store: store, port: 47321, didStore: { callbacks += 1 })
        let session = try await start(remote, token: token)
        _ = try await consume(await remote.handle(try request(list, token: token, session: session)))
        let invalid = ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "send_message", "arguments": ["title": "", "bot": "Claude"]]] as [String: Any]
        _ = try await consume(await remote.handle(try request(invalid, token: token, session: session)))
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(connections.all[0].lastUsedAt)
        let send = ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [
            "name": "send_message", "arguments": ["title": "Stored", "idempotency_key": "retry"]]] as [String: Any]
        for duplicate in [false, true] {
            let result = try await consume(await remote.handle(try request(send, token: token, session: session)))
            let receipt = (result["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            XCTAssertEqual(receipt?["duplicate"] as? Bool, duplicate)
        }
        XCTAssertEqual(callbacks, 2)
        XCTAssertNotNil(connections.all[0].lastUsedAt)
        let messages = try store.messages(matching: MessageQuery())
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].source, "mcp")
        XCTAssertNil(messages[0].bot)
        remote.stop()
        let stopped = await remote.handle(try request(send, token: token, session: session))
        XCTAssertEqual(stopped.response.statusCode, 503)
        XCTAssertEqual(callbacks, 2)
    }

    func testOnlyDetectedOriginsAllowedAndStopInvalidatesSessions() async throws {
        let connections = try RemoteConnections(store: MemoryRemoteSecrets())
        let token = try connections.create(name: "Test", route: .thisMachine, now: Date()).token
        let remote = RemoteMCP(connections: connections, store: try InboxStore(path: ":memory:"), port: 47321,
                               addresses: ReachAddresses(tailscaleIP: "100.101.2.3", tailscaleHost: "mac.tail.ts.net"), didStore: {})
        for (host, origin) in [("127.0.0.1:47321", "http://127.0.0.1:47321"),
                               ("100.101.2.3:47321", "http://100.101.2.3:47321"), ("mac.tail.ts.net", "https://mac.tail.ts.net")] {
            let reply = await remote.handle(try request(initialize, token: token, headers: ["Host": host, "Origin": origin]))
            XCTAssertEqual(reply.response.statusCode, 200)
            _ = try await consume(reply)
        }
        let hostile = await remote.handle(try request(initialize, token: token, headers: ["Host": "evil.example", "Origin": "https://evil.example"]))
        XCTAssertEqual(hostile.response.statusCode, 421)
        let wrongIP = await remote.handle(try request(initialize, token: token, headers: ["Origin": "http://100.101.2.4:47321"]))
        XCTAssertEqual(wrongIP.response.statusCode, 403)
        let session = try await start(remote, token: token)
        let pending = await remote.handle(try request(list, token: token, session: session))
        remote.stop()
        if case .stream(let stream, _) = pending.response { for try await _ in stream {} }
        pending.finish(false)
        let stopped = await remote.handle(try request(list, token: token, session: session))
        XCTAssertEqual(stopped.response.statusCode, 503)
    }
}
