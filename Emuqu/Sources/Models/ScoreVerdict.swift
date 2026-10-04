import Foundation
import SwiftUI

/// The canonical 6-tier verdict ladder for the Recovery
/// Score (0-100). Used by:
///   • Dashboard hero (Surface 1) verdict word + colour
///   • Recovery Score detail header
///   • Notification readout templating
///   • RecapCard share artifact
///
/// The ladder is observational, not diagnostic. Verbs in subverdicts
/// follow the voice rule: "Push hard if you want" *suggests* permission;
/// "Take it" is a strong recommendation, never an imperative on health.
enum ScoreVerdict: String, CaseIterable, Sendable {
    case excellent
    case good
    case fair
    case payAttention
    case low
    case veryLow

    /// Map a 0-100 composite recovery score to its verdict tier.
    /// Mirrors the verdict ladder.
    ///
    /// Decided on the rounded score, the number every screen shows: 74.6
    /// read "75 · Fair" where the unrounded score was passed in and "75 ·
    /// Good" where the rounded one was. Clamped to 0…100 first, as the
    /// displayed number is, so an over-range score reads "Excellent", not
    /// "Very low".
    init(score: Double) {
        switch Self.clampedDisplayScore(score).rounded() {
        case 90...100: self = .excellent
        case 75..<90:  self = .good
        case 60..<75:  self = .fair
        case 45..<60:  self = .payAttention
        case 30..<45:  self = .low
        default:       self = .veryLow
        }
    }

    /// Single-word verdict shown next to the hero ring.
    var word: String {
        switch self {
        case .excellent:    "Excellent"
        case .good:         "Good"
        case .fair:         "Fair"
        case .payAttention: "Pay attention"
        case .low:          "Low"
        case .veryLow:      "Very low"
        }
    }

    /// Subverdict — second line under the verdict word in detail views and
    /// notifications. One sentence, observational, ends with permission or
    /// suggestion (the voice rule).
    var subverdict: String {
        switch self {
        case .excellent:    "Well above your usual range. A good day to train hard if you want to."
        case .good:         "Above your usual range. Normal training is fine."
        case .fair:         "In your normal range. Listen to how you feel today."
        case .payAttention: "Below your usual range. An easy day is worth considering."
        case .low:          "Well below your usual range. Worth easing off."
        case .veryLow:      "Far below your usual range. Worth a rest day."
        }
    }

    /// `word` in the app's language, for the screen. `word` itself stays
    /// English for the assistant's fact lines and logs.
    var localizedWord: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .excellent:    return String(localized: "Excellent", bundle: bundle)
        case .good:         return String(localized: "Good", bundle: bundle)
        case .fair:         return String(localized: "Fair", bundle: bundle)
        case .payAttention: return String(localized: "Pay attention", bundle: bundle)
        case .low:          return String(localized: "Low", bundle: bundle)
        case .veryLow:      return String(localized: "Very low", bundle: bundle)
        }
    }

    /// `subverdict` in the app's language.
    var localizedSubverdict: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .excellent:    return String(localized: "Well above your usual range. A good day to train hard if you want to.", bundle: bundle)
        case .good:         return String(localized: "Above your usual range. Normal training is fine.", bundle: bundle)
        case .fair:         return String(localized: "In your normal range. Listen to how you feel today.", bundle: bundle)
        case .payAttention: return String(localized: "Below your usual range. An easy day is worth considering.", bundle: bundle)
        case .low:          return String(localized: "Well below your usual range. Worth easing off.", bundle: bundle)
        case .veryLow:      return String(localized: "Far below your usual range. Worth a rest day.", bundle: bundle)
        }
    }

    /// SF Symbol that pairs with the verdict — required to comply with
    /// `UIAccessibility.shouldDifferentiateWithoutColor` (always pair colour
    /// with a glyph).
    var glyphName: String {
        switch self {
        case .excellent:    "checkmark.seal.fill"
        case .good:         "checkmark.circle.fill"
        case .fair:         "circle.fill"
        case .payAttention: "exclamationmark.circle.fill"
        case .low:          "exclamationmark.triangle.fill"
        case .veryLow:      "exclamationmark.octagon.fill"
        }
    }

    /// Wong (2011) deuteranopia-safe colour for the verdict tier.
    /// Resolved from `AppTheme.wong*` so theme overrides flow through.
    var color: Color {
        switch self {
        case .excellent, .good: AppTheme.wongOptimal
        case .fair:             AppTheme.wongGood
        case .payAttention:     AppTheme.wongCaution
        case .low, .veryLow:    AppTheme.wongAttention
        }
    }

    /// `color` for the verdict word itself; see `AppTheme.wongOptimalText`.
    @MainActor var textColor: Color {
        switch self {
        case .excellent, .good: AppTheme.wongOptimalText
        case .fair:             AppTheme.wongGoodText
        case .payAttention:     AppTheme.wongCautionText
        case .low, .veryLow:    AppTheme.wongAttentionText
        }
    }

    /// Lower bound (inclusive) of the score range for this tier — used for
    /// progress arcs and confidence bands.
    var lowerBound: Int {
        switch self {
        case .excellent:    90
        case .good:         75
        case .fair:         60
        case .payAttention: 45
        case .low:          30
        case .veryLow:      0
        }
    }

    /// Upper bound of the score range for this tier. Exclusive, matching the
    /// half-open ranges in `init(score:)` (`.good` is `75..<90`), except
    /// `.excellent` which is inclusive at 100. Using the exclusive value keeps
    /// arc math `(score − lowerBound)/(upperBound − lowerBound)` in [0,1] and
    /// removes the 1-unit dead zone that a value of 89 left between tiers.
    var upperBound: Int {
        switch self {
        case .excellent:    100
        case .good:         90
        case .fair:         75
        case .payAttention: 60
        case .low:          45
        case .veryLow:      30
        }
    }
}

// MARK: - Non-finite-safe display clamp (single source of truth)

extension ScoreVerdict {
    /// Clamp a raw recovery-score value to a finite `0…100` `Double`, collapsing
    /// a non-finite (NaN/Inf) input to `0`. `value` is expected already on the
    /// 0–100 display scale.
    ///
    /// Why this exists: a `recoveryScore` archived by an older build can
    /// be non-finite (a short quick reading with nil DFA-α1 / frequency-domain,
    /// or an old compute path). `Int(NaN)` / `Int(Inf)` is a hard `Fatal error`,
    /// and a NaN fed into SwiftUI `.trim`/frame geometry corrupts the render.
    /// This is the ONE place the raw→display clamp lives, so every score render
    /// site is trap-proof by construction rather than each re-deriving the guard.
    static func clampedDisplayScore(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 100) : 0
    }

    /// `clampedDisplayScore` rounded to the `0…100` `Int` the ScoreRing consumes.
    /// Never traps on a non-finite input.
    static func safeDisplayScore(_ value: Double) -> Int {
        Int(clampedDisplayScore(value).rounded())
    }
}
