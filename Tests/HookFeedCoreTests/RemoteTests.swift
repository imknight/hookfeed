import CryptoKit
import Foundation
import XCTest
@testable import HookFeedCore

final class RemoteTests: XCTestCase {
    private final class Secrets: RemoteSecretStore {
        var values: [RemoteConnection] = []
        var failSave = false
        func load() throws -> [RemoteConnection] { values }
        func save(_ values: [RemoteConnection]) throws {
            if failSave { throw CocoaError(.fileWriteUnknown) }
            self.values = values
        }
    }

    func testDetectPicksTailscaleCGNATAddress() {
        let addresses = ReachAddresses.detect(interfaces: [("en0", "192.168.0.160"), ("utun4", "100.101.2.3")], tailscaleDNSName: "mac.tailnet.ts.net.")
        XCTAssertEqual(addresses.tailscaleIP, "100.101.2.3")
        XCTAssertEqual(addresses.baseURL(for: .thisMachine, port: 47321)?.absoluteString, "http://127.0.0.1:47321")
        XCTAssertEqual(addresses.baseURL(for: .tailscaleIP, port: 47321)?.absoluteString, "http://100.101.2.3:47321")
        XCTAssertEqual(addresses.baseURL(for: .tailscaleHTTPS, port: 47321)?.absoluteString, "https://mac.tailnet.ts.net")
        for ip in ["192.168.0.1", "0.0.0.0", "100.63.255.255", "100.128.0.0", "100.100.999.2", "100.100.2.3.extra"] {
            XCTAssertNil(ReachAddresses.detect(interfaces: [("test", ip)], tailscaleDNSName: nil).tailscaleIP)
        }
        for ip in ["100.64.0.0", "100.127.255.255"] {
            XCTAssertEqual(ReachAddresses.detect(interfaces: [("test", ip)], tailscaleDNSName: nil).tailscaleIP, ip)
        }
        XCTAssertNil(ReachAddresses(tailscaleIP: nil, tailscaleHost: nil).baseURL(for: .tailscaleHTTPS, port: 47321))
    }

    func testTokenIsShownOnceAndStoredHashed() throws {
        let secrets = Secrets()
        let connections = try RemoteConnections(store: secrets)
        let created = try connections.create(name: "Home server", route: .thisMachine, now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(created.token.hasPrefix("hf_"))
        XCTAssertEqual(created.token.count, 46)
        XCTAssertFalse(created.token.contains("="))
        XCTAssertEqual(created.connection.tokenHash, Data(SHA256.hash(data: Data(created.token.utf8))))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(secrets.values), as: UTF8.self).contains(created.token))
        XCTAssertEqual(try RemoteConnections(store: secrets).authenticate(bearer: created.token)?.id, created.connection.id)
        XCTAssertNil(connections.authenticate(bearer: created.token + "x"))
        XCTAssertNil(connections.authenticate(bearer: nil))
        XCTAssertNotEqual(try connections.create(name: "Second", route: .thisMachine, now: Date()).token, created.token)
        secrets.failSave = true
        XCTAssertThrowsError(try connections.revoke(id: created.connection.id))
        XCTAssertNotNil(connections.authenticate(bearer: created.token))
    }

    func testSendUsesBotFromRequestAndNoImplicitBot() throws {
        let secrets = Secrets()
        let connections = try RemoteConnections(store: secrets)
        let token = try connections.create(name: "Server", route: .thisMachine, now: Date()).token
        let store = try InboxStore(path: ":memory:")
        for bot in ["Grokbot", "Charname", nil] as [String?] {
            var fields = ["title": "Hi"]
            fields["bot"] = bot
            let result = RemoteRequest.handle(method: "POST", path: "/v1/messages", headers: ["Authorization": "Bearer \(token)"], body: try JSONEncoder().encode(fields), connections: connections, store: store, now: Date())
            XCTAssertEqual(result.status, 201)
            XCTAssertEqual(try JSONDecoder().decode(SendReceipt.self, from: result.json).status, "stored")
        }
        let messages = try store.messages()
        XCTAssertEqual(messages.map(\.bot), [nil, "Charname", "Grokbot"])
        XCTAssertTrue(messages.allSatisfy { $0.source == "remote" && $0.origin == nil })
    }

    func testRejectsAuthBoundsInvalidJSONAndFieldsWithoutStoring() throws {
        let secrets = Secrets()
        let connections = try RemoteConnections(store: secrets)
        let token = try connections.create(name: "Server", route: .thisMachine, now: Date()).token
        let store = try InboxStore(path: ":memory:")
        func request(_ body: Data, auth: String? = nil) -> Int {
            RemoteRequest.handle(method: "POST", path: "/v1/messages", headers: auth.map { ["authorization": $0] } ?? [:], body: body, connections: connections, store: store, now: Date()).status
        }
        let good = Data(#"{"title":"Hi"}"#.utf8)
        for auth in [nil, "Bearer wrong", "Basic \(token)", "Bearer \(token) extra"] { XCTAssertEqual(request(good, auth: auth), 401) }
        XCTAssertEqual(request(Data(repeating: 32, count: 65537), auth: "Bearer \(token)"), 413)
        for body in ["{", "[]", "null", #"{"title":1}"#, #"{"title":"x","bot":null}"#, #"{"title":"x","unknown":"x"}"#, #"{"title":"x","origin":"hookfeed-run-v1"}"#, #"{"title":"x","sender":"old"}"#, #"{"title":"x","kind":"bad"}"#, #"{"title":""}"#] {
            XCTAssertEqual(request(Data(body.utf8), auth: "Bearer \(token)"), 400, body)
        }
        XCTAssertEqual(request(try JSONEncoder().encode(["title": "x", "bot": String(repeating: "x", count: 81)]), auth: "Bearer \(token)"), 400)
        XCTAssertEqual(try store.messages().count, 0)
        XCTAssertNil(secrets.values.first?.lastUsedAt)
    }

    func testRevokedTokenAndLastUsedOnlyAfterSuccessfulStore() throws {
        let secrets = Secrets()
        let connections = try RemoteConnections(store: secrets)
        let created = try connections.create(name: "Server", route: .thisMachine, now: Date(timeIntervalSince1970: 1))
        let store = try InboxStore(path: ":memory:")
        let now = Date(timeIntervalSince1970: 50)
        func request(_ title: String, date: Date) throws -> Int {
            RemoteRequest.handle(method: "POST", path: "/v1/messages", headers: ["authorization": "Bearer \(created.token)"], body: try JSONEncoder().encode(["title": title, "idempotency_key": "key"]), connections: connections, store: store, now: date).status
        }
        XCTAssertNotNil(connections.authenticate(bearer: created.token))
        XCTAssertNil(secrets.values.first?.lastUsedAt)
        XCTAssertEqual(try request("Hi", date: now), 201)
        XCTAssertEqual(secrets.values.first?.lastUsedAt, now)
        XCTAssertEqual(try request("Conflict", date: now.addingTimeInterval(10)), 400)
        XCTAssertEqual(secrets.values.first?.lastUsedAt, now)
        try connections.revoke(id: created.connection.id)
        XCTAssertEqual(try request("Hi", date: now), 401)
        XCTAssertEqual(try store.messages().count, 1)
        XCTAssertTrue(try RemoteConnections(store: secrets).all.isEmpty)
    }

    func testHealthAndRouting() throws {
        let connections = try RemoteConnections(store: Secrets())
        let store = try InboxStore(path: ":memory:")
        for (method, path, expected) in [("GET", "/v1/health", 200), ("GET", "/v1/messages", 405), ("POST", "/v1/health", 405), ("GET", "/mcp", 404), ("POST", "/v1/messages?token=x", 404)] {
            XCTAssertEqual(RemoteRequest.handle(method: method, path: path, headers: [:], body: Data(), connections: connections, store: store, now: Date()).status, expected)
        }
    }
}
