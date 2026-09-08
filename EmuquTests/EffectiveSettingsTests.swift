@testable import Emuqu
import XCTest

/// Tests for the resolved ("effective") user settings.
///
/// Every training-load and zone
/// calculation in the app reads these: `effectiveMaxHR` anchors HR reserve in
/// the Banister TRIMP exponential, `effectiveLTHR` is the denominator hrTSS
/// divides by, and `effectiveBodyWeightKg` scales calorie estimates. A wrong
/// fallback here moves every number the user sees without any single screen
/// looking broken.
@MainActor
final class EffectiveSettingsTests: XCTestCase {
    private func settings() -> UserSettings { UserSettings() }

    private func age(_ years: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -years, to: Date()) ?? Date()
    }

    // MARK: - Max HR

    func testUserEnteredMaxHRWins() {
        var s = settings()
        s.maxHR = 191
        XCTAssertEqual(s.effectiveMaxHR, 191)
    }

    /// Tanaka, Monahan & Seals (JACC 2001): HRmax ~= 208 - 0.7 x age. The older
    /// `220 - age` under-estimated for older adults, which inflated HR reserve
    /// and over-weighted easy activity — a 4-mile walk reading as a ~100-TRIMP
    /// session.
    ///
    /// NOT tested at age 40: `208 - 0.7x40` and `220 - 40` are BOTH 180, so an
    /// assertion there cannot tell the two formulas apart: a planted revert to
    /// `220 - age` survives it (mutation verifier). The ages below all
    /// discriminate.
    /// Delegation only. The exact Tanaka values are pinned in
    /// `MaxHeartRateTests` against an explicit calendar.
    ///
    /// Do not restate the arithmetic here: that means deriving an age through
    /// `Calendar.current` and a live `Date()`. `age(n)` adds -n years
    /// preserving wall-clock time, so across a historic DST-rule change the
    /// result can be n years minus an hour — and `dateComponents` then
    /// answers n-1. That makes a test of pure arithmetic depend on the ambient
    /// time zone, and it fails in full-suite runs while passing alone.
    /// The property is checked here; the formula is checked where
    /// no date is involved.
    func testMaxHRFromAgeDelegatesToTanaka() {
        var s = settings()
        s.maxHR = nil
        s.birthday = age(30)
        XCTAssertEqual(
            s.effectiveMaxHR,
            MaxHeartRate.effective(
                userEntered: nil, birthday: s.birthday,
                reference: Date(), calendar: Calendar.current
            ),
            "effectiveMaxHR must be whatever MaxHeartRate says for the same inputs"
        )
        // And it must be Tanaka's answer, not 220-age, for a thirty-something:
        // the two differ by at least 2 bpm either side of 40.
        XCTAssertGreaterThan(s.effectiveMaxHR, 183, "220-age would give 190 or less here")
    }

    /// A real age gets the formula value, not the clamp.
    ///
    /// Asserting `effectiveMaxHR == floor` for a 95-year-old pins the defect
    /// `MaxHeartRateTests` guards against: with a floor of 150, Tanaka reaches
    /// 150 at age 83, so every user above 83 is handed an HRmax higher than
    /// the formula gives. The tolerance spans the two ages the ambient
    /// calendar may resolve (94 or 95).
    func testMaxHRFromAgeUsesTheFormulaNotTheFloor() {
        var s = settings()
        s.maxHR = nil
        s.birthday = age(95)
        XCTAssertEqual(Double(s.effectiveMaxHR), 142, accuracy: 1,
                       "208 - 0.7x95 = 141.5; age may resolve as 94 or 95")
        XCTAssertGreaterThan(s.effectiveMaxHR, MaxHeartRate.floor,
                             "a plausible age must not be clamped")
    }

    func testMaxHRFromAgeIsCappedAt220() {
        var s = settings()
        s.maxHR = nil
        s.birthday = age(1)
        XCTAssertLessThanOrEqual(s.effectiveMaxHR, 220)
    }

    func testMaxHRWithNoInputsHasASafeDefault() {
        var s = settings()
        s.maxHR = nil
        s.birthday = nil
        XCTAssertEqual(s.effectiveMaxHR, 180, "downstream zone math must never divide by nil")
    }

    // MARK: - LTHR

    func testUserEnteredLTHRWins() {
        var s = settings()
        s.lactateThresholdHR = 172
        XCTAssertEqual(s.effectiveLTHR, 172)
    }

    func testLTHRDerivesFrom88PercentOfMaxHR() {
        var s = settings()
        s.lactateThresholdHR = nil
        s.maxHR = 200
        XCTAssertEqual(s.effectiveLTHR, 176, "0.88 x 200")
    }

    func testLTHRFloorIs120NotThe160TheCommentClaimed() {
        // The doc comment said "160 floor"; the code floors
        // at 120. Pinned so the two cannot disagree again — LTHR is the hrTSS
        // denominator, so its value is load-bearing for every training figure.
        var s = settings()
        s.lactateThresholdHR = nil
        s.maxHR = 1
        XCTAssertEqual(s.effectiveLTHR, 120)
    }

    func testLTHRIsBelowMaxHRForRealisticInputs() {
        var s = settings()
        s.lactateThresholdHR = nil
        for maxHR in [150, 170, 190, 210] {
            s.maxHR = maxHR
            XCTAssertLessThan(
                s.effectiveLTHR, maxHR,
                "threshold HR must sit below max HR for maxHR=\(maxHR)"
            )
        }
    }

    // MARK: - Resting HR

    func testUserRestingHRWins() {
        var s = settings()
        s.userRestingHR = 44
        s.baselineHR = 58
        XCTAssertEqual(s.effectiveRestingHR, 44)
    }

    func testFallsBackToTheTrackedBaseline() {
        var s = settings()
        s.userRestingHR = nil
        s.baselineHR = 52.4
        XCTAssertEqual(s.effectiveRestingHR, 52)
    }

    func testImplausiblyLowValuesAreIgnored() {
        // A resting HR at or below 30 is a data error, not a very fit athlete.
        // Accepting it would blow up HR reserve.
        var s = settings()
        s.userRestingHR = 12
        s.baselineHR = nil
        XCTAssertEqual(s.effectiveRestingHR, 60, "an implausible entry falls back to the default")
    }

    func testRestingHRHasASafeDefault() {
        var s = settings()
        s.userRestingHR = nil
        s.baselineHR = nil
        XCTAssertEqual(s.effectiveRestingHR, 60)
    }

    // MARK: - Body weight

    func testUserWeightWins() {
        var s = settings()
        s.bodyWeightKg = 68.5
        XCTAssertEqual(s.effectiveBodyWeightKg, 68.5, accuracy: 1e-9)
    }

    func testZeroOrMissingWeightFallsBack() {
        var s = settings()
        s.bodyWeightKg = 0
        XCTAssertEqual(s.effectiveBodyWeightKg, 75.0, accuracy: 1e-9)
        s.bodyWeightKg = nil
        XCTAssertEqual(s.effectiveBodyWeightKg, 75.0, accuracy: 1e-9)
    }

    // MARK: - Cycling FTP

    func testCyclingFTPIsNilWhenUnsetOrZero() {
        // Nil rather than a guessed default: power zones built on an invented
        // FTP are worse than no power zones.
        var s = settings()
        s.cyclingFTPWatts = nil
        XCTAssertNil(s.effectiveCyclingFTP)
        s.cyclingFTPWatts = 0
        XCTAssertNil(s.effectiveCyclingFTP)
        s.cyclingFTPWatts = -10
        XCTAssertNil(s.effectiveCyclingFTP)
    }

    func testCyclingFTPPassesThroughWhenSet() {
        var s = settings()
        s.cyclingFTPWatts = 245
        XCTAssertEqual(s.effectiveCyclingFTP, 245)
    }
}
