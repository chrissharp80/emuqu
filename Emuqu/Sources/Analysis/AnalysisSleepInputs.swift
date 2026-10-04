import Foundation

// Sleep inputs to `AnalysisSummaryGenerator`, lifted out of it.
//
// Nesting them there would only reflect where they are used. Nothing about
// them depends on the generator: they are plain value types the caller fills in
// and hands over, and two of them are the largest declarations in a type
// already at its size budget — 101 lines describing data, not behaviour.
//
// Renamed on the way out. `AnalysisSleepInput` is meaningful qualified as
// `AnalysisSummaryGenerator.SleepInput` and far too vague at file scope in an
// app with several sleep representations, so the prefix is carried in the name
// rather than lost.

struct AnalysisSleepInput {
    let totalSleepMinutes: Int
    let inBedMinutes: Int
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let awakeMinutes: Int
    /// Percent; nil when the night's wake was not measured (`SleepData.measuredSleepEfficiency`).
    let sleepEfficiency: Double?

    var totalSleepFormatted: String {
        let hours = totalSleepMinutes / 60
        let mins = totalSleepMinutes % 60
        return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }

    var isShortSleep: Bool {
        totalSleepMinutes > 0 && totalSleepMinutes < HRVThresholds.sleepShortMinutes
    }

    var isGoodSleep: Bool {
        totalSleepMinutes >= HRVThresholds.sleepMinimumMinutes
    }

    var isFragmented: Bool {
        awakeMinutes > HRVThresholds.sleepFragmentedAwakeMinutes
    }

    static let empty = AnalysisSleepInput(
        totalSleepMinutes: 0, inBedMinutes: 0,
        deepSleepMinutes: nil, remSleepMinutes: nil,
        awakeMinutes: 0, sleepEfficiency: nil
    )

    init(totalSleepMinutes: Int, inBedMinutes: Int, deepSleepMinutes: Int?, remSleepMinutes: Int?, awakeMinutes: Int, sleepEfficiency: Double?) {
        self.totalSleepMinutes = totalSleepMinutes
        self.inBedMinutes = inBedMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.sleepEfficiency = sleepEfficiency
    }

    init(from healthKit: SleepData?) {
        guard let hk = healthKit else {
            self = .empty
            return
        }
        totalSleepMinutes = hk.nightSleepMinutes
        inBedMinutes = hk.inBedMinutes
        deepSleepMinutes = hk.deepSleepMinutes
        remSleepMinutes = hk.remSleepMinutes
        awakeMinutes = hk.awakeMinutes
        sleepEfficiency = hk.measuredSleepEfficiency
    }
}

struct AnalysisSleepTrendInput {
    let averageSleepMinutes: Double
    let averageDeepSleepMinutes: Double?
    let averageEfficiency: Double?
    let trend: SleepTrend
    let nightsAnalyzed: Int

    enum SleepTrend: String {
        case improving, declining, stable, insufficient
    }

    var averageSleepFormatted: String {
        let hours = Int(averageSleepMinutes) / 60
        let mins = Int(averageSleepMinutes) % 60
        return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }

    static let empty = AnalysisSleepTrendInput(
        averageSleepMinutes: 0, averageDeepSleepMinutes: nil,
        averageEfficiency: nil, trend: .insufficient, nightsAnalyzed: 0
    )

    init(averageSleepMinutes: Double, averageDeepSleepMinutes: Double?, averageEfficiency: Double?, trend: SleepTrend, nightsAnalyzed: Int) {
        self.averageSleepMinutes = averageSleepMinutes
        self.averageDeepSleepMinutes = averageDeepSleepMinutes
        self.averageEfficiency = averageEfficiency
        self.trend = trend
        self.nightsAnalyzed = nightsAnalyzed
    }

    init(from healthKit: HealthKitManager.SleepTrendStats?) {
        guard let hk = healthKit else {
            self = .empty
            return
        }
        averageSleepMinutes = hk.averageSleepMinutes
        averageDeepSleepMinutes = hk.averageDeepSleepMinutes
        averageEfficiency = hk.averageEfficiency
        nightsAnalyzed = hk.nightsAnalyzed
        switch hk.trend {
        case .improving: trend = .improving
        case .declining: trend = .declining
        case .stable: trend = .stable
        case .insufficient: trend = .insufficient
        }
    }
}
