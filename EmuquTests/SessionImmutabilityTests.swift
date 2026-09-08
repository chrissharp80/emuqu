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

    // MARK: - A re-score reproduces the accepted value (§13.3 stability)

    func testRescoreOfInsufficientSessionReproducesAcceptedScore() {
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
}
