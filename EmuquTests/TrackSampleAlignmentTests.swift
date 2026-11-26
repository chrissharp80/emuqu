import CoreLocation
@testable import Emuqu
import XCTest

/// Placing an old walk's GPS fixes on its per-second samples by altitude.
/// Each sample carries the latest fix's altitude, so a fix shows up in the
/// samples as the second the carried altitude changed. A fix that read the
/// same as the one before it leaves no change to find, and must be placed
/// between its neighbours instead of piled onto one second.
final class TrackSampleAlignmentTests: XCTestCase {
    /// A fix `index` steps north (about 11 m each) reading `altitude`.
    private func fix(_ index: Int, altitude: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50 + Double(index) * 0.0001, longitude: 8),
            altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    /// One sample a second for `seconds`, each carrying the altitude of the
    /// latest fix to arrive (`arrivals`: second → altitude).
    private func samples(seconds: Int, arrivals: [Int: Double]) -> [WorkoutSample] {
        var carried: Double?
        return (0 ..< seconds).map { second in
            if let reading = arrivals[second] { carried = reading }
            return WorkoutSample(offsetSec: second, distanceMeters: Double(second), altitudeMeters: carried)
        }
    }

    /// Flat ground the GPS read as level: every fix reads 100.0 m, so the
    /// samples show one change. Matching each fix to the first sample that
    /// reads 100.0 put them all on second 0; there is nothing to place them
    /// by, so the altitude placement is not used.
    func testALevelTrackIsNotPiledOntoOneSecond() {
        let track = (0 ..< 5).map { fix($0, altitude: 100.0) }
        let arrivals = Dictionary(uniqueKeysWithValues: (0 ..< 5).map { ($0 * 10, 100.0) })

        XCTAssertNil(TrackSampleAlignment.byAltitude(track, samples: samples(seconds: 50, arrivals: arrivals)))
    }

    /// Fixes that repeat the reading before them go between the fixes on
    /// either side, by the ground covered, instead of onto the first one's
    /// second.
    func testRepeatedReadingsArePlacedBetweenTheirNeighbours() throws {
        let altitudes = [100.0, 100.0, 100.0, 101.0, 102.0]
        let track = altitudes.enumerated().map { fix($0.offset, altitude: $0.element) }
        let arrivals = Dictionary(uniqueKeysWithValues: altitudes.enumerated().map { ($0.offset * 10, $0.element) })

        let offsets = try XCTUnwrap(TrackSampleAlignment.byAltitude(track, samples: samples(seconds: 50, arrivals: arrivals)))

        XCTAssertEqual(offsets, [0, 10, 20, 30, 40])
    }

    /// A reading held for longer than the gap allowed between two fixes does
    /// not lose the fixes after it: the next new reading is looked for within
    /// the gap for each fix since the last placed one.
    func testAHeldReadingDoesNotLoseTheFixesAfterIt() throws {
        let altitudes = Array(repeating: 100.0, count: 16) + [101.0, 102.5, 104.0]
        let track = altitudes.enumerated().map { fix($0.offset, altitude: $0.element) }
        let arrivals = Dictionary(uniqueKeysWithValues: altitudes.enumerated().map { ($0.offset * 10, $0.element) })

        let offsets = try XCTUnwrap(TrackSampleAlignment.byAltitude(track, samples: samples(seconds: 190, arrivals: arrivals)))

        XCTAssertEqual(offsets.last, 180, "the climb after 160 s of level readings is placed where it arrived")
        XCTAssertEqual(offsets.compactMap { $0 }, offsets.compactMap { $0 }.sorted(), "fixes stay in order")
        XCTAssertEqual(Set(offsets.compactMap { $0 }).count, track.count, "no two fixes share a second")
    }
}
