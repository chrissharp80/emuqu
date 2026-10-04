import Foundation

/// Published MET (metabolic equivalent) tables expressed as pace bands per
/// sport, factored out of `WorkoutRecorder` so the numbers that end up in
/// Apple Health as active energy are testable on their own.
///
/// Values come from the Ainsworth Compendium of Physical Activities, except
/// rowing, which uses the Concept2-published table by 500 m split pace.
///
/// This is a pure lookup: no state, no isolation, no dependencies. It exists
/// as a namespace rather than a type so there is nothing to construct and
/// nothing to keep in sync.
enum METLookup {
    /// One row of the lookup: everything slower than `upperKmh` scores `mets`.
    /// The final row of every table uses `.infinity` as its ceiling, so a
    /// lookup can never fall off the end of a table.
    struct Band: Equatable {
        let upperKmh: Double
        let mets: Double
    }

    /// MET estimate for a sport at a given speed, or nil when the speed is
    /// outside the range the tables describe.
    ///
    /// Returns nil below 1.2 km/h: that is slower than a walking crawl, which
    /// means the caller's pace calculation was sitting on the GPS-jitter gate
    /// and the resulting METs number would be noise rather than work.
    ///
    /// `crossFit` has no pace table — it rarely carries GPS or pace at all —
    /// so it returns a moderate-vigorous constant that keeps any
    /// distance-bearing fallback physiologically sane.
    static func mets(sport: Sport, speedKmh: Double) -> Double? {
        guard speedKmh.isFinite, speedKmh >= 1.2 else { return nil }
        guard let bands = bands(for: sport) else { return crossFitConstantMETs }
        // Tables are ordered by ascending ceiling and terminate at .infinity,
        // so `first(where:)` always matches; the tail is belt-and-braces.
        return bands.first(where: { speedKmh < $0.upperKmh })?.mets ?? bands.last?.mets
    }

    /// Fallback for sports with no pace table. 8.0 METs is "vigorous effort"
    /// in the Compendium — the honest midpoint for mixed-modal training.
    static let crossFitConstantMETs = 8.0

    /// nil means the sport has no pace table.
    static func bands(for sport: Sport) -> [Band]? {
        switch sport {
        case .walk: return walk
        case .run, .trailRun, .treadmill: return run
        case .bike, .indoorBike, .airBike: return bike
        case .hike: return hike
        case .row: return row
        case .crossFit: return nil
        }
    }

    static let walk: [Band] = [
        Band(upperKmh: 3.0, mets: 2.0),  // stroll
        Band(upperKmh: 4.5, mets: 3.0),  // casual walk
        Band(upperKmh: 5.6, mets: 3.5),  // brisk
        Band(upperKmh: 6.4, mets: 4.3),  // fast walk
        Band(upperKmh: .infinity, mets: 5.0)  // very fast walk / light jog
    ]

    /// Each band scores the Compendium value at its LOWER speed, the same
    /// convention as `walk`, so a jog is never credited the value of the
    /// next whole mph up. Below 4 mph, where the Compendium lists no running
    /// row, the 4 mph value applies.
    static let run: [Band] = [
        Band(upperKmh: 8.0, mets: 6.0),   // 4 mph (6.4 km/h), ~9:20 min/km
        Band(upperKmh: 9.7, mets: 8.3),   // 5 mph
        Band(upperKmh: 11.3, mets: 9.8),  // 6 mph
        Band(upperKmh: 12.9, mets: 11.0), // 7 mph
        Band(upperKmh: 14.5, mets: 11.8), // 8 mph
        Band(upperKmh: 16.1, mets: 12.8), // 9 mph
        Band(upperKmh: 17.7, mets: 14.5), // 10 mph
        Band(upperKmh: .infinity, mets: 16.0) // 11 mph
    ]

    /// The Compendium's mph ranges in km/h: <10, 10–11.9, 12–13.9, 14–15.9,
    /// 16–19.9 and ≥20 mph.
    static let bike: [Band] = [
        Band(upperKmh: 16.1, mets: 4.0),  // leisure, <10 mph
        Band(upperKmh: 19.3, mets: 6.8),
        Band(upperKmh: 22.5, mets: 8.0),
        Band(upperKmh: 25.7, mets: 10.0),
        Band(upperKmh: 32.2, mets: 12.0),
        Band(upperKmh: .infinity, mets: 15.8)
    ]

    static let hike: [Band] = [
        Band(upperKmh: 3.5, mets: 4.0),
        Band(upperKmh: 5.0, mets: 5.3),
        Band(upperKmh: .infinity, mets: 7.0)
    ]

    /// Concept2-published table by 500 m split pace. Speed conversion:
    /// km/h = 1800 / (seconds per 500 m), so 5:00 = 6, 3:20 = 9, 2:30 = 12
    /// and about 2:09 = 14 km/h. A band's upper speed is exclusive: 2:30
    /// exactly falls in the 10.5-MET band.
    static let row: [Band] = [
        Band(upperKmh: 6, mets: 4.5),   // very light, slower than 5:00
        Band(upperKmh: 9, mets: 6.0),   // moderate, 5:00–3:20
        Band(upperKmh: 12, mets: 8.5),  // vigorous, 3:20–2:30
        Band(upperKmh: 14, mets: 10.5), // hard, 2:30–~2:09
        Band(upperKmh: .infinity, mets: 12.0)  // race pace, faster than ~2:09
    ]

    /// Every table, for invariant checks and tests.
    static let allTables: [(name: String, bands: [Band])] = [
        ("walk", walk), ("run", run), ("bike", bike), ("hike", hike), ("row", row)
    ]
}
