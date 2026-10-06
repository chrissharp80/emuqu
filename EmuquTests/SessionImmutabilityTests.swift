@testable import Emuqu
import XCTest

/// §13.3 Integrity Contract (docs/FLOWCHART.md): opening or re-scoring an
/// archived session must produce an IDENTICAL frozen score. This suite guards
/// against one specific way it drifted.
///
/// The bug: three of the four `ReanalysisService` re-score compute paths
/// defaulted `useBaselineHRV` to `false`. An `.insufficient` / `.preSleep`
/// session is scored off BASELINE HRV at acceptance (its own RMSSD is
/// untrustworthy); when a later sleep-edit / training-only re-score recomputed
/// it WITHOUT that fallback, the frozen score moved — violating §13.3.
///
/// The re-score path derives the flag from
/// the session's own reliability, so a re-score reproduces the accepted value.
/// These tests assert (a) that derivation equals the acceptance rule for every
/// quality, and (b) that it actually removes a real score difference.
///
/// Referenced by the §13.3 contract in `docs/FLOWCHART.md`.
@MainActor
final class SessionImmutabilityTests: XCTestCase {

    // Baseline resting HRV ≈ 40 ms (lnRmssdMean = log 40). A session RMSSD well
    // below baseline is where the baseline-HRV fallback changes the score, so
    // these tests exercise the drift rather than passing tautologically.
    private var baselineStats: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
        )
    }

    // Tier-1 (HRV-only) config isolates the HRV factor, where `useBaselineHRV`
    // acts — no sleep / training / vitals to dilute the effect.
    private var config: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
            enableSleepIntegration: false, penalizeMissingSleep: false, userAge: 40
        )
    }

    // Fixed anchor so `referenceDate` (baseline-staleness) can't vary the score.
    private let anchor = Date(timeIntervalSince1970: 1_750_000_000)

    private func compositeScore(rmssd: Double, useBaselineHRV: Bool) -> Double {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: rmssd, meanHR: 58.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: config,
            useBaselineHRV: useBaselineHRV,
            referenceDate: anchor
        ).compositeScore
    }

    private func session(quality: HRVDataQuality?) -> HRVSession {
        var s = HRVSession(startDate: anchor, sessionType: .overnight)
        s.hrvDataQuality = quality
        return s
    }

    // MARK: - Derivation equals the acceptance rule (the invariant the fix relies on)

    func testBaselineHRVDerivationMatchesAcceptanceRuleForAllQualities() {
        // `SessionAcceptanceService` sets `useBaselineHRV = true` exactly for
        // the two untrustworthy classes and marks the quality accordingly. The
        // re-score paths now derive `!isReliableForHRVAggregates`. They must
        // agree for every quality, or a re-score drifts the frozen score.
        let cases: [(HRVDataQuality?, Bool)] = [
            (.insufficient, true),
            (.preSleep, true),
            (.good, false),
            (nil, false) // legacy entries: treated as reliable, never hidden
        ]
        for (quality, acceptanceUsesBaseline) in cases {
            let derived = !session(quality: quality).isReliableForHRVAggregates
            XCTAssertEqual(
                derived, acceptanceUsesBaseline,
                "useBaselineHRV derivation must match acceptance for quality \(String(describing: quality))"
            )
        }
    }

    // MARK: - The derived flag reproduces the accepted value (§13.3 stability)

    /// Scores at the calculator level: the flag every `ReanalysisService` path
    /// derives (`!isReliableForHRVAggregates`) gives the composite acceptance
    /// froze, and leaving the fallback off gives a different one.
    /// `ReanalysisService` reads its baseline from `BaselineTracker`, which
    /// loads the shared on-disk baseline file, so the service itself is not
    /// driven here.
    func testDerivedBaselineFallbackReproducesTheAcceptedCompositeForAnInsufficientNight() {
        // Depressed RMSSD (15 ms) well below the 40 ms baseline — the shape
        // that makes a session `.insufficient` in the first place.
        let depressedRmssd = 15.0
        let insufficient = session(quality: .insufficient)
        let derivedUseBaseline = !insufficient.isReliableForHRVAggregates
        XCTAssertTrue(derivedUseBaseline, ".insufficient must derive useBaselineHRV = true")

        // Acceptance freezes with useBaselineHRV = true; the fixed re-score
        // derives the same → byte-identical composite (§13.3, no drift).
        let accepted = compositeScore(rmssd: depressedRmssd, useBaselineHRV: true)
        let rescored = compositeScore(rmssd: depressedRmssd, useBaselineHRV: derivedUseBaseline)
        XCTAssertEqual(rescored, accepted, accuracy: 1e-9,
                       "A re-score must reproduce the accepted score, not drift (§13.3).")

        // Prove the drift is real: omitting the flag (useBaselineHRV = false)
        // scores the same session differently. If this ever fails with
        // equality, the fixture stopped exercising the bug — move RMSSD further
        // from baseline.
        let legacyOmission = compositeScore(rmssd: depressedRmssd, useBaselineHRV: false)
        XCTAssertNotEqual(legacyOmission, accepted, accuracy: 1e-6,
                          "The baseline-HRV fallback must actually change the score for an untrustworthy session.")
    }

    // MARK: - Determinism: identical inputs → identical frozen pieces

    func testCompositeScoreAndFrozenReadinessAreDeterministic() {
        let s1 = compositeScore(rmssd: 15.0, useBaselineHRV: true)
        let s2 = compositeScore(rmssd: 15.0, useBaselineHRV: true)
        XCTAssertEqual(s1, s2, accuracy: 1e-12, "calculateWithBreakdown must be a pure function of its inputs.")

        let r1 = ReanalysisService.computeFrozenReadiness(compositeScore: s1, trainingContext: nil)
        let r2 = ReanalysisService.computeFrozenReadiness(compositeScore: s2, trainingContext: nil)
        XCTAssertEqual(r1, r2, accuracy: 1e-12, "frozenReadiness must be deterministic for a fixed composite.")
    }

    // MARK: - The archived-session update follows the same rule

    /// `updateCompositeRecoveryScore` hard-coded `useBaselineHRV: false`, so
    /// re-saving an `.insufficient` night from the results sheet scored its
    /// untrustworthy RMSSD and moved the frozen score. It now derives the flag
    /// from the session, like every `ReanalysisService` path.
    func testArchivedScoreUpdateScoresAnUntrustworthyNightFromTheBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceRescore-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch {
                // swallow-ok: nothing was archived, so there is no directory to remove.
            }
        }
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let archive = SessionArchive(directory: directory, sleepScheduleProvider: { schedule }, sessionMergeModeProvider: { .off })
        let service = SessionAcceptanceService(
            archive: archive, healthKit: MockHealthKitService(), baselineTracker: BaselineTracker(), rawBackup: RawRRBackup(),
            onCloudSync: { _ in }, onCloudDelete: { _ in }
        )
        var night = session(quality: .insufficient)
        night.endDate = anchor.addingTimeInterval(8 * 3600)
        night.analysisResult = depressedResult()
        try archive.archive(night)

        let saved = await service.updateCompositeRecoveryScore(
            for: night, scoringConfig: config, trainingContext: nil, baselineStats: baselineStats,
            typicalSleepHours: 7.5, sleepSchedule: schedule
        )

        XCTAssertTrue(saved)
        let hrv = try XCTUnwrap(archive.retrieve(night.id)?.scoreBreakdown?.factors.first { $0.label == "HRV" })
        XCTAssertEqual(hrv.score, compositeScore(rmssd: 15, useBaselineHRV: true), accuracy: 1e-9)
    }

    private func depressedResult() -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1035, sdnn: 30, rmssd: 15, pnn50: 2, sdsd: 14, meanHR: 58, sdHR: 3, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 10, sd2: 40, sd1Sd2Ratio: 0.25, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.85, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: anchor
        )
    }
}
