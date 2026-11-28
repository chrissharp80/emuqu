import Foundation

/// Where `analyze_data` reads a metric from: the existing catalog lookup
/// whose records carry that field. The analysis never selects data itself;
/// it reads the same records get_hrv, get_sleep, get_vitals, get_recovery and
/// list_workouts return, so its numbers agree with theirs.
enum AnalyzeDataSource: String, CaseIterable, Sendable {
    case hrv, sleep, vitals, recovery, workout

    /// The source whose records carry `metric`, searched in this order.
    static func analyzeDataSource(forMetric metric: String) -> AnalyzeDataSource? {
        allCases.first { $0.analyzeDataFieldNames.contains(metric) }
    }

    /// Fields every record carries that are not a measurement.
    private static let analyzeDataIdentityFields: Set<String> = ["date", "session_type", "id"]

    var analyzeDataFieldNames: Set<String> {
        Set(analyzeDataRecordFields).subtracting(Self.analyzeDataIdentityFields)
    }

    private var analyzeDataRecordFields: [String] {
        switch self {
        case .hrv: RecordFields.hrv
        case .sleep: RecordFields.sleep
        case .vitals: RecordFields.vitals
        case .recovery: RecordFields.recovery
        case .workout: SessionNamespace.workoutRecordFields
        }
    }

    /// Overnight sources file each reading under the local day its midpoint
    /// falls in; workouts under the day they started.
    var analyzeDataIsOvernight: Bool { self != .workout }

    /// The per-period lookup: one record per reading in `period`.
    func analyzeDataPeriodKey(_ period: String, sport: String?) -> String {
        switch self {
        case .hrv: "hrv.recent(\(period))"
        case .sleep: "sleep.recent(\(period))"
        case .vitals: "vitals.recent(\(period))"
        case .recovery: "recovery.score.recent(\(period))"
        case .workout: "workout.list(\(([period] + [sport].compactMap { $0 }).joined(separator: ",")))"
        }
    }

    /// The one-day lookup: the reading that day, picked the way the app's
    /// screens pick it.
    func analyzeDataDateKey(_ day: String, sport: String?) -> String {
        switch self {
        case .hrv: "hrv.by_date(\(day))"
        case .sleep: "sleep.by_date(\(day))"
        case .vitals: "vitals.by_date(\(day))"
        case .recovery: "recovery.score.by_date(\(day))"
        case .workout: "workout.by_date(\(([day] + [sport].compactMap { $0 }).joined(separator: ",")))"
        }
    }

    /// Unit by the field's own suffix, the naming every record follows.
    static func analyzeDataUnit(forMetric metric: String) -> String? {
        if metric == "score" { return "points (0-100)" }
        if metric.hasPrefix("respiratory_rate") { return "breaths per minute" }
        return analyzeDataUnitSuffixes.first { metric.hasSuffix($0.suffix) }?.unit
    }

    private static let analyzeDataUnitSuffixes: [(suffix: String, unit: String)] = [
        ("_sec_per_km", "seconds per km"), ("_sec_per_500m", "seconds per 500 m"), ("_bpm", "bpm"), ("_ms2", "ms squared"),
        ("_ms", "ms"), ("_minutes", "minutes"), ("_percent", "percent"), ("_per_min", "per minute"), ("_sec", "seconds"),
        ("_kmh", "km/h"), ("_m_per_hr", "meters per hour"), ("_per_hr", "per hour"), ("_m", "meters"), ("_c", "degrees C"), ("_w", "watts")
    ]
}
