@testable import Emuqu
import HealthKit
import XCTest

/// The decisions `HealthWorkoutImporter` makes before it touches HealthKit:
/// what counts as a workout, which sport it is, whether Emuqu already has it,
/// and how a step count becomes a cadence.
final class HealthWorkoutImporterTests: XCTestCase {
    private typealias Importer = HealthWorkoutImporter

    // MARK: - Sport mapping

    func testOutdoorTypesMapToTheirSports() {
        XCTAssertEqual(Importer.sport(for: .running, isIndoor: false), .run)
        XCTAssertEqual(Importer.sport(for: .walking, isIndoor: false), .walk)
        XCTAssertEqual(Importer.sport(for: .hiking, isIndoor: false), .hike)
        XCTAssertEqual(Importer.sport(for: .cycling, isIndoor: false), .bike)
        XCTAssertEqual(Importer.sport(for: .rowing, isIndoor: false), .row)
    }

    /// GPS pace is meaningless on a treadmill, and Emuqu keeps the two as
    /// separate sports for exactly that reason — so the indoor flag has to
    /// survive the import.
    func testIndoorFlagSelectsTheIndoorSport() {
        XCTAssertEqual(Importer.sport(for: .running, isIndoor: true), .treadmill)
        XCTAssertEqual(Importer.sport(for: .cycling, isIndoor: true), .indoorBike)
    }

    /// Walking indoors is still walking; hiking indoors is not a thing. Only
    /// the two sports that actually have an indoor twin may change.
    func testIndoorFlagDoesNotDisturbSportsWithNoIndoorTwin() {
        XCTAssertEqual(Importer.sport(for: .walking, isIndoor: true), .walk)
        XCTAssertEqual(Importer.sport(for: .hiking, isIndoor: true), .hike)
        XCTAssertEqual(Importer.sport(for: .rowing, isIndoor: true), .row)
    }

    func testFunctionalTrainingTypesMapToCrossFit() {
        XCTAssertEqual(Importer.sport(for: .crossTraining, isIndoor: false), .crossFit)
        XCTAssertEqual(Importer.sport(for: .functionalStrengthTraining, isIndoor: false), .crossFit)
        XCTAssertEqual(Importer.sport(for: .highIntensityIntervalTraining, isIndoor: false), .crossFit)
    }

    /// Emuqu has no swim, no elliptical and no yoga. Importing one as a
    /// plausible neighbour would file it in the user's history under a label
    /// that is simply wrong, then hand it to pace and TRIMP maths written for
    /// a different activity. nil means "not offered", which is honest.
    func testSportsTheAppDoesNotHaveAreNotImportable() {
        for activity in [HKWorkoutActivityType.swimming, .elliptical, .yoga, .traditionalStrengthTraining, .other] {
            XCTAssertNil(Importer.sport(for: activity, isIndoor: false), "\(activity.rawValue) must not be importable")
        }
    }

    // MARK: - Duplicate detection

    func testWorkoutAlreadyInTheArchiveIsNotOffered() {
        let start = Date()
        XCTAssertTrue(Importer.isAlreadyArchived(start: start, existingStarts: [start]))
    }

    /// A Watch and a phone rarely agree on a start time to the second, and a
    /// Strava sync of an Emuqu export lands minutes after the original.
    func testNearbyStartsCountAsTheSameWorkout() {
        let start = Date()
        XCTAssertTrue(Importer.isAlreadyArchived(start: start, existingStarts: [start.addingTimeInterval(120)]))
        XCTAssertTrue(Importer.isAlreadyArchived(start: start, existingStarts: [start.addingTimeInterval(-120)]))
    }

    func testToleranceBoundaryIsInclusiveAndFiniteInBothDirections() {
        let start = Date()
        let tolerance = Importer.duplicateStartToleranceSec
        XCTAssertTrue(Importer.isAlreadyArchived(start: start, existingStarts: [start.addingTimeInterval(tolerance)]))
        XCTAssertFalse(Importer.isAlreadyArchived(start: start, existingStarts: [start.addingTimeInterval(tolerance + 1)]))
        XCTAssertFalse(Importer.isAlreadyArchived(start: start, existingStarts: [start.addingTimeInterval(-tolerance - 1)]))
    }

    /// Back-to-back sessions are distinct workouts, not duplicates — the
    /// tolerance must not swallow an afternoon run because there was a morning
    /// one.
    func testDistantWorkoutOnTheSameDayIsStillOffered() {
        let morning = Date()
        let evening = morning.addingTimeInterval(9 * 3_600)
        XCTAssertFalse(Importer.isAlreadyArchived(start: evening, existingStarts: [morning]))
    }

    func testEmptyArchiveOffersEverything() {
        XCTAssertFalse(Importer.isAlreadyArchived(start: Date(), existingStarts: []))
    }

    // MARK: - Cadence

    /// A step sample is a count over a window, not an instant, so the window
    /// is the divisor and the timestamp is its midpoint.
    func testStepCountBecomesStepsPerMinuteAtTheSampleMidpoint() {
        let start = Date()
        let samples = Importer.cadenceSamples(from: [
            HealthSampleWindow(start: start, end: start.addingTimeInterval(60), value: 170)
        ])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].1, 170, accuracy: 0.0001)
        XCTAssertEqual(samples[0].0.timeIntervalSince(start), 30, accuracy: 0.0001)
    }

    func testShorterWindowScalesUpToPerMinute() {
        let start = Date()
        let samples = Importer.cadenceSamples(from: [
            HealthSampleWindow(start: start, end: start.addingTimeInterval(30), value: 85)
        ])
        XCTAssertEqual(samples[0].1, 170, accuracy: 0.0001)
    }

    /// Dividing by a zero-length window is `inf`, and the cadence chart
    /// converts with `Int(...)`, which traps on `inf`.
    func testZeroLengthWindowIsDroppedRatherThanDividedByZero() {
        let start = Date()
        XCTAssertTrue(
            Importer.cadenceSamples(from: [HealthSampleWindow(start: start, end: start, value: 100)]).isEmpty
        )
        XCTAssertTrue(
            Importer.cadenceSamples(from: [
                HealthSampleWindow(start: start, end: start.addingTimeInterval(-10), value: 100)
            ]).isEmpty
        )
    }

    func testNegativeStepCountIsDropped() {
        let start = Date()
        XCTAssertTrue(
            Importer.cadenceSamples(from: [
                HealthSampleWindow(start: start, end: start.addingTimeInterval(60), value: -5)
            ]).isEmpty
        )
    }

    func testGoodSamplesSurviveAlongsideBadOnes() {
        let start = Date()
        let samples = Importer.cadenceSamples(from: [
            HealthSampleWindow(start: start, end: start, value: 100),
            HealthSampleWindow(start: start, end: start.addingTimeInterval(60), value: 160)
        ])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].1, 160, accuracy: 0.0001)
    }

    // MARK: - Thresholds

    func testThresholdsMatchTheAuditedValues() {
        XCTAssertEqual(Importer.minimumImportableDuration, 60)
        XCTAssertEqual(Importer.duplicateStartToleranceSec, 300)
    }
}
