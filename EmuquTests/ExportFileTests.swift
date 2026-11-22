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
}
