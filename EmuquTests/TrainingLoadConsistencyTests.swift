@testable import Emuqu
import HealthKit
import XCTest

/// The live training load (`TrainingMetricsCache.current`) and the
/// day-by-day series behind the Load & Trajectory chart are built by one
/// day-load builder and one EWMA step, against one set of heart-rate
/// anchors. Before, the live path scored HR-only workouts against a 60 bpm
/// default while the series used the user's resting-HR setting, so with a
/// 48 bpm setting a 60-minute session at 140 bpm was 84.0 TRIMP in `current`
/// and 93.6 in the chart.
final class TrainingLoadConsistencyTests: XCTestCase {
    private let calendar = Calendar.current

    private func day(_ offset: Int, from reference: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference)) ?? reference
    }

    private func workout(on date: Date, minutes: Double = 60, avgHR: Double = 140, load: Double? = nil) -> HealthKitManager.WorkoutSummary {
        HealthKitManager.WorkoutSummary(
            date: date.addingTimeInterval(8 * 3600), type: .running, durationMinutes: minutes,
            caloriesBurned: nil, averageHR: avgHR, maxHR: nil, precomputedLoad: load
        )
    }

    // MARK: - Heart-rate anchors

    func testWithoutAppleRestingHRTheSettingIsUsedNotSixty() {
        let anchors = TrainingLoadSeries.HeartRateAnchors.resolve(appleRestingHR: nil, settingRestingHR: 48, settingMaxHR: 185)
        XCTAssertEqual(anchors.restingHR, 48)
        XCTAssertEqual(anchors.maxHR, 185)
    }

    func testAppleRestingHRWinsOverTheSetting() {
        let anchors = TrainingLoadSeries.HeartRateAnchors.resolve(appleRestingHR: 52, settingRestingHR: 48, settingMaxHR: 185)
        XCTAssertEqual(anchors.restingHR, 52)
    }

    /// The reviewer's case: the day's load is scored against the 48 bpm
    /// setting, which is a different number from the old 60 bpm default.
    func testTheDayLoadUsesTheResolvedRestingHR() {
        let anchors = TrainingLoadSeries.HeartRateAnchors.resolve(appleRestingHR: nil, settingRestingHR: 48, settingMaxHR: 185)
        let session = workout(on: day(0))
        let daily = TrainingLoadSeries.dailyLoad(workouts: [session], firstDay: day(-2), lastDay: day(0), anchors: anchors)
        let expected = session.effectiveLoad(restingHR: 48, maxHR: 185)
        XCTAssertEqual(daily[day(0)] ?? -1, expected, accuracy: 1e-9)
        XCTAssertGreaterThan(expected - session.effectiveLoad(restingHR: 60, maxHR: 185), 5)
    }

    // MARK: - One builder, one EWMA

    func testDailyLoadZeroFillsAndSkipsWorkoutsOutsideTheWindow() {
        let anchors = TrainingLoadSeries.HeartRateAnchors(restingHR: 50, maxHR: 185)
        let daily = TrainingLoadSeries.dailyLoad(
            workouts: [workout(on: day(-10), load: 80), workout(on: day(-1), load: 40), workout(on: day(3), load: 90)],
            firstDay: day(-3), lastDay: day(0), anchors: anchors
        )
        XCTAssertEqual(daily.count, 4)
        XCTAssertEqual(daily[day(-3)], 0)
        XCTAssertEqual(daily[day(-1)], 40)
        XCTAssertNil(daily[day(-10)])
        XCTAssertNil(daily[day(3)])
    }

    func testDailyLoadIsCappedAtTheDailyCeiling() {
        let anchors = TrainingLoadSeries.HeartRateAnchors(restingHR: 50, maxHR: 185)
        let daily = TrainingLoadSeries.dailyLoad(
            workouts: [workout(on: day(0), load: 900), workout(on: day(0), load: 900)],
            firstDay: day(0), lastDay: day(0), anchors: anchors
        )
        XCTAssertEqual(daily[day(0)], TrainingConstants.TRIMP.maxDailyLoad)
    }

    func testOneStepIsTheExactExponentialEWMA() {
        let point = TrainingLoadSeries.Point.zero.stepped(load: 100)
        XCTAssertEqual(point.atl, 100 * (1 - exp(-1.0 / 7)), accuracy: 1e-9)
        XCTAssertEqual(point.ctl, 100 * (1 - exp(-1.0 / 42)), accuracy: 1e-9)
    }

    /// The live value reads `point(through:)`; the series reads `replay`.
    /// Over the same days they must be the same number, every day.
    func testLivePointAndSeriesReplayAgreeOnEveryDay() {
        let anchors = TrainingLoadSeries.HeartRateAnchors(restingHR: 48, maxHR: 185)
        let workouts = (0 ..< 60).filter { [1, 0, 1, 0, 1, 1, 0][$0 % 7] == 1 }.map { workout(on: day(-$0)) }
        let daily = TrainingLoadSeries.dailyLoad(workouts: workouts, firstDay: day(-59), lastDay: day(0), anchors: anchors)
        let series = TrainingLoadSeries.replay(daily)
        for offset in [-59, -30, -1, 0] {
            let live = TrainingLoadSeries.point(through: day(offset), in: daily)
            XCTAssertEqual(series[day(offset)], live, "day \(offset)")
        }
    }

    // MARK: - Freshness

    private func needsRebuild(age: TimeInterval, observed: Bool = false, settings: Bool = false) -> Bool {
        let now = Date()
        return TrainingMetricsCache.needsRebuild(
            lastUpdated: now.addingTimeInterval(-age), hasResult: true,
            observedChange: observed, settingsChanged: settings, reference: now
        )
    }

    /// Before, an unchanged result was reused however old it was, so a
    /// workout from another app didn't reach the load until the next day.
    func testAnUnchangedResultIsRecomputedAfterHalfAnHour() {
        XCTAssertFalse(needsRebuild(age: 10 * 60))
        XCTAssertTrue(needsRebuild(age: TrainingMetricsCache.unchangedMaxAgeSec + 1))
    }

    /// Before, a resting- or max-HR change waited for the next day.
    func testASettingsChangeRecomputesAtOnce() {
        XCTAssertTrue(needsRebuild(age: 5, settings: true))
    }

    func testAWorkoutOrDayChangeRecomputesAfterTheBurstThrottle() {
        XCTAssertFalse(needsRebuild(age: 60, observed: true))
        XCTAssertTrue(needsRebuild(age: TrainingMetricsCache.burstThrottleSec + 1, observed: true))
    }

    func testNoResultAlwaysRecomputes() {
        XCTAssertTrue(TrainingMetricsCache.needsRebuild(
            lastUpdated: nil, hasResult: true, observedChange: false, settingsChanged: false, reference: Date()
        ))
        XCTAssertTrue(TrainingMetricsCache.needsRebuild(
            lastUpdated: Date(), hasResult: false, observedChange: false, settingsChanged: false, reference: Date()
        ))
    }

    func testLoadSettingsSeeAHeartRateSettingChange() {
        var settings = UserSettings()
        settings.userRestingHR = 48
        let before = TrainingMetricsCache.LoadSettings(settings)
        settings.userRestingHR = 52
        XCTAssertNotEqual(before, TrainingMetricsCache.LoadSettings(settings))
    }

    func testHealthKitFingerprintSeesAnotherAppsWorkout() {
        let base = [workout(on: day(-2))]
        XCTAssertEqual(TrainingMetricsCache.healthKitFingerprint(base), TrainingMetricsCache.healthKitFingerprint(base))
        XCTAssertNotEqual(
            TrainingMetricsCache.healthKitFingerprint(base),
            TrainingMetricsCache.healthKitFingerprint(base + [workout(on: day(-1))])
        )
    }
}
