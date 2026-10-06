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

    /// The defect this pins: the owner on an Xcode build, and every
    /// grandfathered beta tester, was counted down through the trial as if their access would
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

    /// Never started: both the trial and the unlock are offered.
    func testANewUserIsOfferedTheTrialAndTheUnlock() {
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: false, canStartTrial: true), .trialAndUnlock)
    }

    /// Once this Apple ID has started the trial, only the unlock is offered.
    func testOnceTheTrialHasStartedOnlyTheUnlockIsOffered() {
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: false, canStartTrial: false), .unlockOnly)
    }

    /// Only a purchase ends the offer, whatever the trial's state.
    func testABuyerIsShownAsUnlockedWithNothingOnOffer() {
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: true, canStartTrial: true), .unlocked)
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: true, canStartTrial: false), .unlocked)
    }

    /// The defect this pins: a device that kept an expired trial start from an
    /// earlier build offered "Start Free Trial", the purchase succeeded, and
    /// the kept start meant it granted no days. The trial clock is now the
    /// App Store transaction's purchase date, so an Apple ID without one is
    /// offered a trial that runs the full thirty days, whatever this device
    /// kept, and one with it is offered nothing new.
    func testStoreKitsTrialRecordDecidesOverALocalTrialStart() {
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: false, hasLocalTrialStart: true, hasPermanentAccess: false))
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: false, hasLocalTrialStart: false, hasPermanentAccess: false))
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: true, hasLocalTrialStart: false, hasPermanentAccess: false))
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: true, hasLocalTrialStart: true, hasPermanentAccess: false))
    }

    /// Before StoreKit answers, a trial start kept here holds the trial back.
    func testUntilStoreKitAnswersTheLocalTrialStartDecides() {
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: nil, hasLocalTrialStart: true, hasPermanentAccess: false))
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(
            storeKitHasTrialTransaction: nil, hasLocalTrialStart: false, hasPermanentAccess: false))
    }

    /// Free access that does not expire gains nothing from a trial, so the
    /// trial is not offered; the unlock still is.
    func testPermanentFreeAccessIsOfferedTheUnlockButNotTheTrial() {
        for hasTransaction in [nil, false, true] as [Bool?] {
            XCTAssertFalse(PaywallGatePolicy.canStartTrial(
                storeKitHasTrialTransaction: hasTransaction, hasLocalTrialStart: false, hasPermanentAccess: true))
        }
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: false, canStartTrial: false), .unlockOnly)
    }

    /// The defect this pins: earlier sandbox builds anchored App Review's
    /// Apple IDs as beta testers, so a reviewer got no paywall at launch and
    /// a "beta tester" note in the App Store build. A beta anchor grants
    /// access only on an install verified as production.
    func testABetaAnchorGrantsNothingOutsideAProductionInstall() {
        XCTAssertFalse(PaywallGatePolicy.grantsBetaTesterAccess(
            isAnchoredBetaTester: true, isVerifiedProductionInstall: false))
        XCTAssertTrue(PaywallGatePolicy.grantsBetaTesterAccess(
            isAnchoredBetaTester: true, isVerifiedProductionInstall: true))
        XCTAssertFalse(PaywallGatePolicy.grantsBetaTesterAccess(
            isAnchoredBetaTester: false, isVerifiedProductionInstall: true))
    }
}
