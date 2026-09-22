@testable import Emuqu
import XCTest

/// The paywall gate at launch: who sees the paywall, who sees the trial
/// reminder, and who sees nothing.
final class PaywallGatePolicyTests: XCTestCase {
    func testNoAccessMeansThePaywall() {
        XCTAssertEqual(PaywallGatePolicy.launchModal(
            hasAccess: false, hasPermanentAccess: false, isInTrial: false,
            trialDaysRemaining: 0, reminderShownToday: false), .paywall)
    }

    /// The defect this pins: the owner on an Xcode build, and every TestFlight
    /// tester, was counted down through the trial as if their access would
    /// end. Permanent access means no reminder, ever.
    func testPermanentAccessNeverSeesTheTrialReminder() {
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: true, isInTrial: true,
            trialDaysRemaining: 1, reminderShownToday: false))
        XCTAssertFalse(PaywallGatePolicy.showsTrialClock(hasPermanentAccess: true, isTrialActive: true))
    }

    func testATrialUserIsRemindedOncePerDayInTheFinalWeek() {
        XCTAssertEqual(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true,
            trialDaysRemaining: 5, reminderShownToday: false), .trialReminder)
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true,
            trialDaysRemaining: 5, reminderShownToday: true))
        XCTAssertTrue(PaywallGatePolicy.showsTrialClock(hasPermanentAccess: false, isTrialActive: true))
    }

    /// Nothing interrupts the first three weeks. A countdown from day one of
    /// thirty is nagging, and those are the nights the score is built from.
    func testNoReminderUntilTheFinalWeek() {
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true,
            trialDaysRemaining: 30, reminderShownToday: false))
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true,
            trialDaysRemaining: 8, reminderShownToday: false))
        XCTAssertEqual(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: true,
            trialDaysRemaining: 7, reminderShownToday: false), .trialReminder)
    }

    func testAccessOutsideTheTrialShowsNothing() {
        XCTAssertNil(PaywallGatePolicy.launchModal(
            hasAccess: true, hasPermanentAccess: false, isInTrial: false,
            trialDaysRemaining: 0, reminderShownToday: false))
    }
}
