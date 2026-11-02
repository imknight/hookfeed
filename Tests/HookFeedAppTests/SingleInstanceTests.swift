import AppKit
import HookFeedCore
import XCTest
@testable import HookFeedApp

final class SingleInstanceTests: XCTestCase {
    func testIgnoresOwnProcessAndChoosesExistingInstance() {
        XCTAssertNil(SingleInstance.existingPID(in: [(42, false)], current: 42))
        XCTAssertNil(SingleInstance.existingPID(in: [], current: 42))
        XCTAssertEqual(SingleInstance.existingPID(in: [(42, false), (17, false)], current: 42), 17)
        XCTAssertEqual(SingleInstance.existingPID(in: [(17, false), (42, false)], current: 42), 17)
        XCTAssertNil(SingleInstance.existingPID(in: [(17, true), (42, false)], current: 42))
    }

    @MainActor
    func testRelaunchWaitsForQuittingOwner() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var owner: RemoteFileLock? = try RemoteFileLock(path: path)
        let quitting = Task {
            try await Task.sleep(for: .milliseconds(100))
            owner = nil
        }
        XCTAssertNotNil(owner)
        let relaunched = try await RemoteFileLock.acquire(path: path, timeout: 0.6)
        try await quitting.value
        XCTAssertNotNil(relaunched)
    }

    func testLiveOwnerHasBoundedWaitWithoutNeedingBundleID() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try RemoteFileLock(path: path)
        let start = Date()
        do {
            _ = try await RemoteFileLock.acquire(path: path, timeout: 0.12)
            XCTFail("A running owner must retain its instance lock")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EWOULDBLOCK) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        withExtendedLifetime(owner) { }
    }

    @MainActor
    func testDistributedReopenOpensInboxInAccessoryMode() async {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let previousOpen = AppNavigation.showInbox
        let delegate = HookFeedAppDelegate()
        let center = DistributedNotificationCenter.default()
        let object = UUID().uuidString
        let opened = expectation(description: "Running instance opens inbox")
        AppNavigation.showInbox = { opened.fulfill() }
        app.setActivationPolicy(.accessory)
        center.addObserver(delegate, selector: #selector(HookFeedAppDelegate.openInbox(_:)), name: SingleInstance.openInbox, object: object)
        defer {
            center.removeObserver(delegate)
            AppNavigation.showInbox = previousOpen
            app.setActivationPolicy(previousPolicy)
        }
        center.postNotificationName(SingleInstance.openInbox, object: object, userInfo: nil, deliverImmediately: true)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }

}
