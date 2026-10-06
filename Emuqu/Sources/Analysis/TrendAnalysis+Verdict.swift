import Foundation

/// The one rule that decides whether a series of overnight readings is
/// rising, falling or holding steady. Every trend surface calls it: the
/// Trends screen card and insights, Flo's trend context and its
/// `recovery.trend` tool, the morning report's 7-day trend, the trend
/// comparison card and the PDF's short-window trend.
///
/// Method. HRV is compared on ln(RMSSD), the scale the cited research uses
/// (Plews 2013, Buchheit 2014). The mean of the most recent 7 days is set
/// against the readings before it, and the difference must clear the
/// smallest worthwhile change, 0.5 × the SD of those earlier readings, the
/// same SWC band the recovery score uses. For a window long enough to hold a
/// gradual drift that no single week shows, a least-squares slope gives a
/// second test, which must also clear the SWC (0.5 × the residual SD) across
/// the window. A change has to be both worthwhile and distinguishable from
/// day-to-day noise: each test is a t-test at two-sided 2.5 %, so pure noise
/// reads as a trend at most 5 % of the time across both (Bonferroni).
enum TrendVerdict {
    /// How a metric's day-to-day noise behaves. RMSSD, SDNN and spectral
    /// powers are log-normal, so they are compared as logarithms.
    enum Scale: Sendable {
        case logarithmic
        case linear
    }

    /// Which way the series moved, without a judgement of good or bad.
    enum Movement: String, Sendable {
        case up
        case down
        case flat
        case insufficient
    }

    struct Reading: Sendable {
        let date: Date
        let value: Double
    }

    struct Result: Sendable, Equatable {
        let movement: Movement
        /// The most recent 7 days against the readings before them, in
        /// percent: the geometric-mean ratio on the logarithmic scale, the
        /// difference of means over the earlier mean on the linear one.
        /// Nil when there are too few readings to compare.
        let recentChangePercent: Double?
        let readingCount: Int
    }

    /// Below this the earlier and recent groups have one reading each and no
    /// spread to test against.
    static let minimumReadings = 4
    /// The slope test needs enough residual degrees of freedom to estimate
    /// day-to-day noise.
    static let minimumReadingsForSlope = 7
    /// The rolling window the research compares against the baseline.
    static let recentWindowDays = 7.0
    /// The smallest worthwhile change, in SDs (Plews/Buchheit).
    static let swcSDMultiple = 0.5

    /// The verdict for `readings` on `scale`. Order does not matter;
    /// non-positive values are dropped on the logarithmic scale.
    static func evaluate(_ readings: [Reading], scale: Scale) -> Result {
        let points = transformed(readings, scale: scale)
        guard points.count >= minimumReadings else {
            return Result(movement: .insufficient, recentChangePercent: nil, readingCount: points.count)
        }
        let groups = split(points)
        let level = levelComparison(recent: groups.recent, earlier: groups.earlier, scale: scale)
        let percent = changePercent(level.difference, earlierMean: groups.earlier.mean, scale: scale)
        if level.isWorthwhileAndClear {
            return Result(movement: direction(level.difference), recentChangePercent: percent, readingCount: points.count)
        }
        // The slope may only call a direction the recent week agrees with,
        // so the reported percentage never points the other way.
        if let change = slopeChange(points, scale: scale), change.sign == level.difference.sign, level.difference != 0 {
            return Result(movement: direction(change), recentChangePercent: percent, readingCount: points.count)
        }
        return Result(movement: .flat, recentChangePercent: percent, readingCount: points.count)
    }

    /// Convenience for parallel arrays of values and dates.
    static func evaluate(values: [Double], dates: [Date], scale: Scale) -> Result {
        evaluate(zip(dates, values).map { Reading(date: $0, value: $1) }, scale: scale)
    }

    // MARK: - Preparation

    /// A reading on the analysis scale, `day` counted from the first reading.
    struct Point {
        let day: Double
        let value: Double
    }

    private static func transformed(_ readings: [Reading], scale: Scale) -> [Point] {
        let usable = readings
            .filter { $0.value.isFinite && (scale == .linear || $0.value > 0) }
            .sorted { $0.date < $1.date }
        guard let first = usable.first?.date else { return [] }
        return usable.map { reading in
            Point(
                day: reading.date.timeIntervalSince(first) / 86_400,
                value: scale == .logarithmic ? log(reading.value) : reading.value
            )
        }
    }

    /// The readings of the last 7 days against everything before them. The
    /// recent group never takes more than half, so a window of a week or less
    /// still has earlier readings to compare with.
    private static func split(_ points: [Point]) -> (recent: [Double], earlier: [Double]) {
        let lastDay = points.last?.day ?? 0
        let inWindow = points.filter { $0.day > lastDay - recentWindowDays }.count
        let recentCount = max(2, min(inWindow, points.count / 2))
        let values = points.map(\.value)
        return (Array(values.suffix(recentCount)), Array(values.dropLast(recentCount)))
    }

    private static func direction(_ change: Double) -> Movement {
        change > 0 ? .up : .down
    }

    // MARK: - Level test (rolling 7-day mean against the earlier readings)

    struct LevelComparison {
        let difference: Double
        let isWorthwhileAndClear: Bool
    }

    /// Pooled two-sample t-test: under "no change" the noise is the same in
    /// both groups, which is exactly the assumption the pooled test makes.
    static func levelComparison(recent: [Double], earlier: [Double], scale: Scale) -> LevelComparison {
        let difference = settled(recent.mean - earlier.mean, scaleOf: earlier.mean)
        let degrees = recent.count + earlier.count - 2
        let pooled = (Double(recent.count - 1) * Statistics.sampleVariance(recent)
            + Double(earlier.count - 1) * Statistics.sampleVariance(earlier)) / Double(max(degrees, 1))
        let standardError = sqrt(pooled * (1 / Double(recent.count) + 1 / Double(earlier.count)))
        let swc = swcSDMultiple * spreadForSWC(earlierSD(earlier, scale: scale), scale: scale)
        let clear = abs(tStatistic(difference, standardError: standardError)) >= tCritical(degrees: degrees)
        return LevelComparison(difference: difference, isWorthwhileAndClear: abs(difference) > swc && clear)
    }

    /// On the logarithmic scale the baseline SD is the app's own estimator,
    /// widened while there are fewer than seven readings, like the recovery
    /// score's baseline.
    private static func earlierSD(_ earlier: [Double], scale: Scale) -> Double {
        scale == .logarithmic ? BaselineTracker.widenedLnSD(earlier) : earlier.sampleSD
    }

    /// The SD floor the recovery score uses for ln(RMSSD), so a series with
    /// almost no spread cannot make a fraction of a percent "worthwhile".
    private static func spreadForSWC(_ sd: Double, scale: Scale) -> Double {
        scale == .logarithmic ? max(sd, BaselineConstants.lnRmssdSDFloor) : sd
    }

    /// Rounding noise from averaging identical values is not a change.
    private static func settled(_ difference: Double, scaleOf reference: Double) -> Double {
        abs(difference) <= 1e-9 * (abs(reference) + 1) ? 0 : difference
    }

    private static func tStatistic(_ difference: Double, standardError: Double) -> Double {
        guard standardError > 0 else { return difference == 0 ? 0 : .infinity }
        return difference / standardError
    }

    // MARK: - Slope test (gradual drift across a long window)

    /// The fitted change across the window when the slope is both
    /// significant and larger than the SWC; nil otherwise.
    static func slopeChange(_ points: [Point], scale: Scale) -> Double? {
        guard points.count >= minimumReadingsForSlope,
              let fit = Statistics.linearRegression(x: points.map(\.day), y: points.map(\.value)),
              let span = points.last.map({ $0.day - (points.first?.day ?? 0) })
        else { return nil }
        let xMean = points.map(\.day).mean
        let sxx = points.reduce(0) { $0 + ($1.day - xMean) * ($1.day - xMean) }
        let residuals = points.map { $0.value - (fit.intercept + fit.slope * $0.day) }
        let residualSD = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(points.count - 2))
        let change = settled(fit.slope * span, scaleOf: points.map(\.value).mean)
        let slopeError = sxx > 0 ? residualSD / sqrt(sxx) : 0
        let clear = abs(tStatistic(fit.slope, standardError: slopeError)) >= tCritical(degrees: points.count - 2)
        let worthwhile = abs(change) > swcSDMultiple * spreadForSWC(residualSD, scale: scale)
        return clear && worthwhile && change != 0 ? change : nil
    }

    // MARK: - Reporting

    private static func changePercent(_ difference: Double, earlierMean: Double, scale: Scale) -> Double? {
        switch scale {
        case .logarithmic: return (exp(difference) - 1) * 100
        case .linear: return earlierMean != 0 ? difference / abs(earlierMean) * 100 : nil
        }
    }

    // MARK: - Student t critical values

    /// Upper 1.25 % point of Student's t (two-sided 2.5 %) for 1–9 degrees of
    /// freedom, computed from the regularized incomplete beta function.
    private static let tCriticalTable: [Double] = [
        25.4517, 6.2053, 4.1765, 3.4954, 3.1634, 2.9687, 2.8412, 2.7515, 2.6850
    ]

    /// The normal quantile for the same tail, 1.25 %.
    private static let zCritical = 2.2414027276049464

    /// Two-sided 2.5 % critical value of Student's t. From ten degrees of
    /// freedom the Cornish-Fisher expansion matches the exact value to five
    /// significant figures.
    static func tCritical(degrees: Int) -> Double {
        let nu = max(degrees, 1)
        if nu <= tCriticalTable.count { return tCriticalTable[nu - 1] }
        let z = zCritical
        let v = Double(nu)
        let z3 = pow(z, 3), z5 = pow(z, 5), z7 = pow(z, 7), z9 = pow(z, 9)
        return z + (z3 + z) / (4 * v)
            + (5 * z5 + 16 * z3 + 3 * z) / (96 * v * v)
            + (3 * z7 + 19 * z5 + 17 * z3 - 15 * z) / (384 * pow(v, 3))
            + (79 * z9 + 776 * z7 + 1482 * z5 - 1920 * z3 - 945 * z) / (92_160 * pow(v, 4))
    }
}

// MARK: - Sessions

extension TrendVerdict {
    /// Each session's overnight RMSSD, dated. Callers pass sessions already
    /// filtered to the readings their surface trusts.
    static func rmssdReadings(_ sessions: [HRVSession]) -> [Reading] {
        sessions.compactMap { session in session.rmssd.map { Reading(date: session.startDate, value: $0) } }
    }

    /// The "7-day HRV trend" the morning report, its PDF, Flo's summary and
    /// the trend comparison card quote: the percentage by which the last
    /// 7 days' geometric-mean RMSSD differs from the earlier readings. Nil
    /// unless the shared verdict calls the series rising or falling, so a
    /// surface that prints it never announces noise as a trend.
    static func weeklyRMSSDChange(_ sessions: [HRVSession]) -> Double? {
        let result = evaluate(rmssdReadings(sessions), scale: .logarithmic)
        guard result.movement == .up || result.movement == .down else { return nil }
        return result.recentChangePercent
    }
}
