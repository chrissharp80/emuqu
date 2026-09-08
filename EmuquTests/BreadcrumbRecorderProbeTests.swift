@testable import Emuqu
import XCTest

/// Probe: is `BreadcrumbRecorder.shared` constructible outside the app?
///
/// Written because `GetMeBackView` — the safety screen a lost user
/// opens — crashed when rendered by the snapshot harness. That view holds
/// `var recorder = BreadcrumbRecorder.shared`, so merely
/// constructing the view builds the singleton, which builds a
/// `CLLocationManager`. This narrows crash-in-the-view from
/// crash-in-the-location-stack.
@MainActor
final class BreadcrumbRecorderProbeTests: XCTestCase {
    func testSharedRecorderIsConstructible() {
        let recorder = BreadcrumbRecorder.shared
        XCTAssertNotNil(recorder, "the breadcrumb recorder must be constructible")
    }

    func testAuthorizationStatusIsAKnownCase() {
        let status = BreadcrumbRecorder.shared.authorizationStatus
        XCTAssertTrue([.notDetermined, .restricted, .denied, .authorizedAlways, .authorizedWhenInUse].contains(status),
                      "authorizationStatus must be one of CoreLocation's cases, got \(status.rawValue)")
    }

    func testActiveTrailIsNilBeforeAnyRecording() {
        XCTAssertNil(BreadcrumbRecorder.shared.activeTrail, "no trail is active until a recording starts")
    }
}
