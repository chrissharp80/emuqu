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

    /// The defect this pins: earlier sandbox builds anchored every sandbox
    /// Apple ID, App Review's included, as a permanent beta tester, and the
    /// paywall then showed "Full access is already active" with no purchase
    /// button. Free access keeps the offer, with a note saying it is free.
    func testABetaTesterWhoHasNotBoughtIsStillOfferedBothPurchases() {
        XCTAssertEqual(PaywallGatePolicy.offer(hasPurchasedProduct: false, canStartTrial: true), .trialAndUnlock)
        XCTAssertEqual(PaywallGatePolicy.accessNote(
            hasPurchasedProduct: false, isBetaTester: true, hasPermanentAccess: true), .betaTester)
    }

    func testADeveloperInstallIsToldAccessIsActiveAboveTheOffer() {
        XCTAssertEqual(PaywallGatePolicy.accessNote(
            hasPurchasedProduct: false, isBetaTester: false, hasPermanentAccess: true), .freeAccess)
    }

    /// A buyer who is also a recorded beta tester is a buyer.
    func testABuyerIsToldTheAppIsUnlocked() {
        XCTAssertEqual(PaywallGatePolicy.accessNote(
            hasPurchasedProduct: true, isBetaTester: true, hasPermanentAccess: true), .purchased)
    }

    /// A new user and a trial user have no access that lasts, so no note.
    func testNoNoteWithoutLastingAccess() {
        XCTAssertNil(PaywallGatePolicy.accessNote(
            hasPurchasedProduct: false, isBetaTester: false, hasPermanentAccess: false))
    }

    /// The defect this pins: a trial start kept in the synced keychain from an
    /// earlier build or another Apple ID hid the trial product, so a reused
    /// review device could not exercise it. StoreKit's record decides once it
    /// has answered.
    func testStoreKitsTrialRecordDecidesOverALocalTrialStart() {
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: false, hasLocalTrialStart: true))
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: false, hasLocalTrialStart: false))
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: true, hasLocalTrialStart: false))
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: true, hasLocalTrialStart: true))
    }

    /// Before StoreKit answers, a trial start kept here hides the trial.
    func testUntilStoreKitAnswersTheLocalTrialStartDecides() {
        XCTAssertFalse(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: nil, hasLocalTrialStart: true))
        XCTAssertTrue(PaywallGatePolicy.canStartTrial(storeKitHasTrialTransaction: nil, hasLocalTrialStart: false))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWithNoTrialStartTheTermsPromiseTheFullTrial() {
        XCTAssertEqual(PaywallGatePolicy.trialTerms(
            hasFreePermanentAccess: false, localTrialStart: nil, now: now), .fullTrial)
    }

    /// Starting the trial again keeps the earliest start, so the terms give
    /// the kept trial's end, not thirty more days.
    func testARunningLocalTrialIsDescribedByItsEndDate() {
        let start = now.addingTimeInterval(-10 * 86_400)
        XCTAssertEqual(PaywallGatePolicy.trialTerms(
            hasFreePermanentAccess: false, localTrialStart: start, now: now),
            .endsOn(start.addingTimeInterval(TrialPolicy.duration)))
    }

    func testAnEndedLocalTrialIsSaidToHaveEnded() {
        let start = now.addingTimeInterval(-TrialPolicy.duration - 86_400)
        XCTAssertEqual(PaywallGatePolicy.trialTerms(
            hasFreePermanentAccess: false, localTrialStart: start, now: now), .alreadyEnded)
    }

    /// A tester's free access does not lock when a trial ends, so their terms
    /// must not say it will.
    func testFreeAccessTermsSayTheTrialLeavesItAsItIs() {
        XCTAssertEqual(PaywallGatePolicy.trialTerms(
            hasFreePermanentAccess: true, localTrialStart: nil, now: now), .keepsFreeAccess)
        XCTAssertEqual(PaywallGatePolicy.trialTerms(
            hasFreePermanentAccess: true, localTrialStart: now, now: now), .keepsFreeAccess)
    }
}
