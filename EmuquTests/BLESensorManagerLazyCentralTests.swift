@preconcurrency import CoreBluetooth
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

/// The sensor managers' link lifecycle, driven through the per-device
/// callback handlers the CoreBluetooth delegate methods forward to: connect,
/// discover, subscribe, fail and switch device, with made-up device ids.
@MainActor
final class BLESensorLinkLifecycleTests: XCTestCase {
    private let deviceA = UUID()
    private let deviceB = UUID()
    private let refused = NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientAuthentication.rawValue)

    /// An empty defaults suite, so remembered devices stay out of the app's.
    private var defaults: UserDefaults {
        let suite = "BLESensorLinkLifecycleTests"
        let made = UserDefaults(suiteName: suite) ?? .standard
        made.removePersistentDomain(forName: suite)
        return made
    }

    /// Speed 3 m/s, cadence 180 spm.
    private let rscPacket = Data([0x00, 0x00, 0x03, 0xB4])

    private func strokePacket(power: UInt16) -> Data {
        Data([0x10, 0x27, 0x00, UInt8(power & 0xFF), UInt8(power >> 8), 0x2C, 0x01, 0x05, 0x00, 0, 0, 0, 0, 0, 0])
    }

    /// Speed 3 m/s, stroke rate 24 spm.
    private let additionalStatusPacket = Data([0x10, 0x27, 0x00, 0xB8, 0x0B, 24])

    // MARK: - Foot pod

    /// Connects `id` through one subscribed measurement.
    private func linkPod(_ pod: FootPodManager, _ id: UUID) {
        let rsc = FootPodManager.rscMeasurementChar_UUID
        pod.claimLink(id, name: "Pod")
        XCTAssertTrue(pod.linkConnected(id))
        XCTAssertTrue(pod.linkFoundServices(id, recognised: 1, error: nil))
        XCTAssertTrue(pod.linkFoundCharacteristics(id, measurements: [rsc], error: nil))
        pod.linkNotificationChanged(id, characteristic: rsc, isNotifying: true, error: nil)
    }

    func testAStaleDisconnectFromTheOldPodLeavesTheNewOneConnected() {
        let pod = FootPodManager(defaults: defaults)
        linkPod(pod, deviceA)
        linkPod(pod, deviceB)
        XCTAssertFalse(pod.linkDropped(deviceA))
        XCTAssertFalse(pod.linkFailedToConnect(deviceA, error: nil))
        XCTAssertEqual(pod.connectionState, .connected)
        XCTAssertEqual(pod.linkedDeviceId, deviceB.uuidString)
    }

    func testTheOldPodsMeasurementsAreIgnoredOnceTheNewOneIsLinked() {
        let pod = FootPodManager(defaults: defaults)
        linkPod(pod, deviceA)
        linkPod(pod, deviceB)
        pod.receivedMeasurement(rscPacket, characteristic: FootPodManager.rscMeasurementChar_UUID, from: deviceA)
        XCTAssertNil(pod.instantaneousSpeedMS)
        XCTAssertNil(pod.cadenceStepsPerMin)
        pod.receivedMeasurement(rscPacket, characteristic: FootPodManager.rscMeasurementChar_UUID, from: deviceB)
        XCTAssertEqual(pod.instantaneousSpeedMS, 3)
    }

    /// Connected is shown only once the pod confirms a subscription; a
    /// refused one ends the link instead of leaving it looking connected.
    func testARefusedSubscriptionEndsThePodLink() {
        let pod = FootPodManager(defaults: defaults)
        let rsc = FootPodManager.rscMeasurementChar_UUID
        pod.claimLink(deviceA, name: "Pod")
        XCTAssertTrue(pod.linkConnected(deviceA))
        XCTAssertTrue(pod.linkFoundServices(deviceA, recognised: 1, error: nil))
        XCTAssertTrue(pod.linkFoundCharacteristics(deviceA, measurements: [rsc], error: nil))
        XCTAssertEqual(pod.connectionState, .connecting)
        pod.linkNotificationChanged(deviceA, characteristic: rsc, isNotifying: false, error: refused)
        XCTAssertEqual(pod.connectionState, .disconnected)
        XCTAssertNil(pod.linkedDeviceId)
        XCTAssertTrue(pod.knownDevices.isEmpty)
    }

    func testAFailedPodDiscoveryEndsTheLink() {
        let pod = FootPodManager(defaults: defaults)
        pod.claimLink(deviceA, name: "Pod")
        XCTAssertTrue(pod.linkConnected(deviceA))
        XCTAssertFalse(pod.linkFoundServices(deviceA, recognised: 0, error: refused))
        XCTAssertEqual(pod.connectionState, .disconnected)
        XCTAssertNil(pod.linkedDeviceId)
    }

    /// A trainer whose power subscription is refused still delivers speed
    /// and cadence, so one refusal among several leaves it connected.
    func testOneRefusedSubscriptionAmongSeveralKeepsThePodLink() {
        let pod = FootPodManager(defaults: defaults)
        let rsc = FootPodManager.rscMeasurementChar_UUID
        let power = FootPodManager.cyclingPowerMeasurementChar_UUID
        pod.claimLink(deviceA, name: "Pod")
        XCTAssertTrue(pod.linkConnected(deviceA))
        XCTAssertTrue(pod.linkFoundServices(deviceA, recognised: 2, error: nil))
        XCTAssertTrue(pod.linkFoundCharacteristics(deviceA, measurements: [rsc], error: nil))
        XCTAssertTrue(pod.linkFoundCharacteristics(deviceA, measurements: [power], error: nil))
        pod.linkNotificationChanged(deviceA, characteristic: power, isNotifying: false, error: refused)
        pod.linkNotificationChanged(deviceA, characteristic: rsc, isNotifying: true, error: nil)
        XCTAssertEqual(pod.connectionState, .connected)
        XCTAssertEqual(pod.knownDevices.first?.supportsPower, false)
    }

    /// A pod that stops sending (the runner stopped, the pod slept) without
    /// dropping the link has no current speed, cadence or stride, rather
    /// than its last values recorded every second.
    func testPodSpeedCadenceAndStrideExpireAfterTheFreshnessWindow() {
        let pod = FootPodManager(defaults: defaults)
        linkPod(pod, deviceA)
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let withStride = Data([0x01, 0x00, 0x03, 0xB4, 0x78, 0x00])
        pod.receivedMeasurement(withStride, characteristic: FootPodManager.rscMeasurementChar_UUID, from: deviceA, now: sent)
        let soon = sent.addingTimeInterval(2)
        XCTAssertEqual(pod.currentSpeedMS(now: soon), 3)
        XCTAssertEqual(pod.currentCadenceStepsPerMin(now: soon), 180)
        XCTAssertEqual(pod.currentStrideLengthMeters(now: soon), 1.2)
        let quiet = sent.addingTimeInterval(30)
        XCTAssertNil(pod.currentSpeedMS(now: quiet))
        XCTAssertNil(pod.currentCadenceStepsPerMin(now: quiet))
        XCTAssertNil(pod.currentStrideLengthMeters(now: quiet))
    }

    // MARK: - Concept2

    private func linkErg(_ erg: Concept2Manager, _ id: UUID) {
        let chars = Concept2Manager.rowingDataChars
        erg.claimLink(id, name: "PM5")
        XCTAssertTrue(erg.linkConnected(id))
        XCTAssertTrue(erg.linkFoundServices(id, recognised: 1, error: nil))
        XCTAssertTrue(erg.linkFoundCharacteristics(id, measurements: chars, error: nil))
        for uuid in chars { erg.linkNotificationChanged(id, characteristic: uuid, isNotifying: true, error: nil) }
    }

    func testAStaleDisconnectFromTheOldErgLeavesTheNewOneConnected() {
        let erg = Concept2Manager(defaults: defaults)
        linkErg(erg, deviceA)
        linkErg(erg, deviceB)
        XCTAssertFalse(erg.linkDropped(deviceA))
        XCTAssertFalse(erg.linkFailedToConnect(deviceA))
        XCTAssertEqual(erg.connectionState, .connected)
        XCTAssertEqual(erg.linkedDeviceId, deviceB.uuidString)
    }

    func testTheOldErgsStrokesAreIgnoredOnceTheNewOneIsLinked() {
        let erg = Concept2Manager(defaults: defaults)
        linkErg(erg, deviceA)
        linkErg(erg, deviceB)
        erg.receivedMeasurement(strokePacket(power: 245), characteristic: Concept2Manager.strokeDataChar_UUID, from: deviceA)
        XCTAssertNil(erg.currentPowerWatts())
        erg.receivedMeasurement(strokePacket(power: 245), characteristic: Concept2Manager.strokeDataChar_UUID, from: deviceB)
        XCTAssertEqual(erg.currentPowerWatts(), 245)
    }

    func testRefusedErgSubscriptionsEndTheLink() {
        let erg = Concept2Manager(defaults: defaults)
        let chars = Concept2Manager.rowingDataChars
        erg.claimLink(deviceA, name: "PM5")
        XCTAssertTrue(erg.linkConnected(deviceA))
        XCTAssertTrue(erg.linkFoundServices(deviceA, recognised: 1, error: nil))
        XCTAssertTrue(erg.linkFoundCharacteristics(deviceA, measurements: chars, error: nil))
        XCTAssertEqual(erg.connectionState, .connecting)
        for uuid in chars { erg.linkNotificationChanged(deviceA, characteristic: uuid, isNotifying: false, error: refused) }
        XCTAssertEqual(erg.connectionState, .disconnected)
        XCTAssertNil(erg.linkedDeviceId)
        XCTAssertTrue(erg.knownDevices.isEmpty)
    }

    /// A stroke's power and rate stand through the slowest rowing stroke
    /// (one every 6 s); after the last stroke, an unpaused rest must not keep
    /// counting that stroke's watts or showing its rate.
    func testErgPowerAndStrokeRateExpireAfterTheFreshnessWindow() {
        let erg = Concept2Manager(defaults: defaults)
        linkErg(erg, deviceA)
        let stroke = Date(timeIntervalSince1970: 1_700_000_000)
        erg.receivedMeasurement(strokePacket(power: 245), characteristic: Concept2Manager.strokeDataChar_UUID, from: deviceA, now: stroke)
        erg.receivedMeasurement(additionalStatusPacket, characteristic: Concept2Manager.additionalDataChar_UUID, from: deviceA, now: stroke)
        let withinWindow = stroke.addingTimeInterval(6)
        XCTAssertEqual(erg.currentPowerWatts(now: withinWindow), 245)
        XCTAssertEqual(erg.currentStrokeRateSPM(now: withinWindow), 24)
        let afterWindow = stroke.addingTimeInterval(30)
        XCTAssertNil(erg.currentPowerWatts(now: afterWindow))
        XCTAssertNil(erg.currentStrokeRateSPM(now: afterWindow))
    }
}
