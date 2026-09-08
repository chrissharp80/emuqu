@testable import Emuqu
import os
import XCTest

/// Tests for `DailyLoopAnalysis` — the "today, in one glance" loop classifier
/// shared by the Holistic Daily Report PDF and the Dashboard's Today's Loop card.
///
/// This type is the single
/// source of truth for a user-facing verdict that appears in two surfaces. It is
/// also the codebase's cleanest example of the refactor spec's functional core:
/// value-typed snapshot inputs, pure computed-property outputs, no singletons.
/// That makes it trivially testable.
///
/// Coverage targets, in the order the type computes them:
///   • `workoutIntensity` — the α1 / %max-HR fusion and each of its branches
///   • `lnRmssdBaseline` — the log-normal SWC baseline, its 3-reading minimum,
///     its self-exclusion rule, and its unreliable-session filter
///   • `hrvZScore` / above / below — the ±0.5 SD Smallest Worthwhile Change band
///   • `loopState` — all six states including the cumulative-load guard
///   • `verdict` / `verdictTone` / `loopParagraph` — the narrative layer
final class DailyLoopAnalysisTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    /// `NSTimeZone.default` is process-global; see `ArchivePolicyTests` for the
    /// leak this guards against.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - workoutIntensity

    /// No workout metadata at all → `.easy` is the documented fallback.
    func testIntensityWithoutMetadataIsEasy() {
        let a = makeAnalysis(workout: makeWorkout(metadata: nil))
        XCTAssertEqual(a.workoutIntensity, .easy)
    }

    /// High α1 (≥ 0.75) with sub-threshold HR is the aerobic signature.
    func testHighAlpha1AndLowHRIsEasy() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [0.95, 0.85, 0.90], peakHR: 120))
        XCTAssertEqual(a.workoutIntensity, .easy, "α1 ≥ 0.75 with peak < 75% max is the aerobic signature")
    }

    /// α1 below 0.50 means the autonomic system is saturated — hard regardless of HR.
    func testLowAlpha1IsHardEvenAtModestHR() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [0.40, 0.45, 0.35], peakHR: 130))
        XCTAssertEqual(a.workoutIntensity, .hard, "α1 < 0.50 is hard even when peak HR looks moderate")
    }

    /// ≥ 85% of max HR is hard on the HR axis alone.
    func testPeakAt85PercentMaxIsHard() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [], peakHR: 170), userMaxHR: 200)
        XCTAssertEqual(a.workoutIntensity, .hard)
    }

    /// The 0.70–0.85 %max band is moderate.
    func testPeakInSeventyToEightyFiveBandIsModerate() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [], peakHR: 150), userMaxHR: 200)
        XCTAssertEqual(a.workoutIntensity, .moderate)
    }

    /// Below 70% max with no α1 evidence falls through to easy.
    func testLowPeakWithoutAlphaIsEasy() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [], peakHR: 110), userMaxHR: 200)
        XCTAssertEqual(a.workoutIntensity, .easy)
    }

    /// Boundary: exactly 85% of max is hard (the comparison is `>=`).
    func testPeakExactlyAt85PercentIsHard() {
        let a = makeAnalysis(workout: makeWorkout(alphas: [], peakHR: 170), userMaxHR: 200)
        XCTAssertEqual(a.workoutIntensity, .hard, "0.85 boundary is inclusive")
    }

    // MARK: - Baseline and the SWC band

    /// Fewer than three prior readings → no baseline, so no z-score and no
    /// above/below classification.
    func testBaselineRequiresThreeReadings() {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 60),
            recent: [makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertNil(a.recoveryBaselineRMSSD, "Two readings is below the 3-reading minimum")
        XCTAssertNil(a.hrvZScore)
        XCTAssertFalse(a.isRecoveryAboveBaseline)
        XCTAssertFalse(a.isRecoveryBelowBaseline)
    }

    /// The baseline is geometric — exp(mean(ln x)) — not arithmetic. For
    /// 40/50/62.5 the geometric mean is exactly 50, the arithmetic mean is
    /// 50.83. Pinning the geometric value is what keeps this card's narrative
    /// consistent with the recovery score.
    func testBaselineIsGeometricNotArithmetic() throws {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 50),
            recent: [makeOvernight(rmssd: 40), makeOvernight(rmssd: 50), makeOvernight(rmssd: 62.5)]
        )
        let baseline = try XCTUnwrap(a.recoveryBaselineRMSSD)
        XCTAssertEqual(baseline, 50.0, accuracy: 0.001, "exp(mean(ln)) of 40/50/62.5 is exactly 50")
        XCTAssertNotEqual(baseline, 50.833, accuracy: 0.01, "must not be the arithmetic mean")
    }

    /// A reading is never compared against a baseline that contains it.
    func testTodaysSessionIsExcludedFromItsOwnBaseline() throws {
        let today = makeOvernight(rmssd: 200)
        let a = makeAnalysis(
            overnight: today,
            recent: [today, makeOvernight(rmssd: 50), makeOvernight(rmssd: 50), makeOvernight(rmssd: 50)]
        )
        let baseline = try XCTUnwrap(a.recoveryBaselineRMSSD)
        XCTAssertEqual(baseline, 50.0, accuracy: 0.001, "today's 200 ms must not inflate its own baseline")
    }

    /// Sessions flagged `.insufficient` / `.preSleep` must not enter the
    /// baseline — mirrors `BaselineTracker`.
    func testUnreliableSessionsExcludedFromBaseline() {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 50),
            recent: [
                makeOvernight(rmssd: 50),
                makeOvernight(rmssd: 50),
                makeOvernight(rmssd: 5, quality: .insufficient),
                makeOvernight(rmssd: 5, quality: .preSleep)
            ]
        )
        XCTAssertNil(
            a.recoveryBaselineRMSSD,
            "Only 2 reliable readings remain after filtering, which is below the 3-reading minimum"
        )
    }

    /// Inside ±0.5 SD nothing is claimed in either direction — this is the
    /// deadband the recovery score also treats as neutral.
    func testWithinSWCBandIsNeitherAboveNorBelow() throws {
        // Baseline is 48/50/52 → mean ln ≈ 3.9115, SD ≈ 0.040. That SD is tight,
        // so the ±0.5 SD band is only about ±2% in raw RMSSD: 51 ms already sits
        // at z ≈ 0.51, just OUTSIDE the band. 50.5 ms lands at z ≈ 0.26, safely
        // inside it. The narrowness is the point — the deadband scales with the
        // person's own variability, not a fixed percentage.
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 50.5),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        let z = try XCTUnwrap(a.hrvZScore)
        XCTAssertLessThan(abs(z), 0.5, "fixture must land inside the SWC band for this test to mean anything")
        XCTAssertFalse(a.isRecoveryAboveBaseline)
        XCTAssertFalse(a.isRecoveryBelowBaseline)
    }

    /// Beyond +0.5 SD the reading counts as genuinely above baseline.
    func testBeyondSWCBandIsAboveBaseline() throws {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 90),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        let z = try XCTUnwrap(a.hrvZScore)
        XCTAssertGreaterThanOrEqual(z, 0.5)
        XCTAssertTrue(a.isRecoveryAboveBaseline)
        XCTAssertFalse(a.isRecoveryBelowBaseline)
    }

    /// And symmetrically below.
    func testBeyondSWCBandIsBelowBaseline() throws {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 25),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        let z = try XCTUnwrap(a.hrvZScore)
        XCTAssertLessThanOrEqual(z, -0.5)
        XCTAssertTrue(a.isRecoveryBelowBaseline)
        XCTAssertFalse(a.isRecoveryAboveBaseline)
    }

    /// The percentage readout is relative to the geometric baseline.
    func testHrvPercentVsBaseline() throws {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 60),
            recent: [makeOvernight(rmssd: 50), makeOvernight(rmssd: 50), makeOvernight(rmssd: 50)]
        )
        let pct = try XCTUnwrap(a.hrvPercentVsBaseline)
        XCTAssertEqual(pct, 20.0, accuracy: 0.01, "60 against a baseline of 50 is +20%")
    }

    /// A zero or missing RMSSD produces no z-score rather than a divide-by-zero.
    func testZeroRmssdYieldsNoZScore() {
        let a = makeAnalysis(
            overnight: makeOvernight(rmssd: 0),
            recent: [makeOvernight(rmssd: 50), makeOvernight(rmssd: 50), makeOvernight(rmssd: 50)]
        )
        XCTAssertNil(a.hrvZScore)
        XCTAssertNil(a.hrvPercentVsBaseline)
    }

    // MARK: - loopState

    /// No workout at all is the cold-start case.
    func testNoWorkoutIsUndetermined() {
        let a = DailyLoopAnalysis(
            workoutSession: nil, overnightSession: makeOvernight(rmssd: 50),
            recentOvernightSessions: [], userMaxHR: 190
        )
        XCTAssertEqual(a.loopState, .undetermined)
        XCTAssertEqual(a.verdictTone, .neutral)
        XCTAssertEqual(a.verdict.label, "Not enough data yet")
    }

    /// High recovery + easy session + no cumulative load = room to push.
    func testHighRecoveryEasySessionIsUnderloading() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.95], peakHR: 110, trimp: 30, tsb: 5, atl: 30, ctl: 40),
            overnight: makeOvernight(rmssd: 90),
            recent: highBaselineFixture
        )
        XCTAssertEqual(a.loopState, .underloading)
        XCTAssertEqual(a.verdictTone, .positive)
        XCTAssertTrue(a.verdict.label.contains("Underloading"))
    }

    /// Regression guard: the same high-recovery easy day, but
    /// the athlete is cumulatively loaded (TSB ≤ −5). `.underloading` would tell
    /// them to push on top of accumulated fatigue, so it must become
    /// `.absorbing` instead.
    func testCumulativeLoadBlocksUnderloadingViaTSB() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.95], peakHR: 110, trimp: 30, tsb: -10, atl: 45, ctl: 35),
            overnight: makeOvernight(rmssd: 90),
            recent: highBaselineFixture
        )
        XCTAssertEqual(a.loopState, .absorbing, "TSB ≤ −5 must refuse the 'room to push' verdict")
    }

    /// Same guard, reached through ACWR ≥ 1.3 rather than TSB.
    func testCumulativeLoadBlocksUnderloadingViaACWR() {
        // ATL 52 / CTL 40 = 1.3 exactly, with TSB deliberately positive so the
        // TSB arm of the guard cannot be what fires.
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.95], peakHR: 110, trimp: 30, tsb: 5, atl: 52, ctl: 40),
            overnight: makeOvernight(rmssd: 90),
            recent: highBaselineFixture
        )
        XCTAssertEqual(a.loopState, .absorbing, "ACWR ≥ 1.3 must refuse the 'room to push' verdict")
    }

    /// The guard is specific to the easy branch — a hard day with high recovery
    /// is `.absorbing` regardless.
    func testHighRecoveryHardSessionIsAbsorbing() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.40], peakHR: 180, trimp: 200, tsb: 5, atl: 30, ctl: 40),
            overnight: makeOvernight(rmssd: 90),
            recent: highBaselineFixture
        )
        XCTAssertEqual(a.loopState, .absorbing)
        XCTAssertEqual(a.verdictTone, .positive)
    }

    /// Recovery inside the SWC band is the balanced case whatever the load.
    func testNeutralRecoveryIsSustainable() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
            overnight: makeOvernight(rmssd: 50),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertEqual(a.loopState, .sustainable)
        XCTAssertEqual(a.verdictTone, .positive)
    }

    /// Low recovery handled with an easy day is the correct call.
    func testLowRecoveryEasySessionIsBackedOff() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.95], peakHR: 105, trimp: 20),
            overnight: makeOvernight(rmssd: 25),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertEqual(a.loopState, .backedOff)
        XCTAssertEqual(a.verdictTone, .neutral, "backed off is neutral, not positive")
    }

    /// Low recovery plus a hard session is the only cautionary state.
    func testLowRecoveryHardSessionIsHighStrain() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.40], peakHR: 185, trimp: 220),
            overnight: makeOvernight(rmssd: 25),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertEqual(a.loopState, .highStrain)
        XCTAssertEqual(a.verdictTone, .caution, "high strain is the one caution-toned state")
    }

    // MARK: - Narrative layer

    /// Every state must produce non-empty label and blurb — the PDF and the
    /// card both render these directly.
    func testEveryStateProducesNonEmptyVerdictCopy() {
        let fixtures: [(String, DailyLoopAnalysis)] = [
            ("underloading", makeAnalysis(
                workout: makeWorkout(alphas: [0.95], peakHR: 110, trimp: 30, tsb: 5, atl: 30, ctl: 40),
                overnight: makeOvernight(rmssd: 90), recent: highBaselineFixture
            )),
            ("absorbing", makeAnalysis(
                workout: makeWorkout(alphas: [0.40], peakHR: 180, trimp: 200),
                overnight: makeOvernight(rmssd: 90), recent: highBaselineFixture
            )),
            ("sustainable", makeAnalysis(
                workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
                overnight: makeOvernight(rmssd: 50),
                recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
            )),
            ("backedOff", makeAnalysis(
                workout: makeWorkout(alphas: [0.95], peakHR: 105, trimp: 20),
                overnight: makeOvernight(rmssd: 25),
                recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
            )),
            ("highStrain", makeAnalysis(
                workout: makeWorkout(alphas: [0.40], peakHR: 185, trimp: 220),
                overnight: makeOvernight(rmssd: 25),
                recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
            )),
            ("undetermined", DailyLoopAnalysis(
                workoutSession: nil, overnightSession: nil,
                recentOvernightSessions: [], userMaxHR: 190
            ))
        ]
        for (name, a) in fixtures {
            XCTAssertFalse(a.verdict.label.isEmpty, "\(name) label must not be empty")
            XCTAssertFalse(a.verdict.blurb.isEmpty, "\(name) blurb must not be empty")
            XCTAssertFalse(a.loopParagraph.isEmpty, "\(name) paragraph must not be empty")
        }
    }

    /// The `.absorbing` blurb is split by today's intensity — calling an easy
    /// walk "real work" was the user-visible bug this split fixed.
    func testAbsorbingCopySplitsByIntensity() {
        let easyAbsorbing = makeAnalysis(
            workout: makeWorkout(alphas: [0.95], peakHR: 110, trimp: 30, tsb: -10, atl: 45, ctl: 35),
            overnight: makeOvernight(rmssd: 90), recent: highBaselineFixture
        )
        let hardAbsorbing = makeAnalysis(
            workout: makeWorkout(alphas: [0.40], peakHR: 180, trimp: 200),
            overnight: makeOvernight(rmssd: 90), recent: highBaselineFixture
        )
        XCTAssertEqual(easyAbsorbing.loopState, .absorbing)
        XCTAssertEqual(hardAbsorbing.loopState, .absorbing)
        XCTAssertEqual(easyAbsorbing.verdict.label, hardAbsorbing.verdict.label, "label is shared")
        XCTAssertNotEqual(
            easyAbsorbing.verdict.blurb, hardAbsorbing.verdict.blurb,
            "an easy day must not be described as 'real work into the system'"
        )
        XCTAssertFalse(easyAbsorbing.verdict.blurb.contains("real work"))
        XCTAssertTrue(hardAbsorbing.verdict.blurb.contains("real work"))
    }

    /// Inside the SWC band the paragraph must not quote a percentage the
    /// recovery score won't act on.
    func testParagraphSuppressesPercentageInsideSWCBand() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
            overnight: makeOvernight(rmssd: 50.5),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertTrue(
            a.loopParagraph.contains("in line with your baseline"),
            "a within-noise move must be described as in-line, not as a percentage"
        )
        XCTAssertFalse(a.loopParagraph.contains("% above"))
        XCTAssertFalse(a.loopParagraph.contains("% below"))
    }

    /// Outside the band it does quote the percentage and the direction.
    func testParagraphQuotesPercentageOutsideSWCBand() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
            overnight: makeOvernight(rmssd: 90),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertTrue(a.loopParagraph.contains("% above"), "a real move should be quoted with direction")
    }

    /// With no baseline at all the paragraph falls back to the raw reading
    /// rather than claiming a comparison it cannot make.
    func testParagraphFallsBackToRawReadingWithoutBaseline() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
            overnight: makeOvernight(rmssd: 47),
            recent: []
        )
        XCTAssertTrue(a.loopParagraph.contains("47 ms"), "no baseline → quote the raw value")
    }

    /// And with no reading at all it says so.
    func testParagraphHandlesMissingOvernightReading() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 90),
            overnight: nil, recent: []
        )
        XCTAssertTrue(a.loopParagraph.contains("Without a morning HRV reading"))
    }

    /// TRIMP is surfaced in the paragraph so the number the user sees on the
    /// card matches the one in the PDF.
    func testParagraphReportsTrimp() {
        let a = makeAnalysis(
            workout: makeWorkout(alphas: [0.60], peakHR: 150, trimp: 137),
            overnight: makeOvernight(rmssd: 50),
            recent: [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
        )
        XCTAssertTrue(a.loopParagraph.contains("137 TRIMP"))
    }

    // MARK: - Fixtures

    /// A baseline around 50 ms with enough spread that a 90 ms reading clears
    /// +0.5 SD. Shared by the `.absorbing` / `.underloading` cases.
    private var highBaselineFixture: [HRVSession] {
        [makeOvernight(rmssd: 48), makeOvernight(rmssd: 50), makeOvernight(rmssd: 52)]
    }

    private func makeAnalysis(
        workout: HRVSession? = nil,
        overnight: HRVSession? = nil,
        recent: [HRVSession] = [],
        userMaxHR: Int = 190
    ) -> DailyLoopAnalysis {
        DailyLoopAnalysis(
            workoutSession: workout,
            overnightSession: overnight,
            recentOvernightSessions: recent,
            userMaxHR: userMaxHR
        )
    }

    /// Overnight session carrying a real `analysisResult`, because `rmssd` is
    /// read through `analysisResult.timeDomain` rather than stored directly.
    private func makeOvernight(
        rmssd: Double,
        quality: HRVDataQuality = .good,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> HRVSession {
        let timeDomain = TimeDomainMetrics(
            meanRR: 1000, sdnn: 55, rmssd: rmssd, pnn50: 20,
            sdsd: rmssd * 0.9, meanHR: 60, sdHR: 5, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        let result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: date
        )
        var session = HRVSession(startDate: date, sessionType: .overnight)
        session.endDate = date.addingTimeInterval(8 * 3600)
        session.analysisResult = result
        session.hrvDataQuality = quality
        return session
    }

    /// Workout session with an optional metadata payload. `alphas` and `peakHR`
    /// drive `workoutIntensity`; `tsb`/`atl`/`ctl` drive the cumulative-load guard.
    private func makeWorkout(
        alphas: [Double] = [],
        peakHR: Int? = nil,
        trimp: Double = 0,
        tsb: Double? = nil,
        atl: Double = 0,
        ctl: Double = 0
    ) -> HRVSession {
        var samples: [WorkoutSample] = []
        for (i, alpha) in alphas.enumerated() {
            samples.append(WorkoutSample(offsetSec: i * 60, heartRate: nil, alpha1: alpha))
        }
        if let peakHR {
            samples.append(WorkoutSample(offsetSec: (alphas.count + 1) * 60, heartRate: peakHR))
        }
        var metadata = WorkoutMetadata(sport: .run)
        metadata.samples = samples.isEmpty ? nil : samples
        metadata.luciaTRIMP = trimp
        return makeWorkout(metadata: metadata, tsb: tsb, atl: atl, ctl: ctl)
    }

    private func makeWorkout(
        metadata: WorkoutMetadata?,
        tsb: Double? = nil,
        atl: Double = 0,
        ctl: Double = 0
    ) -> HRVSession {
        var session = HRVSession(
            startDate: Date(timeIntervalSince1970: 1_700_030_000),
            sessionType: .workout
        )
        session.workoutMetadata = metadata
        if let tsb {
            session.trainingSnapshot = TrainingContext(
                atl: atl, ctl: ctl, tsb: tsb, yesterdayTrimp: 0,
                vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
            )
        }
        return session
    }
    // MARK: - Parity with the recovery score

    /// The daily-loop card and the recovery score must divide by the SAME
    /// standard deviation.
    ///
    /// `BaselineTracker` widens the sample SD by sqrt(7/n) below a seven-night
    /// window so a short baseline cannot produce bang-bang scores;
    /// `DailyLoopAnalysis` used a plain sample SD while its own doc comment
    /// called its z-score "the exact quantity the recovery score's HRV factor is
    /// built from". At three nights they differed by 1.53x — enough to print
    /// "below baseline" on the card for a morning the score treats as ordinary
    /// variation. This asserts the estimator itself, so the two cannot drift
    /// again without a red test.
    func testShortBaselineSDMatchesTheRecoveryScoreEstimator() {
        let lnValues = [3.6, 3.9, 3.7]   // three nights, the cold-start case

        let widened = BaselineTracker.widenedLnSD(lnValues)
        let plainSampleSD = lnValues.sampleSD

        XCTAssertGreaterThan(
            widened, plainSampleSD,
            "Below seven nights the estimator must widen; otherwise every deviation is inflated."
        )
        XCTAssertEqual(
            widened, plainSampleSD * (7.0 / 3.0).squareRoot(), accuracy: 1e-9,
            "The widening factor is sqrt(7/n) — the value the recovery score divides by."
        )
    }

    /// And at seven nights or more the widening is inert, so the long-baseline
    /// behaviour is unchanged.
    func testFullWindowBaselineIsNotWidened() {
        let lnValues = [3.6, 3.9, 3.7, 3.8, 3.5, 3.9, 3.6, 3.7]
        XCTAssertEqual(BaselineTracker.widenedLnSD(lnValues), lnValues.sampleSD, accuracy: 1e-12)
    }

}
