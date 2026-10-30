import XCTest
@testable import HookFeedApp

final class UpdateEligibilityTests: XCTestCase {
    func testOnlyOfficialNonDebugBuildsCanUpdate() {
        XCTAssertFalse(UpdateEligibility.allowsUpdates(isDebug: false, teamIdentifier: { nil }))
        XCTAssertFalse(UpdateEligibility.allowsUpdates(isDebug: false, teamIdentifier: { "OTHERTEAM" }))
        XCTAssertFalse(UpdateEligibility.allowsUpdates(isDebug: true, teamIdentifier: { "FDRSA4WESN" }))
        XCTAssertTrue(UpdateEligibility.allowsUpdates(isDebug: false, teamIdentifier: { "FDRSA4WESN" }))
    }

    @MainActor
    func testDebugBuildDoesNotCreateUpdater() {
        let updater = AppUpdater()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }
}
