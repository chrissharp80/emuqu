@testable import Emuqu
import XCTest

// MARK: - Decimal marks, text tables and date formats

extension RRDataImporterTests {
    /// A comma that is a decimal mark is read as one: in a `;` or tab file
    /// always, in a comma file only when it is one column of RR seconds.
    /// The rows after them are shapes that must still read as before.
    func testParseCSV_readsDecimalCommasAndTabs() throws {
        let cases: [(csv: String, expected: [Int])] = [
            ("RR (s);HR\n0,812;74\n0,8;75\n1,05;57", [812, 800, 1050]),
            ("RR\n0,812\n0,8\n1,05\n1,1", [812, 800, 1050, 1100]),
            ("0,812\n0,8\n1,05\n1,1", [812, 800, 1050, 1100]),
            ("time\trr\n0.0\t812\n0.812\t830", [812, 830]),
            ("time\trr\n0,0\t0,812\n0,812\t0,83", [812, 830]),
            ("timestamp,rr\n0,800\n800,750\n1550,810", [800, 750, 810]),
            ("1,5000\n2,850", [850]),
            ("rr_ms\n800\n750", [800, 750]),
            ("timestamp;rr\n0;800\n800;750", [800, 750]),
            ("note,rr_ms\n\"walk, easy\",812\n\"rest\",830", [812, 830])
        ]
        for (csv, expected) in cases {
            XCTAssertEqual(try RRDataImporter().parseCSV(csv).0, expected, csv)
        }
    }

    /// `count` rows of a time column (seconds, rising) beside `rr`, in the
    /// order `row` writes them.
    private static func textTable(count: Int, row: (String) -> String) -> String {
        (0 ..< count).map { row(String(format: "%.3f", Double($0) * 0.8)) }.joined(separator: "\n")
    }

    /// A text file that is a table reads its RR column, not its timestamps;
    /// RR values one or more to a line still read every value.
    func testParsePlainText_readsTheRRColumnOfATable() throws {
        let cases: [(text: String, expected: [Int])] = [
            ("Time\tRR\n" + Self.textTable(count: 12) { "\($0)\t0.800" }, Array(repeating: 800, count: 12)),
            (Self.textTable(count: 12) { "\($0)   812" }, Array(repeating: 812, count: 12)),
            (Self.textTable(count: 12) { "812 \($0)" }, Array(repeating: 812, count: 12)),
            ("Time (s)  RR (ms)\n" + Self.textTable(count: 12) { "\($0)  812" }, Array(repeating: 812, count: 12)),
            ("800 750 810 790", [800, 750, 810, 790]),
            ("800\n750\n810\n790", [800, 750, 810, 790]),
            ("800 750 810\n820 830 790\n850 760 800", [800, 750, 810, 820, 830, 790, 850, 760, 800])
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try RRDataImporter().parsePlainText(text), expected, text)
        }
    }

    /// A tab-separated time and RR text file imports rather than failing
    /// validation on its timestamps.
    func testATextTableImports() throws {
        let text = "Time\tRR\n" + Self.textTable(count: 70) { "\($0)\t0.800" }
        let result = try RRDataImporter().importContent(text, fileName: "rr.txt")
        XCTAssertEqual(result.rrIntervals, Array(repeating: 800, count: 70))
    }

    /// The year, month and day of a date, in UTC (the class pins it).
    private func yearMonthDay(_ date: Date) -> [Int] {
        let parts = Calendar.current.dateComponents(in: TestTimeZone.utc, from: date)
        return [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0]
    }

    /// Two-digit years, times to the minute and 12-hour times read as the
    /// dates they are; a date before 2000 is no recording. The rows after
    /// the misreads are formats that must still read as before.
    func testParseDate_readsSpreadsheetDatesAndRefusesMisreads() {
        let cases: [(text: String, order: RRDataImporter.SlashDateOrder, expected: [Int]?)] = [
            ("1/5/24 12:00", .monthFirst, [2024, 1, 5]),
            ("12/31/23 12:00", .monthFirst, [2023, 12, 31]),
            ("13/05/24 12:00", .dayFirst, [2024, 5, 13]),
            ("1/15/2024 12:30", .monthFirst, [2024, 1, 15]),
            ("01/05/2024 11:05:00 AM", .monthFirst, [2024, 1, 5]),
            ("01/05/2024 1:05 PM", .monthFirst, [2024, 1, 5]),
            ("2024-01-15 12:30", .monthFirst, [2024, 1, 15]),
            ("2024-01-15 12:30 PM", .monthFirst, [2024, 1, 15]),
            ("2024/01/15 12:00:00", .dayFirst, [2024, 1, 15]),
            ("0001-05-24", .monthFirst, nil),
            ("1999-06-01 12:00:00", .monthFirst, nil),
            ("not a date", .monthFirst, nil),
            ("05/04/2024 12:00:00", .monthFirst, [2024, 5, 4]),
            ("05/04/2024 12:00:00", .dayFirst, [2024, 4, 5]),
            ("2024-01-15T12:30:00Z", .monthFirst, [2024, 1, 15]),
            ("2024-01-15 12:30:00", .monthFirst, [2024, 1, 15])
        ]
        for (text, order, expected) in cases {
            XCTAssertEqual(RRDataImporter().parseDate(text, slashOrder: order).map { yearMonthDay($0) }, expected, text)
        }
    }

    /// An Elite HRV summary re-saved by a spreadsheet, with two-digit years
    /// and no seconds, imports every row in its own year.
    func testParseEliteHRV_aSpreadsheetResaveKeepsItsDates() throws {
        let csv = """
        Date Time Start,HR,Rmssd
        1/15/24 12:30,60,40.0
        1/16/24 12:30,61,41.0
        """
        let sessions = try RRDataImporter().parseEliteHRVSummary(csv, fileName: "e.csv").sessions
        XCTAssertEqual(sessions.map { yearMonthDay($0.date) }, [[2024, 1, 15], [2024, 1, 16]])
    }

    /// An `rr_ms` sample with a fractional millisecond is a beat, rounded;
    /// one outside the storable range is not.
    func testParseJSON_aFractionalRRMsIsRounded() throws {
        let json = #"[{"rr_ms": 812.4}, {"rr_ms": 830}, {"rr_ms": 1e30}, {"rr_ms": -5}]"#
        XCTAssertEqual(try RRDataImporter().parseJSON(json).0, [812, 830])
    }
}
