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
    func load() throws -> [RemoteConnection] { values }
    func save(_ connections: [RemoteConnection]) throws { values = connections }
}
