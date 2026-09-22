import Foundation

// Sleep-classifier, baseline, sleep-science, history, dashboard, morning-
// result and heat constants, plus `FeatureFlags`. Each is an independent
// namespace.

// MARK: - HRV Sleep Stage Classifier

/// Thresholds and weights for the rank-based HRV sleep stage classifier.
enum SleepClassifierConstants {
    // -- Score thresholds for standalone classification --

    /// Minimum composite score to classify a window as deep sleep
    static let deepScoreThreshold: Double = 0.60
    /// Minimum composite score to classify a window as REM.
    /// Set higher than deep (0.60) because REM shares many HRV features with light/core
    /// sleep — a permissive threshold leads to systematic REM overestimation.
    /// At 0.63, a window needs genuine physiological REM evidence (elevated CV, low RMSSD,
    /// high DFA/LF/HF) and can't be classified as REM by temporal bonus alone.
    static let remScoreThreshold: Double = 0.63
    /// Minimum composite score to classify a window as awake
    static let awakeScoreThreshold: Double = 0.80

    // -- Augmentation thresholds (override Watch stages) --

    /// Core/unspecified → Deep (Watch's most common miss)
    static let augmentCoreToDeepThreshold: Double = 0.68
    /// Core/unspecified → REM
    static let augmentCoreToREMThreshold: Double = 0.63
    /// Awake → REM (REM muscle twitches confused with wakefulness)
    static let augmentAwakeToREMThreshold: Double = 0.68
    /// Deep ↔ REM cross-correction — very strong evidence required
    static let augmentCrossStageThreshold: Double = 0.72
    /// Deep ↔ REM cross-correction — existing score must be below this to allow override
    static let augmentCrossStageRejectThreshold: Double = 0.40

    // -- Temporal scoring anchors --

    /// Night fraction below which deep sleep temporal bonus is maximal
    static let deepTemporalEarlyEnd: Double = 0.4
    /// Night fraction below which deep sleep temporal bonus is partial
    static let deepTemporalMidEnd: Double = 0.6
    /// Partial deep temporal bonus value
    static let deepTemporalMidBonus: Double = 0.4
    /// Minimal deep temporal bonus in late night
    static let deepTemporalLateBonus: Double = 0.15

    /// Night fraction above which REM temporal bonus is maximal.
    /// Pushed to 0.6 (from 0.5): REM periods lengthen in cycles 3-4, not cycle 2.
    /// At 0.5 (4h into 8h sleep), the temporal bonus was firing too early and
    /// dominating the composite, causing ~50% REM classification (should be ~20-25%).
    static let remTemporalLateStart: Double = 0.6
    /// Night fraction above which REM temporal bonus is partial
    static let remTemporalMidStart: Double = 0.35
    /// Partial REM temporal bonus value (reduced from 0.4 to 0.25)
    static let remTemporalMidBonus: Double = 0.25

    /// Fallback median DFA α1 when no valid DFA values are available
    static let fallbackMedianDFA: Double = 0.85

    /// -- Deep composite weights (all-features variant: freq + DFA) --
    enum DeepWeightsAllFeatures {
        static let hr: Double = 0.12
        static let rmssd: Double = 0.10
        static let cv: Double = 0.08
        static let hf: Double = 0.15
        static let lfHf: Double = 0.18
        static let dfa: Double = 0.22
        static let temporal: Double = 0.15
    }

    /// Deep composite weights — frequency domain only (no DFA)
    enum DeepWeightsFreqOnly {
        static let hr: Double = 0.15
        static let rmssd: Double = 0.13
        static let cv: Double = 0.10
        static let hf: Double = 0.18
        static let lfHf: Double = 0.24
        static let temporal: Double = 0.20
    }

    /// Deep composite weights — DFA only (no frequency domain)
    enum DeepWeightsDFAOnly {
        static let hr: Double = 0.18
        static let rmssd: Double = 0.18
        static let cv: Double = 0.12
        static let dfa: Double = 0.32
        static let temporal: Double = 0.20
    }

    /// Deep composite weights — time domain only (no freq, no DFA)
    enum DeepWeightsTimeDomainOnly {
        static let hr: Double = 0.25
        static let rmssd: Double = 0.25
        static let cv: Double = 0.15
        static let temporal: Double = 0.35
    }

    /// -- REM composite weights (all-features variant: freq + DFA) --
    /// Temporal weight is kept low across all variants so that time-of-night
    /// is a supporting signal, not the dominant factor. Temporal weights in
    /// the 0.32-0.64 range alone push windows past the REM threshold in the
    /// second half of sleep, producing ~50% REM (should be ~20-25%).
    /// Physiological features (LF/HF, DFA, CV) carry the majority of weight.
    enum REMWeightsAllFeatures {
        static let rmssd: Double = 0.10
        static let cv: Double = 0.10
        static let lfHf: Double = 0.24
        static let hf: Double = 0.12
        static let dfa: Double = 0.26
        static let temporal: Double = 0.18
    }

    /// REM composite weights — frequency domain only
    enum REMWeightsFreqOnly {
        static let rmssd: Double = 0.12
        static let cv: Double = 0.12
        static let lfHf: Double = 0.30
        static let hf: Double = 0.18
        static let temporal: Double = 0.28
    }

    /// REM composite weights — DFA only
    enum REMWeightsDFAOnly {
        static let rmssd: Double = 0.16
        static let cv: Double = 0.16
        static let dfa: Double = 0.38
        static let temporal: Double = 0.30
    }

    /// REM composite weights — time domain only.
    /// This is the least reliable feature set for REM detection. CV (heart rate
    /// variability coefficient) is the best single time-domain REM discriminator,
    /// so it gets the highest weight. Temporal is capped at 0.25 so it can only
    /// tip borderline cases, never dominate the classification.
    enum REMWeightsTimeDomainOnly {
        static let rmssd: Double = 0.32
        static let cv: Double = 0.43
        static let temporal: Double = 0.25
    }

    /// -- Awake composite weights --
    enum AwakeWeightsWithFreq {
        static let hr: Double = 0.30
        static let rmssd: Double = 0.25
        static let cv: Double = 0.15
        static let lfHf: Double = 0.20
        static let hf: Double = 0.10
    }

    enum AwakeWeightsWithoutFreq {
        static let hr: Double = 0.35
        static let rmssd: Double = 0.30
        static let cv: Double = 0.20
        static let dfa: Double = 0.15
    }
}

// MARK: - Baseline Tracker

/// Thresholds for baseline deviation interpretation and replacement decisions.
///
/// The ±10% / ±20% deviation bands are a UI-layer simplification of Plews
/// et al. 2013's Smallest Worthwhile Change (SWC = 0.5 SD of ln(RMSSD)).
/// SWC expressed as a percentage of the baseline mean typically lands in
/// the 8–15% range for trained populations (Plews 2013, Buchheit 2014),
/// so 10% is a conservative "meaningful" boundary and 20% marks "clearly
/// outside normal variation." These thresholds are display-only; the
/// recovery score itself uses the underlying z-score directly via
/// `zToRecoveryScore` in RecoveryScoreCalculator.
enum BaselineConstants {
    // -- RMSSD deviation interpretation thresholds (percentage) --

    /// RMSSD deviation below which status is "significantly below baseline"
    static let rmssdSignificantlyBelowThreshold: Double = -20.0
    /// RMSSD deviation below which status is "below baseline"
    static let rmssdBelowThreshold: Double = -10.0
    /// RMSSD deviation above which status is "significantly above baseline"
    static let rmssdSignificantlyAboveThreshold: Double = 20.0
    /// RMSSD deviation above which status is "above baseline"
    static let rmssdAboveThreshold: Double = 10.0

    /// Overall status threshold (RMSSD deviation %)
    static let overallBelowThreshold: Double = -15.0
    static let overallAboveThreshold: Double = 15.0

    // -- Replacement decision thresholds --

    /// Score improvement required for non-consolidated to replace consolidated (15%)
    static let consolidatedReplacementFraction: Double = 0.15
    /// Score tolerance for consolidated to replace non-consolidated (within 10%)
    static let consolidatedAdvantageFraction: Double = 0.9
    /// Score tolerance for organized-recovery advantage (within 5%)
    static let organizedRecoveryAdvantageFraction: Double = 0.95

    /// Artifact rate multiplier ceiling — new window rejected if artifacts exceed this × existing
    static let artifactCeilingMultiplier: Double = 1.5
    /// Artifact rate floor to prevent near-zero baselines from rejecting good windows
    static let artifactCeilingFloor: Double = 2.0

    /// HR stability rejection multiplier — new window rejected if CV exceeds this × existing
    static let hrStabilityRejectMultiplier: Double = 1.3

    /// Minimum readiness score improvement fraction required to replace (5%)
    static let minimumImprovementFraction: Double = 0.05

    /// Minimum ln(RMSSD) day-to-day SD used as the z-score denominator.
    /// 0.10, not a bare division-by-zero guard like 0.01: when a user's
    /// overnight RMSSD is stable (or the window is short), the sample SD
    /// collapses toward the floor, and dividing a real ln deviation by ~0.01
    /// produces |z| of 8+ — so a trivial −8% night (ln −0.08) scores like a
    /// −8 SD catastrophe and the SWC deadband (±0.5 SD) shrinks to ±0.5%
    /// RMSSD, defeating its own purpose. 0.10 is the documented
    /// irreducible noise floor of overnight RMSSD: day-to-day technical +
    /// biological variability is ~5–10% CV (Plews/Buchheit 2013, Al Haddad 2011,
    /// Nakamura), and lnSD ≈ CV at these magnitudes. Below this you can't tell a
    /// real change from measurement noise, so it must not score like one. Only
    /// FLOORS the SD — users with genuinely wider variability are unaffected.
    /// Tunable: this sets how big a deviation counts as "real" for a stable user.
    static let lnRmssdSDFloor: Double = 0.10
    /// Recovery baseline SD floor for resting HR
    static let meanHRSDFloor: Double = 0.5
}

// MARK: - Sleep Science Analyzer

/// Weights and thresholds for the enhanced sleep score and architecture analysis.
enum SleepScienceConstants {
    // -- Fragmentation index formula coefficients --

    /// Awakenings-per-hour multiplier in fragmentation formula
    static let fragmentationAwakeningsWeight: Double = 10.0
    /// Wake-percentage multiplier in fragmentation formula
    static let fragmentationWakePercentWeight: Double = 2.0

    // -- Cycle detection --

    /// Non-REM minutes after REM required to close a cycle
    static let cycleCloseNonREMMinutes: Int = 15
    /// Minimum combined minutes for a trailing cycle to be recorded
    static let minimumFinalCycleMinutes: Int = 30

    // -- Architecture scoring --

    /// Percentage of deep sleep in first half to be considered front-loaded
    static let architectureDeepFrontLoadedThreshold: Double = 55.0
    /// Percentage of REM in second half to be considered back-loaded
    static let architectureREMBackLoadedThreshold: Double = 55.0

    // -- Enhanced sleep score weights (total = 100) --

    /// Duration component maximum points
    static let durationMaxPoints: Double = 25.0
    /// Duration ratio cap (no extra credit beyond 110% of target)
    static let durationRatioCap: Double = 1.1

    /// Efficiency component maximum points
    static let efficiencyMaxPoints: Double = 20.0
    /// Default efficiency target when age norms are unavailable
    static let defaultEfficiencyTarget: Double = 85.0
    /// Efficiency ratio cap
    static let efficiencyRatioCap: Double = 1.1

    /// Stages component maximum points (deep + REM, 10 each)
    static let stagesMaxPoints: Double = 20.0
    /// Default stages score when no stage data is available
    static let stagesDefaultScore: Double = 10.0
    /// Per-stage deviation penalty multiplier (age-adjusted scoring)
    static let stageDeviationPenalty: Double = 0.5
    /// Population-norm deep sleep target percentage
    static let populationDeepTarget: Double = 20.0
    /// Population-norm REM target percentage
    static let populationREMTarget: Double = 25.0

    /// Fragmentation component maximum points
    static let fragmentationMaxPoints: Double = 15.0

    /// Cycles component maximum points
    static let cyclesMaxPoints: Double = 10.0
    /// Average cycle length divisor for expected-cycle calculation (hours)
    static let averageCycleLengthHours: Double = 1.5
    /// Minimum expected cycles (floor)
    static let minimumExpectedCycles: Int = 3

    /// Architecture component maximum points
    static let architectureMaxPoints: Double = 10.0
}

// MARK: - History View Model

enum HistoryConstants {
    /// Debounce interval for filter changes (milliseconds)
    static let filterDebounceMs: Int = 150

    /// Close window threshold for overnight duplicate detection (seconds)
    static let closeWindowSeconds: TimeInterval = 90 * 60
    /// Overlap ratio threshold for duplicate detection
    static let overlapRatioThreshold: Double = 0.85
    /// Maximum duration for a tiny artifact row (seconds)
    static let tinyArtifactMaxDuration: TimeInterval = 45 * 60
    /// Near-end tolerance for artifact detection (seconds)
    static let nearEndTolerance: TimeInterval = 30 * 60
    /// Start tolerance for artifact within long bounds (seconds)
    static let artifactStartTolerance: TimeInterval = 5 * 60
    /// End tolerance for artifact within long bounds (seconds)
    static let artifactEndTolerance: TimeInterval = 30 * 60
}

// MARK: - Morning Results View Model

enum MorningResultsConstants {
    /// HRV trend percentage thresholds
    enum TrendThresholds {
        /// Below this absolute percentage, HRV is "consistent"
        static let consistent: Double = 10.0
        /// Above this, HRV is "significantly" above/below average
        static let significant: Double = 20.0
        /// Baseline deviation threshold for personal baseline insight
        static let baselineDeviation: Double = 15.0
    }

    /// HR difference threshold for elevated/lower resting HR insight
    static let hrDiffThreshold: Double = 5.0
    /// Stress multiplier threshold for elevated stress insight
    static let stressMultiplierThreshold: Double = 1.3
    /// Minimum stress value to trigger elevated stress insight
    static let stressAbsoluteThreshold: Double = 200.0
    /// 7-day trend percentage threshold for improvement/decline insight
    static let trendThreshold: Double = 10.0
    /// Minimum sessions before trends are "more accurate"
    static let minSessionsForAccurateTrends: Int = 7
}

// MARK: - Heat Acclimatization

/// Constants for the `HeatAcclimation` model. Time constants are taken
/// from the heat-acclimatization literature; severity/duration/band cutoffs
/// are empirical design choices calibrated to that literature and to
/// Garmin's published behaviour (heat tracking begins above ~22 °C air).
/// See the file-level doc on `HeatAcclimation` for the full citation list.
enum HeatConstants {
    // MARK: Heat-stress stimulus (humidity-aware, WBGT °C)

    /// Shade-WBGT (°C) below which a session provides no meaningful heat
    /// stimulus. 19 °C WBGT corresponds to roughly 22 °C air at ~50% RH —
    /// matching Garmin's air-temperature trigger — but, being WBGT, it also
    /// counts a humid 20 °C day (which genuinely stresses thermoregulation)
    /// and correctly ignores a cool, dry one.
    /// Ref: Garmin "Heat & Altitude Acclimation"; Racinais S et al. 2015
    ///      Br J Sports Med 49(18):1164 (heat consensus).
    static let stimulusWBGTThreshold: Double = 19.0

    /// WBGT °C above the threshold at which a session is maximally adaptive.
    /// 12 so a session saturates at WBGT ≈ 31 (threshold 19 + 12), not 35.
    /// A span reaching 35 °C only counts as "fully adaptive" at
    /// heat-stroke-range WBGT, which (a) the literature doesn't
    /// require — real heat-acclimation training targets WBGT ~25–31 — and
    /// (b) systematically under-credited HUMID-but-not-desert conditions,
    /// since the shade-WBGT proxy already runs conservative (it omits the
    /// outdoor sun/globe term). Effect: a humid 85 °F/80% session (WBGT ≈
    /// 33.5) saturates at 1.0, a humid 75 °F/85% session (WBGT ≈ 27)
    /// scores ~0.67 (vs ~0.4 with a 16 span), and a cool-but-saturated
    /// 66 °F/90% walk (WBGT ≈ 22) scores ~0.28 — credited, but still
    /// only moderate (it genuinely is low heat stress). Humid-climate
    /// training builds visible acclimation.
    static let severitySpanC: Double = 12.0

    /// Minimum active minutes for a session to count as a heat stimulus —
    /// below this the exposure is too brief to drive adaptation.
    static let minStimulusMinutes: Double = 15.0

    /// Active minutes at which a single session delivers a full daily
    /// stimulus. Heat-acclimation protocols use 45–90 min sessions; 45 min
    /// of sustained heat exercise is a complete daily dose.
    /// Ref: Périard JD et al. 2015 Scand J Med Sci Sports 25(S1):20-38.
    static let fullStimulusMinutes: Double = 45.0

    // MARK: Acclimation dynamics (asymmetric Banister EWMA)

    /// Induction rate per exposure day. τ ≈ 5 days ⇒ k = 1 − e^(−1/5) ≈
    /// 0.181. Sustained at a full stimulus this reaches ~75% by day 7 and
    /// ~94% by day 14 — matching "HR adaptation complete ~7 days, full
    /// acclimatization 10–14 days."
    /// Ref: Waldron M et al. 2024 Temperature 11(3):223-241 (onset
    ///      time-course); Tyler CJ et al. 2016 Sports Med 46(11):1699.
    static let inductionRatePerDay: Double = 0.181

    /// Decay rate per non-exposure day, ~2.5%/day ⇒ ~30% lost after 14 days
    /// and roughly half gone within a month, with the fast-acquired
    /// adaptations (plasma volume, exercising HR) fading first.
    /// Ref: Daanen HAM, Racinais S, Périard JD. 2018 Sports Med
    ///      48(2):409-430 (decay meta-analysis).
    static let decayRatePerDay: Double = 0.025

    // MARK: Bands (0–100 level)

    /// Floor of the "partially acclimated" band.
    static let partialBandFloor: Double = 25.0
    /// Floor of the "well acclimated" band.
    static let wellBandFloor: Double = 60.0
    /// Floor of the "fully acclimated" band.
    static let fullBandFloor: Double = 85.0

    /// Default "ready for the heat" target the readout coaches toward —
    /// solidly into full acclimatization.
    static let defaultTargetLevel: Double = 85.0

    /// WBGT °C span from the stimulus threshold to the heat level a fully
    /// acclimated (level 100) athlete is comfortably adapted to. Threshold
    /// 19 + 11 ⇒ adapted to WBGT ≈ 30 (a hot ~33 °C day) when fully
    /// acclimated; used only to phrase the abstract level as a felt
    /// temperature.
    static let adaptedWBGTSpanC: Double = 11.0

    // MARK: Series window

    /// How far back the daily replay looks. 60 days comfortably exceeds the
    /// full induction-plus-decay memory of the model (a ~22-day decay
    /// half-life means days older than this contribute <1%), so a zero seed
    /// is invisible — the same convergence argument the training-load
    /// series uses with its longer CTL window.
    static let replayLookbackDays: Int = 60
}

// MARK: - Feature Flags
//
// Kill switches for the few code paths that may
// need to be flipped without a TestFlight cycle:
//   • The medical-query guard (defense in depth — unlikely to be flipped
//     off, but useful to disable IF the guard ever blocks a legitimate
//     query so we can swap rules)
//   • Per-cloud-provider AI (in case a provider has an outage / new TOS /
//     prompt-injection incident)
//   • Experimental scoring (rollback path when a new model lands and a
//     user wants to revert)
//
// Persistence: UserDefaults (suite shared with App Group). All flags
// default to "current production behaviour" — i.e. enabled for
// long-shipping features, disabled for experimental ones. The store
// is `final` and uses `OSAllocatedUnfairLock` so it can be read from any
// actor without main-thread bouncing.

import os

/// Centralised feature-flag store. Read via `FeatureFlags.shared`.
///
/// `@unchecked Sendable` because `UserDefaults` itself is not Sendable but
/// IS thread-safe per Apple's docs. The `cache` field is guarded by
/// `OSAllocatedUnfairLock`. Listed in the `scripts/check_unchecked_sendable.sh`
/// allowlist.
final class FeatureFlags: Sendable {
    static let shared = FeatureFlags()

    private static let suiteName = AppConfig.appGroupIdentifier
    private let cache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// Resolved per access rather than stored: `UserDefaults` is not
    /// `Sendable`, and Foundation caches suites internally so this is cheap.
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suiteName) ?? .standard }

    private init() {}

    // MARK: Flag definitions

    enum Key: String, CaseIterable, Sendable {
        /// MedicalQueryGuard active. Default true. Disabling is a deliberate,
        /// support-driven action (e.g. a guard rule blocking a legitimate
        /// question). When disabled, the AIProvider system prompt's
        /// MEDICAL BOUNDARY block still applies — defense in depth, not
        /// the only line.
        case medicalGuardEnabled

        /// Per-provider kill switches. UI in Settings → Flo
        /// shows the toggles; disabling routes the user back to a
        /// configured provider or Apple Intelligence.
        case providerOpenAIEnabled
        case providerAnthropicEnabled
        case providerGeminiEnabled
        case providerGrokEnabled
        case providerDeepSeekEnabled

        /// Beat Consistency card (HRV detail). Default true. Kill switch
        /// per App Store 1.4.1 posture: the metric is
        /// rhythm-adjacent (pNN50 / CV(RR) dispersion), and although it
        /// deliberately uses no arrhythmia vocabulary, carries a
        /// not-a-medical-diagnosis explainer, and the assistant refuses
        /// arrhythmia queries, review guidance for wellness apps says
        /// rhythm-adjacent surfaces need a remote-able off switch. Cite
        /// this flag in App Review notes.
        case beatConsistencyCardEnabled

        var defaultValue: Bool {
            switch self {
            case .medicalGuardEnabled,
                 .providerOpenAIEnabled,
                 .providerAnthropicEnabled,
                 .providerGeminiEnabled,
                 .providerGrokEnabled,
                 .providerDeepSeekEnabled,
                 .beatConsistencyCardEnabled:
                return true
            }
        }
    }

    func value(for key: Key) -> Bool {
        cache.withLock { cache in
            if let cached = cache[key.rawValue] { return cached }
            let stored: Bool
            if defaults.object(forKey: key.rawValue) == nil {
                stored = key.defaultValue
            } else {
                stored = defaults.bool(forKey: key.rawValue)
            }
            cache[key.rawValue] = stored
            return stored
        }
    }

    func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        cache.withLock { $0[key.rawValue] = value }
    }

    /// Snapshot of current flag values for diagnostics + the Settings
    /// → Diagnostics → "Provider status" view.
    func snapshot() -> [(key: Key, value: Bool, isDefault: Bool)] {
        Key.allCases.map { key in
            let v = value(for: key)
            return (key: key, value: v, isDefault: v == key.defaultValue)
        }
    }
}
