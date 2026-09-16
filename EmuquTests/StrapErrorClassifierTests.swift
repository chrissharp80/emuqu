@testable import Emuqu
import PolarBleSdk
import XCTest

/// Tests for which strap errors are retried on the same link.
///
/// Retrying a real failure hides it; failing on a "not ready yet" refusal
/// abandons a recording the strap would have accepted a second later. The SDK
/// makes these refusals locally, before any radio traffic, so retrying them
/// costs nothing.
final class StrapErrorClassifierTests: XCTestCase {
    private struct Unrelated: Error {}

    func testTheSDKsLocalRefusalsAreNotReadyYet() {
        XCTAssertTrue(StrapErrorClassifier.isNotReadyYet(PolarErrors.notificationNotEnabled))
        XCTAssertTrue(StrapErrorClassifier.isNotReadyYet(BleGattException.gattDisconnected))
        XCTAssertTrue(StrapErrorClassifier.isNotReadyYet(PolarManager.PolarError.featureNotReady("h10Recording")))
    }

    /// Some SDK paths wrap the refusal in a device error's description.
    func testAWrappedRefusalIsNotReadyYet() {
        XCTAssertTrue(StrapErrorClassifier.isNotReadyYet(PolarErrors.deviceError(description: "notificationNotEnabled")))
    }

    func testRealFailuresAreNotRetried() {
        XCTAssertFalse(StrapErrorClassifier.isNotReadyYet(PolarErrors.deviceError(description: "file not found")))
        XCTAssertFalse(StrapErrorClassifier.isNotReadyYet(PolarErrors.operationNotSupported))
        XCTAssertFalse(StrapErrorClassifier.isNotReadyYet(PolarManager.PolarError.noRecordingFound))
        XCTAssertFalse(StrapErrorClassifier.isNotReadyYet(PolarManager.PolarError.pairingLost))
        XCTAssertFalse(StrapErrorClassifier.isNotReadyYet(Unrelated()))
    }
}
