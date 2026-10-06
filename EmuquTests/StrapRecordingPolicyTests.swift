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
        let outcome = StrapRecordingPolicy.statusOutcome(ongoing: true, current: .idle)
        XCTAssertTrue(outcome.isRecordingOnDevice)
        XCTAssertEqual(outcome.recordingState, .recording)
    }

    /// A "not recording" reading updates the flag but must NOT move a
    /// transitional state: this is polled while the app may be mid-`.starting`,
    /// mid-`.stopping` or mid-`.fetching`, and a "not yet" reading during one
    /// would drag it backwards.
    func testANegativeReadingLeavesATransitionalStateAlone() {
        for state in [PolarManager.RecordingState.starting, .stopping, .fetching, .idle] {
            let outcome = StrapRecordingPolicy.statusOutcome(ongoing: false, current: state)
            XCTAssertFalse(outcome.isRecordingOnDevice)
            XCTAssertNil(outcome.recordingState, "a negative reading moved \(state)")
        }
    }

    /// Was `testANegativeReadingUpdatesTheFlagButNotTheState`, which pinned a
    /// stale `.recording` forever: after an H10 workout stop the strap was
    /// stopped, the status read said so, and every later arm was refused as
    /// `alreadyRecording` all night (dfa-strap Bug 4).
    func testASettledRecordingTheStrapDeniesReturnsToIdle() {
        let outcome = StrapRecordingPolicy.statusOutcome(ongoing: false, current: .recording)
        XCTAssertFalse(outcome.isRecordingOnDevice)
        XCTAssertEqual(outcome.recordingState, .idle)
        XCTAssertEqual(
            decision(recording: outcome.recordingState ?? .recording, onDevice: outcome.isRecordingOnDevice),
            .startH10, "the next arm must not be refused"
        )
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
    }

    // MARK: - Transfers

    /// Every flow downloads under a hard deadline; Stop, Retry and Recover had
    /// none and could spin for ever on a stale link.
    func testEveryTransferBudgetIsBounded() {
        for budget in [StrapRecordingPolicy.TransferBudget.attended, .unattended] {
            XCTAssertGreaterThan(budget.stopSeconds, 0)
            XCTAssertLessThanOrEqual(budget.stopSeconds, 60)
            XCTAssertGreaterThanOrEqual(budget.downloadSeconds, 120, "a full night takes one to two minutes")
            XCTAssertLessThanOrEqual(budget.downloadSeconds, 300)
        }
        XCTAssertTrue(StrapRecordingPolicy.TransferBudget.attended.showsProgress)
        XCTAssertFalse(StrapRecordingPolicy.TransferBudget.unattended.showsProgress)
    }

    /// Quick retries while a just-stopped file finalizes, then link resets.
    func testRetriesPauseBrieflyThenResetTheLink() {
        let steps = (1 ..< StrapRecordingPolicy.maxDownloadAttempts).map {
            StrapRecordingPolicy.retryStep(after: .transient, attempt: $0, justStopped: true)
        }
        XCTAssertEqual(Array(steps.prefix(3)), Array(repeating: .pause(milliseconds: 500), count: 3))
        XCTAssertEqual(Array(steps[3 ..< 6]), Array(repeating: .pause(milliseconds: 1000), count: 3))
        XCTAssertTrue(steps.dropFirst(6).allSatisfy { $0 == .resetLink })
        XCTAssertEqual(
            StrapRecordingPolicy.retryStep(after: .transient, attempt: StrapRecordingPolicy.maxDownloadAttempts, justStopped: true),
            .giveUp
        )
    }

    /// A strap holding only an earlier session's recording gives the same
    /// answer on every retry.
    func testARecordingFromAnotherSessionIsNotRetried() {
        XCTAssertEqual(StrapRecordingPolicy.retryStep(after: .deterministic, attempt: 1, justStopped: true), .giveUp)
    }

    /// An empty listing right after a stop may be a file still finalizing; an
    /// empty listing on a strap that was not recording means it holds nothing.
    func testAnEmptyListingIsRetriedOnlyAfterAStop() {
        XCTAssertEqual(StrapRecordingPolicy.retryStep(after: .nothingListed, attempt: 1, justStopped: true), .pause(milliseconds: 500))
        XCTAssertEqual(StrapRecordingPolicy.retryStep(after: .nothingListed, attempt: 1, justStopped: false), .giveUp)
    }

    // MARK: - Which recording is whose

    /// strap-copies Bug 1: Recover with saved state for tonight filed the
    /// previous night's file under tonight's session.
    func testOnlyARecordingStartedDuringTheSessionBelongsToIt() {
        let tonight = Date(timeIntervalSince1970: 1_790_000_000)
        let lastNight = tonight.addingTimeInterval(-24 * 3600)
        XCTAssertFalse(StrapRecordingPolicy.recording(startedAt: lastNight, belongsToSessionStartedAt: tonight))
        XCTAssertTrue(StrapRecordingPolicy.recording(startedAt: tonight.addingTimeInterval(90), belongsToSessionStartedAt: tonight))
        XCTAssertTrue(
            StrapRecordingPolicy.recording(startedAt: tonight.addingTimeInterval(-1), belongsToSessionStartedAt: tonight),
            "the id holds whole seconds"
        )
        XCTAssertFalse(
            StrapRecordingPolicy.recording(startedAt: tonight.addingTimeInterval(30 * 3600), belongsToSessionStartedAt: tonight),
            "a recording from the next day is not this session's"
        )
    }

    // MARK: - What the Record screen offers

    /// strap-copies Bug 9: the strap keeps every downloaded recording, and the
    /// Recover card offered the same, already-saved night on every connect.
    func testADownloadedRecordingIsNotOfferedAgain() {
        XCTAssertFalse(unrecovered(downloaded: true))
        XCTAssertTrue(unrecovered(downloaded: false), "a recording never downloaded is the user's missing data")
    }

    /// Recordings from before the download record existed fall back to
    /// whether the archive has a session that close to them.
    func testARecordingOlderThanTheRecordFallsBackToTheArchive() {
        XCTAssertFalse(unrecovered(downloaded: false, predates: true, archived: true))
        XCTAssertTrue(unrecovered(downloaded: false, predates: true, archived: false))
    }

    func testNothingStoredOrUndatedIsNotOffered() {
        XCTAssertFalse(StrapRecordingPolicy.holdsUnrecoveredRecording(
            hasStoredRecording: false, storedRecordingStart: Date(), alreadyDownloaded: false,
            predatesDownloadRecord: false, archiveHasSessionNearStart: false
        ))
        XCTAssertFalse(StrapRecordingPolicy.holdsUnrecoveredRecording(
            hasStoredRecording: true, storedRecordingStart: nil, alreadyDownloaded: false,
            predatesDownloadRecord: false, archiveHasSessionNearStart: false
        ))
    }

    private func unrecovered(downloaded: Bool, predates: Bool = false, archived: Bool = false) -> Bool {
        StrapRecordingPolicy.holdsUnrecoveredRecording(
            hasStoredRecording: true, storedRecordingStart: Date(), alreadyDownloaded: downloaded,
            predatesDownloadRecord: predates, archiveHasSessionNearStart: archived
        )
    }

    // MARK: - Arming refusals

    func testABatteryRefusalIsTerminalAndOthersCanClearUp() {
        XCTAssertEqual(StrapRecordingPolicy.startRefusal(for: PolarManager.PolarError.strapBatteryTooLow(percent: 10)), .batteryTooLow)
        XCTAssertEqual(
            StrapRecordingPolicy.startRefusal(for: PolarManager.PolarError.strapHoldsUndownloadedRecording),
            .undownloadedRecordingOnStrap
        )
        XCTAssertEqual(StrapRecordingPolicy.startRefusal(for: PolarManager.PolarError.featureNotReady("x")), .retryable)
        XCTAssertEqual(StrapRecordingPolicy.startRefusal(for: CancellationError()), .retryable)
    }

    /// After BATTERY_TOO_LOW at 10 %, only a higher reading (a new cell) is
    /// worth another start.
    func testArmingIsRetriedOnlyOnceTheBatteryRises() {
        XCTAssertFalse(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: 10, batteryNow: 10))
        XCTAssertFalse(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: 10, batteryNow: 9))
        XCTAssertFalse(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: 10, batteryNow: nil))
        XCTAssertTrue(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: 10, batteryNow: 100))
        XCTAssertFalse(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: nil, batteryNow: 15))
        XCTAssertTrue(StrapRecordingPolicy.mayRetryArming(afterBatteryRefusalAt: nil, batteryNow: 80))
    }

    /// The pre-night warning: an H10 at or below 20 %; never a Verity Sense,
    /// which does not record to its memory on a streamed night.
    func testALowH10IsWarnedAboutBeforeTheNight() {
        XCTAssertTrue(StrapRecordingPolicy.strapMayRefuseToRecord(batteryLevel: 10, deviceType: .h10))
        XCTAssertTrue(StrapRecordingPolicy.strapMayRefuseToRecord(batteryLevel: 20, deviceType: .h10))
        XCTAssertFalse(StrapRecordingPolicy.strapMayRefuseToRecord(batteryLevel: 21, deviceType: .h10))
        XCTAssertFalse(StrapRecordingPolicy.strapMayRefuseToRecord(batteryLevel: 10, deviceType: .veritySense))
        XCTAssertFalse(StrapRecordingPolicy.strapMayRefuseToRecord(batteryLevel: nil, deviceType: .h10))
    }

    /// Only a recording the app holds may be cleared from the strap.
    func testOnlyASavedRecordingMayBeCleared() {
        XCTAssertTrue(StrapRecordingPolicy.recordingIsSaved(alreadyDownloaded: true, predatesDownloadRecord: false, archiveHasSessionNearStart: false))
        XCTAssertTrue(StrapRecordingPolicy.recordingIsSaved(alreadyDownloaded: false, predatesDownloadRecord: true, archiveHasSessionNearStart: true))
        XCTAssertFalse(StrapRecordingPolicy.recordingIsSaved(alreadyDownloaded: false, predatesDownloadRecord: false, archiveHasSessionNearStart: true))
        XCTAssertFalse(StrapRecordingPolicy.recordingIsSaved(alreadyDownloaded: false, predatesDownloadRecord: true, archiveHasSessionNearStart: false))
    }
}
