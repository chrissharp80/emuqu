@testable import Emuqu
import XCTest

final class UserSettingsTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultSettings() {
        let settings = UserSettings()
        XCTAssertNil(settings.fitnessLevel, "Fitness level should default to nil")
        XCTAssertEqual(settings.temperatureUnit, .fahrenheit)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertNil(settings.trialStartDate, "Trial should not be started by default")
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        var settings = UserSettings()
        settings.fitnessLevel = .athlete
        settings.temperatureUnit = .celsius
        settings.hasCompletedOnboarding = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserSettings.self, from: data)

        XCTAssertEqual(decoded.fitnessLevel, .athlete)
        XCTAssertEqual(decoded.temperatureUnit, .celsius)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
    }

    func testLegacyDecodingMissingFields() throws {
        // Minimal JSON — all optional fields should get defaults
        let json = "{}"
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)

        XCTAssertNil(decoded.fitnessLevel, "Should default to nil when missing")
        XCTAssertEqual(decoded.temperatureUnit, .fahrenheit, "Should default to fahrenheit")
        XCTAssertNil(decoded.trialStartDate, "Should default to nil when missing")
    }

    func testTrialStartDateRoundtrip() throws {
        var settings = UserSettings()
        let now = Date()
        settings.trialStartDate = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserSettings.self, from: data)

        XCTAssertNotNil(decoded.trialStartDate)
        XCTAssertEqual(
            try XCTUnwrap(decoded.trialStartDate?.timeIntervalSince1970),
            now.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - TemperatureUnit

    func testTemperatureUnitConvert() {
        // Celsius deviation stays the same
        XCTAssertEqual(TemperatureUnit.celsius.convert(0.5), 0.5, accuracy: 0.01)

        // Fahrenheit conversion: deviation * 9/5
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(0.5), 0.9, accuracy: 0.01)
    }

    func testTemperatureUnitAbsoluteFromDeviation() {
        // Baseline is ~36.5°C for wrist
        let celsiusAbsolute = TemperatureUnit.celsius.absoluteFromDeviation(0.0)
        XCTAssertEqual(celsiusAbsolute, 36.5, accuracy: 0.1)

        let fahrenheitAbsolute = TemperatureUnit.fahrenheit.absoluteFromDeviation(0.0)
        XCTAssertEqual(fahrenheitAbsolute, 97.7, accuracy: 0.1)
    }

    func testTemperatureUnitSymbol() {
        XCTAssertEqual(TemperatureUnit.celsius.symbol, "°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.symbol, "°F")
    }

    func testTemperatureUnitAllCases() {
        XCTAssertEqual(TemperatureUnit.allCases.count, 2)
    }

    // MARK: - SleepSchedule

    func testSleepScheduleDefaults() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        // Default bedtime and wake time should be set
        XCTAssertNotNil(schedule.bedtimeHour)
        XCTAssertNotNil(schedule.wakeHour)
    }

    func testSleepScheduleIsInOvernightWindow() throws {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) // 22:00 bedtime, 06:00 wake

        // Create a date at 2 AM (should be in overnight window)
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 2
        components.minute = 0
        let nightDate = try XCTUnwrap(cal.date(from: components))

        XCTAssertTrue(
            schedule.isInOvernightWindow(nightDate),
            "2 AM should be in overnight window"
        )

        // 10:30 AM is the overnight window end (wake 06:00 + 4.5h), so 11 AM should be outside
        components.hour = 11
        components.minute = 0
        let latemorning = try XCTUnwrap(cal.date(from: components))

        XCTAssertFalse(
            schedule.isInOvernightWindow(latemorning),
            "11 AM is past the window end (wake 06:00 + 4.5h = 10:30)"
        )

        // 5 PM should be outside: overnightWindowStart anchors to current-day bedtime
        // minus 2h (20:00), which is AFTER 17:00, so 5 PM falls before the next window starts
        // and after the previous window ended at 10:30 AM.
        components.hour = 17
        let afternoon = try XCTUnwrap(cal.date(from: components))

        XCTAssertFalse(
            schedule.isInOvernightWindow(afternoon),
            "5 PM should NOT be in overnight window"
        )
    }

    // MARK: - FitnessLevel

    func testFitnessLevelAllCases() {
        XCTAssertGreaterThan(FitnessLevel.allCases.count, 0)
        for level in FitnessLevel.allCases {
            XCTAssertFalse(level.description.isEmpty)
        }
    }

    // MARK: - WindowUserAdjusted & SleepUserAdjusted Codable

    func testWindowUserAdjustedRoundtrip() throws {
        var session = makeMinimalSession()
        session.windowUserAdjusted = true
        session.sleepUserAdjusted = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertEqual(decoded.windowUserAdjusted, true, "windowUserAdjusted should survive roundtrip")
        XCTAssertEqual(decoded.sleepUserAdjusted, true, "sleepUserAdjusted should survive roundtrip")
    }

    func testWindowUserAdjustedDefaultsToNil() throws {
        let session = makeMinimalSession()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertNil(decoded.windowUserAdjusted, "windowUserAdjusted should default to nil")
        XCTAssertNil(decoded.sleepUserAdjusted, "sleepUserAdjusted should default to nil")
    }

    // MARK: - Helpers

    private func makeMinimalSession() -> HRVSession {
        HRVSession(
            startDate: Date(),
            sessionType: .overnight
        )
    }
}
