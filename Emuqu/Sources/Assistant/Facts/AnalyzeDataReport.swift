import Foundation

/// One record a lookup returned, placed on the day it is filed under.
struct AnalyzeDataItem: Sendable {
    let analyzeDay: String
    let analyzeStart: Date
    let analyzeKind: String?
    let analyzeDuration: Double
    let analyzeFields: [String: FactValue]
}

/// An overnight's filed day and length, from `session.recent`.
struct AnalyzeDataNight: Sendable {
    let analyzeNightDay: String
    let analyzeNightDuration: Double
}

/// A metric's values over a period, oldest first, with the days that had a
/// recording but no value and, for a short overnight period, the days with
/// no recording at all.
struct AnalyzeDataSeries: Sendable {
    let analyzeSourceKey: String
    var analyzePoints: [AnalyzeDataPoint] = []
    var analyzeDaysWithoutValue: [String] = []
    var analyzeDaysWithoutRecording: [String]?
    var analyzeFailure: FactValue?
}

/// Builds `analyze_data`'s records from a series. Every number in them is
/// computed here; the values list says which day each one came from.
enum AnalyzeDataReport {
    /// Values are listed in full up to a month of days.
    static let analyzeDataListedLimit = 31

    // MARK: - Reading records

    static func analyzeDataNumber(_ value: FactValue?) -> Double? {
        switch value {
        case let .integer(number)?: Double(number)
        case let .double(number)?: number.isFinite ? number : nil
        case let .durationSec(seconds)?: Double(seconds)
        default: nil
        }
    }

    static func analyzeDataRecords(_ value: FactValue) -> [[String: FactValue]] {
        switch value {
        case let .list(items): items.compactMap(analyzeDataFields(of:))
        case let .record(fields): [fields]
        default: []
        }
    }

    private static func analyzeDataFields(of value: FactValue) -> [String: FactValue]? {
        if case let .record(fields) = value { return fields }
        return nil
    }

    /// The record on its filed day: an overnight's from `nights` (keyed by
    /// start second), anything else the local day it started.
    static func analyzeDataItem(_ fields: [String: FactValue], nights: [Int: AnalyzeDataNight]) -> AnalyzeDataItem? {
        guard case let .date(start)? = fields["date"] else { return nil }
        let night = nights[Int(start.timeIntervalSince1970.rounded())]
        var kind: String?
        if case let .string(type)? = fields["session_type"] { kind = type }
        return AnalyzeDataItem(
            analyzeDay: night?.analyzeNightDay ?? FactLocalDay.formatter().string(from: start),
            analyzeStart: start, analyzeKind: kind, analyzeDuration: night?.analyzeNightDuration ?? 0, analyzeFields: fields
        )
    }

    /// One reading per day, picked the way the by-date lookups pick it: the
    /// longest overnight, else the day's other reading. Oldest day first.
    static func analyzeDataOnePerDay(_ items: [AnalyzeDataItem]) -> [AnalyzeDataItem] {
        let byDay = Dictionary(grouping: items, by: \.analyzeDay)
        let picked = byDay.values.compactMap { dayItems -> AnalyzeDataItem? in
            let overnights = dayItems.filter { $0.analyzeKind == nil || $0.analyzeKind == SessionType.overnight.rawValue }
            let pool = overnights.isEmpty ? dayItems : overnights
            return pool.max { $0.analyzeDuration < $1.analyzeDuration }
        }
        return picked.sorted { $0.analyzeStart < $1.analyzeStart }
    }

    /// The series of `metric` from `items`, oldest first. `recordedDays` are
    /// days with a recording that may have left no record in `items`.
    static func analyzeDataFilled(_ series: AnalyzeDataSeries, items: [AnalyzeDataItem], metric: String, recordedDays: Set<String>) -> AnalyzeDataSeries {
        var out = series
        out.analyzePoints = items.compactMap { item in
            analyzeDataNumber(item.analyzeFields[metric]).map {
                AnalyzeDataPoint(analyzeDay: item.analyzeDay, analyzeAmount: $0, analyzeKind: item.analyzeKind == SessionType.overnight.rawValue ? nil : item.analyzeKind)
            }
        }
        let valued = Set(out.analyzePoints.map(\.analyzeDay))
        out.analyzeDaysWithoutValue = Set(items.map(\.analyzeDay)).union(recordedDays).subtracting(valued).sorted()
        return out
    }

    /// The local days of a period up to `analyzeDataListedLimit` + 1 of them,
    /// never past today; nil for a longer or unknown period.
    static func analyzeDataDays(in period: String, now: Date = Date()) -> [String]? {
        guard let interval = PeriodParser.interval(for: period, now: now) else { return nil }
        let calendar = Calendar.current
        let end = min(interval.end, now)
        var day = calendar.startOfDay(for: interval.start)
        var days: [String] = []
        let formatter = FactLocalDay.formatter()
        while day < end {
            guard days.count <= analyzeDataListedLimit, let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            days.append(formatter.string(from: day))
            day = next
        }
        return days
    }
}

// MARK: - Records

extension AnalyzeDataReport {
    /// The values themselves, oldest first, when there are few enough to list.
    static func analyzeDataValuesList(_ points: [AnalyzeDataPoint]) -> FactValue? {
        guard points.count <= analyzeDataListedLimit else { return nil }
        return .list(points.map { point in
            var fields: [String: FactValue] = ["date": .string(point.analyzeDay), "value": .double(point.analyzeAmount)]
            if let kind = point.analyzeKind { fields["session_type"] = .string(kind) }
            return .record(fields)
        })
    }

    /// The days the series has no value for, as fields.
    static func analyzeDataGapFields(_ series: AnalyzeDataSeries) -> [String: FactValue] {
        var fields: [String: FactValue] = [:]
        if !series.analyzeDaysWithoutValue.isEmpty { fields["dates_without_value"] = .list(series.analyzeDaysWithoutValue.map(FactValue.string)) }
        if let unrecorded = series.analyzeDaysWithoutRecording, !unrecorded.isEmpty {
            fields["dates_without_recording"] = .list(unrecorded.map(FactValue.string))
        }
        return fields
    }

    /// count, mean, median, min and max with their days, sum, stdev, the
    /// first and last day, and the values when they fit.
    static func analyzeDataSummaryFields(_ series: AnalyzeDataSeries) -> [String: FactValue] {
        let points = series.analyzePoints
        let amounts = points.map(\.analyzeAmount)
        let places = AnalyzeDataMath.analyzeDataStatPlaces(amounts)
        var fields = analyzeDataGapFields(series)
        fields["n"] = .integer(points.count)
        fields["mean"] = analyzeDataRoundedValue(AnalyzeDataMath.analyzeDataMean(amounts), places: places)
        fields["median"] = analyzeDataRoundedValue(AnalyzeDataMath.analyzeDataMedian(amounts), places: places)
        fields["sum"] = analyzeDataRoundedValue(amounts.isEmpty ? nil : amounts.reduce(0, +), places: places)
        fields["stdev"] = analyzeDataRoundedValue(AnalyzeDataMath.analyzeDataSampleStdev(amounts), places: places, absent: "a spread needs two or more values")
        fields.merge(analyzeDataExtremeFields(points)) { current, _ in current }
        if let values = analyzeDataValuesList(points) { fields["values"] = values }
        return fields
    }

    /// min / max with the earliest day each was reached (`min(by:)` and
    /// `max(by:)` keep the first of equal values), and the span's ends.
    private static func analyzeDataExtremeFields(_ points: [AnalyzeDataPoint]) -> [String: FactValue] {
        guard let first = points.first, let last = points.last,
              let low = points.min(by: { $0.analyzeAmount < $1.analyzeAmount }),
              let high = points.max(by: { $0.analyzeAmount < $1.analyzeAmount })
        else { return [:] }
        return [
            "min": .double(low.analyzeAmount), "min_date": .string(low.analyzeDay),
            "max": .double(high.analyzeAmount), "max_date": .string(high.analyzeDay),
            "first_date": .string(first.analyzeDay), "last_date": .string(last.analyzeDay)
        ]
    }

    /// Least-squares slope per day and per week, first and last value, the
    /// change between them, and the mean.
    static func analyzeDataTrendFields(_ series: AnalyzeDataSeries) -> [String: FactValue] {
        let points = series.analyzePoints
        let amounts = points.map(\.analyzeAmount)
        var fields = analyzeDataGapFields(series)
        fields["n"] = .integer(points.count)
        fields["mean"] = analyzeDataRoundedValue(AnalyzeDataMath.analyzeDataMean(amounts), places: AnalyzeDataMath.analyzeDataStatPlaces(amounts))
        let slope = AnalyzeDataMath.analyzeDataDayOffsets(points.map(\.analyzeDay)).flatMap { AnalyzeDataMath.analyzeDataLeastSquaresSlope(xs: $0, ys: amounts) }
        let slopePlaces = AnalyzeDataMath.analyzeDataSlopePlaces(amounts)
        let reason = "a trend needs values on two or more different days"
        fields["slope_per_day"] = analyzeDataRoundedValue(slope, places: slopePlaces, absent: reason)
        fields["slope_per_week"] = analyzeDataRoundedValue(slope.map { $0 * 7 }, places: slopePlaces, absent: reason)
        fields.merge(analyzeDataEndpointFields(points)) { current, _ in current }
        if let values = analyzeDataValuesList(points) { fields["values"] = values }
        return fields
    }

    private static func analyzeDataEndpointFields(_ points: [AnalyzeDataPoint]) -> [String: FactValue] {
        guard let first = points.first, let last = points.last else { return [:] }
        let places = AnalyzeDataMath.analyzeDataStatPlaces(points.map(\.analyzeAmount))
        return [
            "first_date": .string(first.analyzeDay), "first_value": .double(first.analyzeAmount),
            "last_date": .string(last.analyzeDay), "last_value": .double(last.analyzeAmount),
            "change": .double(AnalyzeDataMath.analyzeDataRounded(last.analyzeAmount - first.analyzeAmount, places: places))
        ]
    }

    /// `second - first` and its percent change, both rounded; absent when
    /// either side is.
    static func analyzeDataDifferenceFields(_ first: Double?, _ second: Double?, places: Int) -> [String: FactValue] {
        guard let first, let second else {
            let reason = "one side has no value"
            return ["difference": .missing(reason: .notRecorded, detail: reason), "percent_change": .missing(reason: .notRecorded, detail: reason)]
        }
        return [
            "difference": .double(AnalyzeDataMath.analyzeDataRounded(second - first, places: places)),
            "percent_change": analyzeDataRoundedValue(AnalyzeDataMath.analyzeDataPercentChange(from: first, to: second), places: 1, absent: "the first value is zero")
        ]
    }

    static func analyzeDataRoundedValue(_ number: Double?, places: Int, absent: String = "no values") -> FactValue {
        number.map { .double(AnalyzeDataMath.analyzeDataRounded($0, places: places)) } ?? .missing(reason: .notRecorded, detail: absent)
    }
}

// MARK: - Pace in the user's units

extension AnalyzeDataReport {
    /// The figures that are a pace themselves (not a difference or a slope).
    private static let analyzeDataPaceFigures: Set<String> = ["mean", "median", "min", "max", "first_value", "last_value", "value", "value_a", "value_b"]

    /// For a pace metric, each pace figure gains `<figure>_pace_display` in
    /// the user's units, so the model never converts seconds per km itself.
    static func analyzeDataWithPaceDisplay(_ value: FactValue, metric: String, units: UnitsPreference = UnitsPreferenceStore.current) -> FactValue {
        guard PaceDisplay.isPaceKey(metric) else { return value }
        switch value {
        case let .record(fields):
            return .record(analyzeDataPaceFields(fields, metric: metric, units: units))
        case let .list(items):
            return .list(items.map { analyzeDataWithPaceDisplay($0, metric: metric, units: units) })
        default:
            return value
        }
    }

    private static func analyzeDataPaceFields(_ fields: [String: FactValue], metric: String, units: UnitsPreference) -> [String: FactValue] {
        var out = fields.mapValues { analyzeDataWithPaceDisplay($0, metric: metric, units: units) }
        for key in analyzeDataPaceFigures {
            guard case let .double(seconds)? = fields[key], let display = units.formatPace(secondsPerMeter: seconds / 1_000) else { continue }
            out["\(key)_pace_display"] = .string(display)
        }
        return out
    }
}
