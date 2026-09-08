@testable import Emuqu
import XCTest

/// The paywall gate at launch: who sees the paywall, who sees the trial
/// reminder, and who sees nothing.
final class PaywallGatePolicyTests: XCTestCase {
    func testNoAccessMeansThePaywall() {
        XCTAssertEqual(PaywallGatePolicy.launchModal(
            hasAccess: false, hasPermanentAccess: false, isInTrial: false, reminderShownToday: false), .paywall)
    }

    /// The defect this pins: the owner on an Xcode build, and every TestFlight
    /// tester, was counted down through the seven days as if their access
    /// would end. Permanent access means no reminder, ever.
    func testPermanentAccessNeverSeesTheTrialReminder() {
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: true, isInTrial: true, reminderShownToday: false))
        XCTAssertFalse(PaywallGatePolicy.showsTrialClock(hasPermanentAccess: true, isTrialActive: true))
    }

    func testATrialUserIsRemindedOncePerDay() {
        XCTAssertEqual(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true, reminderShownToday: false), .trialReminder)
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true, reminderShownToday: true))
        XCTAssertTrue(PaywallGatePolicy.showsTrialClock(hasPermanentAccess: false, isTrialActive: true))
    }

    func testAccessOutsideTheTrialShowsNothing() {
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: false, reminderShownToday: false))
    }
}
