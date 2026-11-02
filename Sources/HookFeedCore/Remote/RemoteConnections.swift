import CryptoKit
import Foundation
import Security

public struct RemoteConnection: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let route: ReachRoute
    public let tokenHash: Data
    public let createdAt: Date
    public var lastUsedAt: Date?
}

public protocol RemoteSecretStore {
    func load() throws -> [RemoteConnection]
    func save(_ connections: [RemoteConnection]) throws
}

public final class RemoteConnections: @unchecked Sendable {
    private let store: any RemoteSecretStore
    private var connections: [RemoteConnection]
    private let lock = NSLock()
    private let coordinationPath: String?
    private var version: UInt64?

    public init(store: any RemoteSecretStore, coordinationPath: String? = nil) throws {
        self.coordinationPath = coordinationPath
        self.store = store
        connections = []
        try synchronized { }
    }

    public var all: [RemoteConnection] {
        (try? synchronized { connections }) ?? []
    }

    public func create(name: String, route: ReachRoute, now: Date) throws -> (connection: RemoteConnection, token: String) {
        let name = name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.utf8.contains(0) else {
            throw HookFeedError.invalidInput(field: "name", reason: "use 1–80 characters.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HookFeedError.invalidInput(field: "token", reason: "could not generate secure random bytes.")
        }
        let token = "hf_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let connection = RemoteConnection(id: UUID().uuidString.lowercased(), name: name, route: route,
                                          tokenHash: Data(SHA256.hash(data: Data(token.utf8))), createdAt: now)
        return try synchronized(writing: true) {
            let updated = connections + [connection]
            try store.save(updated)
            connections = updated
            return (connection, token)
        }
    }

    public func authenticate(bearer: String?) -> RemoteConnection? {
        guard let bearer, bearer.hasPrefix("hf_"), bearer.utf8.count == 46 else { return nil }
        let hash = Data(SHA256.hash(data: Data(bearer.utf8)))
        return try? synchronized { connections.first { connection in
            guard connection.tokenHash.count == hash.count else { return false }
            var difference: UInt8 = 0
            for (a, b) in zip(connection.tokenHash, hash) { difference |= a ^ b }
            return difference == 0
        } }
    }

    public func revoke(id: String) throws {
        try synchronized(writing: true) {
            let updated = connections.filter { $0.id != id }
            try store.save(updated)
            connections = updated
        }
    }

    public func markUsed(id: String, now: Date) {
        // A metadata write failure must not turn an already stored message into a failed send.
        try? synchronized(writing: true) {
            guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
            var updated = connections
            updated[index].lastUsedAt = now
            try store.save(updated)
            connections = updated
        }
    }

    private func synchronized<T>(writing: Bool = false, _ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let ownership = try coordinationPath.map { try RemoteFileLock(path: $0, wait: true) }
        return try withExtendedLifetime(ownership) {
            let storedVersion = try ownership?.version
            if ownership == nil && version == nil || ownership != nil && version != storedVersion {
                connections = try store.load()
                version = storedVersion ?? 0
            }
            if writing, let ownership {
                try ownership.bumpVersion()
                version = nil
            }
            let result = try action()
            if writing { version = try ownership?.version ?? 0 }
            return result
        }
    }
}
