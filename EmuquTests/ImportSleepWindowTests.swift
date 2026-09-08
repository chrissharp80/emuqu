@testable import Emuqu
import XCTest

/// Tests for the import path's sleep-window arithmetic.
///
/// This logic lived inside `ImportDataView+Actions.swift` and
/// had no test reaching it, because it sat in a SwiftUI view. It decides what
/// window an imported overnight recording is analysed over, from dates that
/// come out of a user-supplied file.
final class ImportSleepWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_622_534_400)

    // MARK: - The crash this extraction fixed

    func testNonFiniteBoundaryIsRejectedRatherThanTrapping() {
        // `Date.distantFuture` minus a 2021 date is finite but enormous; a
        // literal NaN date is the harder case and is what an unguarded
        // `Int64(Double)` conversion traps on.
        let nan = Date(timeIntervalSince1970: .nan)
        let result = ImportSleepWindow.offsetMs(of: nan, from: start)
        guard case let .failure(why) = result else {
            return XCTFail("a non-finite boundary must be rejected, not converted")
        }
        XCTAssertEqual(why, .notFinite)
    }

    func testAbsurdlyDistantBoundaryIsRejectedRatherThanTrapping() {
        let result = ImportSleepWindow.offsetMs(of: .distantFuture, from: start)
        guard case let .failure(why) = result else {
            return XCTFail("a boundary 2000 years out must be rejected")
        }
        XCTAssertEqual(why, .outOfRange)
    }

    func testDistantPastIsAlsoRejected() {
        guard case .failure = ImportSleepWindow.offsetMs(of: .distantPast, from: start) else {
            return XCTFail("a boundary in the distant past must be rejected")
        }
    }

    // MARK: - Ordinary conversions

    func testBoundaryAfterStartIsPositiveMilliseconds() {
        let ninetyMin = start.addingTimeInterval(90 * 60)
        guard case let .success(ms) = ImportSleepWindow.offsetMs(of: ninetyMin, from: start) else {
            return XCTFail("a 90-minute offset must convert")
        }
        XCTAssertEqual(ms, 90 * 60 * 1000)
    }

    func testBoundaryBeforeStartIsNegative() {
        // Sleep beginning before the recording started is real: the user put
        // the strap on after falling asleep. A negative offset must survive.
        let earlier = start.addingTimeInterval(-20 * 60)
        guard case let .success(ms) = ImportSleepWindow.offsetMs(of: earlier, from: start) else {
            return XCTFail("a boundary before the recording must still convert")
        }
        XCTAssertEqual(ms, -20 * 60 * 1000)
    }

    // MARK: - Window assembly

    func testBothBoundariesPresent() {
        let window = ImportSleepWindow.offsets(
            sleepStart: start.addingTimeInterval(600),
            sleepEnd: start.addingTimeInterval(8 * 3600),
            recordingStart: start
        )
        XCTAssertEqual(window.startMs, 600_000)
        XCTAssertEqual(window.wakeMs, 8 * 3600 * 1000)
    }

    func testMissingBoundariesStayNil() {
        let window = ImportSleepWindow.offsets(
            sleepStart: nil, sleepEnd: nil, recordingStart: start
        )
        XCTAssertNil(window.startMs)
        XCTAssertNil(window.wakeMs)
    }

    func testRejectedBoundaryIsReportedAndDropped() {
        var notes: [String] = []
        let window = ImportSleepWindow.offsets(
            sleepStart: .distantFuture,
            sleepEnd: start.addingTimeInterval(3_600),
            recordingStart: start,
            note: { notes.append($0) }
        )
        XCTAssertNil(window.startMs, "an unrepresentable boundary must be dropped, not clamped")
        XCTAssertEqual(window.wakeMs, 3_600_000, "the good boundary must survive")
        XCTAssertEqual(notes.count, 1, "the drop must be reported, not silent")
    }

    // MARK: - Artifact percentage

    func testArtifactPercentOfEmptySeriesIsNilNotNaN() {
        // This was `0/0` as a Double, which printed "nan%" in the import log.
        XCTAssertNil(ImportSleepWindow.artifactPercent(artifactCount: 0, totalBeats: 0))
    }

    func testArtifactPercentIsAShare() {
        XCTAssertEqual(
            ImportSleepWindow.artifactPercent(artifactCount: 25, totalBeats: 100) ?? 0,
            25.0, accuracy: 0.0001
        )
    }
}
