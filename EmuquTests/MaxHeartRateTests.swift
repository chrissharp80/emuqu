@testable import Emuqu
import XCTest

/// Tests for age-predicted maximum heart rate.
///
/// This number anchors HR-reserve in the Banister TRIMP exponential and defines
/// every HR zone boundary, so an error here silently rescales training load and
/// every zone the user sees.
///
/// These assert on the arithmetic directly. The equivalent assertions in
/// `EffectiveSettingsTests` had to go through `Calendar.current` and a live
/// `Date()`, which made a test of pure arithmetic depend on the process-global
/// time zone — it was observed failing in a full suite run and passing alone.
final class MaxHeartRateTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return c
    }

    /// Fixed calendar dates; the components are always valid, so a failure here
    /// would be a broken test rather than a broken expectation.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    // MARK: - The formula

    /// Tanaka, not 220−age. The two agree only at 40, which is why the original
    /// test at that age let a mutation survive.
    func testTanakaDiffersFromTwoTwentyMinusAgeEitherSideOfForty() {
        XCTAssertEqual(MaxHeartRate.tanaka(age: 30), 187, "208 − 0.7×30 = 187, not 190")
        XCTAssertEqual(MaxHeartRate.tanaka(age: 40), 180, "the one age where both agree")
        XCTAssertEqual(MaxHeartRate.tanaka(age: 60), 166, "208 − 0.7×60 = 166, not 160")
        XCTAssertEqual(MaxHeartRate.tanaka(age: 70), 159, "208 − 0.7×70 = 159, not 150")
    }

    /// The reason for the change: 220−age under-estimates HRmax for older
    /// adults, which inflates HR reserve and over-weights easy activity.
    func testTanakaExceedsTwoTwentyMinusAgeForOlderAdults() {
        for age in 45 ... 85 {
            XCTAssertGreaterThan(
                MaxHeartRate.tanaka(age: age), 220 - age,
                "Tanaka must not under-estimate HRmax at \(age)"
            )
        }
    }

    func testMaxHeartRateFallsAsAgeRises() {
        let values = (20 ... 60).map { MaxHeartRate.tanaka(age: $0) }
        XCTAssertEqual(values, values.sorted(by: >), "HRmax must be non-increasing in age")
    }

    // MARK: - Clamps

    /// The floor guards the INPUT, not the output.
    ///
    /// Asserting `tanaka(age: 95) == floor` would pin
    /// a defect rather than a requirement. With a floor of 150, Tanaka reaches
    /// 150 at age 83, so every user above 83 is handed an HRmax ABOVE what the
    /// formula gives. That overstates HRmax, understates heart-rate reserve,
    /// and makes their sessions score easier than they were — the wrong
    /// direction for the group a population equation already serves worst.
    ///
    /// The floor is 130 (≈ age 111), so a real age always gets the real
    /// formula value and only impossible input is caught.
    func testRealAgesGetTheFormulaValueRatherThanTheFloor() {
        XCTAssertEqual(MaxHeartRate.tanaka(age: 85), 149, "208 − 0.7×85 = 148.5, rounds to 149")
        XCTAssertEqual(MaxHeartRate.tanaka(age: 95), 142, "208 − 0.7×95 = 141.5, rounds to 142")
        XCTAssertGreaterThan(MaxHeartRate.tanaka(age: 95), MaxHeartRate.floor,
                             "a plausible age must not be clamped")
    }

    func testImplausiblyHighAgesHitTheFloor() {
        XCTAssertEqual(MaxHeartRate.tanaka(age: 200), MaxHeartRate.floor)
    }

    /// A negative or absurd age must not produce a super-human ceiling.
    func testImplausibleAgesAreCapped() {
        XCTAssertEqual(MaxHeartRate.tanaka(age: 0), 208)
        XCTAssertEqual(MaxHeartRate.tanaka(age: -100), MaxHeartRate.ceiling)
    }

    func testEveryAgeStaysInsideTheClamp() {
        for age in -50 ... 150 {
            let hr = MaxHeartRate.tanaka(age: age)
            XCTAssertGreaterThanOrEqual(hr, MaxHeartRate.floor)
            XCTAssertLessThanOrEqual(hr, MaxHeartRate.ceiling)
        }
    }

    // MARK: - Age derivation

    func testAgeIsCompletedYears() {
        let born = date(1990, 6, 15)
        XCTAssertEqual(MaxHeartRate.age(from: born, to: date(2026, 6, 15), calendar: utc), 36)
    }

    /// The day before a birthday is still the previous age — the boundary that
    /// makes this timezone-sensitive when the calendar is ambient.
    func testTheDayBeforeABirthdayIsStillTheYoungerAge() {
        let born = date(1990, 6, 15)
        XCTAssertEqual(MaxHeartRate.age(from: born, to: date(2026, 6, 14), calendar: utc), 35)
        XCTAssertEqual(MaxHeartRate.age(from: born, to: date(2026, 6, 15), calendar: utc), 36)
    }

    /// With an explicit calendar the answer cannot move under ambient state.
    func testAgeIsStableAcrossCalendarTimeZones() throws {
        let born = date(1990, 6, 15)
        let reference = date(2026, 6, 15)
        for offset in [-12, -5, 0, 5, 14] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: offset * 3_600) ?? .gmt
            let age = try XCTUnwrap(MaxHeartRate.age(from: born, to: reference, calendar: calendar))
            XCTAssertTrue([35, 36].contains(age), "GMT\(offset) gave \(age)")
        }
    }

    // MARK: - The whole rule

    /// An explicit value the user entered always wins over the estimate.
    func testAUserEnteredValueWins() {
        XCTAssertEqual(
            MaxHeartRate.effective(userEntered: 191, birthday: date(1990, 6, 15),
                                   reference: date(2026, 6, 15), calendar: utc),
            191
        )
    }

    /// Zero and negative are not values a user meant to enter.
    func testANonPositiveUserValueFallsThroughToTheEstimate() {
        for entered in [0, -5] {
            XCTAssertEqual(
                MaxHeartRate.effective(userEntered: entered, birthday: date(1990, 6, 15),
                                       reference: date(2026, 6, 15), calendar: utc),
                183, "entered \(entered) should fall through to Tanaka at 36: 208 − 0.7×36 = 183"
            )
        }
    }

    /// No birthday and no entry: a usable number, so downstream zone math never
    /// divides by nil or zero.
    func testWithNothingToGoOnASafeDefaultIsReturned() {
        XCTAssertEqual(
            MaxHeartRate.effective(userEntered: nil, birthday: nil,
                                   reference: date(2026, 6, 15), calendar: utc),
            MaxHeartRate.defaultWithoutBirthday
        )
        XCTAssertEqual(
            MaxHeartRate.effective(userEntered: 0, birthday: nil,
                                   reference: date(2026, 6, 15), calendar: utc),
            MaxHeartRate.defaultWithoutBirthday
        )
    }

    /// Whatever the inputs, the result is always usable as a zone denominator.
    func testTheResultIsAlwaysUsable() {
        for entered in [nil, 0, -10, 150, 300] as [Int?] {
            for birthday in [nil, date(1930, 1, 1), date(2020, 1, 1)] as [Date?] {
                let hr = MaxHeartRate.effective(userEntered: entered, birthday: birthday,
                                                reference: date(2026, 6, 15), calendar: utc)
                XCTAssertGreaterThan(hr, 0, "entered=\(String(describing: entered))")
            }
        }
    }
}
