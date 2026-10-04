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
    /// The ambient locale cannot be switched inside a test process, so the test
    /// formats the same instant the way a Thai Buddhist-calendar locale would and
    /// shows the id still carries the Gregorian year.
    func testTheExerciseIdIsUnaffectedByANonGregorianLocale() {
        let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = Date(timeIntervalSince1970: 1_788_354_245) // 13:04:05 UTC, as the asserted ids spell out
        let buddhist = DateFormatter()
        buddhist.locale = Locale(identifier: "th_TH@calendar=buddhist")
        buddhist.calendar = Calendar(identifier: .buddhist)
        buddhist.timeZone = utc
        buddhist.dateFormat = "yyyyMMddHHmmss"

        XCTAssertEqual(buddhist.string(from: date), "25690902130405", "the Buddhist era is 543 years ahead")
        XCTAssertEqual(StrapExerciseDecoder.exerciseId(at: date, timeZone: utc), "20260902130405")
    }

    /// Later recordings must sort after earlier ones by name.
    func testExerciseIdsSortChronologically() {
        let earlier = StrapExerciseDecoder.exerciseId(at: Date(timeIntervalSince1970: 1_788_000_000))
        let later = StrapExerciseDecoder.exerciseId(at: Date(timeIntervalSince1970: 1_788_090_000))
        XCTAssertLessThan(earlier, later)
    }

    // MARK: - Recording start from the id

    private let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// The SDK's entry date for an H10 exercise is when the list was read, so
    /// the id is the only record of when a recording began. It must round-trip.
    func testTheRecordingStartRoundTripsThroughTheId() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let id = StrapExerciseDecoder.exerciseId(at: start, timeZone: utc)

        XCTAssertEqual(StrapExerciseDecoder.recordingStart(fromExerciseId: id, timeZone: utc), start)
    }

    func testTheRecordingStartIsReadInTheTimeZoneItWasWrittenIn() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? utc
        let id = StrapExerciseDecoder.exerciseId(at: start, timeZone: tokyo)

        XCTAssertEqual(StrapExerciseDecoder.recordingStart(fromExerciseId: id, timeZone: tokyo), start)
        XCTAssertNotEqual(StrapExerciseDecoder.recordingStart(fromExerciseId: id, timeZone: utc), start)
    }

    /// Only ids this app wrote carry a start time.
    func testIdsThisAppDidNotWriteHaveNoStart() {
        for id in ["", "EXERCISE", "2026090213040", "202609021304055", "2026-09-02T13", "20260902130４05", "20261302130405"] {
            XCTAssertNil(StrapExerciseDecoder.recordingStart(fromExerciseId: id, timeZone: utc), "id \(id)")
        }
    }

    // MARK: - Which recording is tonight's

    private struct Entry: Equatable {
        let id: String
    }

    private func entry(_ secondsSince1970: TimeInterval) -> Entry {
        Entry(id: StrapExerciseDecoder.exerciseId(at: Date(timeIntervalSince1970: secondsSince1970), timeZone: utc))
    }

    private func newest(_ entries: [Entry], notBefore: TimeInterval?) -> Entry? {
        StrapExerciseDecoder.newestRecording(
            entries, exerciseId: \.id,
            notBefore: notBefore.map { Date(timeIntervalSince1970: $0) }, timeZone: utc
        )
    }

    /// A strap holding last night's file and tonight's must yield tonight's,
    /// whatever order it lists them in.
    func testTheNewestRecordingIsChosenRegardlessOfListingOrder() {
        let lastNight = entry(1_788_000_000)
        let tonight = entry(1_788_086_400)

        XCTAssertEqual(newest([tonight, lastNight], notBefore: nil), tonight)
        XCTAssertEqual(newest([lastNight, tonight], notBefore: nil), tonight)
    }

    /// A file that started before the session is not the session's recording,
    /// even if it is the only one on the strap.
    func testARecordingFromBeforeTheSessionIsNeverChosen() {
        let lastNight = entry(1_788_000_000)

        XCTAssertNil(newest([lastNight], notBefore: 1_788_086_000))
    }

    /// The session's own recording starts at or after the session.
    func testARecordingStartingAtTheSessionStartIsChosen() {
        let tonight = entry(1_788_086_400)

        XCTAssertEqual(newest([tonight], notBefore: 1_788_086_400), tonight)
    }

    /// An id this app did not write has no start: it is only a fallback when
    /// nothing is required of the recording's date.
    func testAForeignIdIsOnlyAFallbackWhenNoDateIsRequired() {
        let foreign = Entry(id: "EXERCISE")

        XCTAssertEqual(newest([foreign], notBefore: nil), foreign)
        XCTAssertNil(newest([foreign], notBefore: 1_788_000_000))
        XCTAssertEqual(newest([foreign, entry(1_788_000_000)], notBefore: nil), entry(1_788_000_000))
    }

    func testTheDurationIsTheSumOfTheIntervals() {
        let points = StrapExerciseDecoder.rrPoints(fromIntervalsMs: [800, 900, 1_300])

        XCTAssertEqual(StrapExerciseDecoder.durationSeconds(of: points), 3.0, accuracy: 1e-9)
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
