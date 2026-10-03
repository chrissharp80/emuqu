import SwiftUI

// MARK: - HR Zone
//
// 5-zone model keyed to % of user MAX HR (NOT session-observed peak). The
// previous implementation divided by `peakHR` within the session, which
// produced absurd output like "Zone 5 at 100 bpm" when the user was
// standing still — because the session peak was only ~105, so 100/105 ≈ 95%
// rounded into Z5. The zone buckets have to be anchored to the user's
// physiological ceiling, not whatever this particular session happened to
// hit at its highest.
//
// Effective max HR resolution (see UserSettings.effectiveMaxHR):
//   1. User override (Settings → Fitness)
//   2. Age-based Tanaka estimate (208 − 0.7 × age) from birthday — see
//      `MaxHeartRate.effective`
//   3. Default 180 — conservative floor so zone coloring doesn't blow up
//      for fit users without any profile info.
//
// Zone fractions match the Edwards TRIMP / Lucia layout that
// WorkoutAnalyzer already uses internally for training-load math.
enum HRZone: Int, CaseIterable, Identifiable {
    case z1 = 1
    case z2 = 2
    case z3 = 3
    case z4 = 4
    case z5 = 5

    var id: Int { rawValue }

    /// Classify HR against the user's max HR. Returns nil for HR below ~50%
    /// of max (warm-up / rest / normal daily life) so the UI renders the
    /// number in neutral color instead of flagging it as any zone at all.
    ///
    /// Pass `userMaxHR` from `UserSettings.effectiveMaxHR`. Never pass a
    /// session-peak HR — that's what caused the original bug.
    static func classify(hr: Int, userMaxHR: Int) -> HRZone? {
        guard userMaxHR > 0, hr > 0 else { return nil }
        let frac = Double(hr) / Double(userMaxHR)
        switch frac {
        case 0.50 ..< 0.60: return .z1
        case 0.60 ..< 0.70: return .z2
        case 0.70 ..< 0.80: return .z3
        case 0.80 ..< 0.90: return .z4
        // Open-ended: an HR above the estimated max means the real max is
        // higher than the estimate, and that is still maximal effort.
        case 0.90...: return .z5
        default: return nil
        }
    }

    /// Intentionally generic. "Zone 5" ≠ "VO₂ Max zone" until the user
    /// provides lab-tested calibration; we use a plain numeric label and
    /// let color convey intensity. Users can still infer meaning ("red =
    /// hard") without the app over-claiming.
    var label: String { "Zone \(rawValue)" }

    /// `label` in the app language, for the screen. `label` stays English:
    /// it is what the AI context reads.
    var localizedLabel: String { String(localized: "Zone \(rawValue)", bundle: LanguageManager.appBundle) }

    var shortLabel: String { "Z\(rawValue)" }

    var color: Color {
        switch self {
        case .z1: Color(red: 0.40, green: 0.60, blue: 0.90)   // cool blue
        case .z2: Color(red: 0.40, green: 0.80, blue: 0.55)   // sage green
        case .z3: Color(red: 0.95, green: 0.80, blue: 0.30)   // amber
        case .z4: Color(red: 0.95, green: 0.55, blue: 0.25)   // warm orange
        case .z5: Color(red: 0.90, green: 0.30, blue: 0.30)   // red
        }
    }
}
