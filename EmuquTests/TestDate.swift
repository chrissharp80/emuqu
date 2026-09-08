@testable import Emuqu
import Foundation
import XCTest

/// Fixture dates and identifiers that fail loudly instead of trapping.
///
/// Test fixtures reached for `Calendar.date(from:)!` and friends. Those
/// unwraps are safe for well-formed components — but "safe" carries a lot of
/// weight inside a test target. A force-unwrap traps, a trap takes down the
/// whole test *process*, and the run then reports nothing at all rather than
/// one red case with a message pointing at the broken fixture.
///
/// Each helper below reports the failure at the call site and returns a
/// harmless stand-in, so one bad fixture costs you one test instead of the
/// suite.
enum TestDate {
    static func from(
        _ components: DateComponents,
        calendar: Calendar = .current,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Date {
        guard let date = calendar.date(from: components) else {
            XCTFail("could not build a fixture date from \(components)", file: file, line: line)
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    static func adding(
        _ component: Calendar.Component,
        _ value: Int,
        to date: Date,
        calendar: Calendar = .current,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Date {
        guard let result = calendar.date(byAdding: component, value: value, to: date) else {
            XCTFail("could not add \(value) \(component) to \(date)", file: file, line: line)
            return date
        }
        return result
    }

    static func settingTime(
        hour: Int,
        minute: Int = 0,
        second: Int = 0,
        of date: Date,
        calendar: Calendar = .current,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Date {
        guard let result = calendar.date(
            bySettingHour: hour, minute: minute, second: second, of: date
        ) else {
            XCTFail("could not set \(hour):\(minute):\(second) on \(date)", file: file, line: line)
            return date
        }
        return result
    }
}

enum TestUUID {
    /// A UUID from a hand-written literal. Constant by construction, so this
    /// never fires — but a typo in the literal should redden one test, not
    /// abort the run.
    static func fixed(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UUID {
        guard let id = UUID(uuidString: string) else {
            XCTFail("not a valid UUID string: \(string)", file: file, line: line)
            return UUID()
        }
        return id
    }
}

/// Stand-ins for analysis values a fixture could not compute.
///
/// Used where a fixture helper cannot throw and the alternative was a
/// force-unwrap: the test still fails on the assertion that mattered, rather
/// than trapping before it gets there.
enum TestFixtureDefaults {
    static let timeDomain = TimeDomainMetrics(
        meanRR: 0, sdnn: 0, rmssd: 0, pnn50: 0,
        sdsd: 0, meanHR: 0, sdHR: 0, triangularIndex: 0
    )
}
