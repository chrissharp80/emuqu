@testable import Emuqu
import XCTest

final class ExtensionsTests: XCTestCase {
    // MARK: - Optional Comparisons

    func testIsNilOrLessThan() {
        let nilVal: Int? = nil
        XCTAssertTrue(nilVal.isNilOrLessThan(5))

        let val: Int? = 3
        XCTAssertTrue(val.isNilOrLessThan(5))
        XCTAssertFalse(val.isNilOrLessThan(2))
        XCTAssertFalse(val.isNilOrLessThan(3))
    }

    func testIsNilOrGreaterThan() {
        let nilVal: Int? = nil
        XCTAssertTrue(nilVal.isNilOrGreaterThan(5))

        let val: Int? = 7
        XCTAssertTrue(val.isNilOrGreaterThan(5))
        XCTAssertFalse(val.isNilOrGreaterThan(10))
        XCTAssertFalse(val.isNilOrGreaterThan(7))
    }

    func testUpdateMin() {
        var val: Int?
        val.updateMin(5)
        XCTAssertEqual(val, 5)

        val.updateMin(3)
        XCTAssertEqual(val, 3)

        val.updateMin(10)
        XCTAssertEqual(val, 3, "Should not update when new value is larger")
    }

    func testUpdateMax() {
        var val: Int?
        val.updateMax(5)
        XCTAssertEqual(val, 5)

        val.updateMax(10)
        XCTAssertEqual(val, 10)

        val.updateMax(3)
        XCTAssertEqual(val, 10, "Should not update when new value is smaller")
    }

    // MARK: - Collection Statistics (Floating Point)

    func testAverageEmpty() {
        let empty: [Double] = []
        XCTAssertNil(empty.average)
    }

    func testAverageNonEmpty() {
        XCTAssertEqual([2.0, 4.0, 6.0].average, 4.0)
    }

    func testSum() {
        XCTAssertEqual([1.0, 2.0, 3.0].sum, 6.0)
        let empty: [Double] = []
        XCTAssertEqual(empty.sum, 0)
    }

    // MARK: - Duration Helpers

    func testMinutesAsHours() {
        XCTAssertEqual(90.minutesAsHours, 1.5)
        XCTAssertEqual(60.minutesAsHours, 1.0)
    }

    // MARK: - Safe Array Access

    func testSafeSubscript() {
        let arr = [10, 20, 30]
        XCTAssertEqual(arr[safe: 0], 10)
        XCTAssertEqual(arr[safe: 2], 30)
        XCTAssertNil(arr[safe: 3])
        XCTAssertNil(arr[safe: -1])
    }

    func testSafeSubscriptEmpty() {
        let arr: [Int] = []
        XCTAssertNil(arr[safe: 0])
    }

    // MARK: - Date Helpers

    func testAddingHours() {
        let date = Date()
        let result = date.addingHours(2)
        let diff = result.timeIntervalSince(date)
        XCTAssertEqual(diff, 7200, accuracy: 1)
    }

    func testAddingDays() {
        let date = Date()
        let result = date.addingDays(3)
        let diff = result.timeIntervalSince(date)
        XCTAssertEqual(diff, 3 * 86400, accuracy: 1)
    }

    func testAddingMinutes() {
        let date = Date()
        let result = date.addingMinutes(30)
        let diff = result.timeIntervalSince(date)
        XCTAssertEqual(diff, 1800, accuracy: 1)
    }

    func testStartOfDay() {
        let now = Date()
        let start = now.startOfDay
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: start), 0)
        XCTAssertEqual(cal.component(.minute, from: start), 0)
        XCTAssertEqual(cal.component(.second, from: start), 0)
    }

    // MARK: - ReadingTag Lookup

    func testSetContainsTagNamed() {
        let tags: Set<ReadingTag> = [.morning, .evening, .stressed]
        XCTAssertTrue(tags.contains(tagNamed: "Morning"))
        XCTAssertFalse(tags.contains(tagNamed: "Relaxed"))
    }

    func testSetTagNamed() {
        let tags: Set<ReadingTag> = [.morning, .evening]
        XCTAssertNotNil(tags.tag(named: "Morning"))
        XCTAssertNil(tags.tag(named: "Nonexistent"))
    }

    // MARK: - HRVSession Array Extensions

    func testValidSessionsFilter() {
        let sessions = [
            makeSession(state: .complete, hasAnalysis: true),
            makeSession(state: .failed, hasAnalysis: false),
            makeSession(state: .collecting, hasAnalysis: false),
            makeSession(state: .complete, hasAnalysis: false),
            makeSession(state: .complete, hasAnalysis: true)
        ]
        XCTAssertEqual(sessions.validSessions.count, 2)
    }

    // MARK: - Helpers

    private func makeSession(state: HRVSession.SessionState, hasAnalysis: Bool) -> HRVSession {
        var session = HRVSession(startDate: Date())
        session.state = state
        if hasAnalysis {
            session.analysisResult = HRVAnalysisResult(
                windowStart: 0,
                windowEnd: 100,
                timeDomain: TimeDomainMetrics(
                    meanRR: 800, sdnn: 50, rmssd: 40, pnn50: 20, sdsd: 30,
                    meanHR: 75, sdHR: 5, triangularIndex: 10
                ),
                frequencyDomain: nil,
                nonlinear: NonlinearMetrics(
                    sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5,
                    sampleEntropy: nil, approxEntropy: nil,
                    dfaAlpha1: nil, dfaAlpha2: nil, dfaAlpha1R2: nil
                ),
                ansMetrics: nil,
                artifactPercentage: 5.0,
                cleanBeatCount: 95,
                analysisDate: Date()
            )
        }
        return session
    }
}
