@testable import Emuqu
import XCTest

/// Covers the helpers in Extensions.swift.
final class ExtensionsTests: XCTestCase {
    // MARK: - DurationFormatter.hoursMinutes

    func testHoursAndMinutes() {
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 83), "1h 23m")
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 605), "10h 5m")
    }

    func testWholeHoursDropTheMinutes() {
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 60), "1h")
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 480), "8h")
    }

    func testUnderAnHourShowsMinutesOnly() {
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 45), "45m")
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: 0), "0m")
    }

    func testNegativeDurationsClampToZero() {
        XCTAssertEqual(DurationFormatter.hoursMinutes(minutes: -30), "0m")
    }
}
