import Foundation

/// Which archived workout a single-workout lookup reads. Every `workout.*`
/// lookup that names one workout takes this same argument, so "my run on
/// March 3", "the second workout that day" and a workout id reach the same
/// record through any of them:
///   - a workout UUID;
///   - `yyyy-MM-dd`: the latest workout started that local day;
///   - `yyyy-MM-dd,sport`: the latest workout of that sport that day;
///   - `yyyy-MM-dd,N` or `yyyy-MM-dd,sport,N`: the Nth started that day
///     (1 = the first), of that sport when one is named.
struct WorkoutSelector: Equatable {
    enum Target: Equatable {
        case workoutID(UUID)
        case localDay(String)
    }

    let target: Target
    var sport: Sport?
    var position: Int?

    static let selectorShape = "'yyyy-MM-dd', 'yyyy-MM-dd,sport', 'yyyy-MM-dd,sport,N', 'yyyy-MM-dd,N' or a workout id"

    static func parseSelector(_ raw: String) throws(FactArgumentError) -> WorkoutSelector {
        let parts = try FactNumericArgument.fields(raw, counts: [1, 2, 3], format: selectorShape)
        if parts.count == 1, let uuid = UUID(uuidString: parts[0]) {
            return WorkoutSelector(target: .workoutID(uuid))
        }
        guard FactLocalDay.formatter().date(from: parts[0]) != nil else {
            throw FactArgumentError(detail: "expected yyyy-MM-dd or a workout id, got '\(parts[0].prefix(40))'")
        }
        var selector = WorkoutSelector(target: .localDay(parts[0]))
        for part in parts.dropFirst() {
            try selector.apply(part)
        }
        return selector
    }

    /// A part starting with a digit is the position that day, any other a sport.
    private mutating func apply(_ part: String) throws(FactArgumentError) {
        if part.first?.isNumber == true {
            guard position == nil else { throw FactArgumentError(detail: "expected \(Self.selectorShape), got two positions") }
            // The recency ordinal's bounds give a trap-free whole number; a
            // position counts from 1, the first workout started that day.
            let parsed = try FactNumericArgument.ordinal.integer(part)
            guard parsed >= 1 else { throw FactArgumentError(detail: "position counts from 1 (the first workout that day), got \(parsed)") }
            position = parsed
        } else {
            guard sport == nil else { throw FactArgumentError(detail: "expected \(Self.selectorShape), got two sports") }
            sport = try Self.sport(named: part)
        }
    }

    /// The sport a model-written name means: the sport's id ("trail_run"),
    /// its English name ("Trail Run") or a common word for it ("running").
    static func sport(named raw: String) throws(FactArgumentError) -> Sport {
        let name = normalized(raw)
        if let sport = Sport.allCases.first(where: { normalized($0.rawValue) == name || normalized($0.displayName) == name }) {
            return sport
        }
        if let sport = sportAliases[name] { return sport }
        let accepted = Sport.allCases.map(\.rawValue).joined(separator: ", ")
        throw FactArgumentError(detail: "unknown sport '\(raw.prefix(40))'; use one of \(accepted)")
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static let sportAliases: [String: Sport] = [
        "running": .run, "walking": .walk, "hiking": .hike, "cycling": .bike, "biking": .bike, "bicycle": .bike,
        "rowing": .row, "trail_running": .trailRun, "cross_fit": .crossFit
    ]
}

/// The workout a selector found, or the reply saying why there is none.
enum WorkoutPick {
    case picked(HRVSession)
    case notPicked(FactValue)
}

/// A period list's argument: the period, and the sport it keeps when named.
struct WorkoutPeriodFilter {
    let period: String
    let sport: Sport?

    /// `period` or `period,sport` ("last_30d,run").
    static func parsePeriodFilter(_ raw: String) throws(FactArgumentError) -> WorkoutPeriodFilter {
        let parts = try FactNumericArgument.fields(raw, counts: [1, 2], format: "'period' or 'period,sport'")
        guard PeriodParser.interval(for: parts[0]) != nil else {
            throw FactArgumentError(detail: detail(of: PeriodParser.unknownPeriod(parts[0])))
        }
        let sport = try parts.count == 2 ? WorkoutSelector.sport(named: parts[1]) : nil
        return WorkoutPeriodFilter(period: parts[0], sport: sport)
    }

    private static func detail(of reply: FactValue) -> String {
        if case let .missing(_, detail) = reply, let detail { return detail }
        return "unknown period"
    }

    func keeps(_ session: HRVSession) -> Bool {
        sport.map { session.workoutMetadata?.sport == $0 } ?? true
    }
}
