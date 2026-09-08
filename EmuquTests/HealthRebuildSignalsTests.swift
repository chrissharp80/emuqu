@testable import Emuqu
import XCTest

/// A rebuilt workout has no GPS track, so pace, effort and elevation can only
/// come from the signals Apple Health records continuously on their own. These
/// cover the conversions, which are where a rebuilt workout would quietly lie.
final class HealthRebuildSignalsTests: XCTestCase {
    private typealias Importer = HealthWorkoutImporter

    // MARK: - Elevation

    /// HealthKit defines a flight as ten feet of ascent. It is the only terrain
    /// figure the passive record carries, and reporting a hilly walk as flat is
    /// worse than reporting it coarsely.
    func testFlightClimbedIsTenFeetInMetres() {
        XCTAssertEqual(Importer.metersPerFlightClimbed, 3.048, accuracy: 0.0001)
    }

    func testTwentyFlightsIsAboutSixtyMetresOfClimb() {
        XCTAssertEqual(20 * Importer.metersPerFlightClimbed, 60.96, accuracy: 0.01)
    }

    // MARK: - Which passive distance belongs to which sport

    /// Apple Health keeps a continuous walking/running distance and a
    /// continuous cycling distance. Reading the wrong one is not a rounding
    /// error — it attaches the metres someone covered walking to the ride they
    /// did, and vice versa.
    func testFootSportsReadWalkingRunningDistance() {
        for sport in [Sport.run, .trailRun, .treadmill, .walk, .hike] {
            XCTAssertEqual(
                Importer.passiveDistanceType(for: sport), .distanceWalkingRunning,
                "\(sport) should read walking/running distance"
            )
        }
    }

    func testBikeSportsReadCyclingDistance() {
        for sport in [Sport.bike, .indoorBike] {
            XCTAssertEqual(
                Importer.passiveDistanceType(for: sport), .distanceCycling,
                "\(sport) should read cycling distance"
            )
        }
    }

    /// Health records no passive distance for these, and borrowing the walking
    /// figure would report the metres the user walked as metres they rowed.
    func testSportsWithNoPassiveDistanceReadNothing() {
        for sport in [Sport.row, .airBike, .crossFit] {
            XCTAssertNil(
                Importer.passiveDistanceType(for: sport),
                "\(sport) has no passive distance in Health"
            )
        }
    }

    // MARK: - Why a rebuild came back empty

    /// A read HealthKit never authorized returns an empty result with no
    /// error, which is indistinguishable from an empty day unless you notice
    /// that a phone in someone's pocket does not record zero steps for six
    /// hours. Telling those two apart is the difference between "your walk is
    /// gone" and "turn on Steps".
    func testNoStepSamplesAtAllReadsAsAPermissionProblem() {
        XCTAssertEqual(Importer.failure(whenBoutNotFoundWith: []), .noSamplesAtAll)
    }

    func testStepsPresentButNoBoutReadsAsNoActivity() {
        let steps = [HealthSampleWindow(start: .distantPast, end: .distantPast, value: 0)]
        XCTAssertEqual(Importer.failure(whenBoutNotFoundWith: steps), .noActivityAfterStart)
    }
}
