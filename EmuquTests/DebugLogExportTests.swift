@testable import Emuqu
import XCTest

/// The log export's read of the log file. A file that exists but cannot be
/// read must fail loudly, so the export falls back to the in-memory buffer
/// and says so, rather than exporting an empty log under a normal header.
final class DebugLogExportTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DebugLogExportTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// No file yet (nothing flushed since Persistent Logging was turned on)
    /// is an empty log, not a failure.
    func testAMissingLogFileReadsAsEmpty() throws {
        let missing = directory.appendingPathComponent("debug_log.txt")
        XCTAssertEqual(try DebugLogger.readLogFile(at: missing), "")
    }

    func testAReadableLogFileReadsAsItsText() throws {
        let file = directory.appendingPathComponent("debug_log.txt")
        try Data("line one\nline two\n".utf8).write(to: file)
        XCTAssertEqual(try DebugLogger.readLogFile(at: file), "line one\nline two\n")
    }

    /// A file that is there but is not UTF-8 text throws, so the export can
    /// tell a failed read from an empty log.
    func testAnUnreadableLogFileThrows() throws {
        let file = directory.appendingPathComponent("debug_log.txt")
        try Data([0x6C, 0x6F, 0x67, 0xFF, 0xFE, 0x0A]).write(to: file)
        XCTAssertThrowsError(try DebugLogger.readLogFile(at: file))
    }

    /// The fallback export names the failure in its header's source line.
    func testTheFallbackSourceSaysTheFileCouldNotBeRead() {
        struct ReadFailure: LocalizedError { var errorDescription: String? { "planted read failure" } }
        let source = DebugLogger.unreadableFileSource(ReadFailure())
        XCTAssertTrue(source.contains("the log file could not be read"), source)
        XCTAssertTrue(source.contains("planted read failure"), source)
    }
}
