import Foundation
import Security

public struct KeychainSecretStore: RemoteSecretStore {
    public static var service: String { ProcessInfo.processInfo.environment["HOOKFEED_KEYCHAIN_SERVICE"] ?? "app.hookfeed.remote" }
    let service: String
    private let allowInteraction: Bool
    public let helperPath: String?
    #if DEBUG
    private var testKeychain: SecKeychain?
    #endif
    public init(service: String = Self.service, allowInteraction: Bool = true, helperPath: String? = Self.bundledHelperPath) {
        self.service = service
        self.allowInteraction = allowInteraction
        self.helperPath = helperPath
    }

    public static var bundledHelperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hookfeed").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "connections", kSecAttrSynchronizable as String: false]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        #if DEBUG
        if let testKeychain { query[kSecMatchSearchList as String] = [testKeychain] }
        #endif
        return query
    }

    public func load() throws -> [RemoteConnection] {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(operation: "load", status: status) }
        return try JSONDecoder().decode([RemoteConnection].self, from: data)
    }

    public func save(_ connections: [RemoteConnection]) throws {
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
            if let helperPath { entry[kSecAttrAccess as String] = try helperAccess(at: helperPath) }
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(operation: "create", status: added) }
        } else if status != errSecSuccess { throw KeychainFailure(operation: "update", status: status) }
    }

    public func authorizeHelper(at path: String) throws {
        try save(load())
        let access = try helperAccess(at: path)
        var query = query
        query[kSecReturnRef as String] = true
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { throw KeychainFailure(operation: "find", status: status) }
        status = SecKeychainItemSetAccess(item as! SecKeychainItem, access)
        guard status == errSecSuccess else { throw KeychainFailure(operation: "authorize helper for", status: status) }
    }

    private func helperAccess(at path: String) throws -> SecAccess {
        var applications: [SecTrustedApplication] = []
        for path in [nil, path] as [String?] {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else { throw KeychainFailure(operation: "trust helper for", status: status) }
            applications.append(application)
        }
        var access: SecAccess?
        let status = SecAccessCreate("HookFeed Remote connections" as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else { throw KeychainFailure(operation: "authorize helper for", status: status) }
        return access
    }

    #if DEBUG
    // Called only after the debug harness verifies temporary HOME/store and a UUID service.
    public static func isolatedTestStore(home: String, service: String, helperPath: String? = nil, password: String = UUID().uuidString) throws -> KeychainSecretStore {
        let path = URL(fileURLWithPath: home).appendingPathComponent("remote-tests.keychain-db").path
        var keychain: SecKeychain?
        let status: OSStatus
        if FileManager.default.fileExists(atPath: path) {
            status = SecKeychainOpen(path, &keychain)
        } else {
            status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
        }
        guard status == errSecSuccess, let keychain else { throw KeychainFailure(operation: "open test keychain for", status: status) }
        var store = KeychainSecretStore(service: service, helperPath: helperPath)
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
