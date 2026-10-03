import Foundation

/// Calculate sleep trend statistics
struct SleepTrendStats {
    let averageSleepMinutes: Double
    let averageDeepSleepMinutes: Double?
    let averageEfficiency: Double
    let trend: SleepTrend // improving, declining, stable
    let nightsAnalyzed: Int

    enum SleepTrend: String {
        case improving
        case declining
        case stable
        case insufficient = "insufficient data"
    }
}
