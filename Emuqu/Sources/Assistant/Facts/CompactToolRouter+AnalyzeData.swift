import Foundation

/// What one `analyze_data` call asks of one metric.
struct AnalyzeDataRequest: Sendable {
    let analyzeMetric: String
    let analyzeSource: AnalyzeDataSource
    /// Kept only for workout metrics, where list_workouts takes it.
    let analyzeSport: String?
}

/// One day of compare_dates: the day, the by-date lookup read, its value and,
/// when the day's reading is not an overnight, its session type.
struct AnalyzeDataDateSide: Sendable {
    let analyzeSideDay: String
    let analyzeSideKey: String
    let analyzeSideAmount: Double?
    let analyzeSideKind: String?
}

// `analyze_data`: averages, lowest and highest days, trends and comparisons
// of one metric, computed by the app from the records the other read tools
// return. Values are read through the existing lookups (hrv.recent,
// sleep.recent, vitals.recent, recovery.score.recent, workout.list and their
// by-date twins), so the data each figure comes from is the data the user
// would see from those tools.
extension CompactToolRouter {
    func resolveAnalyzeData(args: [String: String]) async -> FactValue {
        guard let metric = Self.analyzeDataArg(args["metric"]) else {
            return Self.analyzeDataInvalid("analyze_data requires 'metric', a field name from the records (e.g. rmssd_ms, total_sleep_minutes, resting_heart_rate_bpm, score, distance_m)")
        }
        guard let source = AnalyzeDataSource.analyzeDataSource(forMetric: metric) else {
            return Self.analyzeDataInvalid("unknown metric '\(metric)': pass a numeric field name from a get_hrv, get_sleep, get_vitals, get_recovery or list_workouts record")
        }
        let sport = source == .workout ? Self.analyzeDataArg(args["sport"]) : nil
        let request = AnalyzeDataRequest(analyzeMetric: metric, analyzeSource: source, analyzeSport: sport)
        let value = await analyzeDataRun(Self.analyzeDataArg(args["op"]) ?? "summary", request: request, args: args)
        return AnalyzeDataReport.analyzeDataWithPaceDisplay(value, metric: metric)
    }

    private func analyzeDataRun(_ op: String, request: AnalyzeDataRequest, args: [String: String]) async -> FactValue {
        switch op {
        case "summary", "trend":
            return await analyzeDataPeriodOp(op, request: request, period: Self.analyzeDataArg(args["period"]) ?? "last_30d")
        case "compare_dates":
            return await analyzeDataCompareDates(request, args: args)
        case "compare_periods":
            return await analyzeDataComparePeriods(request, args: args)
        default:
            return Self.analyzeDataInvalid("unknown op '\(op)': summary, trend, compare_dates or compare_periods")
        }
    }

    // MARK: - Ops

    private func analyzeDataPeriodOp(_ op: String, request: AnalyzeDataRequest, period: String) async -> FactValue {
        let series = await analyzeDataSeries(request, period: period)
        if let failure = series.analyzeFailure { return failure }
        guard !series.analyzePoints.isEmpty else { return Self.analyzeDataNoValues(request, period: period, series: series) }
        var fields = Self.analyzeDataHeader(request, op: op)
        fields["period"] = .string(period)
        fields["source_lookup"] = .string(series.analyzeSourceKey)
        let stats = op == "trend" ? AnalyzeDataReport.analyzeDataTrendFields(series) : AnalyzeDataReport.analyzeDataSummaryFields(series)
        return .record(fields.merging(stats) { current, _ in current })
    }

    private func analyzeDataComparePeriods(_ request: AnalyzeDataRequest, args: [String: String]) async -> FactValue {
        guard let periodA = Self.analyzeDataArg(args["period_a"]), let periodB = Self.analyzeDataArg(args["period_b"]) else {
            return Self.analyzeDataInvalid("op='compare_periods' requires 'period_a' and 'period_b'")
        }
        let seriesA = await analyzeDataSeries(request, period: periodA)
        let seriesB = await analyzeDataSeries(request, period: periodB)
        if let failure = seriesA.analyzeFailure ?? seriesB.analyzeFailure { return failure }
        let meanA = AnalyzeDataMath.analyzeDataMean(seriesA.analyzePoints.map(\.analyzeAmount))
        let meanB = AnalyzeDataMath.analyzeDataMean(seriesB.analyzePoints.map(\.analyzeAmount))
        let places = AnalyzeDataMath.analyzeDataStatPlaces((seriesA.analyzePoints + seriesB.analyzePoints).map(\.analyzeAmount))
        var fields = Self.analyzeDataHeader(request, op: "compare_periods")
        fields["period_a"] = Self.analyzeDataPeriodSide(periodA, series: seriesA)
        fields["period_b"] = Self.analyzeDataPeriodSide(periodB, series: seriesB)
        return .record(fields.merging(AnalyzeDataReport.analyzeDataDifferenceFields(meanA, meanB, places: places)) { current, _ in current })
    }

    private func analyzeDataCompareDates(_ request: AnalyzeDataRequest, args: [String: String]) async -> FactValue {
        guard let dayA = Self.analyzeDataDay(args["date_a"]), let dayB = Self.analyzeDataDay(args["date_b"]) else {
            return Self.analyzeDataInvalid("op='compare_dates' requires 'date_a' and 'date_b' as YYYY-MM-DD (or today / yesterday)")
        }
        let sideA = await analyzeDataDateSide(request, day: dayA)
        let sideB = await analyzeDataDateSide(request, day: dayB)
        var fields = Self.analyzeDataHeader(request, op: "compare_dates")
        fields.merge(Self.analyzeDataSideFields(sideA, suffix: "a")) { current, _ in current }
        fields.merge(Self.analyzeDataSideFields(sideB, suffix: "b")) { current, _ in current }
        let without = [sideA, sideB].filter { $0.analyzeSideAmount == nil }.map(\.analyzeSideDay)
        if !without.isEmpty { fields["dates_without_value"] = .list(without.map(FactValue.string)) }
        let places = AnalyzeDataMath.analyzeDataStatPlaces([sideA.analyzeSideAmount, sideB.analyzeSideAmount].compactMap { $0 })
        return .record(fields.merging(AnalyzeDataReport.analyzeDataDifferenceFields(sideA.analyzeSideAmount, sideB.analyzeSideAmount, places: places)) { current, _ in current })
    }

    // MARK: - Reading the lookups

    /// The metric over `period`, one value per day for overnight metrics and
    /// one per workout for workout metrics.
    private func analyzeDataSeries(_ request: AnalyzeDataRequest, period: String) async -> AnalyzeDataSeries {
        let source = request.analyzeSource
        var series = AnalyzeDataSeries(analyzeSourceKey: source.analyzeDataPeriodKey(period, sport: request.analyzeSport))
        if let invalid = PeriodParser.invalidPeriod(period) {
            series.analyzeFailure = invalid
            return series
        }
        let listed = await registry.resolveAsync(series.analyzeSourceKey)
        if case let .missing(reason, _) = listed, reason != .notRecorded {
            series.analyzeFailure = listed
            return series
        }
        guard source.analyzeDataIsOvernight else {
            let items = AnalyzeDataReport.analyzeDataRecords(listed).compactMap { AnalyzeDataReport.analyzeDataItem($0, nights: [:]) }
            return AnalyzeDataReport.analyzeDataFilled(series, items: items.sorted { $0.analyzeStart < $1.analyzeStart }, metric: request.analyzeMetric, recordedDays: [])
        }
        return await analyzeDataOvernightSeries(series, listed: listed, metric: request.analyzeMetric, period: period)
    }

    /// Overnight records placed on their filed day (from session.recent),
    /// one per day, with the period's days that had no recording.
    private func analyzeDataOvernightSeries(_ series: AnalyzeDataSeries, listed: FactValue, metric: String, period: String) async -> AnalyzeDataSeries {
        let nights = await analyzeDataNights(period)
        let items = AnalyzeDataReport.analyzeDataRecords(listed).compactMap { AnalyzeDataReport.analyzeDataItem($0, nights: nights) }
        let recorded = Set(nights.values.map(\.analyzeNightDay))
        var out = AnalyzeDataReport.analyzeDataFilled(series, items: AnalyzeDataReport.analyzeDataOnePerDay(items), metric: metric, recordedDays: recorded)
        let seen = recorded.union(items.map(\.analyzeDay))
        out.analyzeDaysWithoutRecording = AnalyzeDataReport.analyzeDataDays(in: period)?.filter { !seen.contains($0) }
        return out
    }

    /// Every overnight recording in the period by start second: its filed
    /// day and length.
    private func analyzeDataNights(_ period: String) async -> [Int: AnalyzeDataNight] {
        var nights: [Int: AnalyzeDataNight] = [:]
        for fields in AnalyzeDataReport.analyzeDataRecords(await registry.resolveAsync("session.recent(\(period))")) {
            guard case let .date(start)? = fields["date"], case let .string(day)? = fields["day"] else { continue }
            let length = AnalyzeDataReport.analyzeDataNumber(fields["duration_sec"]) ?? 0
            nights[Int(start.timeIntervalSince1970.rounded())] = AnalyzeDataNight(analyzeNightDay: day, analyzeNightDuration: length)
        }
        return nights
    }

    /// One day's value from the by-date lookup.
    private func analyzeDataDateSide(_ request: AnalyzeDataRequest, day: String) async -> AnalyzeDataDateSide {
        let key = request.analyzeSource.analyzeDataDateKey(day, sport: request.analyzeSport)
        let record = AnalyzeDataReport.analyzeDataRecords(await registry.resolveAsync(key)).first ?? [:]
        var kind: String?
        if case let .string(type)? = record["session_type"], type != SessionType.overnight.rawValue { kind = type }
        return AnalyzeDataDateSide(analyzeSideDay: day, analyzeSideKey: key, analyzeSideAmount: AnalyzeDataReport.analyzeDataNumber(record[request.analyzeMetric]), analyzeSideKind: kind)
    }

    // MARK: - Shaping

    private static func analyzeDataHeader(_ request: AnalyzeDataRequest, op: String) -> [String: FactValue] {
        var fields: [String: FactValue] = ["metric": .string(request.analyzeMetric), "op": .string(op)]
        if let unit = AnalyzeDataSource.analyzeDataUnit(forMetric: request.analyzeMetric) { fields["unit"] = .string(unit) }
        if let sport = request.analyzeSport { fields["sport"] = .string(sport) }
        return fields
    }

    private static func analyzeDataSideFields(_ side: AnalyzeDataDateSide, suffix: String) -> [String: FactValue] {
        var fields: [String: FactValue] = [
            "date_\(suffix)": .string(side.analyzeSideDay),
            "value_\(suffix)": side.analyzeSideAmount.map(FactValue.double) ?? .missing(reason: .notRecorded, detail: "no value on \(side.analyzeSideDay)"),
            "source_lookup_\(suffix)": .string(side.analyzeSideKey)
        ]
        if let kind = side.analyzeSideKind { fields["session_type_\(suffix)"] = .string(kind) }
        return fields
    }

    /// One period of compare_periods: its n, mean, min and max with their
    /// days, first and last day, and the days without a value.
    private static func analyzeDataPeriodSide(_ period: String, series: AnalyzeDataSeries) -> FactValue {
        let summary = AnalyzeDataReport.analyzeDataSummaryFields(series)
        var fields = summary.filter { ["n", "mean", "min", "min_date", "max", "max_date", "first_date", "last_date", "dates_without_value", "dates_without_recording"].contains($0.key) }
        fields["period"] = .string(period)
        fields["source_lookup"] = .string(series.analyzeSourceKey)
        return .record(fields)
    }

    private static func analyzeDataNoValues(_ request: AnalyzeDataRequest, period: String, series: AnalyzeDataSeries) -> FactValue {
        let days = series.analyzeDaysWithoutValue.prefix(AnalyzeDataReport.analyzeDataListedLimit).joined(separator: ", ")
        let recorded = days.isEmpty ? "" : "; recorded days without a value: \(days)"
        return .missing(reason: .notRecorded, detail: "no \(request.analyzeMetric) values in \(period) from \(series.analyzeSourceKey)\(recorded)")
    }

    /// A yyyy-MM-dd day; today and yesterday become the local day.
    static func analyzeDataDay(_ raw: String?) -> String? {
        guard let text = analyzeDataArg(raw)?.lowercased() else { return nil }
        let formatter = FactLocalDay.formatter()
        switch text {
        case "today", "tonight", "last_night": return formatter.string(from: Date())
        case "yesterday": return Calendar.current.date(byAdding: .day, value: -1, to: Date()).map(formatter.string(from:))
        default: return text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil && formatter.date(from: text) != nil ? text : nil
        }
    }

    static func analyzeDataArg(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func analyzeDataInvalid(_ detail: String) -> FactValue {
        .missing(reason: .invalidParameter, detail: detail)
    }
}
