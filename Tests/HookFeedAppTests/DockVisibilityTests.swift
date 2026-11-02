import AppKit
import XCTest
@testable import HookFeedApp

final class DockVisibilityTests: XCTestCase {
    @MainActor
    func testDefaultAndPersistedPolicyApplyImmediately() throws {
        let suite = "app.hookfeed.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        defer { defaults.removePersistentDomain(forName: suite); app.setActivationPolicy(previous) }
        XCTAssertEqual(DockVisibility.activationPolicy(defaults: defaults), .regular)
        defaults.set(false, forKey: DockVisibility.key)
        DockVisibility.apply(defaults: defaults)
        XCTAssertEqual(app.activationPolicy(), .accessory)
        XCTAssertEqual(DockVisibility.activationPolicy(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), .accessory)
        defaults.set(true, forKey: DockVisibility.key)
        DockVisibility.apply(defaults: defaults)
        XCTAssertEqual(app.activationPolicy(), .regular)
    }

    @MainActor
    func testInboxCanOpenWithoutChangingAccessoryPolicy() {
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        let previousOpen = AppNavigation.showInbox
        defer { AppNavigation.showInbox = previousOpen; app.setActivationPolicy(previous) }
        app.setActivationPolicy(.accessory)
        var opened = false
        AppNavigation.showInbox = { opened = true }
        AppNavigation.openInbox()
        XCTAssertTrue(opened)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }
}
