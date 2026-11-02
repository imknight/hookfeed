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
    func testHidingDockKeepsActiveSettingsWindowInFront() throws {
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        let suite = "app.hookfeed.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
            app.setActivationPolicy(previous)
        }
        app.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard app.isActive, window.isKeyWindow else {
            throw XCTSkip("This XCTest process cannot obtain foreground activation; verify active Settings focus in the packaged app.")
        }
        defaults.set(false, forKey: DockVisibility.key)
        DockVisibility.apply(defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(app.isActive)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(app.activationPolicy(), .accessory)
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
