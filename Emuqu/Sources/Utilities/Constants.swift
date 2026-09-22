import Foundation

// MARK: - App Configuration

/// Centralized app identifiers — single source of truth for strings that appear
/// in entitlements, Keychain queries, and container lookups.
enum AppConfig {
    /// App Group identifier (must match Signing & Capabilities → App Groups)
    static let appGroupIdentifier = "group.com.chrissharp.flowrecovery"

    /// iCloud container identifier (must match CloudKit entitlement)
    static let iCloudContainerIdentifier = "iCloud.com.chrissharp.flowrecovery"

    /// Keychain service for encryption keys
    static let keychainService = "com.chrissharp.flowrecovery.encryption"

    /// Directory name for session archive storage
    static let archiveDirectoryName = "HRVArchive"

    /// Directory name for raw RR backup storage
    static let backupDirectoryName = "RRBackup"

    /// Resolves the shared App Group container URL, falling back to Documents.
    static func sharedContainerURL() -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return container
        }
        // Not `urls(...)[0]`: iOS guarantees a Documents
        // URL exists, but the docs allow `urls(for:in:)` to return an
        // empty array if the search location can't be resolved. A
        // crash here would be catastrophic (called from app start /
        // archive paths), so fall back to a tmp URL on the impossible
        // path rather than trap.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

// MARK: - UserDefaults Keys

/// Centralized registry of all UserDefaults keys used across the app.
/// Each key is defined once here; usage sites reference these constants
/// instead of raw string literals to prevent typos and make auditing easy.
enum UserDefaultsKeys {
    /// -- Recording State (PersistedRecordingState) --
    static let persistedRecordingState = "RRCollector.persistedRecordingState"

    // -- RRCollector --
    static let activeRecordingStartTime = "RRCollector.activeRecordingStartTime"
    static let activeRecordingSessionId = "RRCollector.activeRecordingSessionId"
    static let activeRecordingSessionType = "RRCollector.activeRecordingSessionType"
    static let pausedSessionId = "RRCollector.pausedSessionId"
    static let mergeDataLossRepaired = "RRCollector.mergeDataLossRepaired.v6"

    // -- PolarManager --
    static let knownDevices = "PolarManager.knownDevices"
    static let lastConnectedTime = "PolarManager.lastConnectedTime"
    /// Legacy key, migrated on first load
    static let legacyLastDeviceId = "PolarManager.lastDeviceId"

    // -- CloudKit Sync --
    static let cloudKitZoneCreated = "CloudKitZoneCreated"
    static let cloudKitSubscriptionRegistered = "CloudKitSubscriptionRegistered"
    static let cloudKitChangeToken = "CloudKitChangeToken"
    static let cloudKitLastSyncDate = "CloudKitLastSyncDate"

    // -- Debug / Logging --
    static let persistentLoggingEnabled = "PersistentLoggingEnabled"
    static let runtimeLoggerEnabled = "RuntimeLoggerEnabled"

    /// -- Audio --
    static let breathingAudioEnabled = "breathingAudioEnabled"

    /// -- Settings --
    static let disclaimerAccepted = "hasAcceptedHealthDisclaimer"

    /// -- Trial --
    static let lastTrialReminderDate = "lastTrialReminderDate"

    /// -- Apple Health --
    /// Set when onboarding's "Skip for now" is tapped on the Apple Health
    /// page; cleared by any request for access. See
    /// `AppLaunchTasks.requestHealthKitAuthorizationIfOnboarded`.
    static let healthAccessSkipped = "healthAccessSkippedInOnboarding"

    // Legacy recording keys are the same as activeRecording* above —
    // PersistedRecordingState migrates from those 3 keys into a single atomic key.
}

// MARK: - Physical Unit Conversions

/// Canonical physical-unit conversion factors. Single source of truth so the
/// same conversion cannot drift between call sites — it previously did:
/// feet-per-metre was written as both `3.281` and `3.280_84`, metres-per-degree
/// latitude as both `111_320` and `111_000`, and mph-per-(m/s) as both
/// `2.236_936` and `2.23694`.
enum UnitConstants {
    /// Feet per metre (exact: 1 / 0.3048 = 3.280839895…).
    static let feetPerMeter: Double = 3.280_84
    /// Miles per hour per metre-per-second (exact: 3600 / 1609.344 = 2.236936…).
    static let mphPerMetersPerSecond: Double = 2.236_936
    /// Metres per degree of latitude (mean; 1° latitude ≈ 111.32 km).
    static let metersPerDegreeLatitude: Double = 111_320
}

// MARK: - Session Lifecycle

enum SessionConstants {
    /// Maximum age (seconds) for a paused session to be considered resumable.
    /// After this threshold, the recording gap is too large to produce a meaningful merged result.
    static let maxResumableSessionAge: TimeInterval = 6 * 3600 // 6 hours
}

// MARK: - Time Conversions

enum TimeConstants {
    static let msPerSecond: Double = 1000.0
    static let msPerMinute: Double = 60000.0
    static let msPerHour: Double = 3_600_000.0
    static let secondsPerMinute: Int = 60
    static let minutesPerHour: Int = 60
    static let hoursPerDay: Int = 24
    static let secondsPerHour: TimeInterval = 3600
    static let secondsPerDay: TimeInterval = 86400
    /// Two-hour gap in seconds (used for overnight session detection)
    static let twoHourGapSeconds: TimeInterval = 7200
}

// MARK: - HRV Analysis

enum HRVConstants {
    /// Minimum/maximum physiologically valid RR intervals (ms)
    enum RRInterval {
        // Physiological RR floor = 300 ms (~200 bpm): a shorter interval is a
        // technical artifact, not a real beat. 300 ms (not 200) is the literature
        // floor — Kubios artifact handling; Lipponen &
        // Tarvainen, J Med Eng Technol 2019;43:173-181.
        static let minimum: Int = 300 // ~200 bpm
        static let maximum: Int = 2000 // ~30 bpm

        static let range: ClosedRange<Int> = minimum ... maximum

        /// Check if an RR interval is physiologically valid
        static func isValid(_ ms: Int) -> Bool {
            range.contains(ms)
        }
    }

    /// Duration thresholds for analysis
    enum MinimumDuration {
        /// Minimum analysis window duration in milliseconds for reliable scoring (5 minutes)
        static let forReliableWindowMs: Int64 = 300_000
        /// Minimum session duration in seconds to trust a below-baseline score.
        /// Anything shorter without organized recovery is insufficient data, not a bad night.
        /// 3 hours covers at least the first two sleep cycles and reaches the recovery zone.
        static let forOvernightSessionSeconds: TimeInterval = 10800
    }

    /// Beat count thresholds for analysis
    enum MinimumBeats {
        static let forAnalysis: Int = 300 // Minimum for reliable HRV metrics
        static let forStreaming: Int = 120 // Relaxed for short recordings
        static let forTriangularIndex: Int = 20
        static let forDFA: Int = 256 // Minimum for fractal analysis
    }

    /// Frequency domain band boundaries (Hz)
    enum FrequencyBands {
        // HRV bands VLF 0.003–0.04, LF 0.04–0.15, HF 0.15–0.40 Hz — Task Force
        // ESC/NASPE, Circulation 1996;93:1043-1065
        static let vlfLow: Double = 0.003
        static let vlfHigh: Double = 0.04
        static let lfLow: Double = 0.04
        static let lfHigh: Double = 0.15
        static let hfLow: Double = 0.15
        static let hfHigh: Double = 0.4

        /// Minimum window duration for VLF analysis (minutes)
        static let minimumVLFWindowMinutes: Double = 5.0
    }

    /// DFA (Detrended Fluctuation Analysis) parameters
    enum DFA {
        // DFA: integrate→box linear detrend→RMS→log-log slope; α1 boxes 4–16,
        // α2 16–64 — Peng et al., Chaos 1995;5:82-87
        static let alpha1ScaleMin: Int = 4
        static let alpha1ScaleMax: Int = 16
        static let alpha2ScaleMin: Int = 16
        static let alpha2ScaleMax: Int = 64

        /// Optimal α1 range for organized parasympathetic recovery
        static let organizedRecoveryAlpha1Range: ClosedRange<Double> = 0.75 ... 1.0

        /// α1 intensity-domain boundaries (Rogers/Gronwald durability
        /// literature): above `alpha1AerobicThreshold` is the aerobic /
        /// correlated regime; below `alpha1AnaerobicThreshold` is heavy
        /// uncorrelated effort. Centralized here rather than inline `0.75` /
        /// `0.5` literals at the 8+ sites across the fitness report views.
        /// DFA-α1 ≈0.75 ↔ aerobic threshold (VT1), ≈0.5 ↔ anaerobic (VT2) —
        /// Rogers, Gronwald et al., Front Physiol 2021;11:596567.
        static let alpha1AerobicThreshold: Double = 0.75
        static let alpha1AnaerobicThreshold: Double = 0.5
    }

    /// Artifact detection thresholds
    enum Artifacts {
        static let maxPercentForAnalysis: Double = 15.0
        static let warnPercentThreshold: Double = 5.0
        static let windowSize: Int = 50
    }

    /// RR-interval physiological validity gates. The
    /// LOWER bound is the 300 ms (~200 bpm) literature floor EVERYWHERE: a
    /// sub-300 ms interval is a technical artifact regardless of source (Kubios;
    /// Lipponen & Tarvainen 2019). Only the UPPER bound stays deliberately
    /// source-specific:
    /// • Polar BLE stream gate (300–2000 ms = 30–200 bpm): tight — the strap
    ///   reports a per-sample error estimate and the tighter band cuts PPI
    ///   noise at the source.
    /// • Watch RR synthesis gate (300–2500 ms, exclusive): wider ceiling only —
    ///   Watch RR is synthesized from averaged HR payloads, so a 2000 ms ceiling
    ///   would clip legitimately long reconstructed intervals and bias the
    ///   series. The floor is now unified with the strap gate; the ceiling is
    ///   the sole remaining, deliberate difference.
    enum RRValidity {
        static let polarStreamRange: ClosedRange<Int> = 300 ... 2000
        static let watchSynthesisMinExclusive: Int = 300
        static let watchSynthesisMaxExclusive: Int = 2500
    }
}

// MARK: - Sleep Analysis

enum SleepConstants {
    /// Sleep duration thresholds (minutes)
    /// Adult recommendation ≥7h; TST <6.5h = short — Watson et al., Sleep
    /// 2015;38(6):843; Hirshkowitz et al., Sleep Health 2015;1(1):40
    static let goodSleepMinutes: Int = 420 // 7 hours
    static let minimumSleepMinutes: Int = 240 // 4 hours
    static let optimalSleepMinutes: Int = 480 // 8 hours

    /// Default split gap (minutes). Now configurable via UserSettings.sleepSplitGapMinutes.
    /// Gaps >= this in sleep data are treated as separate sessions.
    /// ENGINEERING BOUND (no sleep-science basis): gap that splits a sleep
    /// record into separate sessions.
    static let defaultSplitGapMinutes: Int = 20

    /// Threshold (minutes) for disagreement between HealthKit and HR-estimated
    /// sleep boundaries. When they differ by more than this, HR is preferred.
    /// ENGINEERING BOUND (no sleep-science basis): boundary-source disagreement
    /// tolerance before HR is preferred over HealthKit.
    static let boundaryDisagreementMinutes: Int = 15

    /// Ceiling for HR-estimated sleep-onset latency (minutes from recording
    /// start). The recording starts at bedtime, so onset can't plausibly be an
    /// hour of lying awake — typical sleep-onset latency is 10-20 min (>30 min
    /// is clinically prolonged). Clamps the HR estimator, which otherwise reads
    /// the light→deep transition (~1 h) as the moment of falling asleep. See
    /// `HealthKitManager.estimateSleepFromHR`.
    /// SOL clamp 20 min: typical adult SOL 10–20 min, >30 clinically prolonged
    /// — Ohayon et al., Sleep 2004;27(7):1255-73; AASM/ICSD-3.
    static let maxHREstimatedOnsetLatencyMin: Int = 20

    /// Minimum fraction of the SHORTER of {recording span, sleep span} that the
    /// two must overlap before a HealthKit sleep block can be auto-attached to a
    /// recording (see `SleepData.plausiblyBelongsToRecording`). Guards against
    /// HealthKit handing back a whole night's block for a short pre-sleep clip
    /// (~0% overlap → rejected) while still accepting every legitimate shape:
    /// recording spanning the sleep, strap removed before wake, and — critically
    /// — the strap left running for hours PAST wake (recording ≫ sleep).
    /// ENGINEERING BOUND (no sleep-science basis): minimum overlap fraction
    /// before a HealthKit sleep block may auto-attach to a recording.
    static let minSleepRecordingOverlapRatio: Double = 0.5

    /// Minimum length (minutes) for a single daytime nap episode to count toward
    /// 24-hour sleep DURATION. Naps shorter than this restore alertness but carry
    /// little physiological recovery and are more likely to be misdetected
    /// sedentary time, so they are not credited (PeerJ 14460 napping review;
    /// only longer naps reliably reach slow-wave sleep).
    static let napMinimumMinutesToCount: Int = 20

    /// Gap (minutes) that separates two distinct daytime sleep episodes when
    /// grouping HealthKit nap samples, so the per-episode minimum is applied to
    /// each real nap rather than to scattered samples summed together.
    static let napEpisodeGapMinutes: Int = 60

    /// Sleep efficiency thresholds (percentage)
    /// Sleep efficiency <85% = standard abnormal/insomnia cutoff — AASM Clinical
    /// Practice Guideline (Sateia et al.), J Clin Sleep Med 2017;13(2):307
    static let goodEfficiency: Double = 85.0
    static let poorEfficiency: Double = 75.0

    /// Sleep science score bands (0-100) — the single ladder for BOTH
    /// labels and colors. With separate ladders (the morning sheet once
    /// labeled at 85/70/50 while SleepDetailV2 colored at 80/60/45) the same
    /// score could read "Poor" while rendering in caution-amber. V2's bands
    /// are canonical.
    enum ScoreBands {
        static let excellent: Double = 80
        static let good: Double = 60
        static let fair: Double = 45
    }
}

// MARK: - Training Load

enum TrainingConstants {
    /// Acute:Chronic Workload Ratio thresholds
    enum ACR {
        static let detraining: Double = 0.8
        static let optimalLow: Double = 0.8
        static let optimalHigh: Double = 1.1
        static let building: Double = 1.3
        static let overreaching: Double = 1.5
    }

    /// Training Stress Balance interpretation
    enum TSB {
        static let veryFresh: Double = 25
        static let fresh: Double = 10
        static let neutral: Double = -10
        static let tired: Double = -25
    }

    /// TRIMP calculation constants (Bannister method)
    enum TRIMP {
        /// Banister TRIMP exponential weighting coefficients (Morton, Fitz-Clarke
        /// & Banister 1990): intensityFactor = a·e^(b·HRR), male a=0.64 b=1.92,
        /// female a=0.86 b=1.67. These are the `b` exponents.
        /// Banister TRIMP: dur_min × HRR × A·e^(b·HRR) — Morton, Fitz-Clarke &
        /// Banister, J Appl Physiol 1990;69(3):1171-1177 (coeffs: Banister 1991,
        /// Physiological Testing of Elite Athletes).
        static let maleWeighting: Double = 1.92
        static let femaleWeighting: Double = 1.67
        /// The `A` scaling coefficients of the same Banister formula (male 0.64,
        /// female 0.86). Centralized here so the two TRIMP
        /// implementations (`HealthWorkoutSummary.calculateTrimp` summary-level and
        /// `WorkoutAnalyzer.banisterTRIMP` per-beat) read ONE source instead of
        /// hard-coding 0.64/0.86 inline, where an edit to one silently desynced
        /// the other. Same source as the `b` exponents above.
        static let maleScale: Double = 0.64
        static let femaleScale: Double = 0.86
        /// Corruption backstops — the ONLY load guards with an evidence base
        /// ("cap only at non-physiological extremes"; TrainingPeaks/intervals.icu/
        /// GoldenCheetah validate-and-cap, they do NOT discard long/easy sessions).
        /// A legitimate 15–24 h ultra is only ~600–700 TSS, well under these, so
        /// real training is untouched; a corrupt record is bounded here instead of
        /// craterng ATL. There are deliberately no duration/HR-reserve/recovered
        /// ZEROING thresholds here (no peer-reviewed basis; they make load read
        /// "way too low"). See `WorkoutSummary.effectiveLoad`.
        /// ENGINEERING BOUND (no peer-reviewed basis): corrupt-recording
        /// backstop; a 15–24h ultra ≈ 600–700 TSS, so real training is untouched.
        static let maxSingleWorkoutLoad: Double = 1000
        static let maxDailyLoad: Double = 1200
    }

    /// EWMA decay constants
    enum EWMA {
        static let acuteDays: Int = 7 // ATL window
        static let chronicDays: Int = 42 // CTL window
    }

    /// ACWR ramp coefficients for training score modifier
    /// Used in RecoveryScoreCalculator.calculateTrainingScore
    enum ACWRRamp {
        /// Penalty rate for overreaching (ACR 1.3–1.5): 1.0 − (acr − 1.3) × slope
        static let overreachingSlope: Double = 0.75
        /// Penalty rate for heavy overreaching (ACR > 1.5): 0.85 − (acr − 1.5) × slope
        static let heavyOverreachingSlope: Double = 0.50
        /// Penalty rate for detraining (ACR < 0.8): 1.0 − (0.8 − acr) × slope
        static let detrainingSlope: Double = 0.50
        /// Minimum modifier at extreme overreaching (ACR ≥ 2.0)
        static let heavyOverreachingFloor: Double = 0.60
        /// Minimum modifier at extreme detraining
        static let detrainingFloor: Double = 0.85
    }
}

// MARK: - Recovery Scoring Weights

/// Weights for composite recovery score calculation.
/// Separated from algorithm code so all tunable weights live in one place.
///
/// **Post-ACWR removal** — the recovery score architecture
/// is `HRV + Sleep + Vitals`, not `HRV + Sleep + Training`. Training
/// load is not part of the recovery score (it lives on the parallel
/// Load & Trajectory surface). Rationale: per Impellizzeri et al. (2020/2021)
/// the ACWR-injury association is statistically indistinguishable from random
/// numbers in the chronic denominator (Sports Med 51:581–592). Per Altini's
/// 2025 systematic review of 14 commercial composite scores (Doherty et al.,
/// Translational Exercise Biomedicine 2(2):128–144) and his consistent
/// HRV4Training methodology, training load already manifests downstream as
/// suppressed HRV / elevated RHR / altered respiratory rate — including it
/// as an independent score factor double-counts the same physiological event.
/// Vitals (RHR / RR / wrist temperature) catch what HRV misses (illness,
/// inflammation, dehydration) before HRV fully responds.
///
/// **Weights are calibrated against published practitioner heuristics**
/// (Plews 2013 SWC, Buchheit 2014 stability-as-readiness, Altini's "trust
/// HRV when proxies disagree"), **not validated against outcomes**. The
/// methodology page surfaces this honestly, in
/// `RecoveryMethodologyView.validationSection`.
///
/// `validationSection` is what makes that claim true — the page must keep
/// saying the weights are unvalidated. Cited by SYMBOL, not line number, per
/// `scripts/check_comment_citations.sh` — this repo splits files to meet
/// budgets and a line-numbered citation is on a timer from the day it is
/// written. A symbol survives a split.
/// The range every user-facing 0-100 score is clamped to, and the value a
/// non-finite input degrades to.
///
/// Extracted so the two composite paths
/// (`computeBreakdown` and `blendingPerceivedReadiness`) cannot disagree about
/// what "clamped" means, and so a NaN can never map to a *maximum* score by
/// falling through a band table.
enum ScoringBounds {
    static let minScore: Double = 0.0
    static let maxScore: Double = 100.0
    /// Midpoint. Used when an input is non-finite: "we do not know" must not
    /// read as "excellent".
    static let neutralScore: Double = 50.0
    /// Same idea for a subjective 0-1 answer that arrives non-finite.
    static let neutralSubjectiveScore: Double = 50.0
}

enum ScoringWeights {
    /// Tier 3 weights: HRV + Sleep + Vitals all available (full-signal day).
    /// Replaces the pre-ACWR-removal Tier3 (HRV/Sleep/Training 0.50/0.20/0.30).
    enum Tier3 {
        static let hrv: Double = 0.60
        static let sleep: Double = 0.25
        static let vitals: Double = 0.15
    }

    /// Tier 2 weights: HRV + Sleep (no vitals data, e.g. older Apple Watch
    /// without wrist-temperature, or first-week users before RR/temp baselines
    /// stabilize). Proportional renormalisation of the Tier-3 0.60/0.25 split.
    enum Tier2 {
        /// Normal case
        static let hrvNormal: Double = 0.70
        static let sleepNormal: Double = 0.30
        /// Dampened case (poor HRV + poor sleep)
        static let hrvDampened: Double = 0.85
        static let sleepDampened: Double = 0.15
    }

    /// Comeback-mode weights (returning from illness/injury, 21-day window).
    /// HRV is the strongest single signal of autonomic recovery; vitals are
    /// shown as observational only because illness can leave them noisy for
    /// weeks. Per the Comeback-mode spec.
    enum Comeback {
        static let hrv: Double = 0.80
        static let sleep: Double = 0.20
        static let vitals: Double = 0.0
    }

    /// Sleep sub-score component weights
    enum Sleep {
        static let duration: Double = 0.35
        static let efficiency: Double = 0.25
        static let deepSleep: Double = 0.25
        static let remSleep: Double = 0.15

        /// Target share of the night for each stage, used by
        /// `RecoveryScoreCalculator.stageRatio`. Kept here so no numeric
        /// literals live inside a scoring function.
        static let deepSleepTargetProportion: Double = 0.20
        static let remSleepTargetProportion: Double = 0.25
    }

    /// Blend applied to the HRV factor when the recording itself was unusable
    /// and the user supplied a subjective readiness answer. Must sum to 1.
    enum PerceivedReadiness {
        static let baseline: Double = 0.70
        static let subjective: Double = 0.30
    }

    /// Vitals sub-score rules — applied within the 15% Vitals factor.
    ///
    /// The three sub-inputs (RHR, respiratory rate, wrist temperature) are
    /// weighted EQUALLY, and `VitalsScoring.calculateVitalsScore` implements
    /// that as a plain mean of whichever sub-scores exist. Averaging over the
    /// present inputs is the same thing as redistributing a missing input's
    /// weight evenly across the rest, which is the intended behaviour:
    /// a user without wrist-temperature data is not penalised for
    /// missing it.
    ///
    /// This enum deliberately declares no per-vital weights
    /// (`restingHeartRate` / `respiratoryRate` / `wristTemperature`). Such
    /// constants would be dead config describing a weighted-sum mechanism the
    /// scorer does not use, and the Help Center once drifted off them
    /// independently to a 40/35/25 split that matched neither. The
    /// mean IS the weighting, and one statement of it cannot disagree with
    /// itself.
    enum Vitals {
        // Sub-score scoring rules. Defined here so the algorithm code can
        // reference them rather than embed magic numbers.

        /// RHR: 100 if at/below personal baseline; linear penalty of N points
        /// per +1 SD above baseline; floor at 0.
        static let rhrPenaltyPerSD: Double = 10.0

        /// Respiratory rate: 100 if within ±N br/min of baseline; linear
        /// penalty of M points per br/min above baseline; floor at 0.
        static let respiratoryRateBandBreathsPerMin: Double = 1.0
        static let respiratoryRatePenaltyPerBreath: Double = 15.0

        /// Population-norm fallback for nights when the
        /// user's personal 7-day respiratory baseline doesn't exist
        /// yet (new user, intermittent Watch sleep tracking, etc.).
        /// Healthy adult overnight respiratory rate sits in 12–18
        /// br/min (Park 2017, Apple's own Health-app displayed range).
        /// We don't penalize the user for "no baseline yet" — we use
        /// the population window to grade their actual reading until
        /// their personal baseline catches up, then switch over
        /// automatically (the per-user path stays preferred when
        /// available because the deviation against THEIR baseline is
        /// more informative than against the population).
        ///
        /// Inside [popMin, popMax] → score 100.
        /// Above popMax → same `respiratoryRatePenaltyPerBreath`
        /// gradient as the baseline path (15 pts per br/min above
        /// popMax), floored at 0.
        /// Below popMin → flat 90 (mild ding; very low overnight RR
        /// is generally not a recovery deficit — it's the same
        /// signal as a low resting HR — but flag it gently because
        /// sustained <10 with other symptoms can mean over-sedation).
        static let respiratoryRatePopulationMinBPM: Double = 12.0
        static let respiratoryRatePopulationMaxBPM: Double = 18.0
        static let respiratoryRateBelowPopulationScore: Double = 90.0

        /// Wrist temperature deviation bands. Step function on the
        /// POSITIVE deviation from baseline only — penalizes fever /
        /// inflammation but never penalizes a cooler-than-baseline
        /// reading (those reflect bedroom temp, lighter bedding,
        /// deeper SWS, or cycle phase, none of which indicate impaired
        /// recovery). Asymmetric rather than an abs(dev) penalty, which
        /// has no support in the literature.
        static let temperatureBandNormalCelsius: Double = 0.3   // ≤ +0.3 → 100
        static let temperatureBandMildCelsius: Double = 0.5     // +0.3–+0.5 → 75
        static let temperatureBandModerateCelsius: Double = 1.0 // +0.5–+1.0 → 50; > +1.0 → 25
        static let temperatureScoreMild: Double = 75.0
        static let temperatureScoreModerate: Double = 50.0
        static let temperatureScoreSevere: Double = 25.0
    }
}

// MARK: - Analysis Windows

enum WindowConstants {
    /// Minimum window duration (minutes)
    static let minimumDurationMinutes: Double = 4.0

    /// Histogram bin width for triangular index (ms)
    static let triangularIndexBinWidth: Double = 7.8125 // 1/128 second
}

// MARK: - Stress / ANS Normative References

/// Normative reference values for PNS and SNS index computation (Kubios-style z-scores).
/// Based on healthy adults at rest, supine position.
/// Kubios PNS/SNS normative refs (RMSSD 42±19 ms, meanRR 926±90 ms) — Nunan,
/// Sandercock, Brodie, PACE 2010;33:1407-1417.
enum StressNormativeConstants {
    // -- PNS Index references --

    /// Mean RR interval reference (ms) — healthy adult supine
    static let refMeanRR: Double = 926.0
    /// SD of mean RR across population (ms)
    static let refMeanRR_SD: Double = 90.0

    /// RMSSD reference (ms)
    static let refRMSSD: Double = 42.0
    /// SD of RMSSD across population (ms)
    static let refRMSSD_SD: Double = 19.0

    /// Poincaré SD1 reference (ms)
    static let refSD1: Double = 29.0
    /// SD of SD1 across population (ms)
    static let refSD1_SD: Double = 13.0

    // -- SNS Index references --

    /// Mean heart rate reference (bpm)
    static let refMeanHR: Double = 66.0
    /// SD of mean HR across population (bpm)
    static let refMeanHR_SD: Double = 9.0

    /// Baevsky Stress Index reference (normal resting mean)
    static let refSI: Double = 100.0
    /// SD of Stress Index (wide to account for individual variability)
    static let refSI_SD: Double = 50.0

    /// Poincaré SD2 reference (ms)
    static let refSD2: Double = 65.0
    /// SD of SD2 across population (ms)
    static let refSD2_SD: Double = 20.0

    // -- Readiness score thresholds --

    /// RMSSD-to-baseline ratio band considered optimal (inner)
    static let rmssdRatioOptimalLow: Double = 0.85
    static let rmssdRatioOptimalHigh: Double = 1.15

    /// RMSSD-to-baseline ratio band considered acceptable (mid)
    static let rmssdRatioAcceptableLow: Double = 0.70
    static let rmssdRatioAcceptableHigh: Double = 1.30

    /// RMSSD-to-baseline ratio extremes that trigger penalty
    static let rmssdRatioExtremeLow: Double = 0.60
    static let rmssdRatioExtremeHigh: Double = 1.50

    /// Absolute RMSSD thresholds for fit individuals (VO2max > 50)
    static let rmssdFitHigh: Double = 60.0
    static let rmssdFitMid: Double = 40.0
    static let rmssdFitLow: Double = 25.0

    /// Absolute RMSSD thresholds — standard population
    static let rmssdStandardHigh: Double = 50.0
    static let rmssdStandardMid: Double = 30.0
    static let rmssdStandardLow: Double = 20.0

    /// VO2max threshold above which fit-individual RMSSD thresholds apply
    static let vo2MaxFitThreshold: Double = 50.0

    /// Fitness multiplier centering VO2max value
    static let fitnessMultiplierCenterVO2: Double = 40.0
    /// Fitness multiplier divisor (scales VO2 deviation)
    static let fitnessMultiplierDivisor: Double = 100.0
    /// Fitness multiplier floor
    static let fitnessMultiplierMin: Double = 0.8
    /// Fitness multiplier ceiling
    static let fitnessMultiplierMax: Double = 1.3

    /// ANS balance thresholds — PNS minus SNS
    static let ansBalanceStrongParasympathetic: Double = 1.0
    static let ansBalanceMildSympathetic: Double = -1.0

    // -- Baevsky Stress Index algorithm parameters --

    /// Histogram bin width (ms) for Baevsky's SI computation (standard value)
    static let stressIndexBinWidthMs: Double = 50.0

    /// Minimum RR intervals required for Stress Index computation
    static let stressIndexMinRRCount: Int = 20

    // -- Readiness score weights --
    // These score deltas are added to a neutral baseline to produce a 1-10 readiness score.
    // Healthy adult reference values (Task Force, 1996)

    /// Neutral starting score for readiness calculation
    static let readinessNeutralBaseline: Double = 5.0

    /// RMSSD-to-baseline ratio in optimal band
    static let readinessRMSSDOptimalBonus: Double = 2.0
    /// RMSSD-to-baseline ratio in acceptable band
    static let readinessRMSSDAcceptableBonus: Double = 1.0
    /// RMSSD-to-baseline ratio in extreme band (penalty)
    static let readinessRMSSDExtremePenalty: Double = 2.0

    /// Absolute RMSSD above high threshold (no baseline)
    static let readinessAbsoluteRMSSDHighBonus: Double = 1.5
    /// Absolute RMSSD above mid threshold (no baseline)
    static let readinessAbsoluteRMSSDMidBonus: Double = 0.5
    /// Absolute RMSSD below low threshold (no baseline, penalty)
    static let readinessAbsoluteRMSSDLowPenalty: Double = 1.5

    /// DFA α1 flexible range upper bound for readiness scoring
    static let readinessDFAAlpha1FlexibleUpper: Double = 1.25
    /// DFA α1 in optimal range
    static let readinessDFAOptimalBonus: Double = 2.0
    /// DFA α1 in flexible range
    static let readinessDFAFlexibleBonus: Double = 0.5
    /// DFA α1 outside all acceptable ranges (penalty)
    static let readinessDFAPenalty: Double = 1.0

    /// ANS balance: strong parasympathetic dominance
    static let readinessANSStrongParaBonus: Double = 1.5
    /// ANS balance: balanced or slight parasympathetic
    static let readinessANSBalancedBonus: Double = 0.5
    /// ANS balance: mild sympathetic dominance (penalty)
    static let readinessANSMildSympPenalty: Double = 0.5
    /// ANS balance: strong sympathetic dominance (penalty)
    static let readinessANSStrongSympPenalty: Double = 1.5
}
