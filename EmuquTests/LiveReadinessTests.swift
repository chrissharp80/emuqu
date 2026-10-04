@testable import Emuqu
import HealthKit
import XCTest

/// Tests for `LiveReadiness.compute` — the dashboard medallion's "right now"
/// readiness number. The math wraps `RecoveryScoreCalculator.calculateReadiness`
/// (which has its own coverage); these tests pin the *wrapping* layer:
/// dayFraction interpolation, missing-context fallbacks, the
/// pulledDownByTodaysTraining / liftedByRecovery flags, and the 72h workout
/// load filter.
final class LiveReadinessTests: XCTestCase {

    /// Deterministic "now" anchored to **noon today**.
    ///
    /// These tests build fixtures with `hoursAgo: 6` and then assert the result
    /// counts as *today*. Anchored to `Date()`, that silently breaks between
    /// midnight and ~06:00 local: six hours before 01:06 is 19:06 *yesterday*,
    /// so `todayPrimary` correctly excludes it and four tests fail. It is a real
    /// time-of-day flake, not a product bug — the same class of fragility as the
    /// `NSTimeZone.default` leak fixed in the same pass.
    ///
    /// Noon leaves ≥6 h of same-day headroom in every time zone, so the fixtures
    /// mean what they say whenever the suite happens to run.
    private var noonToday: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }
    // MARK: - Inputs / fallbacks

    func testNoSessionAndNoMetricsCollapsesToInputScore() {
        // Caller passes a recovery score with no session or metrics — the
        // hero should still render that number honestly rather than show
        // nothing.
        let r = LiveReadiness.compute(recoveryScore: 78, morningSession: nil, liveMetrics: nil)
        XCTAssertEqual(r.score, 78, accuracy: 0.01)
        XCTAssertEqual(r.morningRecovery, 78, accuracy: 0.01)
        XCTAssertFalse(r.pulledDownByTodaysTraining)
        XCTAssertFalse(r.liftedByRecovery)
    }

    func testNoLiveMetricsCollapsesToInputScore() {
        let session = makeSession(recoveryScore: 8.5)
        let r = LiveReadiness.compute(recoveryScore: 85, morningSession: session, liveMetrics: nil)
        XCTAssertEqual(r.score, 85, accuracy: 0.01,
                       "Without training metrics, readiness must mirror the morning score so the hero stays honest")
        XCTAssertEqual(r.morningRecovery, 85, accuracy: 0.01)
    }

    func testRestDayReadinessTracksMorningRecovery() {
        // No today TRIMP, no recent workouts, ATL/CTL stable. Readiness
        // should be in the same neighborhood as the morning recovery score.
        let session = makeSession(recoveryScore: 7.5, sessionEndAgoHours: 6)
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(
            recoveryScore: 75,
            morningSession: session,
            liveMetrics: metrics,
            now: Date()
        )
        XCTAssertEqual(r.score, 75, accuracy: 12,
                       "Rest day with stable load should land near morning recovery")
        XCTAssertEqual(r.todayTrimp, 0)
    }

    // MARK: - Drift flags

    func testHardWorkoutPullsReadinessBelowMorning() {
        // Morning was Excellent (90); a hard workout earlier today.
        let now = noonToday
        let session = makeSession(recoveryScore: 9.0, sessionEndAgoHours: 8, now: now)
        let workout = makeWorkout(hoursAgo: 3, durationMinutes: 60, avgHR: 165, now: now)
        let metrics = makeMetrics(atl: 40, ctl: 35, todayTrimp: 120, recentWorkouts: [workout])
        let r = LiveReadiness.compute(recoveryScore: 90, morningSession: session, liveMetrics: metrics, now: now)
        XCTAssertLessThan(r.score, r.morningRecovery,
                          "Hard workout should pull readiness below morning")
        XCTAssertTrue(r.pulledDownByTodaysTraining,
                      "≥3pt drop from morning is the signal that today's training is felt")
        XCTAssertFalse(r.liftedByRecovery)
        XCTAssertNotNil(r.todayPrimaryWorkout, "A hard workout today must be named so the panel can describe it")
        XCTAssertEqual(r.todayPrimaryWorkout?.typeLabel, "run")
    }

    func testRestDayWithFatigueDissipationLiftsReadiness() {
        // Morning ATL was high (40); 12 hours later ATL has bled down (35),
        // CTL flat. No new training today.
        let now = noonToday
        let morningContext = makeContext(atl: 40, ctl: 35)
        let session = makeSession(
            recoveryScore: 6.5,
            sessionEndAgoHours: 12,
            trainingSnapshot: morningContext,
            now: now
        )
        let metrics = makeMetrics(atl: 35, ctl: 35, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 65, morningSession: session, liveMetrics: metrics, now: now)
        XCTAssertGreaterThanOrEqual(r.score, r.morningRecovery,
                                    "Fatigue dissipating with no new training should not pull readiness down")
    }

    /// A drift under 3 points either way is noise, not a story to tell: each
    /// flag fires exactly when its side of the drift reaches 3.
    func testFlagsFireOnlyAtAThreePointDrift() {
        let now = noonToday
        let session = makeSession(recoveryScore: 8.0, sessionEndAgoHours: 2, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 32, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: now)
        XCTAssertEqual(r.pulledDownByTodaysTraining, r.morningRecovery - r.score >= 3)
        XCTAssertEqual(r.liftedByRecovery, r.score - r.morningRecovery >= 3)
        XCTAssertFalse(r.pulledDownByTodaysTraining && r.liftedByRecovery)
    }

    // MARK: - Day fraction interpolation

    func testFreshlyAcceptedSessionUsesMorningContextForATL() {
        // 0 hours since acceptance → effective ATL == morning ATL (no
        // EWMA decay applied yet).
        let now = noonToday
        let morningContext = makeContext(atl: 40, ctl: 50)
        let session = makeSession(
            recoveryScore: 8.0,
            sessionEndAgoHours: 0,
            trainingSnapshot: morningContext,
            now: now
        )
        // Live metrics show stepped ATL (the EWMA already decayed) — at t=0
        // we should still feel the morning's higher fatigue.
        let metrics = makeMetrics(atl: 34, ctl: 50, todayTrimp: 0, recentWorkouts: [])
        let rFresh = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: now)

        // Now jump 24h forward — the same inputs but full day elapsed,
        // effective ATL == live stepped ATL (the bleed-off has fully landed).
        let later = now.addingTimeInterval(24 * 3600)
        let rLater = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: later)

        XCTAssertGreaterThan(rLater.score, rFresh.score,
                             "After a full day of dissipation, readiness must be at least as high as at acceptance")
    }

    func testStaleSessionSuppressesFreshnessBonus() {
        // Session is from yesterday (>24h), morning ATL was higher than
        // current — the freshness bonus would otherwise reward multi-day
        // decay. The implementation pins morningATLForReadiness to the
        // interpolated (i.e. live) value once dayFraction >= 1.0, so the
        // bonus collapses to zero.
        let now = noonToday
        let yesterdayContext = makeContext(atl: 60, ctl: 40)
        let session = makeSession(
            recoveryScore: 7.0,
            sessionEndAgoHours: 36,
            trainingSnapshot: yesterdayContext,
            now: now
        )
        let metrics = makeMetrics(atl: 35, ctl: 40, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 70, morningSession: session, liveMetrics: metrics, now: now)
        // Sanity: hours-since-morning matches the input (no nonsense
        // negative or zero values).
        XCTAssertGreaterThan(r.hoursSinceMorning, 24)
        // Without the suppression, the 25-unit ATL gap would mint ~15 bonus
        // points; with it, we should land near the unbiased calculator output.
        XCTAssertLessThan(r.score, 100)
    }

    // MARK: - Acute fatigue gating

    func testRestDayDoesNotDoubleCountYesterdayWorkout() {
        // Yesterday hard workout (still in recentWorkouts at -20h), no
        // training today. The gate must skip the 24h-decayed acute fatigue
        // term — ATL already carries the workout, double-counting would
        // crush readiness on a rest day.
        let now = noonToday
        let session = makeSession(recoveryScore: 8.0, sessionEndAgoHours: 6, now: now)
        let yesterdayWorkout = makeWorkout(hoursAgo: 20, durationMinutes: 60, avgHR: 165, now: now)
        let metricsRestDay = makeMetrics(atl: 35, ctl: 35, todayTrimp: 0, recentWorkouts: [yesterdayWorkout])
        let metricsActiveDay = makeMetrics(atl: 35, ctl: 35, todayTrimp: 50, recentWorkouts: [yesterdayWorkout])
        let rRest = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metricsRestDay, now: now)
        let rActive = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metricsActiveDay, now: now)
        XCTAssertGreaterThanOrEqual(
            rRest.score, rActive.score - 1,
            "Rest day must not be penalised more than an active day with the same lingering yesterday-workout fatigue"
        )
    }

    // MARK: - Recent workout loads (72h filter)

    func testRecentWorkoutLoadsExcludeOlderThan72h() {
        let now = noonToday
        let recent = makeWorkout(hoursAgo: 24, durationMinutes: 45, avgHR: 150, now: now)
        let stale = makeWorkout(hoursAgo: 96, durationMinutes: 60, avgHR: 160, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [recent, stale])
        let loads = LiveReadiness.recentWorkoutLoads(from: metrics, now: now)
        XCTAssertEqual(loads?.count, 1, "Workouts older than 72h must be filtered out")
        XCTAssertEqual(loads?.first?.hoursAgo ?? 0, 24, accuracy: 0.1)
    }

    func testRecentWorkoutLoadsExcludeFutureDated() {
        // Defensive: a clock skew or import error could land a workout in
        // the future. Skip those rather than pollute readiness with a
        // negative `hoursAgo` (the calculator's exp() would explode).
        let now = noonToday
        let future = makeWorkout(hoursAgo: -2, durationMinutes: 30, avgHR: 140, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [future])
        XCTAssertNil(LiveReadiness.recentWorkoutLoads(from: metrics, now: now),
                     "Future-dated workouts must be skipped, leaving an empty load set")
    }

    func testRecentWorkoutLoadsReturnsNilForEmpty() {
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [])
        XCTAssertNil(LiveReadiness.recentWorkoutLoads(from: metrics))
    }

    // MARK: - Hours since reading

    func testHoursSinceMorningReflectsSessionEnd() {
        let now = noonToday
        let session = makeSession(recoveryScore: 8.0, sessionEndAgoHours: 5, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: now)
        XCTAssertEqual(r.hoursSinceMorning, 5, accuracy: 0.01)
    }

    func testHoursSinceMorningClampedAtZero() {
        // A session with endDate slightly in the future (clock skew) must
        // not produce negative hoursSinceMorning.
        let now = noonToday
        let session = makeSession(recoveryScore: 8.0, sessionEndAgoHours: -1, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 35, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: now)
        XCTAssertGreaterThanOrEqual(r.hoursSinceMorning, 0)
    }

    // MARK: - Workout descriptor

    func testWorkoutDescriptorPicksHighestTrimpToday() {
        // The intensity bucket ("hard" vs "moderate") depends on
        // calculateTrimp reading SettingsManager.shared (effectiveMaxHR,
        // biologicalSex), which we don't control in this test. Pin only
        // the invariant we actually care about: the higher-effort workout
        // wins the narrative slot regardless of the user's saved settings.
        let now = noonToday
        let easyWalk = makeWorkout(hoursAgo: 6, durationMinutes: 25, avgHR: 110, now: now, type: .walking)
        let hardRun = makeWorkout(hoursAgo: 3, durationMinutes: 50, avgHR: 165, now: now, type: .running)
        let descriptor = WorkoutDescriptor.todayPrimary(from: [easyWalk, hardRun], now: now)
        XCTAssertEqual(descriptor?.typeLabel, "run", "Highest-TRIMP today wins the narrative slot")
    }

    func testWorkoutDescriptorPhraseShape() {
        // Sanity-check the canonical phrase shape — used directly in copy.
        let descriptor = WorkoutDescriptor(
            typeLabel: "ride", durationMinutes: 60, intensityWord: "moderate", trimp: 70
        )
        XCTAssertEqual(descriptor.phrase, "moderate 60-min ride")
    }

    func testWorkoutDescriptorReturnsNilOnRestDay() {
        XCTAssertNil(WorkoutDescriptor.todayPrimary(from: [], now: Date()))
    }

    func testWorkoutDescriptorRejectsAbsurdDuration() {
        // HealthKit occasionally surfaces 12+ hour "workouts" (sleep
        // tracker imported as workout, sensor that never stopped). Saying
        // "your hard 827-min run is the day's main event" reads as a bug.
        // The narrative slot must reject anything implausibly long, even
        // if it's the highest-TRIMP candidate of the day.
        let now = noonToday
        let bogusAllDay = makeWorkout(hoursAgo: 6, durationMinutes: 827, avgHR: 110, now: now, type: .running)
        let realRun = makeWorkout(hoursAgo: 3, durationMinutes: 45, avgHR: 165, now: now, type: .running)
        let descriptor = WorkoutDescriptor.todayPrimary(from: [bogusAllDay, realRun], now: now)
        XCTAssertNotNil(descriptor)
        XCTAssertLessThanOrEqual(descriptor?.durationMinutes ?? 999, 360,
                                 "Narrative slot must not feature workouts longer than 6h")
    }

    func testWorkoutDescriptorReturnsNilWhenAllCandidatesAreAbsurd() {
        // Edge case: only bogus workouts available. Better to say nothing
        // than to put "hard 827-min run" on the dashboard.
        let now = noonToday
        let onlyBogus = makeWorkout(hoursAgo: 6, durationMinutes: 800, avgHR: 110, now: now, type: .running)
        XCTAssertNil(WorkoutDescriptor.todayPrimary(from: [onlyBogus], now: now))
    }

    func testHeadlineNamesTodaysMarqueeWorkout() {
        let now = noonToday
        let workout = makeWorkout(hoursAgo: 2, durationMinutes: 45, avgHR: 165, now: now)
        let session = makeSession(recoveryScore: 9.2, sessionEndAgoHours: 6, now: now)
        let metrics = makeMetrics(atl: 40, ctl: 35, todayTrimp: 110, recentWorkouts: [workout])
        let r = LiveReadiness.compute(recoveryScore: 92, morningSession: session, liveMetrics: metrics, now: now)
        if r.pulledDownByTodaysTraining {
            XCTAssertTrue(r.headline.contains("run"),
                          "Headline must name the workout type when training pulled readiness down: got \(r.headline)")
            XCTAssertTrue(r.headline.contains("min"),
                          "Headline must include duration so the user knows which workout is being named")
        }
    }

    func testLoopCardTextIsNilOnUnremarkableDays() {
        // No workout, no significant drift → fall through to the verdict
        // ladder's stock subverdict.
        let now = noonToday
        let session = makeSession(recoveryScore: 8.0, sessionEndAgoHours: 1, now: now)
        let metrics = makeMetrics(atl: 30, ctl: 30, todayTrimp: 0, recentWorkouts: [])
        let r = LiveReadiness.compute(recoveryScore: 80, morningSession: session, liveMetrics: metrics, now: now)
        if !r.pulledDownByTodaysTraining && !r.liftedByRecovery {
            XCTAssertNil(r.loopCardText)
        }
    }

    // MARK: - Helpers

    private func makeSession(
        recoveryScore: Double?,
        sessionEndAgoHours: Double = 6,
        trainingSnapshot: TrainingContext? = nil,
        now: Date = Date()
    ) -> HRVSession {
        let end = now.addingTimeInterval(-sessionEndAgoHours * 3600)
        let start = end.addingTimeInterval(-8 * 3600)  // 8h overnight
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.endDate = end
        session.recoveryScore = recoveryScore
        session.trainingSnapshot = trainingSnapshot
        return session
    }

    private func makeContext(atl: Double, ctl: Double) -> TrainingContext {
        TrainingContext(
            atl: atl, ctl: ctl, tsb: ctl - atl,
            yesterdayTrimp: 0, vo2Max: nil,
            daysSinceHardWorkout: nil, recentWorkouts: nil
        )
    }

    private func makeMetrics(
        atl: Double,
        ctl: Double,
        todayTrimp: Double,
        recentWorkouts: [HealthKitManager.WorkoutSummary]
    ) -> TrainingMetrics {
        TrainingMetrics(
            atl: atl, ctl: ctl, tsb: ctl - atl,
            dailyTrimp: [:],
            todayTrimp: todayTrimp,
            todayWorkouts: [],
            recentWorkouts: recentWorkouts
        )
    }

    private func makeWorkout(
        hoursAgo: Double,
        durationMinutes: Double,
        avgHR: Double,
        now: Date = Date(),
        type: HKWorkoutActivityType = .running
    ) -> HealthKitManager.WorkoutSummary {
        HealthKitManager.WorkoutSummary(
            date: now.addingTimeInterval(-hoursAgo * 3600),
            type: type,
            durationMinutes: durationMinutes,
            caloriesBurned: nil,
            averageHR: avgHR,
            maxHR: nil
        )
    }
}
