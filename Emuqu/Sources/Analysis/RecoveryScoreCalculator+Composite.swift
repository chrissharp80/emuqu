import Foundation

// The display helpers for a composite score; the composite itself comes from
// `calculateWithBreakdown`, and the vitals sub-score lives in `VitalsScoring`.

extension RecoveryScoreCalculator {

    // MARK: - Display Helpers

    /// The integer a person sees for a raw 0–100 score.
    ///
    /// When call sites each wrote `Int(score)` or `Int(score.rounded())`, a
    /// session scoring 84.6 rendered **84** on Morning Results and its
    /// accessibility label, and **85** on the Dashboard and in the exported
    /// filename — same session, same instant, two numbers. Both spellings also
    /// TRAP on a non-finite score: `Int(Double.nan)` is a runtime crash, not a
    /// garbage integer.
    ///
    /// The clamp and rounding live in `ScoreVerdict.safeDisplayScore`; this
    /// is the calculator-side name for it, so the two can never disagree.
    static func displayScore(_ score: Double) -> Int {
        ScoreVerdict.safeDisplayScore(score)
    }

    /// Convert a 0-100 composite to the 0-10 scale `session.recoveryScore` is
    /// STORED on. Screens multiply it back by 10 and display 0-100.
    static func toTenScale(_ score: Double) -> Double {
        score / 10.0
    }
}
