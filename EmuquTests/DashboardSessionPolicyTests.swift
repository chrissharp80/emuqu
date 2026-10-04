@testable import Emuqu
import XCTest

/// Tests for `DashboardSessionPolicy` — the pure session-selection rules
/// extracted from `DashboardV2View`.
///
/// The two headline regressions:
///   - A 22-minute partial-backup recovery re-archived AFTER
///     the real 8-hour overnight of the same night displaced it on the
///     dashboard (naive `.first { … }` selection).
///   - A daytime quick reading (depressed mid-effort RMSSD)
///     taken after the morning overnight dominated the HRV chip all day.
final class DashboardSessionPolicyTests: XCTestCase {
    // MARK: - Helpers

    private let calendar = Calendar.current

    /// Fixed 2026 date in the test runner's timezone, so day-attribution
    /// assertions don't depend on when or where the suite runs.
    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return TestDate.from(comps, calendar: calendar)
    }

    private func makeAnalysisResult(analysisDate: Date, readinessScore: Double?) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(
            meanRR: 1000,
            sdnn: 55,
            rmssd: 45,
            pnn50: 20,
            sdsd: 40,
            meanHR: 60,
            sdHR: 5,
            triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30,
            sd2: 60,
            sd1Sd2Ratio: 0.5,
            sampleEntropy: 1.5,
            approxEntropy: 1.3,
            dfaAlpha1: 0.9,
            dfaAlpha2: nil,
            dfaAlpha1R2: 0.95
        )
        let ansMetrics = readinessScore.map {
            ANSMetrics(
                stressIndex: 120,
                pnsIndex: 0.5,
                snsIndex: -0.3,
                readinessScore: $0,
                respirationRate: 14.0,
                nocturnalHRDip: 12.0,
                daytimeRestingHR: 65.0,
                nocturnalMedianHR: 57.0
            )
        }
        return HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 400,
            timeDomain: timeDomain,
            frequencyDomain: nil,
            nonlinear: nonlinear,
            ansMetrics: ansMetrics,
            artifactPercentage: 1.0,
            cleanBeatCount: 400,
            analysisDate: analysisDate
        )
    }

    /// Minimal session fixture in the ArchiveIntegrityTests / TrendAnalysisTests
    /// style: full memberwise init, no RR series (the policy never reads it).
    private func makeSession(
        start: Date,
        durationMinutes: Double,
        type: SessionType = .overnight,
        analyzed: Bool = true,
        recoveryScore: Double? = 7.0,
        readinessScore: Double? = nil,
        sleepEnd: Date? = nil,
        sleepEndMs: Int64? = nil,
        hrvDataQuality: HRVDataQuality? = nil
    ) -> HRVSession {
        var session = HRVSession(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(durationMinutes * 60),
            state: .complete,
            sessionType: type,
            rrSeries: nil,
            analysisResult: analyzed
                ? makeAnalysisResult(analysisDate: start, readinessScore: readinessScore)
                : nil,
            artifactFlags: nil,
            recoveryScore: recoveryScore,
            sleepEndMs: sleepEndMs
        )
        session.hrvDataQuality = hrvDataQuality
        if let sleepEnd {
            let minutes = Int(sleepEnd.timeIntervalSince(start) / 60)
            session.sleepSnapshot = SleepData(
                date: calendar.startOfDay(for: start),
                sleepStart: start,
                sleepEnd: sleepEnd,
                totalSleepMinutes: minutes,
                inBedMinutes: minutes,
                awakeMinutes: 0,
                sleepEfficiency: 95,
                boundarySource: .healthKit
            )
        }
        return session
    }

    private var emptyVitals: RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil,
            respiratoryRateBaseline: nil,
            oxygenSaturation: nil,
            oxygenSaturationMin: nil,
            wristTemperature: nil,
            wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
    }

    private var populatedVitals: RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 14.5,
            respiratoryRateBaseline: 14.0,
            oxygenSaturation: 97.0,
            oxygenSaturationMin: 96.0,
            wristTemperature: 0.1,
            wristTemperatureBaseline: 0.0,
            restingHeartRate: 57.0
        )
    }

    // MARK: - latestOvernightComplete

    /// Regression — a 22-minute partial-backup recovery was
    /// re-archived AFTER the real 8-hour overnight of the same night, so
    /// it sorted first and the naive `.first { … }` picked it. The policy
    /// must pick the longest-duration session within the most recent night.
    func testLatestOvernightCompletePicksLongestWithinSameNight() {
        // Same night (both start Monday May 18); partial sorts first,
        // exactly the ordering that triggered the original bug.
        let partial = makeSession(start: date(5, 18, 23, 30), durationMinutes: 22)
        let realOvernight = makeSession(start: date(5, 18, 22), durationMinutes: 480)
        let sessions = [partial, realOvernight]

        let picked = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar)

        XCTAssertEqual(picked?.id, realOvernight.id)
    }

    /// Regression — a daytime quick reading newer than the
    /// overnight (3 ms RMSSD mid-workout) must not displace the morning
    /// overnight as "today's recovery HRV".
    func testLatestOvernightCompleteIgnoresNewerDaytimeQuickReading() {
        let overnight = makeSession(start: date(5, 18, 22), durationMinutes: 480)
        let middayQuick = makeSession(start: date(5, 19, 14), durationMinutes: 4, type: .quick)
        let sessions = [middayQuick, overnight] // newest first

        let picked = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar)

        XCTAssertEqual(picked?.id, overnight.id)
    }

    /// Across DIFFERENT nights the most recent night wins, even when its
    /// session is shorter — duration only breaks ties WITHIN a night.
    func testLatestOvernightCompleteMostRecentNightWinsAcrossNights() {
        let longOlder = makeSession(start: date(5, 17, 22), durationMinutes: 480)
        let shortNewer = makeSession(start: date(5, 18, 23), durationMinutes: 180)
        let sessions = [shortNewer, longOlder]

        let picked = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar)

        XCTAssertEqual(picked?.id, shortNewer.id)
    }

    /// A night that starts after midnight belongs to the morning it ends,
    /// not to the following night that starts the same evening — keying on
    /// the start day put both in one group and the longer, older one won.
    func testLatestOvernightCompleteKeysNightsOnWakeDay() {
        let mondayNight = makeSession(start: date(5, 19, 0, 30), durationMinutes: 480)
        let tuesdayNight = makeSession(start: date(5, 19, 23), durationMinutes: 420)
        let sessions = [tuesdayNight, mondayNight]

        let picked = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar)

        XCTAssertEqual(picked?.id, tuesdayNight.id)
    }

    // MARK: - `.insufficient` exclusion

    /// Regression — pausing a pre-sleep recording while still awake
    /// archived a 12-min partial as an `.insufficient` overnight with a
    /// baseline-derived score. It must NOT headline the HRV chip: the newer
    /// insufficient partial should be skipped in favor of the real overnight.
    func testLatestOvernightCompleteExcludesInsufficient() {
        let realOvernight = makeSession(start: date(7, 30, 22), durationMinutes: 480)
        let insufficientPartial = makeSession(
            start: date(7, 31, 21, 45), durationMinutes: 13, recoveryScore: 4.8,
            hrvDataQuality: .insufficient
        )
        let sessions = [insufficientPartial, realOvernight] // newest first

        let picked = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar)

        XCTAssertEqual(picked?.id, realOvernight.id)
    }

    /// The recent-days strip must leave a day EMPTY when its only reading is
    /// `.insufficient` — otherwise a paused pre-sleep partial fills the
    /// (dead-strap) slot with a bogus low score, and lands on the wrong day.
    func testSessionForDayExcludesInsufficient() {
        let day = date(7, 31, 21, 45)
        let insufficientPartial = makeSession(
            start: day, durationMinutes: 13, recoveryScore: 4.8, hrvDataQuality: .insufficient
        )

        let picked = DashboardSessionPolicy.sessionForDay(day, in: [insufficientPartial], calendar: calendar)

        XCTAssertNil(picked, "A day whose only reading is .insufficient must render empty")
    }

    /// `.preSleep` (recording ended before sleep → awake RMSSD) is excluded
    /// from the HRV chip too — same reliability gate as `.insufficient`.
    func testLatestOvernightCompleteExcludesPreSleep() {
        let realOvernight = makeSession(start: date(7, 30, 22), durationMinutes: 480)
        let preSleep = makeSession(
            start: date(7, 31, 21), durationMinutes: 40, recoveryScore: 5.0,
            hrvDataQuality: .preSleep
        )
        let picked = DashboardSessionPolicy.latestOvernightComplete(
            in: [preSleep, realOvernight], calendar: calendar
        )
        XCTAssertEqual(picked?.id, realOvernight.id)
    }

    /// A good reading on the same day still wins — the exclusion is scoped to
    /// `.insufficient`/`.preSleep`, not "any short session".
    func testSessionForDayKeepsGoodOverInsufficientSameDay() {
        let good = makeSession(start: date(7, 31, 3), durationMinutes: 420, recoveryScore: 7.0)
        let insufficientPartial = makeSession(
            start: date(7, 31, 21, 45), durationMinutes: 13, recoveryScore: 4.8,
            hrvDataQuality: .insufficient
        )

        let picked = DashboardSessionPolicy.sessionForDay(
            date(7, 31, 12), in: [insufficientPartial, good], calendar: calendar
        )

        XCTAssertEqual(picked?.id, good.id)
    }

    func testLatestOvernightCompleteReturnsNilWithoutAnalyzedOvernights() {
        XCTAssertNil(DashboardSessionPolicy.latestOvernightComplete(in: [], calendar: calendar))

        let unanalyzed = makeSession(start: date(5, 18, 22), durationMinutes: 480, analyzed: false)
        let quick = makeSession(start: date(5, 19, 8), durationMinutes: 5, type: .quick)
        let workout = makeSession(start: date(5, 19, 17), durationMinutes: 45, type: .workout)
        let sessions = [workout, quick, unanalyzed]

        XCTAssertNil(DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: calendar))
    }

    // MARK: - latestWithSleep / latestWithVitals

    func testLatestWithSleepReturnsFirstSessionCarryingSnapshot() {
        let newestNoSleep = makeSession(start: date(6, 9, 22), durationMinutes: 480)
        let withSleep = makeSession(
            start: date(6, 8, 22),
            durationMinutes: 480,
            sleepEnd: date(6, 9, 6)
        )
        let sessions = [newestNoSleep, withSleep]

        XCTAssertEqual(DashboardSessionPolicy.latestWithSleep(in: sessions)?.id, withSleep.id)
        XCTAssertNil(DashboardSessionPolicy.latestWithSleep(in: [newestNoSleep]))
    }

    /// An all-nil vitals snapshot means "Watch hasn't synced yet", not
    /// "vitals exist" — the policy must skip it (matches the dashboard's
    /// live-refetch trigger).
    func testLatestWithVitalsSkipsEmptySnapshot() {
        var newestEmpty = makeSession(start: date(6, 9, 22), durationMinutes: 480)
        newestEmpty.vitalsSnapshot = emptyVitals
        var olderPopulated = makeSession(start: date(6, 8, 22), durationMinutes: 480)
        olderPopulated.vitalsSnapshot = populatedVitals
        let sessions = [newestEmpty, olderPopulated]

        XCTAssertEqual(DashboardSessionPolicy.latestWithVitals(in: sessions)?.id, olderPopulated.id)
        XCTAssertNil(DashboardSessionPolicy.latestWithVitals(in: [newestEmpty]))
    }

    // MARK: - sessionForDay

    /// Wake-date rule — an overnight that started last night and ended this
    /// morning belongs to TODAY (its wake day), keyed on the sleep
    /// snapshot's `sleepEnd`. The recording's `endDate` may be hours (here
    /// a full day — strap left on) past wake and must NOT decide the day.
    func testSessionForDayAttributesOvernightToWakeDayViaSleepSnapshot() {
        let overnight = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 35 * 60, // endDate lands June 11 — forgot to stop the strap
            sleepEnd: date(6, 10, 6, 30)
        )

        let pickedToday = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [overnight], calendar: calendar)
        XCTAssertEqual(pickedToday?.id, overnight.id)

        XCTAssertNil(DashboardSessionPolicy.sessionForDay(date(6, 9, 9), in: [overnight], calendar: calendar))
        XCTAssertNil(DashboardSessionPolicy.sessionForDay(date(6, 11, 9), in: [overnight], calendar: calendar))
    }

    /// Same wake-date rule via the `sleepEndMs` fallback when no sleep
    /// snapshot was frozen.
    func testSessionForDayAttributesOvernightToWakeDayViaSleepEndMs() {
        let overnight = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 36 * 60, // endDate lands June 11
            sleepEndMs: 8 * 3_600_000 // wake at 06:00 June 10
        )

        let pickedToday = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [overnight], calendar: calendar)
        XCTAssertEqual(pickedToday?.id, overnight.id)

        XCTAssertNil(DashboardSessionPolicy.sessionForDay(date(6, 11, 9), in: [overnight], calendar: calendar))
    }

    /// `.workout` captures never count as the day's reading (mid-effort
    /// physiology would put noisy 3 ms RMSSD readings on the streak).
    func testSessionForDayExcludesWorkoutSessions() {
        let workout = makeSession(start: date(6, 10, 17), durationMinutes: 45, type: .workout)
        XCTAssertNil(DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [workout], calendar: calendar))

        // A legitimate quick spot-check on the same day still counts
        // (the rule is exclude-.workout, NOT overnight-only).
        let quick = makeSession(start: date(6, 10, 7), durationMinutes: 5, type: .quick)
        let picked = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [workout, quick], calendar: calendar)
        XCTAssertEqual(picked?.id, quick.id)
    }

    /// Regression, day-attribution side — when a 22-minute
    /// partial-backup recovery shares a day with the real overnight, the
    /// longest-duration overnight wins regardless of array order.
    func testSessionForDayDurationTieBreakPrefersLongestOvernight() {
        let partial = makeSession(start: date(6, 10, 4), durationMinutes: 22)
        let realOvernight = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 480,
            sleepEnd: date(6, 10, 6)
        )

        for ordering in [[partial, realOvernight], [realOvernight, partial]] {
            let picked = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: ordering, calendar: calendar)
            XCTAssertEqual(picked?.id, realOvernight.id)
        }
    }

    /// Overnight is the canonical morning reading — it beats a quick
    /// spot-check on the same day even when the quick sorts first.
    func testSessionForDayPrefersOvernightOverQuickSameDay() {
        let quick = makeSession(start: date(6, 10, 8), durationMinutes: 5, type: .quick)
        let overnight = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 480,
            sleepEnd: date(6, 10, 6)
        )

        let picked = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [quick, overnight], calendar: calendar)
        XCTAssertEqual(picked?.id, overnight.id)
    }

    /// With no overnight on the day, the longest non-workout reading wins.
    func testSessionForDayPicksLongestQuickWhenNoOvernight() {
        let shortQuick = makeSession(start: date(6, 10, 7), durationMinutes: 2, type: .quick)
        let longQuick = makeSession(start: date(6, 10, 8), durationMinutes: 5, type: .quick)

        let picked = DashboardSessionPolicy.sessionForDay(date(6, 10, 9), in: [shortQuick, longQuick], calendar: calendar)
        XCTAssertEqual(picked?.id, longQuick.id)
    }

    // MARK: - recentDays

    func testRecentDaysReturnsSevenDaysEndingTodayOldestFirst() {
        let today = date(6, 10, 9)
        let days = DashboardSessionPolicy.recentDays(from: [], today: today, calendar: calendar)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.date, calendar.startOfDay(for: today))
        XCTAssertEqual(days.first?.date, calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: today)))
        XCTAssertTrue(days.allSatisfy { $0.score == nil && $0.verdict == nil })
    }

    func testRecentDaysScoresFromRecoveryScoreWithVerdict() {
        let today = date(6, 10, 9)
        // Overnight waking this morning — must land in TODAY's cell.
        let overnight = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 480,
            recoveryScore: 7.2,
            sleepEnd: date(6, 10, 6)
        )

        let days = DashboardSessionPolicy.recentDays(from: [overnight], today: today, calendar: calendar)

        XCTAssertEqual(days.last?.score, 72) // 0-10 → 0-100
        XCTAssertEqual(days.last?.verdict, .fair)
        XCTAssertTrue(days.dropLast().allSatisfy { $0.score == nil })
    }

    /// Legacy sessions where `recoveryScore` was never populated fall back
    /// to the HRV-only readiness score rather than rendering "—".
    func testRecentDaysFallsBackToReadinessScoreForLegacySessions() {
        let today = date(6, 10, 9)
        let legacy = makeSession(
            start: date(6, 9, 22),
            durationMinutes: 480,
            recoveryScore: nil,
            readinessScore: 8.0,
            sleepEnd: date(6, 10, 6)
        )

        let days = DashboardSessionPolicy.recentDays(from: [legacy], today: today, calendar: calendar)

        XCTAssertEqual(days.last?.score, 80)
        XCTAssertEqual(days.last?.verdict, .good)
    }
}
