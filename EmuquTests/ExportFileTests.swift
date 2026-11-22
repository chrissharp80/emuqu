@testable import Emuqu
import XCTest

/// Export files go in one temporary folder and an export replaces its own
/// earlier copies, so shared health data does not pile up in tmp. Each test
/// uses a prefix of its own and removes what it wrote.
final class ExportFileTests: XCTestCase {
    private func prefix() -> String {
        "export-file-test-\(UUID().uuidString)-"
    }

    func testWriteLandsInTheExportFolder() throws {
        let name = prefix() + "a.txt"
        let url = try ExportFile.write(Data("x".utf8), named: name)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, ExportFile.directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("x".utf8))
    }

    func testWriteReplacesEarlierCopiesWithTheSamePrefix() throws {
        let stem = prefix()
        let first = try ExportFile.write(Data("1".utf8), named: stem + "1.txt", replacingPrefix: stem)
        let second = try ExportFile.write(Data("2".utf8), named: stem + "2.txt", replacingPrefix: stem)
        addTeardownBlock { try FileManager.default.removeItem(at: second) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// A workout summary builds its exports when it opens but writes nothing
    /// to disk until one is shared: the in-memory export puts no file in the
    /// folder, and writing it lands its bytes under its own name there.
    func testAPendingExportIsOnDiskOnlyOnceWritten() throws {
        let start = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01T00:00:00Z
        let session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(1800),
            state: .complete, sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        let pending = try CSVExporter.pendingFile(session: session, track: [])
        let target = ExportFile.directory.appendingPathComponent(pending.name)

        XCTAssertEqual(pending.name, "workout-21000101-000000.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "building the export wrote a file")

        let url = try pending.write()
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), pending.data)
    }
}
