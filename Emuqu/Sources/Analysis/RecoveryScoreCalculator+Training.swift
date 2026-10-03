import Foundation

// MARK: - Training Load: Foster monotony and strain

extension RecoveryScoreCalculator {
    // MARK: - Foster's Monotony & Strain

    /// Calculate Foster's Monotony and Strain from daily TRIMP values.
    /// Monotony = mean(daily load) / SD(daily load) over 7 days.
    /// Strain = sum(daily load) × Monotony.
    ///
    /// High monotony (>2.0) means little day-to-day variation — every session
    /// looks the same. When combined with high total strain, this is the classic
    /// predictor of illness and maladaptation (Foster 1998).
    ///
    /// - Parameters:
    ///   - dailyTrimp: Dictionary mapping dates to daily TRIMP values
    ///   - referenceDate: The "today" anchor for the trailing 7-day window.
    ///     Defaults to `Date()` so existing callers are unaffected; passing
    ///     an explicit value makes the window deterministic (testability,
    ///     replaying a historical day) instead of reading the wall clock.
    /// - Returns: Tuple of (monotony, strain) over the trailing 7 calendar days
    ///   (days without training count as 0), or nil when that week's total is 0
    static func fosterMonotonyStrain(
        dailyTrimp: [Date: Double],
        referenceDate: Date = Date()
    ) -> (monotony: Double, strain: Double)? {
        // Need 7 consecutive recent days for a meaningful calculation.
        // `Calendar.date(byAdding:)` can return nil at calendar discontinuities
        // (DST shifts, minority-calendar leap-month edges); compactMap + a count
        // check keeps this safe on those edges and returns nil rather than
        // crashing.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let last7 = (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard last7.count == 7 else { return nil }
        let values = last7.map { dailyTrimp[$0] ?? 0.0 }
        let sum = values.reduce(0, +)
        guard sum > 0 else { return nil } // No training at all — nothing to compute
        let monotony = cappedMonotony(of: values, sum: sum)
        return (monotony: monotony, strain: sum * monotony)
    }

    /// Guards against division by zero: with every day identical the SD is 0 and
    /// monotony is theoretically infinite. The cap must ALSO apply when the SD
    /// is small-but-nonzero (e.g. six 50-TRIMP days plus one 50.01), which
    /// otherwise yields monotony in the thousands and trips the severe-strain
    /// dampener on a perfectly normal week. So both branches are capped,
    /// not just the SD == 0 case.
    ///
    /// The window length is taken from `values`, not a
    /// literal 7. A literal would be correct because the only caller guards
    /// `last7.count == 7`, but the spec asks for illegal states to be
    /// unrepresentable and a helper that takes an arbitrary array and divides
    /// by a constant is the shape that violates it: a second caller with a
    /// 14-day window would get a silently wrong monotony.
    private static func cappedMonotony(of values: [Double], sum: Double) -> Double {
        let days = Double(values.count)
        guard days > 0 else { return RecoveryScoreConstants.Training.monotonyCap }
        let mean = sum / days
        let sd = sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / days)
        let rawMonotony = sd > 0 ? mean / sd : RecoveryScoreConstants.Training.monotonyCap
        return min(rawMonotony, RecoveryScoreConstants.Training.monotonyCap)
    }
}
