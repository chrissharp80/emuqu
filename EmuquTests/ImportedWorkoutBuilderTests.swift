import CoreLocation
@testable import Emuqu
import XCTest

/// `ImportedWorkoutBuilder` turns a track plus heart rates into a session the
/// archive treats like a native recording. Two things it must get right beyond
/// the arithmetic: an import must never claim HRV it does not have, and a
/// workout read out of Apple Health must never be written back into it.
@MainActor
final class ImportedWorkoutBuilderTests: XCTestCase {
    private func track(
        minutes: Int = 10,
        points: Int = 0,
        heartRates: [(Date, Int)] = [],
        cadence: [(Date, Double)] = [],
        sport: Sport = .walk,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ImportedWorkoutTrack {
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let locations = (0 ..< points).map { index in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 39.78 + Double(index) * 0.001, longitude: -89.65),
                altitude: 150,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(TimeInterval(index))
            )
        }
        return ImportedWorkoutTrack(
            startDate: start,
            endDate: end,
            track: locations,
            heartRateSamples: heartRates,
            cadenceSamples: cadence,
            sport: sport
        )
    }

    // MARK: - The duplicate-writeback guard

    /// The bug this prevents: `backfillWorkoutsToHealthKit` exports every
    /// workout session whose `healthKitExportedAt` is nil. A workout imported
    /// FROM Apple Health with that field nil would be written straight back as
    /// a second, Emuqu-authored copy of the user's own Strava run.
    func testWorkoutImportedFromHealthIsMarkedAsAlreadyExported() {
        let session = ImportedWorkoutBuilder.buildSession(
            from: track(), source: .appleHealth(sourceName: "Strava")
        )
        XCTAssertNotNil(session.healthKitExportedAt)
    }

    /// A GPX file is not in Apple Health, so it must still be eligible for
    /// export — stamping every import would silently stop GPX-imported
    /// workouts from ever reaching Health.
    func testWorkoutImportedFromAFileIsStillEligibleForExport() {
        let session = ImportedWorkoutBuilder.buildSession(from: track(), source: .gpxFile)
        XCTAssertNil(session.healthKitExportedAt)
    }

    // MARK: - Provenance

    func testAppleHealthProvenanceNamesTheAppThatWroteTheWorkout() {
        let source = ImportedWorkoutBuilder.Source.appleHealth(sourceName: "Strava")
        XCTAssertEqual(source.label, "Apple Health — Strava")
        XCTAssertTrue(source.alreadyInHealthKit)
    }

    func testAppleHealthProvenanceFallsBackWhenTheSourceIsUnnamed() {
        XCTAssertEqual(ImportedWorkoutBuilder.Source.appleHealth(sourceName: "").label, "Apple Health")
    }

    /// Recorded, not imported, is what the provenance used to claim. A reader
    /// asking "where did this session come from" gets the truth.
    func testProvenanceRecordsThatTheSessionWasImported() {
        let session = ImportedWorkoutBuilder.buildSession(
            from: track(), source: .appleHealth(sourceName: "Apple Watch")
        )
        XCTAssertEqual(session.deviceProvenance?.recordingMode, .imported)
        XCTAssertEqual(session.deviceProvenance?.deviceModel, "Apple Health — Apple Watch")
        XCTAssertEqual(session.deviceProvenance?.deviceId, "healthkit-import")
    }

    // MARK: - The honesty contract

    /// Neither GPX nor HealthKit stores beat-to-beat intervals, and nothing
    /// recovers them from an averaged heart rate. Leaving these nil is what
    /// keeps a plausible-looking HRV number computed from the wrong input out
    /// of the user's trends.
    func testImportCarriesNoHRVAnalysis() {
        let heartRates = (0 ..< 60).map {
            (Date(timeIntervalSince1970: 1_700_000_000 + Double($0)), 120 + $0 % 5)
        }
        let session = ImportedWorkoutBuilder.buildSession(
            from: track(heartRates: heartRates), source: .appleHealth(sourceName: "Apple Watch")
        )
        XCTAssertNil(session.rrSeries)
        XCTAssertNil(session.analysisResult)
        XCTAssertNil(session.recoveryScore)
    }

    // MARK: - Session shape

    func testImportedSessionIsACompleteWorkout() {
        let session = ImportedWorkoutBuilder.buildSession(from: track(sport: .run), source: .gpxFile)
        XCTAssertEqual(session.sessionType, .workout)
        XCTAssertEqual(session.state, .complete)
        XCTAssertEqual(session.workoutMetadata?.sport, .run)
        XCTAssertEqual(session.endDate, session.startDate.addingTimeInterval(600))
    }

    func testSamplesCoverEverySecondOfTheWorkout() {
        let session = ImportedWorkoutBuilder.buildSession(from: track(minutes: 2), source: .gpxFile)
        XCTAssertEqual(session.workoutMetadata?.samples?.count, 121)
        XCTAssertEqual(session.workoutMetadata?.samples?.first?.offsetSec, 0)
        XCTAssertEqual(session.workoutMetadata?.samples?.last?.offsetSec, 120)
    }

    func testHeartRateLandsOnTheSecondItWasRecordedFor() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ImportedWorkoutBuilder.buildSession(
            from: track(minutes: 1, heartRates: [(start.addingTimeInterval(10), 142)], start: start),
            source: .gpxFile
        )
        XCTAssertEqual(session.workoutMetadata?.samples?[10].heartRate, 142)
    }

    /// A single bogus timestamp — an epoch-1970 point in an otherwise-2026
    /// file — would otherwise ask for billions of per-second samples and take
    /// the app out of memory.
    func testAbsurdlyLongWorkoutsAreClampedRatherThanAllocated() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let absurd = ImportedWorkoutTrack(
            startDate: start,
            endDate: start.addingTimeInterval(400 * 3_600),
            track: [], heartRateSamples: [], cadenceSamples: [], sport: .walk
        )
        let session = ImportedWorkoutBuilder.buildSession(from: absurd, source: .gpxFile)
        XCTAssertEqual(session.workoutMetadata?.samples?.count, 48 * 3_600 + 1)
    }

    func testBackwardsTimestampsProduceASingleSampleRatherThanTrapping() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let backwards = ImportedWorkoutTrack(
            startDate: start,
            endDate: start.addingTimeInterval(-3_600),
            track: [], heartRateSamples: [], cadenceSamples: [], sport: .walk
        )
        let session = ImportedWorkoutBuilder.buildSession(from: backwards, source: .gpxFile)
        XCTAssertEqual(session.workoutMetadata?.samples?.count, 1)
    }
}
