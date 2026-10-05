@testable import Emuqu
import XCTest

/// The number Get Me Back's SOS button dials for each region, and what it
/// shows. Each expected number is the one the official source cited on
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
        XCTAssertEqual(GetMeBackView.emergencyNumbersShown(region: "BR"), "193 / 112")
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
            XCTAssertEqual(GetMeBackView.emergencyNumbersShown(region: region), "112", region)
        }
        XCTAssertEqual(GetMeBackView.emergencyNumber(region: nil), "112")
    }

    /// An iPad or Mac has no phone and no Emergency SOS gesture: both alerts
    /// tell the user to call from a phone, and neither mentions the side
    /// button. An iPhone keeps the side-button fallback.
    func testDeviceThatCannotCallIsToldToCallFromAPhone() {
        for message in [GetMeBackView.sosConfirmMessage(canPlaceCalls: false), GetMeBackView.dialFailedMessage(canPlaceCalls: false)] {
            XCTAssertEqual(message, GetMeBackView.callFromAPhoneMessage)
            XCTAssertTrue(message.contains(GetMeBackView.emergencyNumbersShown()))
        }
        XCTAssertNotEqual(GetMeBackView.sosConfirmMessage(canPlaceCalls: true), GetMeBackView.callFromAPhoneMessage)
        XCTAssertNotEqual(GetMeBackView.dialFailedMessage(canPlaceCalls: true), GetMeBackView.callFromAPhoneMessage)
    }
}
