import CoreLocation
import Foundation

/// `workout.segment_compare`'s argument: 'lat,lon', then optionally a radius
/// in meters and a date or period bound, in that order ('lat,lon,radius_m',
/// 'lat,lon,yyyy-MM-dd', 'lat,lon,radius_m,last_year'). The bound moves the
/// search window back in time; the per-call cap on how many workouts are
/// read (`SegmentPointSampler`) holds inside it.
struct SegmentQuery {
    let targetLatitude: Double
    let targetLongitude: Double
    var radius: Double = 50
    var bound: DateInterval?
    var boundLabel: String?

    var targetLocation: CLLocation { CLLocation(latitude: targetLatitude, longitude: targetLongitude) }

    static let queryShape = "'lat,lon', 'lat,lon,radius_m', 'lat,lon,date_or_period' or 'lat,lon,radius_m,date_or_period'"

    static func parseSegmentQuery(_ raw: String) throws(FactArgumentError) -> SegmentQuery {
        let parts = try FactNumericArgument.fields(raw, counts: [2, 3, 4], format: queryShape)
        var query = try SegmentQuery(targetLatitude: FactNumericArgument.latitude.value(parts[0]), targetLongitude: FactNumericArgument.longitude.value(parts[1]))
        var rest = Array(parts.dropFirst(2))
        if let last = rest.last, let interval = boundInterval(last) {
            query.bound = interval
            query.boundLabel = last
            rest.removeLast()
        }
        guard rest.count <= 1 else {
            throw FactArgumentError(detail: "expected \(queryShape); '\(rest[1].prefix(40))' is not a date or period")
        }
        if let radius = rest.first { query.radius = try FactNumericArgument.segmentRadiusMeters.value(radius) }
        return query
    }

    /// A yyyy-MM-dd is that local day; anything else is a `PeriodParser` period.
    static func boundInterval(_ raw: String) -> DateInterval? {
        guard let day = FactLocalDay.formatter().date(from: raw) else { return PeriodParser.interval(for: raw) }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return cal.date(byAdding: .day, value: 1, to: start).map { DateInterval(start: start, end: $0) }
    }
}
