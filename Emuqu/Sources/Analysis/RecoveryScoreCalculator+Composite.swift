import Foundation

// The composite entry points and display helpers; the vitals sub-score lives
// in `VitalsScoring`.

extension RecoveryScoreCalculator {

    // MARK: - Composite Score (delegates to breakdown — single source of truth)

    /// Calculate composite recovery score (0-100) from all available data.
    /// Delegates to `calculateWithBreakdown` so there is exactly one scoring path.
    static func calculate(
        _ inputs: ScoreInputs,
        trainingMetrics: HealthKitManager.TrainingMetrics?,
        config: ScoringConfiguration,
        ansBalance: Double? = nil
    ) -> Double {
        let composite = calculateWithBreakdown(
            inputs, trainingMetrics: trainingMetrics, config: config, ansBalance: ansBalance
        ).compositeScore
        // Defensive: guarantee a finite 0–100 value reaches the UI. The
        // score ring renders `Int(score)` / `CGFloat(score)`, which crash
        // on NaN/Inf. Inputs are sanitized in calculateWithBreakdown, so
        // this backstop should never fire — but it makes the contract
        // explicit and crash-proof.
        return composite.isFinite ? min(100, max(0, composite)) : 0
    }

    /// Calculate composite recovery score using TrainingContext (convenience overload).
    static func calculate(
        _ inputs: ScoreInputs,
        trainingContext: TrainingContext?,
        config: ScoringConfiguration,
        ansBalance: Double? = nil
    ) -> Double {
        let composite = calculateWithBreakdown(
            inputs, trainingContext: trainingContext, config: config, ansBalance: ansBalance
        ).compositeScore
        // Defensive: guarantee a finite 0–100 value reaches the UI (see
        // the trainingMetrics overload above).
        return composite.isFinite ? min(100, max(0, composite)) : 0
    }

    // MARK: - Display Helpers

    /// The one place a raw 0–100 score becomes the integer a person sees.
    ///
    /// This must stay the ONE place the raw→display clamp lives. When
    /// call sites each wrote `Int(score)` or
    /// `Int(score.rounded())`, a session scoring 84.6 rendered **84** on
    /// Morning Results and its accessibility label, and **85** on the Dashboard
    /// and in the exported filename — same session, same instant, two numbers.
    ///
    /// Both spellings also TRAP on a non-finite score. `Int(Double.nan)` is a
    /// runtime crash, not a garbage integer, which is the failure the NaN
    /// coercion in `RecoveryScoreCalculator.breakdown(...)` and the sanitiser in
    /// `MorningResultsView+DetailCards` are each working around locally. Doing it
    /// here means a new render site cannot reintroduce either bug.
    static func displayScore(_ score: Double) -> Int {
        guard score.isFinite else { return 0 }
        return Int(min(100, max(0, score)).rounded())
    }

    static func label(for score: Double) -> String {
        if score >= RecoveryScoreConstants.DisplayThresholds.excellent { return "Excellent" }
        if score >= RecoveryScoreConstants.DisplayThresholds.good { return "Good" }
        if score >= RecoveryScoreConstants.DisplayThresholds.fair { return "Fair" }
        return "Low"
    }

    static func message(for score: Double) -> String {
        if score >= RecoveryScoreConstants.DisplayThresholds.excellent { return "You're well recovered. Great day for intense training." }
        if score >= RecoveryScoreConstants.DisplayThresholds.good { return "Decent recovery. Moderate training recommended." }
        if score >= RecoveryScoreConstants.DisplayThresholds.fair { return "Incomplete recovery. Consider light activity." }
        return "Recovery needed. Rest or very light activity only."
    }

    /// Convert 0-100 score to 1-10 scale for display
    static func toTenScale(_ score: Double) -> Double {
        score / 10.0
    }
}
