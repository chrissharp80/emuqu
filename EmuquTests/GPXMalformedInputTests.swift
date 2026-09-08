import CoreLocation
@testable import Emuqu
import XCTest

/// Malformed GPX must produce a bounded error, never a process kill.
///
/// ## Why this suite exists
///
/// `Double("nan")`, `Double("inf")` and `Double("1e400")`
/// all parse successfully, so the importer's "only start a point when both
/// coordinates parse" guard admitted values it could not represent. Those
/// reached `WorkoutAnalyzer.encodePolyline`, where `Int((x * 1e5).rounded())`
/// **traps** — an immediate process kill, not an error the import sheet can
/// show the user. The file comes from a share sheet or Files, so it is
/// attacker-influenced input on a path with no validation.
///
/// A trap cannot be caught in-process, so these tests cannot assert "it did not
/// crash" by catching anything: if the fix regresses, the test runner dies and
/// the suite reports a crash rather than a failure. That is the intended
/// signal, and it is why the encoder is guarded as well as the parser — the
/// importer is one caller of a shared encoder.
@MainActor
final class GPXMalformedInputTests: XCTestCase {
    private func gpx(lat: String, lon: String, ele: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test"><trk><trkseg>
        <trkpt lat="\(lat)" lon="\(lon)"><ele>\(ele)</ele><time>2026-01-01T00:00:00Z</time></trkpt>
        <trkpt lat="51.5" lon="-0.12"><ele>10</ele><time>2026-01-01T00:00:01Z</time></trkpt>
        </trkseg></trk></gpx>
        """.utf8)
    }

    // MARK: - Values that parse but cannot be represented

    func testNonFiniteElevationIsRejectedRatherThanCarried() {
        for text in ["nan", "NaN", "inf", "-inf", "1e400", "-1e400"] {
            XCTAssertNil(Double(text).flatMap { GPXImporter.isValidElevation($0) ? $0 : nil },
                         "Elevation '\(text)' must not survive validation")
        }
    }

    func testNonFiniteCoordinatesAreRejected() {
        for text in ["nan", "inf", "-inf", "1e400"] {
            guard let value = Double(text) else {
                XCTFail("'\(text)' is expected to PARSE — that it does is the trap")
                continue
            }
            XCTAssertFalse(GPXImporter.isValidLatitude(value), "Latitude '\(text)' must be rejected")
            XCTAssertFalse(GPXImporter.isValidLongitude(value), "Longitude '\(text)' must be rejected")
        }
    }

    func testOutOfDomainCoordinatesAreRejected() {
        XCTAssertFalse(GPXImporter.isValidLatitude(91))
        XCTAssertFalse(GPXImporter.isValidLatitude(-91))
        XCTAssertFalse(GPXImporter.isValidLongitude(181))
        XCTAssertFalse(GPXImporter.isValidLongitude(-181))
        XCTAssertTrue(GPXImporter.isValidLatitude(90))
        XCTAssertTrue(GPXImporter.isValidLongitude(-180))
    }

    /// Real recordings must be unaffected — a validator that rejects valid data
    /// is a worse defect than the one it fixes.
    func testOrdinaryValuesStillPass() {
        XCTAssertTrue(GPXImporter.isValidLatitude(51.5074))
        XCTAssertTrue(GPXImporter.isValidLongitude(-0.1278))
        XCTAssertTrue(GPXImporter.isValidElevation(0))
        XCTAssertTrue(GPXImporter.isValidElevation(-420))     // Dead Sea shore
        XCTAssertTrue(GPXImporter.isValidElevation(8849))     // Everest summit
    }

    // MARK: - The encoder, which must not trap whatever reaches it

    /// The conversion that kills the process without the guard. If it regresses,
    /// this does not fail — the runner dies.
    func testPolylineEncoderSurvivesNonFiniteAltitudes() {
        for altitude in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let track = [CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
                                    altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5,
                                    timestamp: Date())]
            XCTAssertNotNil(WorkoutAnalyzer.encodePolyline(track: track),
                            "Encoder returned nil for altitude \(altitude)")
        }
    }

    func testPolylineEncoderSurvivesNonFiniteCoordinates() {
        for value in [Double.nan, .infinity, -.infinity] {
            let track = [CLLocation(coordinate: CLLocationCoordinate2D(latitude: value, longitude: value),
                                    altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                                    timestamp: Date())]
            XCTAssertNotNil(WorkoutAnalyzer.encodePolyline(track: track),
                            "Encoder returned nil for coordinate \(value)")
        }
    }

    /// Valid tracks must still encode to the same thing they always did.
    func testValidTrackStillEncodes() throws {
        let track = (0 ..< 5).map { i -> CLLocation in
            let latitude: CLLocationDegrees = 51.5 + Double(i) * 0.001
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: -0.12)
            return CLLocation(coordinate: coordinate, altitude: 10, horizontalAccuracy: 5,
                              verticalAccuracy: 5, timestamp: Date())
        }
        let encoded = try XCTUnwrap(WorkoutAnalyzer.encodePolyline(track: track))
        XCTAssertFalse(encoded.isEmpty)
    }

    // MARK: - End to end through the importer

    func testMalformedTrackpointIsDroppedAndTheFileStillImports() throws {
        for bad in ["nan", "inf", "1e400", "999"] {
            let parsed = try GPXImporter.parse(data: gpx(lat: bad, lon: "-0.12", ele: "10"))
            XCTAssertTrue(parsed.track.allSatisfy { $0.coordinate.latitude.isFinite },
                          "A non-finite latitude survived parsing of '\(bad)'")
            XCTAssertTrue(parsed.track.allSatisfy { (-90 ... 90).contains($0.coordinate.latitude) },
                          "An out-of-domain latitude survived parsing of '\(bad)'")
            // The conversion that traps without the guard.
            XCTAssertNotNil(WorkoutAnalyzer.encodePolyline(track: parsed.track))
        }
    }

    func testMalformedElevationDropsTheElevationNotThePoint() throws {
        let parsed = try GPXImporter.parse(data: gpx(lat: "51.5", lon: "-0.12", ele: "nan"))
        XCTAssertFalse(parsed.track.isEmpty, "A bad <ele> must not discard an otherwise-valid track")
        XCTAssertTrue(parsed.track.allSatisfy { $0.altitude.isFinite },
                      "A non-finite altitude reached a CLLocation")
        XCTAssertNotNil(WorkoutAnalyzer.encodePolyline(track: parsed.track))
    }
}
