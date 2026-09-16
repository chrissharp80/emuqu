@testable import Emuqu
import XCTest

/// Tests for listing a Verity Sense recording once, however many files it
/// spans.
///
/// The SDK's fallback listing returns one entry per sub-file. Each entry reads
/// the whole recording, so without grouping a night arrives N times over with
/// its clock restarting at zero, and the second removal fails because the first
/// deleted the directory.
final class StrapOfflineRecordingEntriesTests: XCTestCase {
    private typealias Entries = StrapOfflineRecordingEntries

    func testSubFilesShareTheirRecordingsKey() {
        XCTAssertEqual(
            Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI0.REC"),
            Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI12.REC")
        )
        XCTAssertEqual(Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI3.REC"), "/U/0/20260902/R/220000/PPI.REC")
    }

    func testDifferentRecordingsKeepDifferentKeys() {
        XCTAssertNotEqual(
            Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI0.REC"),
            Entries.recordingKey(forPath: "/U/0/20260903/R/220000/PPI0.REC")
        )
        XCTAssertNotEqual(
            Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI0.REC"),
            Entries.recordingKey(forPath: "/U/0/20260902/R/220000/ACC0.REC")
        )
    }

    /// Only the trailing sub-file index is removed; digits elsewhere in the
    /// path are the recording's date and time.
    func testOnlyTheSubFileIndexIsRemoved() {
        XCTAssertEqual(Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI.REC"), "/U/0/20260902/R/220000/PPI.REC")
        XCTAssertEqual(Entries.recordingKey(forPath: "/U/0/20260902/R/220000/PPI7.TXT"), "/U/0/20260902/R/220000/PPI7.TXT")
    }

    func testASplitRecordingIsListedOnceInListingOrder() {
        let paths = [
            "/U/0/20260902/R/220000/PPI0.REC",
            "/U/0/20260902/R/220000/PPI1.REC",
            "/U/0/20260903/R/221500/PPI0.REC",
            "/U/0/20260902/R/220000/PPI2.REC",
            "/U/0/20260903/R/221500/PPI1.REC"
        ]

        XCTAssertEqual(
            Entries.onePerRecording(paths) { $0 },
            ["/U/0/20260902/R/220000/PPI0.REC", "/U/0/20260903/R/221500/PPI0.REC"]
        )
    }

    func testAnUnsplitListingIsUnchanged() {
        let paths = ["/U/0/20260902/R/220000/PPI.REC", "/U/0/20260903/R/221500/PPI.REC"]

        XCTAssertEqual(Entries.onePerRecording(paths) { $0 }, paths)
    }
}
