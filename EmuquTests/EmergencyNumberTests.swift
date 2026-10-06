import CoreLocation
@testable import Emuqu
import XCTest

/// The number Get Me Back's SOS button dials for each country and where the
/// user is, and what it shows. Each expected number is the one the official source cited on
/// `GetMeBackView.emergencyNumber(region:)` gives for rescue and an ambulance.
@MainActor
final class EmergencyNumberTests: XCTestCase {
    func testNorthAmericaAndPhilippinesDial911() {
        for region in ["US", "CA", "MX", "AS", "GU", "PR", "VI", "PH"] {
            XCTAssertEqual(GetMeBackView.emergencyNumber(region: region), "911", region)
        }
    }

    /// Brazil's fire brigade (193) handles missing people, rescue in hostile
    /// terrain and injuries; 112 there reaches the military police.
    func testBrazilDialsFireBrigadeRescue() {
        XCTAssertEqual(GetMeBackView.emergencyNumber(region: "BR"), "193")
        XCTAssertEqual(GetMeBackView.emergencyNumbersShown(dialling: "193"), "193 / 112")
    }

    func testRegionalNumbers() {
        let expected = [
            "GB": "999", "IE": "999", "HK": "999", "AU": "000", "NZ": "111",
            "JP": "119", "KR": "119", "TW": "119", "CN": "120"
        ]
        for (region, number) in expected {
            XCTAssertEqual(GetMeBackView.emergencyNumber(region: region), number, region)
        }
    }

    func testEverywhereElseDials112Alone() {
        for region in ["PL", "DE", "FR", "SE", "IN", "RU", "ZA"] {
            XCTAssertEqual(GetMeBackView.emergencyNumber(region: region), "112", region)
        }
        XCTAssertEqual(GetMeBackView.emergencyNumber(region: nil), "112")
        XCTAssertEqual(GetMeBackView.emergencyNumbersShown(dialling: "112"), "112")
    }

    // MARK: - Where the user is, not the Region setting

    /// A Brazilian Region on a hike in Portugal dials Portugal's 112, and a
    /// German Region in Japan dials Japan's 119: the country the user is in
    /// decides.
    func testCurrentCountryDecidesOverTheRegionSetting() {
        XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: "PT", region: "BR"), "112")
        XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: "JP", region: "DE"), "119")
        XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: "BR", region: "BR"), "193")
        XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: "US", region: "GB"), "911")
    }

    /// With no idea where the user is, a national number such as 193, 119 or
    /// 000 may be dead where they stand; only 112 and 911, which every phone
    /// routes to local emergency services, are dialled.
    func testUnknownLocationDialsANumberEveryPhoneRoutes() {
        for region in ["BR", "JP", "KR", "TW", "CN", "AU", "NZ", "GB", "IE", "HK", "DE", nil] {
            XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: nil, region: region), "112", region ?? "nil")
        }
        for region in ["US", "CA", "PH"] {
            XCTAssertEqual(GetMeBackView.emergencyNumber(currentCountry: nil, region: region), "911", region)
        }
    }

    /// The geocoded country counts only near the point it was resolved at.
    func testGeocodedCountryOnlyCountsNearWhereItWasResolved() {
        let here = CLLocationCoordinate2D(latitude: 38.72, longitude: -9.14)
        let context = RoadGeocodingService.RoadContext(
            road: nil, locality: nil, administrativeArea: nil, country: nil, countryCode: "pt",
            nearestCrossStreet: nil, observedAt: Date(), observedAtCoord: here
        )
        let near = CLLocation(latitude: 38.73, longitude: -9.14)
        let far = CLLocation(latitude: 39.72, longitude: -9.14)
        XCTAssertEqual(GetMeBackView.countryCode(of: context, at: near), "PT")
        XCTAssertNil(GetMeBackView.countryCode(of: context, at: far))
        XCTAssertNil(GetMeBackView.countryCode(of: context, at: nil))
        XCTAssertNil(GetMeBackView.countryCode(of: nil, at: near))
    }

    /// An iPad or Mac has no phone and no Emergency SOS gesture: both alerts
    /// tell the user to call from a phone, and neither mentions the side
    /// button. An iPhone keeps the side-button fallback.
    func testDeviceThatCannotCallIsToldToCallFromAPhone() {
        let phoneOnly = GetMeBackView.callFromAPhoneMessage(dialling: "193")
        let messages = [
            GetMeBackView.sosConfirmMessage(dialling: "193", canPlaceCalls: false),
            GetMeBackView.dialFailedMessage(dialling: "193", canPlaceCalls: false)
        ]
        for message in messages {
            XCTAssertEqual(message, phoneOnly)
            XCTAssertTrue(message.contains("193 / 112"))
        }
        XCTAssertNotEqual(GetMeBackView.sosConfirmMessage(dialling: "193", canPlaceCalls: true), phoneOnly)
        XCTAssertNotEqual(GetMeBackView.dialFailedMessage(dialling: "193", canPlaceCalls: true), phoneOnly)
    }
}
