@testable import Emuqu
import XCTest

/// Unit tests for the pure `HeatAcclimation` model. These pin the model to
/// the physiology literature it cites: induction reaching ~75% by day 7 and
/// ~94% by day 14, decay of ~30% over two weeks, humidity-aware heat
/// scoring, and a zero cold-start. No UI / persistence / I/O touched.
final class HeatAcclimationTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offsetDays: Int) -> Date {
        anchor.addingTimeInterval(TimeInterval(offsetDays) * day)
    }

    // MARK: - WBGT / heat stress

    func testWBGTRisesWithHumidityAtFixedTemperature() {
        let dry = HeatAcclimation.wbgtEstimate(tempC: 30, relativeHumidity: 30)
        let humid = HeatAcclimation.wbgtEstimate(tempC: 30, relativeHumidity: 80)
        XCTAssertGreaterThan(humid, dry, "Humidity must raise heat stress at the same air temperature")
    }

    func testWBGTReferenceValueInRange() {
        // 35 °C / 50% RH is an extreme day. The BoM simplified SHADE-WBGT
        // proxy reads high at high vapour pressure (no wind/globe terms),
        // landing it in the mid-30s °C — conservative by design. This pins
        // the formula so a future refactor can't silently change it.
        let wbgt = HeatAcclimation.wbgtEstimate(tempC: 35, relativeHumidity: 50)
        XCTAssertEqual(wbgt, 34.8, accuracy: 0.5)
    }

    func testWBGTGradientAcrossTrainingConditions() {
        // The severity span should keep a useful gradient: a hot-humid day is
        // a strong-but-not-saturated stimulus, an extreme day is at the
        // ceiling. Bounds follow the severitySpanC = 12 calibration (a
        // session saturates at WBGT ≈ 31, so a
        // 30 °C/55 % day — WBGT ≈ 30 — scores ~0.92, just under the cap).
        let warm = HeatAcclimation.sessionStimulus(
            .init(tempC: 30, relativeHumidity: 55, durationMinutes: 60)
        )
        let extreme = HeatAcclimation.sessionStimulus(
            .init(tempC: 35, relativeHumidity: 50, durationMinutes: 60)
        )
        XCTAssertGreaterThan(warm, 0.4)
        XCTAssertLessThan(warm, 0.95, "A hot-humid day should be strong but not yet a fully saturated stimulus")
        XCTAssertGreaterThanOrEqual(extreme, 0.95, "An extreme day should be a near-maximal stimulus")
        XCTAssertGreaterThan(extreme, warm, "Hotter must score higher")
    }

    func testCoolDryDayIsNotAStimulus() {
        // 16 °C / 40% RH — below the WBGT threshold, no adaptation signal.
        let s = HeatAcclimation.sessionStimulus(
            .init(tempC: 16, relativeHumidity: 40, durationMinutes: 60)
        )
        XCTAssertEqual(s, 0, accuracy: 1e-9)
    }

    func testHotLongSessionIsFullStimulus() {
        let s = HeatAcclimation.sessionStimulus(
            .init(tempC: 34, relativeHumidity: 65, durationMinutes: 60)
        )
        XCTAssertEqual(s, 1.0, accuracy: 1e-6, "A long, very hot session should be a maximal stimulus")
    }

    func testTooBriefSessionDoesNotCount() {
        let s = HeatAcclimation.sessionStimulus(
            .init(tempC: 34, relativeHumidity: 65, durationMinutes: 5)
        )
        XCTAssertEqual(s, 0, accuracy: 1e-9, "A 5-minute exposure is below the minimum stimulus duration")
    }

    func testDailyStimulusSaturatesAtOne() {
        let exposures = Array(
            repeating: HeatAcclimation.Exposure(tempC: 34, relativeHumidity: 65, durationMinutes: 60),
            count: 3
        )
        XCTAssertEqual(HeatAcclimation.dailyStimulus(exposures), 1.0, accuracy: 1e-9)
    }

    // MARK: - Induction time-course (matches literature)

    private func levelAfterSustainedDays(_ n: Int, stimulus: Double = 1.0) -> Double {
        let days = (0..<n).map { HeatAcclimation.DayInput(date: date($0), stimulus: stimulus) }
        return HeatAcclimation.replay(days).last?.level ?? 0
    }

    func testColdStartIsZero() {
        XCTAssertEqual(HeatAcclimation.replay([]).count, 0)
        // First-ever day with no heat: stays at zero.
        let restOnly = HeatAcclimation.replay([.init(date: date(0), stimulus: 0)])
        XCTAssertEqual(restOnly.first?.level ?? -1, 0, accuracy: 1e-9)
    }

    func testInductionReachesAboutSeventyFivePercentByDaySeven() {
        let l = levelAfterSustainedDays(7)
        XCTAssertEqual(l, 75, accuracy: 4, "HR-dominated adaptation is ~complete (~75%) by day 7")
    }

    func testInductionReachesAboutNinetyPercentByDayFourteen() {
        let l = levelAfterSustainedDays(14)
        XCTAssertGreaterThan(l, 90, "Full acclimatization (~14 days) should be >90%")
        XCTAssertLessThan(l, 100)
    }

    func testInductionIsMonotonicUnderSustainedHeat() {
        let days = (0..<14).map { HeatAcclimation.DayInput(date: date($0), stimulus: 1.0) }
        let samples = HeatAcclimation.replay(days)
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThan(b.level, a.level, "Level must rise every sustained-heat day")
        }
    }

    // MARK: - Decay time-course (matches literature)

    func testDecayLosesAboutThirtyPercentInTwoWeeks() throws {
        // Acclimate for 14 days, then 14 days with no heat exposure.
        var days = (0..<14).map { HeatAcclimation.DayInput(date: date($0), stimulus: 1.0) }
        let acclimatedLevel = try XCTUnwrap(HeatAcclimation.replay(days).last).level
        days += (14..<28).map { HeatAcclimation.DayInput(date: date($0), stimulus: 0) }
        let afterDecay = try XCTUnwrap(HeatAcclimation.replay(days).last).level
        let fractionLost = (acclimatedLevel - afterDecay) / acclimatedLevel
        XCTAssertEqual(fractionLost, 0.30, accuracy: 0.05, "~30% of adaptation is lost after two weeks without heat")
    }

    func testDecayIsMonotonicWithoutHeat() {
        var days = (0..<14).map { HeatAcclimation.DayInput(date: date($0), stimulus: 1.0) }
        days += (14..<28).map { HeatAcclimation.DayInput(date: date($0), stimulus: 0) }
        let samples = HeatAcclimation.replay(days)
        let decayPhase = Array(samples.suffix(14))
        for (a, b) in zip(decayPhase, decayPhase.dropFirst()) {
            XCTAssertLessThan(b.level, a.level, "Level must fall every no-heat day")
        }
    }

    // MARK: - Bands

    func testBands() {
        XCTAssertEqual(HeatAcclimation.band(for: 10), .notAcclimated)
        XCTAssertEqual(HeatAcclimation.band(for: 40), .partial)
        XCTAssertEqual(HeatAcclimation.band(for: 70), .wellAcclimated)
        XCTAssertEqual(HeatAcclimation.band(for: 90), .fullyAcclimated)
    }

    // MARK: - Days to target

    func testDaysToTargetFromZeroIsAboutTenDays() throws {
        let n = try XCTUnwrap(
            HeatAcclimation.daysToTarget(current: 0, target: 85, assumedDailyStimulus: 1.0)
        )
        XCTAssertEqual(n, 10, "From cold, ~10 hot days to full acclimatization at a max daily stimulus")
    }

    func testDaysToTargetZeroWhenAlreadyThere() {
        XCTAssertEqual(HeatAcclimation.daysToTarget(current: 90, target: 85), 0)
    }

    func testDaysToTargetUnreachableAtWeakStimulus() {
        // A daily stimulus of 0.5 tops out at level 50, so target 85 is
        // unreachable no matter how many days.
        XCTAssertNil(HeatAcclimation.daysToTarget(current: 0, target: 85, assumedDailyStimulus: 0.5))
    }

    // MARK: - Adapted-to temperature phrasing

    func testAdaptedWBGTNilBelowFloor() {
        XCTAssertNil(HeatAcclimation.adaptedWBGT(for: 10))
    }

    func testAdaptedWBGTRisesWithLevel() throws {
        let mid = try XCTUnwrap(HeatAcclimation.adaptedWBGT(for: 50))
        let high = try XCTUnwrap(HeatAcclimation.adaptedWBGT(for: 100))
        XCTAssertGreaterThan(high, mid)
        XCTAssertEqual(
            high,
            HeatConstants.stimulusWBGTThreshold + HeatConstants.adaptedWBGTSpanC,
            accuracy: 1e-6
        )
    }

    // MARK: - Replay ordering robustness

    func testReplayIsOrderIndependentOfInputArray() throws {
        let forward = (0..<10).map { HeatAcclimation.DayInput(date: date($0), stimulus: 1.0) }
        let shuffled = forward.reversed().map { $0 }
        XCTAssertEqual(
            try XCTUnwrap(HeatAcclimation.replay(forward).last).level,
            try XCTUnwrap(HeatAcclimation.replay(shuffled).last).level,
            accuracy: 1e-9,
            "replay() sorts by date, so input order must not change the result"
        )
    }
}
