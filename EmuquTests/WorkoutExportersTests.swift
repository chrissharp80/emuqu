import CoreLocation
@testable import Emuqu
import os
import XCTest

/// Tests for the three workout track exporters — `GPXExporter`, `TCXExporter`,
/// and `CSVExporter`.
///
/// All three are pure `String`-producing functions over a session plus a
/// `[CLLocation]` track, so nothing stands in the way of testing them.
///
/// These files matter more than their size suggests: they are the app's data
/// portability story. GDPR Art. 20 gives the user a right to their data in a
/// "structured, commonly used and machine-readable format", and a malformed GPX
/// or a CSV with an unescaped comma is a silent, unrecoverable export failure —
/// the user only finds out when the receiving app rejects the file.
///
/// The assertions therefore focus on *structural validity* (parses as XML, has
/// the required elements, one row per sample) and on *escaping*, rather than on
/// exact prose.
final class WorkoutExportersTests: XCTestCase {
    /// Capture-and-restore; `NSTimeZone.default` is
    /// process-global. See `ArchivePolicyTests`.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - GPX

    func testGPXIsWellFormedXML() throws {
        let gpx = GPXExporter.export(session: makeSession(), track: makeTrack(count: 5))
        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), "GPX must parse as well-formed XML; parser error: \(String(describing: parser.parserError))")
    }

    func testGPXCarriesRequiredStructure() {
        let gpx = GPXExporter.export(session: makeSession(), track: makeTrack(count: 3))
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"), "must start with the XML declaration")
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""), "GPX 1.1 is what the schema URL promises")
        XCTAssertTrue(gpx.contains("creator=\"Emuqu\""))
        XCTAssertTrue(gpx.contains("<trkseg>") && gpx.contains("</trkseg>"))
        XCTAssertTrue(gpx.hasSuffix("</gpx>"))
    }

    func testGPXEmitsOneTrackpointPerFix() {
        for count in [0, 1, 5, 50] {
            let gpx = GPXExporter.export(session: makeSession(), track: makeTrack(count: count))
            let points = gpx.components(separatedBy: "<trkpt ").count - 1
            XCTAssertEqual(points, count, "expected \(count) <trkpt> elements")
        }
    }

    /// An empty track must still produce a valid, parseable document rather
    /// than a truncated one — the user may export a treadmill session.
    func testGPXWithEmptyTrackIsStillValid() throws {
        let gpx = GPXExporter.export(session: makeSession(), track: [])
        let data = try XCTUnwrap(gpx.data(using: .utf8))
        XCTAssertTrue(XMLParser(data: data).parse(), "empty track must still be well-formed XML")
        XCTAssertTrue(gpx.contains("<trkseg>"))
    }

    func testGPXWritesCoordinatesAtSixDecimalPlaces() {
        let fix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 35.960_123_456, longitude: -83.920_987_654),
            altitude: 250.44, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let gpx = GPXExporter.export(session: makeSession(), track: [fix])
        XCTAssertTrue(gpx.contains("lat=\"35.960123\""), "6dp is ~11cm — enough precision, bounded size")
        XCTAssertTrue(gpx.contains("lon=\"-83.920988\""), "negative longitudes must round, not truncate")
    }

    /// XML-significant characters in the sport label must be escaped or the
    /// document stops parsing.
    func testGPXEscapesXMLSignificantCharacters() throws {
        let session = makeSession(notes: "Ben & Jerry's <hill> \"repeats\"")
        let gpx = GPXExporter.export(session: session, track: makeTrack(count: 2))
        let data = try XCTUnwrap(gpx.data(using: .utf8))
        XCTAssertTrue(XMLParser(data: data).parse(), "unescaped &, < or > would break the parse")
        XCTAssertFalse(gpx.contains("Ben & Jerry"), "a bare ampersand must not survive into the output")
    }

    // MARK: - TCX

    func testTCXIsWellFormedXML() throws {
        let tcx = TCXExporter.export(session: makeSession(), track: makeTrack(count: 5))
        let data = try XCTUnwrap(tcx.data(using: .utf8))
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), "TCX must parse as well-formed XML; error: \(String(describing: parser.parserError))")
    }

    func testTCXCarriesTrainingCenterDatabaseRoot() {
        let tcx = TCXExporter.export(session: makeSession(), track: makeTrack(count: 3))
        XCTAssertTrue(tcx.contains("TrainingCenterDatabase"), "TCX's root element is what Garmin/Strava look for")
        XCTAssertTrue(tcx.contains("<Activities>"))
    }

    func testTCXWithEmptyTrackIsStillValid() throws {
        let tcx = TCXExporter.export(session: makeSession(), track: [])
        let data = try XCTUnwrap(tcx.data(using: .utf8))
        XCTAssertTrue(XMLParser(data: data).parse())
    }

    func testTCXEscapesXMLSignificantCharacters() throws {
        let tcx = TCXExporter.export(session: makeSession(notes: "a & b < c"), track: makeTrack(count: 2))
        let data = try XCTUnwrap(tcx.data(using: .utf8))
        XCTAssertTrue(XMLParser(data: data).parse())
    }

    // MARK: - CSV

    func testCSVCarriesCommentHeaderAndSportLine() {
        let csv = CSVExporter.export(session: makeSession(), track: makeTrack(count: 3))
        XCTAssertTrue(csv.hasPrefix("# Emuqu workout export"), "leading comment block identifies the producer")
        XCTAssertTrue(csv.contains("# Sport:"))
        XCTAssertTrue(csv.contains("# Units preference:"), "unit system must be recorded or the numbers are ambiguous")
    }

    /// Every non-comment line must have the same number of fields as the header,
    /// or the file is not parseable as CSV.
    func testCSVRowsAllMatchHeaderColumnCount() throws {
        let csv = CSVExporter.export(session: makeSession(), track: makeTrack(count: 6))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
        let header = try XCTUnwrap(lines.first)
        let expected = header.components(separatedBy: ",").count
        XCTAssertGreaterThan(expected, 1, "header must actually be comma-separated")
        for (i, line) in lines.dropFirst().enumerated() {
            XCTAssertEqual(
                line.components(separatedBy: ",").count, expected,
                "row \(i) has a different column count than the header — file is unparseable"
            )
        }
    }

    func testCSVIncludesRecordedPhysiologyInHeader() {
        let csv = CSVExporter.export(session: makeSession(), track: makeTrack(count: 3))
        XCTAssertTrue(csv.contains("# TRIMP:"), "TRIMP is recorded on the fixture and must be surfaced")
        XCTAssertTrue(csv.contains("# Mean HR (bpm):"))
        XCTAssertTrue(csv.contains("# RMSSD (ms):"))
    }

    func testCSVWithEmptyTrackStillProducesHeader() {
        let csv = CSVExporter.export(session: makeSession(), track: [])
        XCTAssertTrue(csv.contains("# Emuqu workout export"))
        XCTAssertFalse(csv.isEmpty)
    }

    /// A session with no metadata at all must not crash the exporters — this is
    /// the imported-session and interrupted-recording case.
    func testAllExportersTolerateSessionWithoutMetadata() throws {
        var bare = HRVSession(startDate: Date(timeIntervalSince1970: 1_700_000_000), sessionType: .workout)
        bare.endDate = Date(timeIntervalSince1970: 1_700_003_600)

        let gpx = GPXExporter.export(session: bare, track: makeTrack(count: 2))
        let tcx = TCXExporter.export(session: bare, track: makeTrack(count: 2))
        let csv = CSVExporter.export(session: bare, track: makeTrack(count: 2))

        XCTAssertTrue(XMLParser(data: try XCTUnwrap(gpx.data(using: .utf8))).parse())
        XCTAssertTrue(XMLParser(data: try XCTUnwrap(tcx.data(using: .utf8))).parse())
        XCTAssertFalse(csv.isEmpty)
    }

    // MARK: - Fixtures

    private func makeTrack(count: Int) -> [CLLocation] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0 ..< count).map { i -> CLLocation in
            // Every value annotated: the same expression written inline cost
            // 663 ms to type-check, because CLLocationDegrees/Distance/Accuracy
            // are all Double typealiases and the literals had to be solved
            // against each of them at once.
            let latitude: CLLocationDegrees = 35.9606 + Double(i) * 0.0001
            let longitude: CLLocationDegrees = -83.9207 + Double(i) * 0.0001
            let altitude: CLLocationDistance = 250 + Double(i)
            let accuracy: CLLocationAccuracy = 5
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: altitude,
                horizontalAccuracy: accuracy,
                verticalAccuracy: accuracy,
                timestamp: base.addingTimeInterval(Double(i))
            )
        }
    }

    private func makeSession(notes: String? = nil) -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = HRVSession(startDate: start, sessionType: .workout)
        session.endDate = start.addingTimeInterval(3600)
        session.notes = notes

        let timeDomain = TimeDomainMetrics(
            meanRR: 1000, sdnn: 55, rmssd: 42.5, pnn50: 20,
            sdsd: 38, meanHR: 142, sdHR: 5, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        session.analysisResult = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: start
        )

        var metadata = WorkoutMetadata(sport: notes == nil ? .run : .hike)
        metadata.distanceMeters = 10_000
        metadata.elevationGainMeters = 180
        metadata.luciaTRIMP = 137.5
        metadata.samples = (0 ..< 6).map { i in
            WorkoutSample(
                offsetSec: i * 60,
                heartRate: 140 + i,
                distanceMeters: Double(i) * 250,
                paceSecPerKm: 300,
                cadenceStepsPerMin: 172,
                altitudeMeters: 250 + Double(i),
                alpha1: 0.75,
                mets: 9.5
            )
        }
        session.workoutMetadata = metadata
        return session
    }
}
