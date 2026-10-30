import Combine
import Foundation
import Security
import Sparkle

enum UpdateEligibility {
    static func allowsUpdates(isDebug: Bool, teamIdentifier: () -> String?) -> Bool {
        !isDebug && teamIdentifier() == "FDRSA4WESN"
    }

    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = (Bundle.main.object(forInfoDictionaryKey: "HookFeedBuildConfiguration") as? String) != "release"
        #endif
        guard UpdateEligibility.allowsUpdates(isDebug: isDebug, teamIdentifier: UpdateEligibility.currentTeamIdentifier) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
