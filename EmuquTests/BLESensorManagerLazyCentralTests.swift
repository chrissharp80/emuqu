@testable import Emuqu
import XCTest

/// Building a `CBCentralManager` shows the iOS Bluetooth prompt. The foot-pod
/// manager is created at launch (the workout recorder holds it) and the
/// Concept2 manager at the first workout of any sport, so neither may build
/// its central until the user scans for or connects to that sensor.
@MainActor
final class BLESensorManagerLazyCentralTests: XCTestCase {
    func testFootPodManagerInitBuildsNoCentral() {
        XCTAssertNil(FootPodManager().centralIfCreated)
    }

    func testConcept2ManagerInitBuildsNoCentral() {
        XCTAssertNil(Concept2Manager().centralIfCreated)
    }

    /// Workout start and stop call these for every sport; with no sensor in
    /// use they must not build a central either.
    func testFootPodTeardownPathsBuildNoCentral() {
        let pod = FootPodManager()
        pod.holdLinkForWorkout(true)
        pod.holdLinkForWorkout(false)
        pod.stopScanning()
        pod.disconnect()
        XCTAssertNil(pod.centralIfCreated)
    }

    func testConcept2TeardownPathsBuildNoCentral() {
        let erg = Concept2Manager()
        erg.holdLinkForWorkout(false)
        erg.stopScanning()
        erg.disconnect()
        XCTAssertNil(erg.centralIfCreated)
    }
}
