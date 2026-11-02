import Foundation
import XCTest
@testable import HookFeedCore

final class RemoteServiceTests: XCTestCase {
    func testListenerLockExcludesAnotherOwnerAndCanBeReacquired() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var owner: RemoteFileLock? = try RemoteFileLock(path: path)
        XCTAssertNotNil(owner)
        XCTAssertThrowsError(try RemoteFileLock(path: path))
        owner = nil
        XCTAssertNoThrow(try RemoteFileLock(path: path))
    }

    func testKeychainCacheReloadsOnlyAfterCoordinatedChanges() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let secrets = SharedRemoteSecrets()
        let app = try RemoteConnections(store: secrets, coordinationPath: path)
        let helper = try RemoteConnections(store: secrets, coordinationPath: path)
        XCTAssertEqual(secrets.loads, 2)
        let first = try app.create(name: "First", route: .thisMachine, now: Date())
        XCTAssertEqual(secrets.loads, 2)
        for _ in 0..<10 {
            XCTAssertNotNil(helper.authenticate(bearer: first.token))
            XCTAssertEqual(helper.all.count, 1)
        }
        XCTAssertEqual(secrets.loads, 3)
        helper.markUsed(id: first.connection.id, now: Date())
        XCTAssertEqual(secrets.loads, 3)
        XCTAssertNotNil(app.all.first?.lastUsedAt)
        XCTAssertEqual(secrets.loads, 4)
        try app.revoke(id: first.connection.id)
        XCTAssertNil(helper.authenticate(bearer: first.token))
        XCTAssertEqual(secrets.loads, 5)
    }

    func testCacheFailsClosedWhenChangedKeychainCannotBeLoaded() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let secrets = SharedRemoteSecrets()
        let app = try RemoteConnections(store: secrets, coordinationPath: path)
        let first = try app.create(name: "First", route: .thisMachine, now: Date())
        let helper = try RemoteConnections(store: secrets, coordinationPath: path)
        try app.revoke(id: first.connection.id)
        secrets.failLoad = true
        XCTAssertNil(helper.authenticate(bearer: first.token))
        XCTAssertTrue(helper.all.isEmpty)
        secrets.failLoad = false
        XCTAssertNil(helper.authenticate(bearer: first.token))
    }

    func testSeparateRegistriesObserveCreationAndRevocationWithoutRestoringTokens() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let secrets = SharedRemoteSecrets()
        let app = try RemoteConnections(store: secrets, coordinationPath: path)
        let helper = try RemoteConnections(store: secrets, coordinationPath: path)
        let first = try app.create(name: "First", route: .thisMachine, now: Date())
        XCTAssertEqual(helper.authenticate(bearer: first.token)?.id, first.connection.id)
        let second = try helper.create(name: "Second", route: .thisMachine, now: Date())
        XCTAssertEqual(app.all.count, 2)
        try app.revoke(id: first.connection.id)
        helper.markUsed(id: first.connection.id, now: Date())
        XCTAssertNil(helper.authenticate(bearer: first.token))
        XCTAssertEqual(helper.authenticate(bearer: second.token)?.id, second.connection.id)
        XCTAssertEqual(app.all.map(\.id), [second.connection.id])
    }
}

private final class SharedRemoteSecrets: RemoteSecretStore {
    var values: [RemoteConnection] = []
    var loads = 0
    var failLoad = false
    func load() throws -> [RemoteConnection] {
        loads += 1
        if failLoad { throw CocoaError(.fileReadNoPermission) }
        return values
    }
    func save(_ connections: [RemoteConnection]) throws { values = connections }
}
