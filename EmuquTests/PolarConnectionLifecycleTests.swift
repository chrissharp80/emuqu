@testable import Emuqu
import XCTest

/// Tests for the strap connection lifecycle — connect, disconnect, cancel, and
/// what a BLE drop is allowed to destroy.
///
/// The drop handling decides whether a mid-night dropout costs the user the
/// night: the H10 keeps recording to its own memory through a BLE drop, so
/// clearing the wrong piece of state either throws away a recoverable night or
/// leaves the strap recording off-body until it blocks the next session.
///
/// Every event here goes through `StrapLinkCoordinator.apply`, the same path
/// the SDK's callbacks take.
@MainActor
final class PolarConnectionLifecycleTests: XCTestCase {
    /// A manager with a live link, built without the pairing store so tests do
    /// not write to the shared App Group defaults.
    private func linkedManager(
        deviceId: String = "H10-ABC123",
        streaming: Bool,
        recordingOnDevice: Bool = true
    ) -> PolarManager {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: deviceId, type: .h10)
        manager.readiness.linkEstablished()
        manager.readiness.markReady(.heartRate)
        manager.readiness.markReady(.h10Recording)
        manager.feedStatus = .live
        if streaming { manager.prepareStreamingStateForTesting() }
        manager.isRecordingOnDevice = recordingOnDevice
        manager.recordingState = .recording
        manager.batteryLevel = 88
        manager.firmwareVersion = "5.1.5"
        manager.hasReceivedSoftwareRevision = true
        manager.currentHeartRate = 54
        return manager
    }

    private func drop(_ manager: PolarManager, deviceId: String = "H10-ABC123", loss: StrapLinkLoss = .connectionLost) {
        manager.link.apply(.disconnected(deviceId: deviceId, loss: loss))
    }

    // MARK: - The invariant that costs a night

    /// A drop WHILE STREAMING keeps the device identity: the session's
    /// provenance and the reconnect both need it.
    func testADropWhileStreamingPreservesTheDeviceIdentityForReconnect() {
        let manager = linkedManager(streaming: true)
        drop(manager)

        XCTAssertEqual(manager.connectedDeviceId, "H10-ABC123", "reconnect cannot find the strap without its id")
        XCTAssertEqual(manager.connectedDeviceType, .h10)
        XCTAssertTrue(manager.isStreaming, "a drop does not end the session; it keeps buffering when the strap returns")
    }

    /// A drop while NOT streaming is an ordinary disconnect: the identity goes.
    func testADropWhileIdleClearsTheDeviceIdentity() {
        let manager = linkedManager(streaming: false)
        drop(manager)

        XCTAssertNil(manager.connectedDeviceId)
        XCTAssertNil(manager.connectedDeviceType)
    }

    /// The H10 records to its own memory independently of BLE. A dropout must
    /// never mark the recording as finished.
    func testADropNeverClearsTheDeviceRecordingState() {
        for streaming in [true, false] {
            let manager = linkedManager(streaming: streaming)
            drop(manager)

            XCTAssertTrue(manager.isRecordingOnDevice, "the strap is still recording through the drop (streaming: \(streaming))")
            XCTAssertEqual(manager.recordingState, .recording, "recording state is not the connection's to reset (streaming: \(streaming))")
        }
    }

    // MARK: - What a drop does clear

    /// Everything that describes the *live link* is stale the moment it drops.
    func testADropClearsEveryLiveLinkReading() {
        for streaming in [true, false] {
            let manager = linkedManager(streaming: streaming)
            drop(manager)

            XCTAssertEqual(manager.connectionState, .disconnected)
            XCTAssertNil(manager.batteryLevel, "streaming: \(streaming)")
            XCTAssertNil(manager.firmwareVersion, "streaming: \(streaming)")
            XCTAssertNil(manager.currentHeartRate, "streaming: \(streaming)")
            XCTAssertFalse(manager.hasReceivedSoftwareRevision)
            XCTAssertEqual(manager.feedStatus, .waitingForStrap)
            XCTAssertFalse(manager.connectionHealthWarning)
        }
    }

    /// Readiness describes one link. Left set, the next code path believes it
    /// can record on a strap that is not there.
    func testADropClearsFeatureReadiness() {
        let manager = linkedManager(streaming: true)
        drop(manager)

        XCTAssertFalse(manager.isH10RecordingFeatureReady)
        XCTAssertFalse(manager.isHrStreamingReady)
        XCTAssertFalse(manager.readiness.isLinked)
    }

    /// The feed and its health watch belong to the link; a drop must end them
    /// or they leak a task per disconnect across a night of them.
    func testADropCancelsTheLinksTasks() {
        let manager = linkedManager(streaming: true)
        manager.linkRuntime.feedTask = Task {}
        manager.linkRuntime.healthTask = Task {}
        drop(manager)

        XCTAssertNil(manager.linkRuntime.feedTask)
        XCTAssertNil(manager.linkRuntime.healthTask)
    }

    /// A drop for a strap that is not the linked one changes nothing — a late
    /// callback from a previous connection must not tear down the current one.
    func testADropForAnotherDeviceIsIgnored() {
        let manager = linkedManager(streaming: true)
        drop(manager, deviceId: "SOME-OTHER-STRAP")

        XCTAssertTrue(manager.readiness.isLinked)
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertEqual(manager.batteryLevel, 88)
    }

    /// A second drop callback for a link already torn down is a no-op, so a
    /// Bluetooth power-off followed by the peripheral's own drop is handled once.
    func testASecondDropForTheSameLinkIsANoOp() {
        let manager = linkedManager(streaming: true)
        drop(manager)
        manager.batteryLevel = 77
        drop(manager)

        XCTAssertEqual(manager.batteryLevel, 77)
    }

    // MARK: - Lost pairing

    /// A pairing the SDK reports unusable is not retried. A session waiting on
    /// that strap is told now, not after the reconnect window.
    func testALostPairingEndsTheSessionsWaitAndSurfacesAnError() {
        let manager = linkedManager(streaming: true)
        drop(manager, loss: .pairingLost(reason: "pairingInformationRemoved"))

        XCTAssertTrue(manager.reconnectExhausted)
        guard case PolarManager.PolarError.pairingLost? = manager.lastError else {
            return XCTFail("expected pairingLost, got \(String(describing: manager.lastError))")
        }
        XCTAssertNil(manager.linkRuntime.reconnectTargetId, "nothing may keep reconnecting to a broken pairing")
    }

    /// An ordinary drop during a session is chased and given the window.
    func testAnOrdinaryDropDuringASessionIsChased() {
        let manager = linkedManager(streaming: true)
        drop(manager)

        XCTAssertEqual(manager.linkRuntime.reconnectTargetId, "H10-ABC123")
        XCTAssertNotNil(manager.linkRuntime.reconnectDeadlineTask)
        XCTAssertFalse(manager.reconnectExhausted, "the window has only just started")
    }

    /// Ending the session ends the wait.
    func testEndingTheSessionCancelsTheReconnectWindow() {
        let manager = linkedManager(streaming: true)
        drop(manager)
        _ = manager.stopStreaming()

        XCTAssertNil(manager.linkRuntime.reconnectDeadlineTask)
    }

    // MARK: - Reconnection

    /// The link returning during a session is counted, so the overnight backup
    /// flushes, and the wait ends.
    func testTheLinkReturningDuringASessionIsCounted() {
        let manager = linkedManager(streaming: true)
        drop(manager)
        manager.linkRuntime.reconnectDeadlineTask?.cancel()
        manager.linkRuntime.reconnectDeadlineTask = Task {}
        let generation = manager.readiness.generation

        let defaults = SharedUserDefaults.appGroup
        let savedDevices = defaults.object(forKey: UserDefaultsKeys.knownDevices)
        let savedConnectedTime = defaults.object(forKey: UserDefaultsKeys.lastConnectedTime)
        defer {
            defaults.set(savedDevices, forKey: UserDefaultsKeys.knownDevices)
            defaults.set(savedConnectedTime, forKey: UserDefaultsKeys.lastConnectedTime)
        }

        manager.link.apply(.connected(deviceId: "H10-ABC123", name: "Polar H10 ABC123"))

        XCTAssertEqual(manager.streamingReconnectCount, 1)
        XCTAssertNil(manager.linkRuntime.reconnectDeadlineTask)
        XCTAssertNil(manager.linkRuntime.reconnectTargetId)
        XCTAssertEqual(manager.readiness.generation, generation + 1)
        XCTAssertEqual(manager.feedStatus, .settingUp)
    }

    // MARK: - Explicit disconnect

    /// The user pressing disconnect is not a dropout: the identity goes. But
    /// the strap may still be recording internally, and that survives.
    func testAnExplicitDisconnectClearsIdentityButNotTheDeviceRecording() {
        let manager = linkedManager(streaming: false)
        manager.disconnect()

        XCTAssertNil(manager.connectedDeviceId)
        XCTAssertNil(manager.connectedDeviceType)
        XCTAssertNil(manager.pendingDeviceId)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.readiness.isLinked)
        XCTAssertTrue(manager.isRecordingOnDevice, "the H10 keeps recording after the phone disconnects")
        XCTAssertEqual(manager.recordingState, .recording)
    }

    /// The drop callback that follows the user's disconnect is not chased.
    func testTheCallbackAfterAnExplicitDisconnectIsNotChased() {
        let manager = linkedManager(streaming: false)
        manager.disconnect()
        drop(manager)

        XCTAssertNil(manager.linkRuntime.reconnectTargetId)
        XCTAssertFalse(manager.linkRuntime.userDisconnectRequested, "the flag is consumed, not left to swallow a later real drop")
    }

    /// Disconnecting when nothing is connected is a no-op, not a state wipe.
    func testDisconnectingWhenNotConnectedChangesNothing() {
        let manager = PolarManager()
        manager.isRecordingOnDevice = true
        manager.recordingState = .recording
        manager.disconnect()

        XCTAssertTrue(manager.isRecordingOnDevice)
        XCTAssertEqual(manager.recordingState, .recording)
    }

    // MARK: - Cancelling a connection attempt

    func testCancellingOutsideAConnectionAttemptIsANoOp() {
        let manager = linkedManager(streaming: false)
        manager.cancelConnection()

        XCTAssertEqual(manager.connectionState, .connected, "a connected device must not be torn down by a cancel")
        XCTAssertEqual(manager.connectedDeviceId, "H10-ABC123")
    }

    func testCancellingWithNoPendingDeviceIsANoOp() {
        let manager = PolarManager()
        manager.connectionState = .connecting
        manager.pendingDeviceId = nil
        manager.cancelConnection()

        XCTAssertEqual(manager.connectionState, .connecting, "nothing to cancel without a pending device")
    }

    // MARK: - Reconnecting to the last device

    func testReconnectingWithNoKnownDeviceDoesNotEnterConnecting() {
        let manager = PolarManager()
        manager.knownDevices = []
        manager.connectToLastDevice()

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertNil(manager.pendingDeviceId)
    }

    // MARK: - Readiness

    func testAFeatureReportForTheLinkedStrapMarksItReady() {
        let manager = linkedManager(streaming: false)
        manager.link.apply(.featureReady(deviceId: "H10-ABC123", feature: .onlineStreaming))

        XCTAssertTrue(manager.readiness.isReady(.onlineStreaming))
    }

    func testAFeatureReportForAnotherStrapIsIgnored() {
        let manager = linkedManager(streaming: false)
        manager.link.apply(.featureReady(deviceId: "OTHER", feature: .onlineStreaming))

        XCTAssertFalse(manager.readiness.isReady(.onlineStreaming))
    }

    /// A summary that leaves a feature unreported settles it as unconfirmed —
    /// the SDK has stopped checking, so the operation may try and let the SDK's
    /// own guard decide.
    func testASummaryWithoutAFeatureLeavesItUnconfirmed() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "H10-ABC123", type: .h10)
        manager.readiness.linkEstablished()
        manager.link.apply(.readinessSummary(deviceId: "H10-ABC123", ready: [.heartRate], unavailable: [.offlineRecording]))

        XCTAssertEqual(manager.readiness.waitOutcome(for: .heartRate), .ready)
        XCTAssertEqual(manager.readiness.waitOutcome(for: .offlineRecording), .unavailable)
        XCTAssertEqual(manager.readiness.waitOutcome(for: .h10Recording), .unconfirmed)
        XCTAssertTrue(manager.link.isUsable(.h10Recording))
        XCTAssertFalse(manager.link.isUsable(.offlineRecording))
    }

    /// Waiting for a feature resumes on the report itself, not on a timer.
    func testAWaiterResumesWhenTheFeatureIsReported() async {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "H10-ABC123", type: .h10)
        manager.readiness.linkEstablished()

        let waiter = Task { @MainActor in
            await manager.link.awaitFeature(.h10Recording, until: Date().addingTimeInterval(30))
        }
        await Task.yield()
        manager.link.apply(.featureReady(deviceId: "H10-ABC123", feature: .h10Recording))

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .ready)
    }

    func testAWaiterTimesOutWithoutALink() async {
        let manager = PolarManager()
        let outcome = await manager.link.awaitFeature(.heartRate, until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(outcome, .timedOut)
    }

    /// A refusal the SDK makes before touching the radio is retried; the
    /// operation runs again and succeeds once the strap is ready, and success
    /// confirms the feature.
    func testANotReadyRefusalIsRetriedAndSuccessConfirmsTheFeature() async throws {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "H10-ABC123", type: .h10)
        manager.readiness.linkEstablished()
        manager.readiness.settleWithoutSummary()
        var attempts = 0

        let value = try await manager.link.whenFeatureUsable(.h10Recording, until: Date().addingTimeInterval(30)) {
            attempts += 1
            if attempts == 1 { throw PolarManager.PolarError.featureNotReady("h10Recording") }
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(manager.readiness.isReady(.h10Recording))
    }

    /// Any other error is the operation's own and is not retried.
    func testAnOperationsOwnErrorIsNotRetried() async {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "H10-ABC123", type: .h10)
        manager.readiness.linkEstablished()
        manager.readiness.markReady(.h10Recording)
        var attempts = 0

        do {
            _ = try await manager.link.whenFeatureUsable(.h10Recording, until: Date().addingTimeInterval(30)) {
                attempts += 1
                throw PolarManager.PolarError.noRecordingFound
            }
            XCTFail("expected the operation's error")
        } catch {
            guard case PolarManager.PolarError.noRecordingFound = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Feed

    /// A sample marks the feed live and sets the live reading, with or without
    /// a session.
    func testASampleWithoutASessionUpdatesTheLiveReadingOnly() {
        let manager = linkedManager(streaming: false)
        manager.feedStatus = .settingUp
        manager.ingestHeartRate([StrapHRSample(hr: 71, rrsMs: [845], rrAvailable: true)])

        XCTAssertEqual(manager.currentHeartRate, 71)
        XCTAssertEqual(manager.feedStatus, .live)
        XCTAssertTrue(manager.streamedRRPoints.isEmpty, "beats are buffered only during a session")
    }

    /// A strap reporting heart rate without RR still shows heart rate.
    func testHeartRateWithoutRRStillUpdatesTheLiveReading() {
        let manager = linkedManager(streaming: true)
        manager.ingestHeartRate([StrapHRSample(hr: 63, rrsMs: [], rrAvailable: false)])

        XCTAssertEqual(manager.currentHeartRate, 63)
        XCTAssertTrue(manager.streamedRRPoints.isEmpty)
    }

    /// Health evaluation publishes the feed's status for the UI.
    func testEvaluatingHealthOnAStalledFeedResubscribesFirst() {
        let manager = linkedManager(streaming: true)
        let now = Date()
        manager.linkRuntime.linkedAt = now.addingTimeInterval(-300)
        manager.linkRuntime.settledAt = now.addingTimeInterval(-290)
        manager.linkRuntime.lastSampleAt = now.addingTimeInterval(-60)

        manager.link.evaluateFeedHealth(now: now)

        XCTAssertEqual(manager.feedStatus, .stalled)
        XCTAssertTrue(manager.connectionHealthWarning)
        XCTAssertEqual(manager.linkRuntime.lastResubscribeAt, now)
    }
}
