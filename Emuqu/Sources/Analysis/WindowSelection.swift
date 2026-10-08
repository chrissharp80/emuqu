import Foundation
import os

/// Recovery window selection - finds best ORGANIZED recovery window
/// Algorithm:
/// 1. Build all windows within 30-70% of sleep (anchored to actual sleep, not recording)
/// 2. Filter ISOLATED SPIKES only (temporal discontinuity: much higher than BOTH neighbors)
/// 3. Compute organization metrics for each window: DFA α1 and HR CV. (LF/HF
///    is NOT computed per window — `scoredBlock` passes `lfHfRatio: nil` — so
///    the LF/HF alternative in `ScoredRecoveryBlock.isOrganizedRecovery` is
///    dormant and HR CV < 8% is always required alongside α1.)
/// 4. Classify windows as "Organized Recovery" vs "High Variability"
/// 5. Among ORGANIZED windows only, select the highest Tier 1 recovery score
///    against the baseline when one exists, else the highest RMSSD
/// 6. If no organized windows, return nil (peak capacity captured separately)
///
/// Key principles. The selection heuristics below are the app's own; only the
/// artifact and stability handling is research-backed. "Organized" here names a
/// QUIET, STABLE stretch of the night that makes a good analysis window — it is
/// not a claim about autonomic state, and `HelpScienceCatalog` is careful never
/// to present it as one:
/// - High HRV values are VALID if the window is stable (DFA α1 ~0.75-1.0, stable HR)
/// - High RMSSD in an unstable window is less reproducible, not less "real"
/// - "Abrupt" = temporal/structural discontinuity, NOT magnitude
/// - NO baseline-relative rejection (no percentile caps, no "95% of neighbor" rules)
/// - NO magnitude-based rejection ("too good to be true" has no scientific basis)
/// - Organized Recovery: DFA α1 ≈ 0.75-1.0 and HR CV < 8% (no α1: HR CV alone).
///   The rule's "LF/HF ≤ 1.5 OR stable HR" alternative needs a per-window
///   LF/HF, which the selector never supplies.
/// - High Variability: high RMSSD but α1 out of range or unstable HR
final class WindowSelector: Sendable {
    // MARK: - Types

    /// Selected recovery window for analysis
    struct RecoveryWindow: Codable {
        let startIndex: Int
        let endIndex: Int
        let startMs: Int64
        let endMs: Int64
        let beatCount: Int
        let nnCount: Int
        let qualityScore: Double
        let artifactRate: Double
        /// Mean HR during this window (bpm)
        let meanHR: Double
        /// HR stability score (lower = more stable, coefficient of variation)
        let hrStability: Double
        /// Reason this window was selected
        let selectionReason: String
        /// Relative position of window midpoint within sleep episode (0.0 = sleep start, 1.0 = wake)
        /// Used for temporal representativeness - ideally between 0.30 and 0.70
        let relativePosition: Double?
        /// Consolidated recovery score (RMSSD weighted by stability)
        let recoveryScore: Double?
        /// Whether this window represents consolidated recovery (sustained plateau AND stable HR)
        /// vs just high HRV capacity. Consolidated windows are the more stable of the two.
        /// A window is consolidated if: (1) it passed persistence/plateau check, AND (2) CV < 8%
        let isConsolidated: Bool

        // MARK: - Organization Metrics (NEW)

        /// DFA α1 for this window (app reference range: 0.75-1.0)
        let dfaAlpha1: Double?
        /// LF/HF ratio for this window. Always nil from the production
        /// selector (`scoredBlock` does not compute it), so the ≤ 1.5
        /// `maxOrganizedLfHf` alternative never takes part in selection; see
        /// `maxOrganizedLfHf` for why it would not be an autonomic claim anyway.
        let lfHfRatio: Double?
        /// Whether this window met the stability heuristics used to pick it.
        /// Organized = DFA α1 ~0.75-1.0 and stable HR (LF/HF is not computed
        /// per window, so its alternative never applies). This is a
        /// window-selection label, not a statement about the nervous system.
        let isOrganizedRecovery: Bool
        /// Classification label for reporting
        let windowClassification: WindowClassification

        /// Window classification for reporting. Bands on DFA α1:
        /// - Organized Recovery (α1 ≈ 0.75-1.0): the app's resting reference range
        /// - Flexible Unconsolidated (α1 ≈ 0.60-0.75): below it
        /// - High Variability (α1 > 1.0 or < 0.6): outside both
        ///
        /// The band NAMES are historical and describe how a window was chosen.
        /// The resting-α1-as-recovery-organization reading they imply is not
        /// validated — see `HelpScienceCatalog.dfaExplainedSections`.
        enum WindowClassification: String, Codable {
            case organizedRecovery = "Organized Recovery"
            case flexibleUnconsolidated = "Flexible / Unconsolidated"
            case highVariability = "High Variability"
            case insufficient = "Insufficient Data"

            /// Short label for compact display, in the app language.
            ///
            /// Lives on this enum, the one production code actually produces,
            /// so `MorningResultsView` decodes the raw string with the same type
            /// that wrote it rather than a parallel enum whose raw values
            /// merely happen to match.
            var shortLabel: String {
                switch self {
                case .organizedRecovery: String(localized: "Organized", bundle: LanguageManager.appBundle)
                case .flexibleUnconsolidated: String(localized: "Flexible", bundle: LanguageManager.appBundle)
                case .highVariability: String(localized: "Variable", bundle: LanguageManager.appBundle)
                case .insufficient: String(localized: "N/A", bundle: LanguageManager.appBundle)
                }
            }
        }

        /// Threshold for "unstable" HR coefficient of variation (8% = 0.08)
        /// Windows with CV above this are considered unstable and represent capacity, not readiness
        static let unstableCVThreshold: Double = 0.08

        /// The app's resting reference range for DFA α1 — a selection
        /// heuristic, not a validated readiness scale.
        /// Research: healthy NREM sleep α1 values (PMC4100066):
        /// N1: 0.89 ± 0.23, N2: 0.85 ± 0.16, N3 (deep): 0.78 ± 0.21
        /// Range 0.75-1.0 captures core healthy NREM values
        static let optimalAlpha1Range: ClosedRange<Double> = 0.75 ... 1.0
        /// Below the reference range. Common, and not a deficit.
        static let flexibleAlpha1Range: ClosedRange<Double> = 0.60 ... 0.75
        /// Maximum LF/HF a window may have to count as "organized".
        ///
        /// Dormant in production: the selector builds every candidate with
        /// `lfHfRatio: nil`, so this threshold is only reached by unit tests
        /// that construct a `ScoredRecoveryBlock` with an LF/HF value.
        ///
        /// NOT "(parasympathetic dominance)",
        /// which is the interpretation `lfhfRatioSection` cites Billman 2013 to
        /// reject. The threshold is a WINDOW-SELECTION heuristic —
        /// a low LF/HF stretch of the night is empirically a quiet, settled one
        /// and makes a stable analysis window — but it is not evidence of an
        /// autonomic state and nothing user-facing may call it that.
        static let maxOrganizedLfHf: Double = 1.5
    }

    /// Complete result including both recovery window and peak capacity
    /// Recovery window may be nil if no organized parasympathetic plateau occurred
    /// Peak capacity is always computed if any sustained windows exist
    struct WindowSelectionResult {
        /// Consolidated recovery window (nil if no organized recovery detected)
        let recoveryWindow: RecoveryWindow?
        /// Peak capacity - highest sustained HRV regardless of organization
        let peakCapacity: PeakCapacity?

        /// Whether consolidated recovery was detected
        var hasConsolidatedRecovery: Bool {
            recoveryWindow != nil
        }
    }

    init(config: Config = .default) {
        self.config = config
    }

    let config: Config
    /// All organized-recovery zones found during the last call to
    /// `findBestWindow`. Populated as a side effect so the pipeline can
    /// forward them to `HRVAnalysisResult.organizedRecoveryZones` without
    /// re-scanning. Empty when no organized windows exist.
    var lastOrganizedZones: [HRVAnalysisResult.TimeRange] {
        get { organizedZonesBox.withLock { $0 } }
        set { organizedZonesBox.withLock { $0 = newValue } }
    }

    /// The zones live behind a lock so a selector can be shared across tasks;
    /// it is otherwise immutable, which is what makes it `Sendable`.
    private let organizedZonesBox = OSAllocatedUnfairLock<[HRVAnalysisResult.TimeRange]>(initialState: [])
}
