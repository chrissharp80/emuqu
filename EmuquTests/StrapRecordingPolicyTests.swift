@testable import Emuqu
import XCTest

/// Tests for the guards around the strap's own on-device recording.
///
/// These decide whether a recording may start, what a status reading means, and
/// whether one needs stopping at session end. They lived inside async SDK
/// plumbing — unreachable without a physical
/// Polar strap. The failure they prevent is a lost night.
final class StrapRecordingPolicyTests: XCTestCase {
    private func decision(
        hasAPI: Bool = true,
        hasDeviceId: Bool = true,
        connection: PolarManager.ConnectionState = .connected,
        recording: PolarManager.RecordingState = .idle,
        onDevice: Bool = false,
        device: PolarDeviceType? = .h10
    ) -> StrapRecordingPolicy.StartDecision {
        StrapRecordingPolicy.startDecision(
            hasAPI: hasAPI, hasDeviceId: hasDeviceId,
            connectionState: connection, recordingState: recording,
            isRecordingOnDevice: onDevice, deviceType: device
        )
    }

    // MARK: - Connection preconditions

    func testAConnectedIdleH10Starts() {
        XCTAssertEqual(decision(), .startH10)
    }

    func testAConnectedIdleVeritySenseTakesTheOfflinePath() {
        XCTAssertEqual(decision(device: .veritySense), .startVeritySense)
    }

    /// Every one of these on its own means there is no link to record over.
    func testEachMissingPieceOfTheLinkRefuses() {
        XCTAssertEqual(decision(hasAPI: false), .notConnected)
        XCTAssertEqual(decision(hasDeviceId: false), .notConnected)
        XCTAssertEqual(decision(connection: .disconnected), .notConnected)
        XCTAssertEqual(decision(connection: .connecting), .notConnected)
        XCTAssertEqual(decision(connection: .scanning), .notConnected)
    }

    /// Connection is checked before recording state: with no strap attached,
    /// "already recording" would be a misleading thing to tell the user.
    func testNotConnectedOutranksAlreadyRecording() {
        XCTAssertEqual(
            decision(connection: .disconnected, recording: .recording, onDevice: true),
            .notConnected
        )
    }

    // MARK: - Refusing to overwrite a running recording

    /// The H10 keeps ONE exercise file. Starting a second recording abandons the
    /// first — the night that is already on the strap is gone.
    func testAStrapAlreadyRecordingRefuses() {
        XCTAssertEqual(decision(onDevice: true), .alreadyRecording)
        XCTAssertEqual(decision(onDevice: true, device: .veritySense), .alreadyRecording)
    }

    /// The app's own non-idle states refuse too — a double tap on Start must not
    /// fire two starts.
    func testANonIdleAppStateRefuses() {
        for state in [PolarManager.RecordingState.starting, .recording, .stopping, .fetching] {
            XCTAssertEqual(decision(recording: state), .alreadyRecording, "\(state) should refuse")
        }
    }

    /// The two signals are independent on purpose. `isRecordingOnDevice` is what
    /// the STRAP reports, which can be true after a crash, a force-quit, or a
    /// session the user started on the device itself — while the app believes it
    /// is idle. That case must still refuse.
    func testAnIdleAppStillRefusesWhenTheStrapSaysItIsRecording() {
        XCTAssertEqual(decision(recording: .idle, onDevice: true), .alreadyRecording)
    }

    /// An unknown device type is treated as an H10 rather than refused —
    /// provenance can be missing on a reconnect, and the H10 path is the one
    /// that degrades safely.
    func testAnUnknownDeviceTypeUsesTheH10Path() {
        XCTAssertEqual(decision(device: nil), .startH10)
    }

    // MARK: - Status readings

    func testAnOngoingRecordingMovesTheAppToRecording() {
        let outcome = StrapRecordingPolicy.statusOutcome(ongoing: true)
        XCTAssertTrue(outcome.isRecordingOnDevice)
        XCTAssertEqual(outcome.recordingState, .recording)
    }

    /// The asymmetry that matters: a "not recording" reading updates the flag
    /// but must NOT move the state machine. This is polled while the app may be
    /// mid-`.starting` or mid-`.stopping`, and a "not yet" reading during either
    /// would drag it backwards.
    func testANegativeReadingUpdatesTheFlagButNotTheState() {
        let outcome = StrapRecordingPolicy.statusOutcome(ongoing: false)
        XCTAssertFalse(outcome.isRecordingOnDevice)
        XCTAssertNil(outcome.recordingState, "a negative reading must not move the state machine")
    }

    // MARK: - Stopping at session end

    /// Leaving the H10 recording runs it flat into the next day.
    func testAnH10ThatIsRecordingMustBeStopped() {
        XCTAssertTrue(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: .h10, hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true
        ))
    }

    /// Verity Sense stops through the download path; the H10 stop does not apply.
    func testAVeritySenseIsNeverStoppedThisWay() {
        XCTAssertFalse(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: .veritySense, hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true
        ))
    }

    func testNothingToStopWhenTheStrapIsNotRecording() {
        XCTAssertFalse(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: .h10, hasAPI: true, hasDeviceId: true, isRecordingOnDevice: false
        ))
    }

    func testNothingToStopWithoutALink() {
        XCTAssertFalse(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: .h10, hasAPI: false, hasDeviceId: true, isRecordingOnDevice: true
        ))
        XCTAssertFalse(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: .h10, hasAPI: true, hasDeviceId: false, isRecordingOnDevice: true
        ))
    }

    /// An unknown type is stopped rather than skipped: an H10 left recording is
    /// a dead battery, and sending the stop to something else is harmless.
    func testAnUnknownDeviceTypeIsStopped() {
        XCTAssertTrue(StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: nil, hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true
        ))
    }

    // MARK: - The two paths agree

    /// Whatever can start must be stoppable, or a recording is orphaned on the
    /// strap. Stated across the whole input space rather than case by case.
    func testAnyStartedH10RecordingIsAlsoStoppable() {
        for connection in [PolarManager.ConnectionState.connected] {
            let started = decision(connection: connection, recording: .idle, onDevice: false, device: .h10)
            guard started == .startH10 else { continue }
            XCTAssertTrue(
                StrapRecordingPolicy.shouldStopDeviceRecording(
                    deviceType: .h10, hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true
                ),
                "an H10 recording this policy allowed to start must also be stoppable"
            )
        }
    }

    // MARK: - Morning download

    /// The regression this pins: an H10 that reconnects after a night with the
    /// phone locked has its "recording on device" flag cleared, and a morning
    /// download that refuses on that flag alone leaves the night on the
    /// strap. The flag is the app's memory; the file is on the strap either way.
    func testAConnectedH10IsAskedForItsFileEvenWhenTheFlagIsOff() {
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: true, hasDeviceId: true, isRecordingOnDevice: false, deviceType: .h10),
            .fetchH10
        )
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true, deviceType: .h10),
            .fetchH10
        )
    }

    func testAVeritySenseIsOnlyAskedWhenItsOfflineRecordingRuns() {
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: true, hasDeviceId: true, isRecordingOnDevice: true, deviceType: .veritySense),
            .fetchVeritySense
        )
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: true, hasDeviceId: true, isRecordingOnDevice: false, deviceType: .veritySense),
            .skipVeritySenseNotRecording
        )
    }

    func testNoLinkMeansNoDownload() {
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: false, hasDeviceId: true, isRecordingOnDevice: true, deviceType: .h10),
            .notConnected
        )
        XCTAssertEqual(
            StrapRecordingPolicy.quickFetchDecision(hasAPI: true, hasDeviceId: false, isRecordingOnDevice: true, deviceType: .h10),
            .notConnected
        )
    }

    /// Ten seconds was not enough for a locked phone to find the strap at wake.
    func testTheMorningReconnectWindowIsAtLeastAMinute() {
        XCTAssertGreaterThanOrEqual(StrapRecordingPolicy.morningReconnectWindowSeconds, 60)
        XCTAssertEqual(OvernightStreamingCoordinator.reconnectPollsBeforeFetch, 120)
    }
}
