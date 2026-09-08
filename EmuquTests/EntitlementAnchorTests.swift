@testable import Emuqu
import Foundation
import XCTest

/// Tests for the two pure halves of the entitlement system: the monotonic
/// merge rules in `EntitlementAnchor` and the trial arithmetic in
/// `TrialPolicy`.
///
/// Both exist to make one class of bug impossible, and neither can be
/// exercised through the UI without a real App Store receipt, a real
/// keychain and a seven-day wait — so the guarantees are pinned here
/// instead.
///
/// The guarantees under test:
///
/// 1. **A trial cannot be restarted.** Deleting and reinstalling the app
///    destroys `user_settings.json`, so the settings copy of
///    `trialStartDate` comes back nil. The anchor survives, and the merge
///    keeps the EARLIEST start date it has ever seen — so the reinstall
///    resumes the original clock rather than granting a fresh 7 days.
/// 2. **A beta tester is never demoted.** `isBetaTester` ORs across tiers,
///    so a tier that has not heard of the user's beta status cannot revoke
///    it. This is what makes the grandfathering permanent.
/// 3. **Winding the clock back buys nothing.** The trial is measured
///    against the furthest point wall-clock time has ever reached, not
///    against whatever the device currently claims.
final class EntitlementAnchorTests: XCTestCase {
    // MARK: - Fixtures

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        beta: Bool = false,
        trialStart: Date? = nil,
        highWater: Date = Date(timeIntervalSince1970: 0)
    ) -> EntitlementAnchor.Record {
        EntitlementAnchor.Record(isBetaTester: beta, trialStartDate: trialStart, highWaterMark: highWater)
    }

    // MARK: - merged: nil handling

    func testMergedWithBothNilIsNil() {
        XCTAssertNil(EntitlementAnchor.merged(nil, nil))
    }

    func testMergedWithOneNilReturnsTheOther() {
        let only = record(beta: true, trialStart: epoch, highWater: epoch)
        XCTAssertEqual(EntitlementAnchor.merged(only, nil), only)
        XCTAssertEqual(EntitlementAnchor.merged(nil, only), only)
    }

    // MARK: - merged: beta status is monotonic

    func testBetaStatusSurvivesATierThatDoesNotKnowAboutIt() {
        // The exact shape of a reinstall: the keychain remembers, the
        // freshly-created UserDefaults tier does not.
        let keychain = record(beta: true)
        let defaults = record(beta: false)
        XCTAssertEqual(EntitlementAnchor.merged(defaults, keychain)?.isBetaTester, true)
        XCTAssertEqual(EntitlementAnchor.merged(keychain, defaults)?.isBetaTester, true)
    }

    func testBetaStatusStaysFalseWhenNoTierClaimsIt() {
        let merged = EntitlementAnchor.merged(record(beta: false), record(beta: false))
        XCTAssertEqual(merged?.isBetaTester, false)
    }

    /// The scenario the whole anchor exists for, stated at the merge level.
    ///
    /// A beta tester deletes the app and reinstalls, or restores onto a new
    /// phone. UserDefaults is gone; `user_settings.json` is gone. The only
    /// surviving evidence is the synchronizable keychain item, which arrives
    /// with their iCloud Keychain. The merge must still grant.
    ///
    /// The ordering half of this — making sure the launch gate consults the
    /// keychain tier before it decides — lives in
    /// `EntitlementAnchor.resolvedForGate(wallClock:)`, called from
    /// `AppLaunchTasks.loadDataAndContinue()` ahead of the gate. Reading the
    /// fast tier alone there would show this user a paywall.
    func testReinstalledBetaTesterIsStillGrandfathered() {
        let wipedFastTier = EntitlementAnchor.Record.empty
        let survivingKeychain = record(beta: true, trialStart: nil, highWater: epoch)

        let merged = EntitlementAnchor.merged(wipedFastTier, survivingKeychain)
        XCTAssertEqual(merged?.isBetaTester, true, "a reinstalled beta tester must never be asked to pay")
    }

    // MARK: - merged: trial start takes the earliest

    func testMergeKeepsTheEarlierTrialStart() {
        let early = epoch
        let late = epoch.addingTimeInterval(60 * 60 * 24 * 3)
        XCTAssertEqual(EntitlementAnchor.merged(record(trialStart: late), record(trialStart: early))?.trialStartDate, early)
        XCTAssertEqual(EntitlementAnchor.merged(record(trialStart: early), record(trialStart: late))?.trialStartDate, early)
    }

    func testMergeAdoptsATrialStartFromTheTierThatHasOne() {
        let merged = EntitlementAnchor.merged(record(trialStart: nil), record(trialStart: epoch))
        XCTAssertEqual(merged?.trialStartDate, epoch)
    }

    /// The reinstall case, end to end: settings are gone (nil), the anchor
    /// remembers a trial that started five days ago. The user must get the
    /// two days they have left, not a new seven.
    func testReinstallResumesTheOriginalTrialRatherThanRestartingIt() {
        let started = epoch
        let now = epoch.addingTimeInterval(60 * 60 * 24 * 5)

        let wipedSettingsTier = record(trialStart: nil, highWater: now)
        let survivingAnchor = record(trialStart: started, highWater: now)

        let merged = EntitlementAnchor.merged(wipedSettingsTier, survivingAnchor)
        XCTAssertEqual(merged?.trialStartDate, started)
        XCTAssertEqual(TrialPolicy.daysRemaining(start: merged?.trialStartDate, now: now), 2)
    }

    // MARK: - merged / advanced: high-water mark is monotonic

    func testMergeKeepsTheLaterHighWaterMark() {
        let later = epoch.addingTimeInterval(500)
        let merged = EntitlementAnchor.merged(record(highWater: epoch), record(highWater: later))
        XCTAssertEqual(merged?.highWaterMark, later)
    }

    func testAdvancedMovesTheMarkForward() {
        let later = epoch.addingTimeInterval(1_000)
        XCTAssertEqual(EntitlementAnchor.advanced(record(highWater: epoch), to: later).highWaterMark, later)
    }

    func testAdvancedRefusesToMoveTheMarkBackwards() {
        let earlier = epoch.addingTimeInterval(-1_000)
        XCTAssertEqual(EntitlementAnchor.advanced(record(highWater: epoch), to: earlier).highWaterMark, epoch)
    }

    // MARK: - effectiveNow: clock-rollback guard

    func testEffectiveNowUsesTheWallClockWhenItIsAhead() {
        let ahead = epoch.addingTimeInterval(3_600)
        XCTAssertEqual(EntitlementAnchor.effectiveNow(record(highWater: epoch), wallClock: ahead), ahead)
    }

    func testEffectiveNowIgnoresAWoundBackClock() {
        let woundBack = epoch.addingTimeInterval(-60 * 60 * 24 * 30)
        XCTAssertEqual(EntitlementAnchor.effectiveNow(record(highWater: epoch), wallClock: woundBack), epoch)
    }

    /// Setting the device clock back a month must not resurrect an expired
    /// trial. This is the whole point of the high-water mark.
    func testWindingTheClockBackDoesNotReviveAnExpiredTrial() {
        let started = epoch
        let afterExpiry = epoch.addingTimeInterval(60 * 60 * 24 * 10)
        let anchor = record(trialStart: started, highWater: afterExpiry)

        let cheatedClock = epoch.addingTimeInterval(60 * 60 * 24)
        let effective = EntitlementAnchor.effectiveNow(anchor, wallClock: cheatedClock)

        XCTAssertFalse(TrialPolicy.isActive(start: anchor.trialStartDate, now: effective))
        XCTAssertEqual(TrialPolicy.daysRemaining(start: anchor.trialStartDate, now: effective), 0)
    }

    // MARK: - TrialPolicy: duration

    func testTrialIsSevenDays() {
        XCTAssertEqual(TrialPolicy.durationDays, 7)
        XCTAssertEqual(TrialPolicy.duration, 7 * 86_400, accuracy: 0.001)
    }

    func testSettingsManagerReportsTheSameDurationAsThePolicy() {
        // The alias on `SettingsManager` must not drift from the policy.
        XCTAssertEqual(SettingsManager.trialDurationDays, TrialPolicy.durationDays)
    }

    // MARK: - TrialPolicy: daysRemaining

    func testDaysRemainingIsZeroWhenTheTrialNeverStarted() {
        XCTAssertEqual(TrialPolicy.daysRemaining(start: nil, now: epoch), 0)
    }

    func testDaysRemainingIsFullOnTheFirstInstant() {
        XCTAssertEqual(TrialPolicy.daysRemaining(start: epoch, now: epoch), 7)
    }

    /// Rounded UP: someone 6.2 days in still has time left today and must
    /// be told "1", never "0".
    func testDaysRemainingRoundsUpSoTheLastDayIsNotLost() {
        let sixPointTwoDaysIn = epoch.addingTimeInterval(60 * 60 * 24 * 6.2)
        XCTAssertEqual(TrialPolicy.daysRemaining(start: epoch, now: sixPointTwoDaysIn), 1)
    }

    func testDaysRemainingCountsDownAcrossTheTrial() {
        for day in 0 ..< 7 {
            let now = epoch.addingTimeInterval(Double(day) * 86_400)
            XCTAssertEqual(
                TrialPolicy.daysRemaining(start: epoch, now: now),
                7 - day,
                "day \(day) should report \(7 - day) remaining"
            )
        }
    }

    func testDaysRemainingIsZeroExactlyAtExpiry() {
        let exactly = epoch.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(TrialPolicy.daysRemaining(start: epoch, now: exactly), 0)
    }

    func testDaysRemainingIsZeroLongAfterExpiry() {
        let muchLater = epoch.addingTimeInterval(60 * 60 * 24 * 400)
        XCTAssertEqual(TrialPolicy.daysRemaining(start: epoch, now: muchLater), 0)
    }

    /// A clock behind the start date clamps to "full trial" rather than
    /// producing a nonsensical negative elapsed time.
    func testDaysRemainingClampsWhenNowPrecedesTheStart() {
        let before = epoch.addingTimeInterval(-60 * 60 * 24 * 3)
        XCTAssertEqual(TrialPolicy.daysRemaining(start: epoch, now: before), 7)
    }

    // MARK: - TrialPolicy: isActive / hasExpired

    func testIsActiveThroughoutTheTrialAndFalseAtExpiry() {
        XCTAssertTrue(TrialPolicy.isActive(start: epoch, now: epoch))
        XCTAssertTrue(TrialPolicy.isActive(start: epoch, now: epoch.addingTimeInterval(6.99 * 86_400)))
        XCTAssertFalse(TrialPolicy.isActive(start: epoch, now: epoch.addingTimeInterval(7 * 86_400)))
    }

    func testIsActiveIsFalseWhenTheTrialNeverStarted() {
        XCTAssertFalse(TrialPolicy.isActive(start: nil, now: epoch))
    }

    /// `hasExpired` is deliberately NOT the inverse of `isActive`: a trial
    /// that never began has not expired, and the paywall copy depends on
    /// telling those two states apart.
    func testHasExpiredDistinguishesNeverStartedFromRanOut() {
        XCTAssertFalse(TrialPolicy.hasExpired(start: nil, now: epoch))
        XCTAssertFalse(TrialPolicy.hasExpired(start: epoch, now: epoch))
        XCTAssertTrue(TrialPolicy.hasExpired(start: epoch, now: epoch.addingTimeInterval(8 * 86_400)))
    }

    // MARK: - Record.empty

    func testEmptyRecordGrantsNothing() {
        let empty = EntitlementAnchor.Record.empty
        XCTAssertFalse(empty.isBetaTester)
        XCTAssertNil(empty.trialStartDate)
        XCTAssertFalse(TrialPolicy.isActive(start: empty.trialStartDate, now: Date()))
    }

    /// `.distantPast` must never win against a real clock, or the trial
    /// would be measured from the wrong end of time.
    func testEmptyRecordHighWaterMarkNeverBeatsARealClock() {
        let now = Date()
        XCTAssertEqual(EntitlementAnchor.effectiveNow(.empty, wallClock: now), now)
    }

    // MARK: - Round-trip coding

    func testRecordSurvivesAJSONRoundTrip() throws {
        let original = record(beta: true, trialStart: epoch, highWater: epoch.addingTimeInterval(99))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EntitlementAnchor.Record.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - History check

    /// The beta cohort is closed, and every tester's device already holds
    /// archived sessions. A store install that finds them at its first look
    /// belongs to a tester; the receipt is not needed.
    func testExistingHistoryAtFirstCheckGrandfathersTheUser() {
        let record = EntitlementAnchor.evaluatedHistory(.empty, hasHistory: true, wallClock: epoch)
        XCTAssertTrue(record.isBetaTester)
        XCTAssertEqual(record.historyCheckedAt, epoch)
    }

    /// A fresh install has nothing on disk; the check is remembered so the
    /// sessions this new user records during the trial never count later.
    func testAFreshInstallIsCheckedOnceAndNeverAgain() {
        let first = EntitlementAnchor.evaluatedHistory(.empty, hasHistory: false, wallClock: epoch)
        XCTAssertFalse(first.isBetaTester)
        XCTAssertEqual(first.historyCheckedAt, epoch)
        let later = EntitlementAnchor.evaluatedHistory(first, hasHistory: true, wallClock: epoch.addingTimeInterval(86_400 * 3))
        XCTAssertEqual(later, first)
    }

    /// The check timestamp merges like the trial start: the earliest wins, so
    /// a reinstall cannot get a second look at a now-populated archive.
    func testTheHistoryCheckKeepsTheEarliestTimestampOnMerge() {
        let early = EntitlementAnchor.evaluatedHistory(.empty, hasHistory: false, wallClock: epoch)
        let late = EntitlementAnchor.evaluatedHistory(.empty, hasHistory: false, wallClock: epoch.addingTimeInterval(3_600))
        XCTAssertEqual(EntitlementAnchor.merged(late, early)?.historyCheckedAt, epoch)
        XCTAssertEqual(EntitlementAnchor.merged(nil, late)?.historyCheckedAt, late.historyCheckedAt)
    }
}
