@testable import Emuqu
import XCTest

/// Tests for turning an H10 exercise recording into a beat series.
///
/// The strap stores a night as a flat list of intervals with no timestamps; this
/// reconstructs the timeline. It sits behind `#if canImport(PolarBleSdk)`, and
/// it is the conversion producing every beat of an overnight recording.
final class StrapExerciseDecoderTests: XCTestCase {
    // MARK: - Exercise id

    /// Fixed-width so recordings sort chronologically by name on the strap.
    func testTheExerciseIdIsAFixedWidthTimestamp() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = utc.date(from: DateComponents(
            year: 2026, month: 9, day: 2, hour: 13, minute: 4, second: 5
        )) ?? .distantPast
        let id = StrapExerciseDecoder.exerciseId(at: date)
        XCTAssertEqual(id.count, 14, "yyyyMMddHHmmss is 14 characters")
        XCTAssertTrue(id.allSatisfy(\.isNumber), "the strap files by this name: digits only")
    }

    /// `DateFormatter` follows the ambient locale unless told otherwise. On a
    /// non-Gregorian calendar the year comes out in that calendar's era, and the
    /// strap cannot round-trip an id it did not issue — so the locale is pinned.
    func testTheExerciseIdIsUnaffectedByTheAmbientLocale() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let expected = StrapExerciseDecoder.exerciseId(at: date)
        let savedLocale = NSLocale.current
        XCTAssertEqual(StrapExerciseDecoder.exerciseId(at: date), expected)
        XCTAssertTrue(expected.allSatisfy(\.isNumber), "locale \(savedLocale.identifier) leaked non-digits")
    }

    /// Later recordings must sort after earlier ones by name.
    func testExerciseIdsSortChronologically() {
        let earlier = StrapExerciseDecoder.exerciseId(at: Date(timeIntervalSince1970: 1_788_000_000))
        let later = StrapExerciseDecoder.exerciseId(at: Date(timeIntervalSince1970: 1_788_090_000))
        XCTAssertLessThan(earlier, later)
    }

    // MARK: - Beats

    func testEachBeatIsStampedAtTheAccumulatedDurationBeforeIt() {
        let points = StrapExerciseDecoder.rrPoints(fromIntervalsMs: [800, 820, 810])
        XCTAssertEqual(points.map(\.t_ms), [0, 800, 1_620])
        XCTAssertEqual(points.map(\.rr_ms), [800, 820, 810])
    }

    func testTheSeriesStartsAtZero() {
        XCTAssertEqual(StrapExerciseDecoder.rrPoints(fromIntervalsMs: [950]).first?.t_ms, 0)
    }

    func testAnEmptyRecordingYieldsNoBeats() {
        XCTAssertTrue(StrapExerciseDecoder.rrPoints(fromIntervalsMs: []).isEmpty)
    }

    func testEveryIntervalBecomesExactlyOneBeat() {
        let intervals = Array(repeating: 900, count: 500)
        XCTAssertEqual(StrapExerciseDecoder.rrPoints(fromIntervalsMs: intervals).count, 500)
    }

    /// A full night is ~30,000 beats; the accumulated timeline must not lose
    /// precision or overflow across that span.
    func testAFullNightAccumulatesExactly() {
        let intervals = Array(repeating: 1_000, count: 30_000)
        let points = StrapExerciseDecoder.rrPoints(fromIntervalsMs: intervals)
        XCTAssertEqual(points.last?.t_ms, 29_999_000, "8h20m of beats must land exactly")
    }

    func testTimestampsAreMonotonic() {
        let points = StrapExerciseDecoder.rrPoints(fromIntervalsMs: [700, 1_500, 400, 2_000, 650])
        for (earlier, later) in zip(points, points.dropFirst()) {
            XCTAssertLessThan(earlier.t_ms, later.t_ms)
        }
    }

    /// The deliberate asymmetry with the optical path: implausible intervals are
    /// NOT dropped here. The H10 is ECG-derived, so an outlier is far more
    /// likely to be a real ectopic beat than sensor noise, and the analysis
    /// pipeline's artifact detection judges it with the whole series in view.
    /// Filtering at the transport would hide it from the layer that should
    /// decide.
    func testImplausibleIntervalsSurviveForTheArtifactDetectorToJudge() {
        let points = StrapExerciseDecoder.rrPoints(fromIntervalsMs: [900, 250, 900, 3_000])
        XCTAssertEqual(points.count, 4, "the ECG path defers artifact decisions downstream")
        XCTAssertEqual(points.map(\.rr_ms), [900, 250, 900, 3_000])
    }

    /// And that is a real difference from the optical path, not an oversight —
    /// stated as a test so the two cannot quietly converge.
    func testTheOpticalPathFiltersWhereThisOneDoesNot() {
        let implausible = 250
        XCTAssertNil(
            StrapPPIFilter.acceptedInterval(
                StrapPPISample(ppInMs: implausible, ppErrorEstimate: 0, blockerBit: 0)
            ),
            "the optical path rejects it"
        )
        XCTAssertEqual(
            StrapExerciseDecoder.rrPoints(fromIntervalsMs: [implausible]).first?.rr_ms,
            implausible,
            "the ECG path keeps it"
        )
    }
}
