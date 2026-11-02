import Foundation

public enum RemotePreferences {
    public static var domain: String { KeychainSecretStore.service + ".settings" }
    public static var listenerLockPath: String { InboxStore.defaultPath + ".remote.lock" }
    public static var connectionsLockPath: String { InboxStore.defaultPath + ".connections.lock" }

    public static var enabled: Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue("enabled" as CFString, domain as CFString) as? Bool ?? false
    }
}
