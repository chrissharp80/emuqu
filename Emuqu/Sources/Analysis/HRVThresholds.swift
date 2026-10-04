import Foundation

/// Centralized HRV thresholds and configuration constants.
/// All physiological thresholds and algorithm parameters are defined here
/// with documentation explaining the research basis for each value.
enum HRVThresholds {
    // MARK: - RR Interval Validity

    /// Minimum valid RR interval in milliseconds (300ms = 200 bpm max)
    static let minimumRRIntervalMs = 300

    /// Maximum valid RR interval in milliseconds (2000ms = 30 bpm min)
    static let maximumRRIntervalMs = 2000

    // MARK: - Signal Verification (rejection / warning thresholds)
    //
    // Centralised constants for `Verification.checkSignalQuality`,
    // `checkEctopy`, `checkOutOfBounds`. Kept here rather than as inline
    // literals in `Verification.swift` so
    // tests / tuning passes can override them via the existing `Config`
    // surface and the bounds stop drifting against
    // `HRVThresholds.minimumRRIntervalMs/maximumRRIntervalMs`.

    /// Maximum acceptable signal-loss gap before the recording is rejected (ms)
    static let verificationMaxGapMs: Int64 = 5000
    /// RR-interval drift warning threshold (ms over the recording)
    static let verificationDriftWarnMs: Double = 200
    /// RR-interval drift rejection threshold (ms over the recording — electrode movement)
    static let verificationDriftRejectMs: Double = 400
    /// Ectopic-beat percentage above which the recording is rejected
    static let verificationEctopyRejectPercent: Double = 10.0
    /// Ectopic-beat absolute count above which a warning is surfaced
    static let verificationEctopyWarnCount: Int = 100
    /// Out-of-range-interval percentage above which the recording is rejected
    static let verificationOutOfBoundsRejectPercent: Double = 5.0
    /// Out-of-range-interval absolute count for "many low/high intervals" warnings
    static let verificationOutOfBoundsWarnCount: Int = 50

    // MARK: - RMSSD Interpretation

    /// Excellent HRV threshold (ms) - strong parasympathetic activity
    static let rmssdExcellent = 50.0

    /// Good HRV threshold (ms) - adequate recovery
    static let rmssdGood = 35.0

    /// RMSSD floor (ms) for the compound "good reading" and strong-vagal-tone
    /// checks, which pair it with stress index or pNN50. Despite the name it
    /// sits above `rmssdGood`.
    static let rmssdModerate = 40.0

    /// Reduced HRV threshold (ms) - recovery may be incomplete
    static let rmssdReduced = 25.0

    /// Low HRV threshold (ms) - significant physiological stress
    static let rmssdLow = 20.0

    // MARK: - Diagnostic Score Thresholds

    // Bands of the summary's diagnostic score that pick its action steps. The
    // headline title comes from the Recovery Score's `ScoreVerdict` instead.

    /// Top band: well recovered
    static let scoreWellRecovered = 80.0

    /// Adequate recovery
    static let scoreAdequateRecovery = 60.0

    /// Incomplete recovery
    static let scoreIncompleteRecovery = 40.0

    // MARK: - Stress Index (Baevsky's SI)

    /// Very low stress threshold - deeply relaxed state
    static let stressIndexVeryLow = 50.0

    /// Low stress upper bound
    static let stressIndexLow = 100.0

    /// Normal stress upper bound
    static let stressIndexNormal = 150.0

    /// Elevated stress threshold
    static let stressIndexElevated = 200.0

    /// High stress threshold - significant physiological load
    static let stressIndexHigh = 300.0

    // MARK: - LF/HF Ratio (empirical bands)
    //
    // These name REGIONS OF THE RATIO, not autonomic states. The names below
    // are the conventional ones and are kept because they are what the
    // literature calls these regions — but the interpretation they suggest
    // does not hold. Billman 2013, "The LF/HF ratio does not accurately
    // measure cardiac sympatho-vagal balance", is the direct refutation, and
    // the app's own Help Center cites it.
    //
    // This header must not read "(Autonomic Balance)", and the
    // findings built on these thresholds must not tell users they are "in
    // fight-or-flight mode" or "well balanced". The thresholds are empirical
    // bands; what is claimed from them is not a verdict. LF/HF also moves strongly with
    // breathing rate, which is enough on its own to stop a single value being
    // a verdict.

    /// Lower band edge — below this, HF clearly exceeds LF.
    static let lfHfParasympatheticDominance = 0.5

    /// Usual resting range, lower bound.
    static let lfHfBalancedLower = 0.8

    /// Usual resting range, upper bound.
    static let lfHfBalancedUpper = 1.5

    /// Optimal range upper bound
    static let lfHfOptimalUpper = 2.0

    /// First band edge above the usual resting range.
    static let lfHfMildSympathetic = 2.5

    /// Second band edge above the usual resting range.
    static let lfHfModerateSympatheticUpper = 3.0

    /// Upper band edge — well above the usual resting range.
    static let lfHfSympatheticDominance = 3.0

    // MARK: - DFA Alpha1 (Fractal Scaling)

    /// Optimal recovery DFA α1 lower bound (organized parasympathetic control)
    static let dfaAlpha1OptimalLower = 0.75

    /// Optimal recovery DFA α1 upper bound
    static let dfaAlpha1OptimalUpper = 1.0

    /// Flexible but unconsolidated range lower bound
    static let dfaAlpha1FlexibleLower = 0.60

    /// Elevated α1 indicating fatigue
    static let dfaAlpha1Fatigue = 1.2

    /// Clearly elevated α1 — fatigue regardless of other markers
    static let dfaAlpha1ClearlyElevated = 1.35

    /// Disorganized α1 — below flexible range, recovery not consolidated
    static let dfaAlpha1Disorganized = 0.65

    /// High variability/disorganization threshold
    static let dfaAlpha1HighVariability = 1.15

    // MARK: - Heart Rate

    /// HR elevation threshold above baseline (bpm)
    static let hrElevationThreshold = 5.0

    /// Significant HR elevation threshold (bpm)
    static let hrSignificantElevation = 8.0

    // MARK: - Sleep Duration

    /// Minimum recommended sleep (minutes) - 7 hours
    static let sleepMinimumMinutes = 420

    /// Severely short sleep (minutes) - under 5 hours. Despite the name, this
    /// is the stricter of the two cuts; the names are hashed by the scoring
    /// governance gate, so they stay.
    static let sleepShortMinutes = 300

    /// Short sleep (minutes) - under 6 hours. Despite the name, this is the
    /// looser of the two cuts.
    static let sleepVeryShortMinutes = 360

    // MARK: - Sleep Quality

    /// Excellent sleep efficiency threshold (%)
    static let sleepEfficiencyExcellent = 92.0

    /// Good sleep efficiency threshold (%)
    static let sleepEfficiencyGood = 90.0

    /// Acceptable sleep efficiency threshold (%)
    static let sleepEfficiencyAcceptable = 80.0

    /// Low sleep efficiency threshold (%)
    static let sleepEfficiencyLow = 75.0

    /// Fragmented sleep awake threshold (minutes)
    static let sleepFragmentedAwakeMinutes = 30

    /// Good deep sleep percentage threshold (%)
    static let deepSleepGoodPercent = 20.0

    /// Low deep sleep percentage threshold (%)
    static let deepSleepLowPercent = 10.0

    /// Minimum deep sleep minutes for adequacy
    static let deepSleepMinimumMinutes = 45

    // MARK: - Trend Analysis

    /// Significant trend change threshold (%)
    static let trendSignificantChange = 20.0

    /// Moderate trend change threshold (%)
    static let trendModerateChange = 10.0

    /// Above baseline threshold (%)
    static let baselineAboveThreshold = 15.0

    // MARK: - pNN50 (Beat-to-Beat Variation)

    /// Very low pNN50 threshold (%) - vagal tone suppressed
    static let pnn50VeryLow = 5.0

    /// Low pNN50 threshold (%)
    static let pnn50Low = 10.0

    /// Moderate pNN50 threshold (%) - adequate vagal activity
    static let pnn50Moderate = 25.0

    /// Strong pNN50 threshold (%) - excellent vagal activity
    static let pnn50Strong = 30.0

    // MARK: - Window Selection

    /// HR coefficient of variation threshold for stability (8%)
    static let windowUnstableCVThreshold = 0.08

    // MARK: - Artifact Detection

    /// Maximum artifact rate for valid analysis
    static let maxArtifactRate = 0.15

    /// Warning artifact rate
    static let warnArtifactRate = 0.10

    /// Ectopic threshold percent deviation from local median
    static let ectopicThresholdPercent = 0.20

    // MARK: - Illness Detection

    /// Severe HRV crash threshold (% below average)
    static let illnessSevereHRVCrash = -50.0

    /// Major HRV drop threshold (% below average)
    static let illnessMajorHRVDrop = -30.0

    /// Consecutive decline days for illness pattern
    static let illnessConsecutiveDeclineDays = 3

    /// Decline threshold per day (%)
    static let illnessDeclineThreshold = 0.95
}

// MARK: - Age and Sex Adjusted HRV Interpretation

/// Provides age and sex-adjusted HRV interpretation based on population norms
/// Research basis: Nunan et al. 2010, Voss et al. 2015, Bonnemeier et al. 2003
enum AgeAdjustedHRV {
    /// Biological sex for HRV adjustment
    enum Sex: String, CaseIterable {
        case male, female

        /// Sex adjustment factor for RMSSD (women average ~5-10% lower)
        var rmssdMultiplier: Double {
            switch self {
            case .male: 1.0
            case .female: 0.92
            }
        }
    }

    /// Age-based RMSSD norms (50th percentile values in ms)
    /// Based on meta-analysis of healthy adult populations
    static func medianRMSSD(forAge age: Int, sex: Sex? = nil) -> Double {
        let baseValue = switch age {
        case ..<20: 55.0
        case 20 ..< 30: 45.0
        case 30 ..< 40: 38.0
        case 40 ..< 50: 32.0
        case 50 ..< 60: 27.0
        case 60 ..< 70: 22.0
        default: 18.0
        }

        // Apply sex adjustment if known
        let multiplier = sex?.rmssdMultiplier ?? 1.0
        return baseValue * multiplier
    }

    /// Get percentile thresholds for RMSSD by age
    /// Returns (low, fair, good, excellent) thresholds
    static func rmssdThresholds(forAge age: Int, sex: Sex? = nil) -> RMSSDThresholds {
        let median = medianRMSSD(forAge: age, sex: sex)

        // Bands relative to the age-adjusted median:
        // Low: below 0.6x median
        // Reduced: 0.6-0.85x median
        // Fair: 0.85-1.15x median
        // Good: 1.15-1.4x median
        // Excellent: 1.4x median and above
        return RMSSDThresholds(
            low: median * 0.6,
            fair: median * 0.85,
            good: median * 1.15,
            excellent: median * 1.4
        )
    }

    /// Interpret RMSSD value with age context
    static func interpret(rmssd: Double, age: Int?, sex: Sex? = nil) -> RMSSDInterpretation {
        guard let age else {
            // Fall back to absolute thresholds if no age
            return interpretAbsolute(rmssd: rmssd)
        }
        let median = medianRMSSD(forAge: age, sex: sex)
        let banding = categorize(rmssd: rmssd, age: age, sex: sex)
        return RMSSDInterpretation(
            category: banding.category,
            ageContext: banding.ageContext,
            percentile: estimatePercentile(rmssd: rmssd, median: median),
            ageAdjustedMedian: median
        )
    }

    /// Which age-adjusted band an RMSSD falls in, and the phrase describing it.
    private static func categorize(
        rmssd: Double, age: Int, sex: Sex?
    ) -> (category: RMSSDCategory, ageContext: String) {
        let thresholds = rmssdThresholds(forAge: age, sex: sex)
        if rmssd >= thresholds.excellent { return (.excellent, "well above average for your age") }
        if rmssd >= thresholds.good { return (.good, "above average for your age") }
        if rmssd >= thresholds.fair { return (.fair, "typical for your age") }
        if rmssd >= thresholds.low { return (.reduced, "below average for your age") }
        return (.low, "significantly below average for your age")
    }

    /// Fall back to absolute interpretation when age unknown, on the named
    /// RMSSD cut points above so the two can never disagree.
    private static func interpretAbsolute(rmssd: Double) -> RMSSDInterpretation {
        let category: RMSSDCategory = if rmssd >= HRVThresholds.rmssdExcellent {
            .excellent
        } else if rmssd >= HRVThresholds.rmssdGood {
            .good
        } else if rmssd >= HRVThresholds.rmssdReduced {
            .fair
        } else if rmssd >= HRVThresholds.rmssdLow {
            .reduced
        } else {
            .low
        }

        return RMSSDInterpretation(
            category: category,
            ageContext: nil,
            percentile: nil,
            ageAdjustedMedian: nil
        )
    }

    /// Estimate percentile from RMSSD relative to median
    /// Uses log-normal distribution assumption typical for HRV data
    private static func estimatePercentile(rmssd: Double, median: Double) -> Int {
        // Approximate percentile using ratio to median
        // HRV follows roughly log-normal distribution with CV ~0.4-0.5
        let ratio = rmssd / median

        if ratio >= 1.8 { return 95 }
        if ratio >= 1.5 { return 85 }
        if ratio >= 1.3 { return 75 }
        if ratio >= 1.1 { return 60 }
        if ratio >= 0.95 { return 50 }
        if ratio >= 0.8 { return 35 }
        if ratio >= 0.65 { return 20 }
        if ratio >= 0.5 { return 10 }
        return 5
    }
}

// MARK: - Interpretation Result Types

enum RMSSDCategory: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case reduced = "Reduced"
    case low = "Low"

    /// The category name in the app language, for reports and other
    /// surfaces that don't run text through the narrative translator.
    var localizedLabel: String {
        switch self {
        case .excellent: String(localized: "Excellent", bundle: LanguageManager.appBundle)
        case .good: String(localized: "Good", bundle: LanguageManager.appBundle)
        case .fair: String(localized: "Fair", bundle: LanguageManager.appBundle)
        case .reduced: String(localized: "Reduced", bundle: LanguageManager.appBundle)
        case .low: String(localized: "Low", bundle: LanguageManager.appBundle)
        }
    }

    /// The age-band phrase in the app language, sentence case.
    var localizedAgeContext: String {
        switch self {
        case .excellent: String(localized: "Well above average for your age", bundle: LanguageManager.appBundle)
        case .good: String(localized: "Above average for your age", bundle: LanguageManager.appBundle)
        case .fair: String(localized: "Typical for your age", bundle: LanguageManager.appBundle)
        case .reduced: String(localized: "Below average for your age", bundle: LanguageManager.appBundle)
        case .low: String(localized: "Significantly below average for your age", bundle: LanguageManager.appBundle)
        }
    }

    var color: String {
        switch self {
        case .excellent: "green"
        case .good: "teal"
        case .fair: "yellow"
        case .reduced: "orange"
        case .low: "red"
        }
    }
}

struct RMSSDInterpretation {
    let category: RMSSDCategory
    let ageContext: String?
    let percentile: Int?
    let ageAdjustedMedian: Double?

    /// Full description with age context
    var fullDescription: String {
        if let context = ageContext {
            return "\(category.rawValue) – \(context)"
        }
        return category.rawValue
    }

    /// Short label for UI
    var label: String {
        category.rawValue
    }

    /// `label` in the app language.
    var localizedLabel: String {
        category.localizedLabel
    }

    /// `ageContext` in the app language; nil when no age was known.
    var localizedAgeContext: String? {
        ageContext == nil ? nil : category.localizedAgeContext
    }

    /// Percentile description if available
    var percentileDescription: String? {
        guard let p = percentile else { return nil }
        return "\(p)th percentile for your age"
    }
}
