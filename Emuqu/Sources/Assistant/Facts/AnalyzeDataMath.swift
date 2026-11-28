import Foundation

/// One dated value of a metric, as a lookup returned it: the local day it is
/// filed under and the number. `analyzeKind` is the session type when the
/// reading is not an overnight (a nap or a quick reading standing in for a
/// day with no overnight).
struct AnalyzeDataPoint: Equatable, Sendable {
    let analyzeDay: String
    let analyzeAmount: Double
    var analyzeKind: String?
}

/// The arithmetic behind `analyze_data`. The assistant asks for an average,
/// a lowest or highest day, a trend or a difference, and the app computes it
/// here, so no number in the answer is the model's own arithmetic over text.
enum AnalyzeDataMath {
    static func analyzeDataRounded(_ number: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (number * scale).rounded() / scale
    }

    /// Decimal places for a mean, median or spread: one for bpm, ms and
    /// minutes, three for small-scale metrics (DFA alpha1, ratios 0-1) whose
    /// one-decimal mean would hide the whole difference.
    static func analyzeDataStatPlaces(_ amounts: [Double]) -> Int {
        (amounts.map(abs).max() ?? 0) < 10 ? 3 : 1
    }

    /// Slopes keep one more place than the stats they come from.
    static func analyzeDataSlopePlaces(_ amounts: [Double]) -> Int {
        analyzeDataStatPlaces(amounts) + 1
    }

    static func analyzeDataMean(_ amounts: [Double]) -> Double? {
        amounts.isEmpty ? nil : amounts.reduce(0, +) / Double(amounts.count)
    }

    static func analyzeDataMedian(_ amounts: [Double]) -> Double? {
        let sorted = amounts.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Sample standard deviation (n - 1); nil below two values.
    static func analyzeDataSampleStdev(_ amounts: [Double]) -> Double? {
        guard amounts.count > 1, let mean = analyzeDataMean(amounts) else { return nil }
        let squares = amounts.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
        return (squares / Double(amounts.count - 1)).squareRoot()
    }

    /// Ordinary least-squares slope of `ys` on `xs`; nil when the xs do not
    /// vary (one day, or every value on the same day).
    static func analyzeDataLeastSquaresSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count > 1, let meanX = analyzeDataMean(xs), let meanY = analyzeDataMean(ys) else { return nil }
        let spreadX = xs.map { ($0 - meanX) * ($0 - meanX) }.reduce(0, +)
        guard spreadX > 0 else { return nil }
        let covariance = zip(xs, ys).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +)
        return covariance / spreadX
    }

    /// Percent change from `first` to `second`; nil when `first` is zero.
    static func analyzeDataPercentChange(from first: Double, to second: Double) -> Double? {
        first == 0 ? nil : (second - first) / abs(first) * 100
    }

    /// Whole days from the first day to each day, for the trend's x axis.
    /// Nil when a day does not parse as yyyy-MM-dd.
    static func analyzeDataDayOffsets(_ days: [String]) -> [Double]? {
        let formatter = FactLocalDay.formatter()
        let parsed = days.compactMap { formatter.date(from: $0) }
        guard parsed.count == days.count, let first = parsed.first else { return nil }
        let calendar = Calendar.current
        return parsed.map { Double(calendar.dateComponents([.day], from: first, to: $0).day ?? 0) }
    }
}
