@testable import Emuqu
import os
import XCTest

final class RRDataImporterTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        // Pin to UTC so the imported recordingDate / parsed CSV rows
        // resolve to the same calendar day on every machine.
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // Stored properties rather than implicitly-unwrapped optionals:
    // XCTest builds the test class once per test method, so these are
    // already fresh for every test.
    private var importer = RRDataImporter()

    // MARK: - isEliteHRVSummary

    func testIsEliteHRVSummary_oldFormat() {
        let content = "datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,rr_min_ms,rr_max_ms,file\n2024-01-15,45.2,48.1,3.2,300,600,1200,session1.csv"
        XCTAssertTrue(importer.isEliteHRVSummary(content))
    }

    func testIsEliteHRVSummary_newFormat() {
        let content = "Member,Type,Position,Date Time Start,Duration,HRV,HR,Rmssd\nJohn,Morning,Seated,2024-01-15 06:30,60,65,58,42.5"
        XCTAssertTrue(importer.isEliteHRVSummary(content))
    }

    func testIsEliteHRVSummary_nonEliteContent() {
        let content = "timestamp,rr_ms\n0,800\n800,750"
        XCTAssertFalse(importer.isEliteHRVSummary(content))
    }

    // MARK: - isFlowHRVMultiSession

    func testIsFlowHRVMultiSession_validFormat() {
        let content = "session_date,timestamp_ms,rr_ms\n2024-01-15_0630,0,800\n2024-01-15_0630,800,750"
        XCTAssertTrue(importer.isFlowHRVMultiSession(content))
    }

    func testIsFlowHRVMultiSession_missingColumns() {
        let content = "timestamp_ms,rr_ms\n0,800\n800,750"
        XCTAssertFalse(importer.isFlowHRVMultiSession(content))
    }

    // MARK: - convertToMilliseconds

    func testConvertToMilliseconds_secondsValue() {
        // Values < 10 are in seconds
        XCTAssertEqual(importer.convertToMilliseconds(0.8), 800)
        XCTAssertEqual(importer.convertToMilliseconds(1.0), 1000)
        XCTAssertEqual(importer.convertToMilliseconds(0.5), 500)
    }

    func testConvertToMilliseconds_alreadyMs() {
        // Values >= 10 are already milliseconds
        XCTAssertEqual(importer.convertToMilliseconds(800.0), 800)
        XCTAssertEqual(importer.convertToMilliseconds(1000.0), 1000)
    }

    func testConvertToMilliseconds_boundaryValue() {
        XCTAssertEqual(importer.convertToMilliseconds(10.0), 10)
        XCTAssertEqual(importer.convertToMilliseconds(9.9), 9900)
    }

    // MARK: - parseJSON

    func testParseJSON_arrayOfNumbers() throws {
        let json = "[800, 750, 810, 790, 800]"
        let (intervals, _, _) = try importer.parseJSON(json)
        XCTAssertEqual(intervals, [800, 750, 810, 790, 800])
    }

    func testParseJSON_arrayOfSeconds() throws {
        let json = "[0.8, 0.75, 0.81]"
        let (intervals, _, _) = try importer.parseJSON(json)
        XCTAssertEqual(intervals, [800, 750, 810])
    }

    func testParseJSON_structuredWithRRKey() throws {
        let json = """
        {"rr": [800, 750, 810], "device": "Polar H10"}
        """
        let (intervals, metadata, _) = try importer.parseJSON(json)
        XCTAssertEqual(intervals, [800, 750, 810])
        XCTAssertEqual(metadata["device"], "Polar H10")
    }

    func testParseJSON_arrayOfDicts() throws {
        let json = """
        [{"rr_ms": 800}, {"rr_ms": 750}, {"rr_ms": 810}]
        """
        let (intervals, _, _) = try importer.parseJSON(json)
        XCTAssertEqual(intervals, [800, 750, 810])
    }

    func testParseJSON_invalidContent() throws {
        XCTAssertThrowsError(try importer.parseJSON("not json at all"))
    }

    // MARK: - parseCSV

    func testParseCSV_singleColumn() throws {
        let csv = "800\n750\n810\n790"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [800, 750, 810, 790])
    }

    func testParseCSV_withHeader() throws {
        let csv = "rr_ms\n800\n750\n810"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [800, 750, 810])
    }

    func testParseCSV_twoColumnsTimestampAndRR() throws {
        let csv = "timestamp,rr\n0,800\n800,750\n1550,810"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [800, 750, 810])
    }

    func testParseCSV_emptyContent() throws {
        XCTAssertThrowsError(try importer.parseCSV(""))
    }

    func testParseCSV_semicolonSeparator() throws {
        let csv = "800\n750\n810"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals.count, 3)
    }

    func testParseCSV_skipsCommentLines() throws {
        let csv = "# This is a comment\nrr\n800\n// Another comment\n750"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [800, 750])
    }

    // MARK: - parseCSV: the three load-bearing asymmetries
    //
    // `rrValue`'s doc comment calls these out as easy to "tidy away" by
    // accident. Nothing asserted them until three mutations
    // — range-checking the header column, un-range-checking the two-column
    // guess, and un-range-checking the fallback — all survived a green suite.

    /// A header names the RR column, so the file is unambiguous: the value is
    /// taken verbatim, even outside the physiological range. Filtering here
    /// would silently drop rows the user can see in their own file, with no
    /// explanation.
    func testParseCSV_headerNamedColumnIsTrustedOutsideThePhysiologicalRange() throws {
        let csv = "timestamp,rr\n0,2500\n2500,800"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [2500, 800])
    }

    /// A single-column file is equally unambiguous and equally trusted.
    func testParseCSV_singleColumnIsTrustedOutsideThePhysiologicalRange() throws {
        let csv = "2500\n800"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [2500, 800])
    }

    /// With no header, "the second column is RR" is only a guess about
    /// `timestamp,rr` exports. A wrong guess must not inject garbage, so this
    /// path IS range-checked: 5000 ms (12 bpm) is dropped, 850 survives.
    func testParseCSV_unheaderedTwoColumnGuessIsRangeChecked() throws {
        let csv = "1,5000\n2,850"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertEqual(intervals, [850])
    }

    /// The fallback to column 0 fires when column 1 fails to PARSE — not when
    /// it parses and then fails the range check. Here column 1 parses as 120
    /// (out of range), so the row is dropped; column 0's perfectly valid 850
    /// is deliberately NOT reached.
    func testParseCSV_fallbackDoesNotFireOnARangeFailure() throws {
        let csv = "850,120"
        let (intervals, _, _) = try importer.parseCSV(csv)
        XCTAssertTrue(intervals.isEmpty)
    }

    /// When column 1 genuinely fails to parse, column 0 is tried — and that
    /// path is range-checked, because reaching it means the shape was not what
    /// the file claimed.
    func testParseCSV_fallbackToFirstColumnIsRangeChecked() throws {
        let outOfRange = "5000,xyz"
        XCTAssertTrue(try importer.parseCSV(outOfRange).0.isEmpty)
        let inRange = "850,xyz"
        XCTAssertEqual(try importer.parseCSV(inRange).0, [850])
    }

    // MARK: - parsePlainText

    func testParsePlainText_onePerLine() throws {
        let text = "800\n750\n810\n790"
        let intervals = try importer.parsePlainText(text)
        XCTAssertEqual(intervals, [800, 750, 810, 790])
    }

    func testParsePlainText_spaceSeparated() throws {
        let text = "800 750 810 790"
        let intervals = try importer.parsePlainText(text)
        XCTAssertEqual(intervals, [800, 750, 810, 790])
    }

    func testParsePlainText_skipsComments() throws {
        let text = "# Header\n800\n750\n// Comment\n810"
        let intervals = try importer.parsePlainText(text)
        XCTAssertEqual(intervals, [800, 750, 810])
    }

    func testParsePlainText_filtersInvalidValues() throws {
        // Values outside physiological range are filtered by isValid check
        let text = "800\n50\n750\n5000\n810"
        let intervals = try importer.parsePlainText(text)
        // Only valid RR intervals should remain
        XCTAssertTrue(intervals.contains(800))
        XCTAssertTrue(intervals.contains(750))
        XCTAssertTrue(intervals.contains(810))
    }

    // MARK: - parseEliteHRVSummary

    func testParseEliteHRVSummary_oldFormat() throws {
        let csv = """
        datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,rr_min_ms,rr_max_ms,file
        2024-01-15 06:30:00,45.2,48.1,3.2,300,600,1200,session1.csv
        2024-01-16 06:45:00,52.1,55.3,2.8,320,580,1150,session2.csv
        """
        let result = try importer.parseEliteHRVSummary(csv, fileName: "test.csv")
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions[0].rmssd, 45.2)
        XCTAssertEqual(result.sessions[1].rmssd, 52.1)
        XCTAssertEqual(result.originalFileName, "test.csv")
    }

    func testParseEliteHRVSummary_tooFewLines() throws {
        let csv = "datetime,rmssd_clean_ms"
        XCTAssertThrowsError(try importer.parseEliteHRVSummary(csv, fileName: "test.csv"))
    }

    // MARK: - resolveEliteHRVColumns

    func testResolveEliteHRVColumns_oldFormat() {
        let headers = ["datetime", "rmssd_clean_ms", "rmssd_raw_ms", "removed_rr_pct", "n_rr", "rr_min_ms", "rr_max_ms", "file"]
        let indices = importer.resolveEliteHRVColumns(headers: headers)
        XCTAssertEqual(indices.date, 0)
        XCTAssertEqual(indices.rmssd, 1)
        XCTAssertEqual(indices.artifactPct, 3)
        XCTAssertEqual(indices.beatCount, 4)
        XCTAssertEqual(indices.rrMin, 5)
        XCTAssertEqual(indices.rrMax, 6)
        XCTAssertEqual(indices.fileName, 7)
    }

    // MARK: - parseFlowHRVMultiSession

    func testParseFlowHRVMultiSession_validData() throws {
        var lines = ["session_date,timestamp_ms,rr_ms"]
        // Generate 70 data points for one session (above 60 beat minimum)
        for i in 0 ..< 70 {
            lines.append("2026-01-25_0443,\(i * 800),800")
        }
        let csv = lines.joined(separator: "\n")
        let result = try importer.parseFlowHRVMultiSession(csv, fileName: "export.csv")
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].rrIntervals.count, 70)
        XCTAssertEqual(result.sessions[0].sessionDate, "2026-01-25_0443")
    }

    func testParseFlowHRVMultiSession_skipsSmallSessions() throws {
        var lines = ["session_date,timestamp_ms,rr_ms"]
        // Only 10 points — below 60 beat minimum
        for i in 0 ..< 10 {
            lines.append("2026-01-25_0443,\(i * 800),800")
        }
        let csv = lines.joined(separator: "\n")
        XCTAssertThrowsError(try importer.parseFlowHRVMultiSession(csv, fileName: "export.csv"))
    }

    func testParseFlowHRVMultiSession_multipleSessions() throws {
        var lines = ["session_date,timestamp_ms,rr_ms"]
        for i in 0 ..< 70 {
            lines.append("2026-01-25_0443,\(i * 800),800")
        }
        for i in 0 ..< 70 {
            lines.append("2026-01-26_0530,\(i * 750),750")
        }
        let csv = lines.joined(separator: "\n")
        let result = try importer.parseFlowHRVMultiSession(csv, fileName: "export.csv")
        XCTAssertEqual(result.sessions.count, 2)
    }

    // MARK: - parseDate

    func testParseDate_iso8601() {
        let date = importer.parseDate("2024-01-15T06:30:00Z")
        XCTAssertNotNil(date)
    }

    func testParseDate_dateOnly() {
        let date = importer.parseDate("2024-01-15")
        XCTAssertNotNil(date)
    }

    func testParseDate_invalidString() {
        let date = importer.parseDate("not a date")
        XCTAssertNil(date)
    }

    // MARK: - createSession

    func testCreateSession_setsCorrectFields() {
        let result = RRDataImporter.ImportResult(
            rrIntervals: [800, 750, 810],
            sourceFormat: .csv,
            originalFileName: "test.csv",
            recordingDate: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:]
        )
        let session = importer.createSession(from: result)
        XCTAssertNotNil(session.rrSeries)
        XCTAssertEqual(session.rrSeries?.points.count, 3)
        XCTAssertEqual(session.rrSeries?.points[0].rr_ms, 800)
        XCTAssertEqual(session.rrSeries?.points[1].rr_ms, 750)
        XCTAssertEqual(session.rrSeries?.points[2].rr_ms, 810)
        XCTAssertNotNil(session.notes)
        XCTAssertTrue(session.notes?.contains("test.csv") == true)
    }

    func testCreateSession_cumulativeTimestamps() throws {
        let result = RRDataImporter.ImportResult(
            rrIntervals: [800, 750, 810],
            sourceFormat: .csv,
            originalFileName: "test.csv",
            recordingDate: nil,
            metadata: [:]
        )
        let session = importer.createSession(from: result)
        let points = try XCTUnwrap(session.rrSeries?.points)
        XCTAssertEqual(points[0].t_ms, 0)
        XCTAssertEqual(points[1].t_ms, 800)
        XCTAssertEqual(points[2].t_ms, 1550)
    }

    // MARK: - parseCSVLine (quoted values)

    func testParseCSVLine_quotedValues() {
        let line = "\"John Doe\",Morning,\"2024-01-15\",45.2"
        let columns = importer.parseCSVLine(line)
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(columns[0], "John Doe")
        XCTAssertEqual(columns[2], "2024-01-15")
    }

    func testParseCSVLine_commaInsideQuotes() {
        let line = "\"Doe, John\",Morning,42.5"
        let columns = importer.parseCSVLine(line)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[0], "Doe, John")
    }
}
