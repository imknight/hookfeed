import Foundation
import HookFeedCore
import Security

struct KeychainSecretStore: RemoteSecretStore {
    static var service: String { ProcessInfo.processInfo.environment["HOOKFEED_KEYCHAIN_SERVICE"] ?? "app.hookfeed.remote" }
    let service: String
    #if DEBUG
    private var testKeychain: SecKeychain?
    #endif
    init(service: String = Self.service) { self.service = service }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "connections", kSecAttrSynchronizable as String: false]
        #if DEBUG
        if let testKeychain { query[kSecMatchSearchList as String] = [testKeychain] }
        #endif
        return query
    }

    func load() throws -> [RemoteConnection] {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(operation: "load", status: status) }
        return try JSONDecoder().decode([RemoteConnection].self, from: data)
    }

    func save(_ connections: [RemoteConnection]) throws {
        let data = try JSONEncoder().encode(connections)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            #if DEBUG
            if let testKeychain {
                entry.removeValue(forKey: kSecMatchSearchList as String)
                entry[kSecUseKeychain as String] = testKeychain
            }
            #endif
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(operation: "create", status: added) }
        } else if status != errSecSuccess { throw KeychainFailure(operation: "update", status: status) }
    }

    #if DEBUG
    // Called only after the debug harness verifies temporary HOME/store and a UUID service.
    static func isolatedTestStore(home: String, service: String) throws -> KeychainSecretStore {
        let path = URL(fileURLWithPath: home).appendingPathComponent("remote-tests.keychain-db").path
        var keychain: SecKeychain?
        let status: OSStatus
        if FileManager.default.fileExists(atPath: path) {
            status = SecKeychainOpen(path, &keychain)
        } else {
            let password = UUID().uuidString
            status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
        }
        guard status == errSecSuccess, let keychain else { throw KeychainFailure(operation: "open test keychain for", status: status) }
        var store = KeychainSecretStore(service: service)
        store.testKeychain = keychain
        return store
    }
    #endif

}

private struct KeychainFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "Could not \(operation) Remote connections in Keychain (\(status))." }
}
