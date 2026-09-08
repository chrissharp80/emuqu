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
    let tsb: Double // Training Stress Balance (CTL - ATL) - "form/freshness"
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
