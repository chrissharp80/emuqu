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

    /// Clearing a split night asks the sensor to remove it once. The first
    /// removal deletes the recording's directory, so a removal per sub-file
    /// fails on the second one (`FakeStrapRadio` throws, as the sensor does)
    /// and Discard reports an error after clearing the night.
    func testASplitRecordingIsRemovedOnce() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-8 * 3600)
        for index in 0 ..< 3 {
            radio.addOfflineRecording(path: "/U/0/20260915/R/220000/PPI\(index).REC", date: start, ppiMs: [900, 900])
        }

        let removed = try await StrapRecordingCoordinator.removeOfflinePpiRecordings(api: radio, deviceId: "VERITY-1")

        XCTAssertEqual(removed, 1)
        let removals = radio.calls.filter { if case .removeOfflineRecord = $0 { return true } else { return false } }
        XCTAssertEqual(removals.count, 1, "one removal per recording, not per sub-file")
        let remaining = try await StrapRecordingCoordinator.listPpiEntries(api: radio, deviceId: "VERITY-1")
        XCTAssertTrue(remaining.isEmpty, "every sub-file goes with the recording's directory")
    }
}
