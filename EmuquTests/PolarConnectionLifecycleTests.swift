@testable import Emuqu
import XCTest

/// Tests for the strap connection lifecycle — connect, disconnect, cancel, and
/// what a BLE drop is allowed to destroy.
///
/// `PolarManager+Discovery.swift` and the disconnect path are the code that
/// decides whether a mid-night dropout costs the user the night: the H10 keeps
/// recording to its own memory through a BLE drop, so clearing the wrong piece
/// of state either throws away a recoverable night or leaves the strap
/// recording off-body until it blocks the next session.
///
/// Both of those have happened (a whole-night loss; the "strap used by
/// another session" report).
@MainActor
final class PolarConnectionLifecycleTests: XCTestCase {
    private func connectedManager(
        deviceId: String = "H10-ABC123",
        streaming: Bool,
        recordingOnDevice: Bool = true
    ) -> PolarManager {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: deviceId, type: .h10)
        manager.isStreaming = streaming
        manager.isRecordingOnDevice = recordingOnDevice
        manager.recordingState = .recording
        manager.batteryLevel = 88
        manager.firmwareVersion = "5.1.5"
        manager.hasReceivedSoftwareRevision = true
        manager.currentHeartRate = 54
        manager.isH10RecordingFeatureReady = true
        manager.isHrStreamingReady = true
        manager.isOfflineRecordingReady = true
        manager.connectionHealthWarning = true
        return manager
    }

    // MARK: - The invariant that costs a night

    /// A drop WHILE STREAMING keeps the device identity, because the reconnect
    /// logic needs it to find the strap again. Clearing it here is what turned
    /// a five-second radio glitch into a lost night.
    func testADropWhileStreamingPreservesTheDeviceIdentityForReconnect() {
        let manager = connectedManager(streaming: true)
        manager.handleDisconnect(pairingError: false)

        XCTAssertEqual(manager.connectedDeviceId, "H10-ABC123",
                       "reconnect cannot find the strap without its id")
        XCTAssertEqual(manager.connectedDeviceType, .h10)
    }

    /// A drop while NOT streaming is an ordinary disconnect: the identity goes,
    /// because nothing is waiting to reconnect to it.
    func testADropWhileIdleClearsTheDeviceIdentity() {
        let manager = connectedManager(streaming: false)
        manager.handleDisconnect(pairingError: false)

        XCTAssertNil(manager.connectedDeviceId)
        XCTAssertNil(manager.connectedDeviceType)
    }

    /// The H10 records to its own memory independently of BLE. A dropout must
    /// never mark the recording as finished — the data is still being written,
    /// and the morning pull is what retrieves it.
    func testADropNeverClearsTheDeviceRecordingState() {
        for streaming in [true, false] {
            let manager = connectedManager(streaming: streaming)
            manager.handleDisconnect(pairingError: false)

            XCTAssertTrue(manager.isRecordingOnDevice,
                          "the strap is still recording through the drop (streaming: \(streaming))")
            XCTAssertEqual(manager.recordingState, .recording,
                           "recording state is not the connection's to reset (streaming: \(streaming))")
        }
    }

    // MARK: - What a drop does clear

    /// Everything that describes the *live link* is stale the moment it drops,
    /// and showing a stale battery or heart rate is worse than showing none.
    func testADropClearsEveryLiveLinkReading() {
        for streaming in [true, false] {
            let manager = connectedManager(streaming: streaming)
            manager.handleDisconnect(pairingError: false)

            XCTAssertEqual(manager.connectionState, .disconnected)
            XCTAssertNil(manager.batteryLevel, "streaming: \(streaming)")
            XCTAssertNil(manager.firmwareVersion, "streaming: \(streaming)")
            XCTAssertNil(manager.currentHeartRate, "streaming: \(streaming)")
            XCTAssertFalse(manager.hasReceivedSoftwareRevision)
            XCTAssertFalse(manager.connectionHealthWarning)
        }
    }

    /// The feature-ready flags describe capabilities of a live connection. Left
    /// set, the next code path believes it can start a recording on a strap
    /// that is not there.
    func testADropClearsTheFeatureReadyFlags() {
        let manager = connectedManager(streaming: true)
        manager.handleDisconnect(pairingError: false)

        XCTAssertFalse(manager.isH10RecordingFeatureReady)
        XCTAssertFalse(manager.isHrStreamingReady)
        XCTAssertFalse(manager.isOfflineRecordingReady)
    }

    /// Live-HR display is a separate subscription from RR streaming; a drop has
    /// to cancel it or it leaks a task per disconnect across a night of them.
    func testADropCancelsLiveHeartRateMonitoring() {
        let manager = connectedManager(streaming: true)
        manager.hrMonitorTask = Task {}
        manager.handleDisconnect(pairingError: false)

        XCTAssertNil(manager.hrMonitorTask)
    }

    /// A pairing failure is logged differently but must not change what is
    /// cleared — the data consequences of a drop are the same either way.
    func testAPairingErrorDoesNotChangeWhatADropClears() {
        let clean = connectedManager(streaming: true)
        clean.handleDisconnect(pairingError: false)
        let paired = connectedManager(streaming: true)
        paired.handleDisconnect(pairingError: true)

        XCTAssertEqual(clean.connectedDeviceId, paired.connectedDeviceId)
        XCTAssertEqual(clean.isRecordingOnDevice, paired.isRecordingOnDevice)
        XCTAssertEqual(clean.connectionState, paired.connectionState)
    }

    // MARK: - Explicit disconnect

    /// The user pressing disconnect is not a dropout: the identity goes. But
    /// the strap may still be recording internally, and that survives.
    func testAnExplicitDisconnectClearsIdentityButNotTheDeviceRecording() {
        let manager = connectedManager(streaming: false)
        manager.disconnect()

        XCTAssertNil(manager.connectedDeviceId)
        XCTAssertNil(manager.connectedDeviceType)
        XCTAssertNil(manager.pendingDeviceId)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertTrue(manager.isRecordingOnDevice,
                      "the H10 keeps recording after the phone disconnects")
        XCTAssertEqual(manager.recordingState, .recording)
    }

    /// Disconnecting when nothing is connected is a no-op, not a state wipe —
    /// it is reachable from UI that does not track the connection itself.
    func testDisconnectingWhenNotConnectedChangesNothing() {
        let manager = PolarManager()
        manager.isRecordingOnDevice = true
        manager.recordingState = .recording
        manager.disconnect()

        XCTAssertTrue(manager.isRecordingOnDevice)
        XCTAssertEqual(manager.recordingState, .recording)
    }

    // MARK: - Cancelling a connection attempt

    /// `cancelConnection` is documented safe to call from any state. It must
    /// only act while a connection is genuinely in flight.
    func testCancellingOutsideAConnectionAttemptIsANoOp() {
        let manager = connectedManager(streaming: false)
        manager.cancelConnection()

        XCTAssertEqual(manager.connectionState, .connected,
                       "a connected device must not be torn down by a cancel")
        XCTAssertEqual(manager.connectedDeviceId, "H10-ABC123")
    }

    func testCancellingWithNoPendingDeviceIsANoOp() {
        let manager = PolarManager()
        manager.connectionState = .connecting
        manager.pendingDeviceId = nil
        manager.cancelConnection()

        XCTAssertEqual(manager.connectionState, .connecting,
                       "nothing to cancel without a pending device")
    }

    // MARK: - Reconnecting to the last device

    /// With no remembered device there is nothing to reconnect to, and the
    /// attempt must not leave the UI showing a connection in progress forever.
    func testReconnectingWithNoKnownDeviceDoesNotEnterConnecting() {
        let manager = PolarManager()
        manager.knownDevices = []
        manager.connectToLastDevice()

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertNil(manager.pendingDeviceId)
    }
}
