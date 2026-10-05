import Foundation

/// TrainingPeaks-style training metrics (TRIMP, ATL, CTL, TSB)
///
/// Codable so `TrainingMetricsCache` can persist the last computed
/// value across launches. With `current` in-memory only, every
/// cold launch starts `nil` and re-fetches ~250 workouts + replays 400 days of
/// Banister EWMA before the dashboard could show a number (the "~19s to
/// populate" cold-start cost). All stored members are already Codable
/// (`WorkoutSummary` has explicit, forward-compatible Codable). The persisted
/// value is only a "show last-known while recomputing" placeholder — the cache's
/// existing workout-fingerprint + TTL gate always reconciles it on launch.
struct TrainingMetrics: Codable {
    let atl: Double // Acute Training Load (7-day EWMA of TRIMP) - "fatigue"
    let ctl: Double // Chronic Training Load (42-day EWMA of TRIMP) - "fitness"
    let tsb: Double // Training-load balance (CTL - ATL) - "form/freshness"
    let dailyTrimp: [Date: Double] // Daily TRIMP values for charting
    let todayTrimp: Double // Today's accumulated TRIMP
    let todayWorkouts: [HealthKitManager.WorkoutSummary] // Today's individual activities
    let recentWorkouts: [HealthKitManager.WorkoutSummary] // Last 14 days of workouts (for detail view)
    /// VO2max latest reading + 30-day change. Flowed
    /// through here (not just on TrainingLoad) so the sync
    /// `TrainingMetricsCache.snapshot()` path can surface them to the
    /// AI's tool layer without an async hop.
    var vo2MaxLatest: Double?
    var vo2MaxChange30Days: Double?
    var vo2MaxSampleCount30Days: Int = 0

    /// Acute:Chronic Ratio
    var acuteChronicRatio: Double? {
        guard ctl > 0 else { return nil }
        return atl / ctl
    }

    static let empty = TrainingMetrics(
        atl: 0,
        ctl: 0,
        tsb: 0,
        dailyTrimp: [:],
        todayTrimp: 0,
        todayWorkouts: [],
        recentWorkouts: []
    )
}

/// The five acute:chronic ratio bands. The Training Load screen and the PDF
/// report both read their labels from here, so the two cannot disagree.
/// The labels describe recent load against the user's own base; they are not
/// injury-risk predictions (Impellizzeri et al. 2020/2021).
enum ACWRBand: CaseIterable, Equatable {
    case belowUsual
    case maintenance
    case inRange
    case aboveUsual
    case sharpIncrease

    /// Below 0.8, 0.8–1.0, above 1.0 to 1.3, above 1.3 to 1.5, above 1.5.
    init(ratio: Double) {
        if ratio < 0.8 {
            self = .belowUsual
        } else if ratio <= 1.0 {
            self = .maintenance
        } else if ratio <= 1.3 {
            self = .inRange
        } else if ratio <= 1.5 {
            self = .aboveUsual
        } else {
            self = .sharpIncrease
        }
    }

    var rangeText: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .belowUsual: return String(localized: "< 0.8", bundle: bundle)
        case .maintenance: return String(localized: "0.8 - 1.0", bundle: bundle)
        case .inRange: return String(localized: "1.0 - 1.3", bundle: bundle)
        case .aboveUsual: return String(localized: "1.3 - 1.5", bundle: bundle)
        case .sharpIncrease: return String(localized: "> 1.5", bundle: bundle)
        }
    }

    var label: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .belowUsual: return String(localized: "Below your usual", bundle: bundle)
        case .maintenance: return String(localized: "Maintenance", bundle: bundle)
        case .inRange: return String(localized: "In range", bundle: bundle)
        case .aboveUsual: return String(localized: "Above your usual", bundle: bundle)
        case .sharpIncrease: return String(localized: "Sharp increase", bundle: bundle)
        }
    }

    var detail: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .belowUsual: return String(localized: "Recent load lower than your fitness base", bundle: bundle)
        case .maintenance: return String(localized: "Maintaining fitness", bundle: bundle)
        case .inRange: return String(localized: "Building fitness sustainably", bundle: bundle)
        case .aboveUsual: return String(localized: "Heavier recent load — listen to your body", bundle: bundle)
        case .sharpIncrease: return String(localized: "Recent load is jumping fast — easy day helps you absorb it", bundle: bundle)
        }
    }
}
