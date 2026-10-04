@testable import Emuqu
import XCTest

/// The MET Norway Locationforecast "compact" parser behind live workout
/// weather, run against a trimmed copy of a real response.
@MainActor
final class MetNorwayForecastTests: XCTestCase {
    /// Three steps: a full one at 12:00, one at 13:00 whose symbol comes only
    /// from `next_6_hours`, and one at 14:00 with no wind, which must be dropped.
    private let fixture = Data("""
    {
      "type": "Feature",
      "geometry": { "type": "Point", "coordinates": [10.75, 59.91, 12] },
      "properties": {
        "meta": { "updated_at": "2026-10-03T11:42:10Z" },
        "timeseries": [
          {
            "time": "2026-10-03T12:00:00Z",
            "data": {
              "instant": { "details": {
                "air_pressure_at_sea_level": 1012.4, "air_temperature": 14.2,
                "cloud_area_fraction": 62.5, "relative_humidity": 71.3,
                "wind_from_direction": 214.6, "wind_speed": 5.0
              } },
              "next_1_hours": { "summary": { "symbol_code": "lightrainshowers_day" }, "details": { "precipitation_amount": 0.3 } },
              "next_6_hours": { "summary": { "symbol_code": "cloudy" }, "details": { "precipitation_amount": 1.1 } }
            }
          },
          {
            "time": "2026-10-03T13:00:00Z",
            "data": {
              "instant": { "details": {
                "air_temperature": 15.0, "relative_humidity": 68.0,
                "wind_from_direction": 220.0, "wind_speed": 4.0
              } },
              "next_6_hours": { "summary": { "symbol_code": "partlycloudy_day" }, "details": {} }
            }
          },
          {
            "time": "2026-10-03T14:00:00Z",
            "data": {
              "instant": { "details": { "air_temperature": 15.5, "relative_humidity": 66.0 } }
            }
          }
        ]
      }
    }
    """.utf8)

    private let noon = Date(timeIntervalSince1970: 1_791_028_800) // 2026-10-03T12:00:00Z

    private func forecast() throws -> MetNorwayForecast {
        MetNorwayForecast(hours: try MetNorwayForecast.parse(fixture), lastModified: nil, expires: nil)
    }

    func testParsesCompleteStepsAndDropsOnesWithoutWind() throws {
        let hours = try MetNorwayForecast.parse(fixture)
        XCTAssertEqual(hours.count, 2, "The 14:00 step has no wind and must be skipped, not guessed")
        XCTAssertEqual(hours[0].time, noon)
        XCTAssertEqual(hours[0].temperatureC, 14.2)
        XCTAssertEqual(hours[0].humidityPercent, 71.3)
        XCTAssertEqual(hours[0].windMetresPerSecond, 5.0)
        XCTAssertEqual(hours[0].windFromDegrees, 214.6)
    }

    func testSymbolPrefersTheNextHourAndFallsBackToTheNextSixHours() throws {
        let hours = try MetNorwayForecast.parse(fixture)
        XCTAssertEqual(hours[0].symbolCode, "lightrainshowers_day")
        XCTAssertEqual(hours[1].symbolCode, "partlycloudy_day")
    }

    func testSnapshotUsesTheNearestStep() throws {
        let snapshot = try XCTUnwrap(try forecast().snapshot(at: noon.addingTimeInterval(50 * 60)))
        XCTAssertEqual(snapshot.temperatureC, 15.0, "12:50 is nearer the 13:00 step")
        XCTAssertEqual(snapshot.conditions, "Partly cloudy")
    }

    func testSnapshotConvertsWindAndLeavesApparentTemperatureEmpty() throws {
        let snapshot = try XCTUnwrap(try forecast().snapshot(at: noon))
        XCTAssertEqual(snapshot.windKMH, 18.0, accuracy: 1e-9, "5 m/s is 18 km/h")
        XCTAssertEqual(snapshot.windDirectionDegrees, 214.6)
        XCTAssertEqual(snapshot.humidityPercent, 71.3)
        XCTAssertEqual(snapshot.conditions, "Rain showers")
        XCTAssertNil(snapshot.apparentTemperatureC, "MET Norway gives no feels-like temperature")
    }

    func testSnapshotIsNilForAForecastHeldTooLong() throws {
        XCTAssertNil(try forecast().snapshot(at: noon.addingTimeInterval(5 * 3600)))
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try MetNorwayForecast.parse(Data("{\"properties\":{}}".utf8)))
    }

    // MARK: - Conditions

    func testSymbolCodesMapToTheAppsConditionNames() {
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "clearsky_night"), "Clear")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "fair_polartwilight"), "Mainly clear")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "cloudy"), "Overcast")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "heavyrain"), "Heavy rain")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "lightsleet"), "Sleet")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "snowshowers_day"), "Snow showers")
    }

    func testEveryThunderCodeIsAThunderstorm() {
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "rainandthunder"), "Thunderstorm")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "lightssnowshowersandthunder_day"), "Thunderstorm")
    }

    func testUnknownOrMissingSymbolIsUnknown() {
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: nil), "Unknown")
        XCTAssertEqual(MetNorwayForecast.conditions(forSymbol: "volcanicash"), "Unknown")
    }

    func testEveryConditionNameIsTranslated() {
        for symbol in ["clearsky", "fair", "partlycloudy", "cloudy", "fog", "rain", "sleetshowers", "snow", "rainandthunder"] {
            let english = MetNorwayForecast.conditions(forSymbol: symbol)
            XCTAssertNotEqual(english, "Unknown", symbol)
            XCTAssertFalse(WeatherService.localizedConditions(english).isEmpty, symbol)
        }
    }

    // MARK: - Terms of service

    func testExpiresHeaderParses() throws {
        let expires = try XCTUnwrap(MetNorwayForecast.httpDate("Sat, 03 Oct 2026 12:31:07 GMT"))
        XCTAssertEqual(expires, noon.addingTimeInterval(31 * 60 + 7))
    }

    func testUserAgentNamesTheAppAndAContact() {
        XCTAssertTrue(WeatherService.userAgent.hasPrefix("Emuqu/"))
        XCTAssertTrue(WeatherService.userAgent.contains("github.com/chrissharp80/emuqu"))
    }

    func testRequestsAreAtLeastTenMinutesApart() {
        XCTAssertGreaterThanOrEqual(WeatherService.minimumRequestInterval, 10 * 60)
    }
}
