@testable import Emuqu
import XCTest

/// Every per-workout intensity judgement is made against the same resolved
/// heart-rate anchors training load uses (`TrainingLoadSeries.HeartRateAnchors`),
/// the forward projection steps the same EWMA, and a workout's read-time power
/// TSS is the one `TrainingLoadPrecedence` computes.
///
/// Before, "hard workout" and the weekly intensity score read heart-rate
/// reserve against a fixed 60 bpm resting HR while the daily load used the
/// user's own, so with a 48 bpm resting HR a 45-minute session at 118 bpm
/// counted in the load at 62.5 % of reserve but was not "hard" at 58 %.
@MainActor
final class TrainingLoadAnchorsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let athlete = TrainingLoadSeries.HeartRateAnchors(restingHR: 48, maxHR: 160)
    private let sixtyBpm = TrainingLoadSeries.HeartRateAnchors(restingHR: 60, maxHR: 160)

    private func session(minutes: Double = 45, avgHR: Double? = 118, daysAgo: Double = 1) -> HealthKitManager.WorkoutSummary {
        HealthKitManager.WorkoutSummary(
            date: now.addingTimeInterval(-daysAgo * 86_400), type: .running, durationMinutes: minutes,
            caloriesBurned: nil, averageHR: avgHR, maxHR: nil
        )
    }

    // MARK: - Hard workout and intensity read the resolved anchors

    func testHardWorkoutIsJudgedAgainstTheResolvedRestingHR() {
        XCTAssertTrue(session().isHardWorkout(anchors: athlete))
        XCTAssertFalse(session().isHardWorkout(anchors: sixtyBpm))
    }

    func testDaysSinceHardWorkoutUsesTheAnchors() {
        XCTAssertEqual(TrainingLoad.daysSinceHardWorkout(in: [session()], anchors: athlete, relativeTo: now), 1)
        XCTAssertNil(TrainingLoad.daysSinceHardWorkout(in: [session()], anchors: sixtyBpm, relativeTo: now))
    }

    /// 45 min → 22.5 duration points; 70 / 112 = 0.625 of reserve → 31.25.
    func testIntensityScoreUsesTheResolvedReserve() {
        XCTAssertEqual(session().intensityScore(anchors: athlete), 22.5 + 0.625 * 50, accuracy: 1e-9)
    }

    func testWithoutHeartRateLongSessionsStillCountAsHard() {
        XCTAssertTrue(session(minutes: 75, avgHR: nil).isHardWorkout(anchors: athlete))
        XCTAssertFalse(session(minutes: 45, avgHR: nil).isHardWorkout(anchors: athlete))
    }

    /// The weekly score, days-since-hard and the daily load all read one set
    /// of anchors.
    func testTheTrainingLoadBuilderPassesItsAnchorsThrough() {
        let load = TrainingHealthQueries.trainingLoad(
            workouts: [session()], days: 7, anchors: athlete, vo2Max: nil, metrics: .empty, relativeTo: now
        )
        XCTAssertEqual(load.daysSinceHardWorkout, 1)
        XCTAssertEqual(load.weeklyLoadScore, (22.5 + 0.625 * 50) / 7 * 7, accuracy: 1e-9)
    }

    // MARK: - The projection steps the shared EWMA

    func testProjectionIsTheSharedEWMAStepRepeated() {
        let days = TrainingLoadProjection.project(startingATL: 70, startingCTL: 50, dailyTrimp: 80, horizonDays: 5)
        var point = TrainingLoadSeries.Point(atl: 70, ctl: 50)
        for day in days {
            point = point.stepped(load: 80)
            XCTAssertEqual(day.atl, point.atl, accuracy: 1e-12)
            XCTAssertEqual(day.ctl, point.ctl, accuracy: 1e-12)
        }
        XCTAssertEqual(days.count, 5)
    }

    // MARK: - One read-time power TSS

    /// A ride stored with NP but no power TSS: the row's figure and the
    /// figure ATL/CTL count come from one function. NP 200 W at FTP 250 W
    /// over a moving hour is IF 0.8 → 64 TSS.
    func testComputedPowerTSSIsThePrecedenceReadTimeFigure() throws {
        let manager = AppDependencies.current.app.settingsManager
        let original = manager.settings
        defer { manager.settings = original }
        manager.settings.cyclingFTPWatts = 250

        var ride = WorkoutMetadata(sport: .bike)
        ride.normalizedPowerWatts = 200
        ride.samples = (0 ... 60).map { WorkoutSample(offsetSec: $0 * 60, heartRate: nil, mets: nil) }

        let shown = try XCTUnwrap(ride.computedPowerTSS)
        let counted = try XCTUnwrap(
            TrainingLoadPrecedence.readTimePowerTSS(ride, ftp: .current(manager.settings))
        )
        XCTAssertEqual(shown, counted, accuracy: 1e-9)
        XCTAssertEqual(shown, 64, accuracy: 1e-9)
    }
}
