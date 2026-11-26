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
                coordinate: CLLocationCoordinate2D(latitude: 0.78 + Double(index) * 0.001, longitude: -0.65),
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
    func testWorkoutImportedFromHealthIsMarkedAsAlreadyExported() throws {
        let session = try ImportedWorkoutBuilder.buildSession(
            from: track(), source: .appleHealth(sourceName: "Strava")
        )
        XCTAssertNotNil(session.healthKitExportedAt)
    }

    /// A GPX file is not in Apple Health, so it must still be eligible for
    /// export — stamping every import would silently stop GPX-imported
    /// workouts from ever reaching Health.
    func testWorkoutImportedFromAFileIsStillEligibleForExport() throws {
        let session = try ImportedWorkoutBuilder.buildSession(from: track(), source: .gpxFile)
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

    /// The provenance says imported, not recorded, so a reader asking "where
    /// did this session come from" gets the truth.
    func testProvenanceRecordsThatTheSessionWasImported() throws {
        let session = try ImportedWorkoutBuilder.buildSession(
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
    func testImportCarriesNoHRVAnalysis() throws {
        let heartRates = (0 ..< 60).map {
            (Date(timeIntervalSince1970: 1_700_000_000 + Double($0)), 120 + $0 % 5)
        }
        let session = try ImportedWorkoutBuilder.buildSession(
            from: track(heartRates: heartRates), source: .appleHealth(sourceName: "Apple Watch")
        )
        XCTAssertNil(session.rrSeries)
        XCTAssertNil(session.analysisResult)
        XCTAssertNil(session.recoveryScore)
    }

    // MARK: - Session shape

    func testImportedSessionIsACompleteWorkout() throws {
        let session = try ImportedWorkoutBuilder.buildSession(from: track(sport: .run), source: .gpxFile)
        XCTAssertEqual(session.sessionType, .workout)
        XCTAssertEqual(session.state, .complete)
        XCTAssertEqual(session.workoutMetadata?.sport, .run)
        XCTAssertEqual(session.endDate, session.startDate.addingTimeInterval(600))
    }

    func testSamplesCoverEverySecondOfTheWorkout() throws {
        let session = try ImportedWorkoutBuilder.buildSession(from: track(minutes: 2), source: .gpxFile)
        XCTAssertEqual(session.workoutMetadata?.samples?.count, 121)
        XCTAssertEqual(session.workoutMetadata?.samples?.first?.offsetSec, 0)
        XCTAssertEqual(session.workoutMetadata?.samples?.last?.offsetSec, 120)
    }

    func testHeartRateLandsOnTheSecondItWasRecordedFor() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try ImportedWorkoutBuilder.buildSession(
            from: track(minutes: 1, heartRates: [(start.addingTimeInterval(10), 142)], start: start),
            source: .gpxFile
        )
        XCTAssertEqual(session.workoutMetadata?.samples?[10].heartRate, 142)
    }

    /// A single bogus timestamp (an epoch-1970 point in an otherwise-2026
    /// file) would ask for billions of per-second samples. The workout is
    /// refused rather than built short inside dates that claim 400 hours.
    func testAWorkoutLongerThanTheBuildLimitIsRefused() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let absurd = ImportedWorkoutTrack(
            startDate: start,
            endDate: start.addingTimeInterval(400 * 3_600),
            track: [], heartRateSamples: [], cadenceSamples: [], sport: .walk
        )
        XCTAssertThrowsError(try ImportedWorkoutBuilder.buildSession(from: absurd, source: .gpxFile)) { error in
            XCTAssertEqual(error as? ImportedWorkoutBuilder.InvalidSpan, .tooLong)
        }
    }

    func testAWorkoutThatEndsBeforeItStartsIsRefused() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let backwards = ImportedWorkoutTrack(
            startDate: start,
            endDate: start.addingTimeInterval(-3_600),
            track: [], heartRateSamples: [], cadenceSamples: [], sport: .walk
        )
        XCTAssertThrowsError(try ImportedWorkoutBuilder.buildSession(from: backwards, source: .gpxFile)) { error in
            XCTAssertEqual(error as? ImportedWorkoutBuilder.InvalidSpan, .endsBeforeStart)
        }
    }

    /// Every built session starts at or before its end, and ends at its last
    /// sample, up to the limit itself.
    func testABuiltSessionEndsAtItsLastSample() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for seconds in [0, 1, 600, 48 * 3_600] {
            let built = ImportedWorkoutTrack(
                startDate: start, endDate: start.addingTimeInterval(TimeInterval(seconds)),
                track: [], heartRateSamples: [], cadenceSamples: [], sport: .walk
            )
            let session = try ImportedWorkoutBuilder.buildSession(from: built, source: .gpxFile)
            let end = try XCTUnwrap(session.endDate)
            XCTAssertGreaterThanOrEqual(end, session.startDate)
            XCTAssertEqual(Int(end.timeIntervalSince(session.startDate)), session.workoutMetadata?.samples?.last?.offsetSec)
            XCTAssertEqual(session.workoutMetadata?.samples?.count, seconds + 1)
        }
    }

    /// A GPX file with one epoch-1970 point spans 56 years: the import says
    /// the file is too large rather than archiving 48 hours inside it.
    func testAGPXFileSpanningDecadesIsRefusedAsTooLarge() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"><trk><trkseg>
        <trkpt lat="51.5" lon="-0.12"><time>1970-01-01T00:00:00Z</time></trkpt>
        <trkpt lat="51.501" lon="-0.12"><time>2026-01-01T08:01:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let parsed = try GPXImporter.parseWorkout(data: try XCTUnwrap(gpx.data(using: .utf8)))
        XCTAssertThrowsError(try GPXImporter.buildSession(from: parsed)) { error in
            guard case .tooLarge = error as? GPXImporter.ImportError else { return XCTFail("threw \(error)") }
        }
    }

    // MARK: - Isolation

    /// The Fitness tab reads, parses and builds an imported GPX file on a
    /// detached task. This body runs off the main actor, so it compiles only
    /// while `GPXImporter` and `ImportedWorkoutBuilder` stay nonisolated, and
    /// the values it returns are the ones the import reports.
    func testAGPXFileParsesAndBuildsOffTheMainActor() async throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"><trk><type>running</type><trkseg>
        <trkpt lat="51.5" lon="-0.12"><time>2026-01-01T08:00:00Z</time></trkpt>
        <trkpt lat="51.501" lon="-0.12"><time>2026-01-01T08:01:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let built = try await Task.detached { () throws -> (sport: Sport, samples: Int, seconds: Int) in
            let parsed = try GPXImporter.parseWorkout(data: data)
            let session = try GPXImporter.buildSession(from: parsed)
            let seconds = try ImportedWorkoutBuilder.durationSeconds(from: parsed.startDate, to: parsed.endDate)
            return (parsed.sport, session.workoutMetadata?.samples?.count ?? 0, seconds)
        }.value
        XCTAssertEqual(built.sport, .run)
        XCTAssertEqual(built.seconds, 60)
        XCTAssertEqual(built.samples, 61)
    }
}
