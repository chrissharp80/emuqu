import Foundation

/// The decisions that guard the strap's own on-device recording: whether a
/// recording may start, what a status reading means, and whether one needs
/// stopping at session end.
///
/// ## Why this exists
///
/// These guards protect the single most expensive failure this app has — a lost
/// night. Starting a second recording while one is running abandons the first;
/// the H10 keeps one file and the new one replaces it. Skipping the stop leaves
/// the strap recording flat into the next day and the battery dead by evening.
///
/// As inline `guard` chains inside async SDK plumbing in
/// `PolarManager+Recording.swift` they sat at **0% coverage**:
/// nothing in the suite could reach them, because reaching them required a
/// connected Polar strap.
///
/// Every input here is already an app-owned type — `PolarDeviceType`,
/// `ConnectionState`, `RecordingState` — so the decisions are separable
/// from the SDK.
enum StrapRecordingPolicy {
    /// What `startRecording` should do, given the connection and recording state.
    enum StartDecision: Equatable {
        /// No API, no device id, or the link is not up.
        case notConnected
        /// Something is already recording — refuse rather than overwrite it.
        case alreadyRecording
        /// Verity Sense records PPI through the offline-recording feature.
        case startVeritySense
        /// H10 records RR through the exercise-recording feature.
        case startH10
    }

    /// Preconditions in the order the caller checks them: connection first, then
    /// whether a recording is already under way, then which strap this is.
    ///
    /// `recordingState != .idle` and `isRecordingOnDevice` are deliberately
    /// separate signals. The first is what *this app* believes it started; the
    /// second is what the strap reports about itself, which can be true after a
    /// crash, a force-quit, or a session the user started on the device. Either
    /// one is enough to refuse.
    static func startDecision(
        hasAPI: Bool,
        hasDeviceId: Bool,
        connectionState: PolarManager.ConnectionState,
        recordingState: PolarManager.RecordingState,
        isRecordingOnDevice: Bool,
        deviceType: PolarDeviceType?
    ) -> StartDecision {
        guard hasAPI, hasDeviceId, connectionState == .connected else { return .notConnected }
        guard recordingState == .idle, !isRecordingOnDevice else { return .alreadyRecording }
        return deviceType == .veritySense ? .startVeritySense : .startH10
    }

    /// What a status reading means for the app's own state.
    struct StatusOutcome: Equatable {
        let isRecordingOnDevice: Bool
        /// The state to move to, or nil to leave it alone.
        let recordingState: PolarManager.RecordingState?
    }

    /// A strap reporting an ongoing recording moves the app to `.recording`.
    ///
    /// A strap reporting *no* recording leaves a transitional state alone:
    /// this is polled while the app may be mid-`.starting`, mid-`.stopping` or
    /// mid-`.fetching`, and a "not yet" reading during one of those would yank
    /// the state machine backwards. A settled `.recording` the strap denies is
    /// different: nothing is in flight, so the app's belief is stale, and
    /// keeping it refuses every later start (`startDecision`) for a strap that
    /// is not recording. That reading returns the app to `.idle`.
    static func statusOutcome(ongoing: Bool, current: PolarManager.RecordingState) -> StatusOutcome {
        guard !ongoing else { return StatusOutcome(isRecordingOnDevice: true, recordingState: .recording) }
        return StatusOutcome(isRecordingOnDevice: false, recordingState: current == .recording ? .idle : nil)
    }

    /// What an unattended download (the morning, a pause, a workout's end,
    /// crash recovery) should do with the strap the app can see.
    enum QuickFetchDecision: Equatable {
        case notConnected
        /// The H10 keeps its exercise file whether or not the app remembers
        /// starting it, so a connected H10 is always asked.
        case fetchH10
        case fetchVeritySense
        /// A Verity Sense with no offline recording running has nothing to
        /// download.
        case skipVeritySenseNotRecording
    }

    static func quickFetchDecision(
        hasAPI: Bool,
        hasDeviceId: Bool,
        isRecordingOnDevice: Bool,
        deviceType: PolarDeviceType?
    ) -> QuickFetchDecision {
        guard hasAPI, hasDeviceId else { return .notConnected }
        guard deviceType == .veritySense else { return .fetchH10 }
        return isRecordingOnDevice ? .fetchVeritySense : .skipVeritySenseNotRecording
    }

    /// How long the morning download waits for the strap to reconnect before
    /// scoring from the live stream. A phone locked all night needs well over
    /// ten seconds.
    static let morningReconnectWindowSeconds: TimeInterval = 60

    /// How long a recording operation waits for the strap's recording feature
    /// after a connect. Covers the SDK's readiness check and a slow service
    /// setup on a busy phone, with margin.
    static let featureReadyWindowSeconds: TimeInterval = 60

    /// How long a deliberate disconnect waits for the SDK to report the drop.
    static let linkDropWaitSeconds: TimeInterval = 5

    /// Whether the H10's internal recording needs an explicit stop at session end.
    ///
    /// Verity Sense is excluded: its offline recording is stopped through the
    /// download path, and sending it the H10 stop is a no-op at best.
    static func shouldStopDeviceRecording(
        deviceType: PolarDeviceType?,
        hasAPI: Bool,
        hasDeviceId: Bool,
        isRecordingOnDevice: Bool
    ) -> Bool {
        guard deviceType != .veritySense else { return false }
        return hasAPI && hasDeviceId && isRecordingOnDevice
    }

    // MARK: - Transfers

    /// How long taking a recording off the strap may take, phase by phase.
    /// Every phase runs under `StrapDeadline`, so a stale link that never
    /// answers ends in an error at the deadline instead of an endless spinner.
    struct TransferBudget: Equatable, Sendable {
        /// Status read, stop and the wait for the file to finalize. A
        /// legitimately slow stop (an 8-hour file flushed to flash) plus the
        /// finalize poll fits well inside it.
        let stopSeconds: UInt64
        /// Every download attempt, back-off and link reset together.
        let downloadSeconds: UInt64
        /// Whether the transfer reports its progress on screen.
        let showsProgress: Bool

        /// Nobody is watching a progress bar (the morning, a workout's end,
        /// crash recovery): a dead strap must fall back to the streamed
        /// beats quickly. A full-night download takes one to two minutes.
        static let unattended = TransferBudget(stopSeconds: 45, downloadSeconds: 120, showsProgress: false)
        /// Stop, Retry, Recover and the rescue before arming: progress is on
        /// screen with Cancel, so a slow link gets more retries.
        static let attended = TransferBudget(stopSeconds: 45, downloadSeconds: 300, showsProgress: true)
    }

    /// How long the strap may take to come back for a transfer when the link
    /// is down.
    static let reconnectWindowSeconds: TimeInterval = morningReconnectWindowSeconds

    /// What a failed download attempt says about the next one.
    enum DownloadFailure: Equatable {
        /// Retrying cannot change the answer: the strap holds no recording
        /// from this session, or the pairing is gone.
        case deterministic
        /// The strap listed no recording at all.
        case nothingListed
        /// A timeout, a refused transfer, a link not ready yet.
        case transient
    }

    /// The step before the next download attempt.
    enum RetryStep: Equatable {
        case giveUp
        /// The file may still be finalizing: wait briefly and read again.
        case pause(milliseconds: UInt64)
        /// The SDK wedges on large transfers (Polar SDK issue #181); a link
        /// reset clears it.
        case resetLink
    }

    /// Download attempts allowed per transfer, before the phase deadline.
    static let maxDownloadAttempts = 9

    /// Quick retries first, while a just-stopped file finishes writing, then
    /// link resets. An empty listing is only worth retrying when this
    /// transfer has just stopped a recording, whose file may not be listed
    /// yet; otherwise the strap simply holds nothing.
    static func retryStep(after failure: DownloadFailure, attempt: Int, justStopped: Bool) -> RetryStep {
        guard attempt < maxDownloadAttempts, failure != .deterministic else { return .giveUp }
        if failure == .nothingListed, !justStopped { return .giveUp }
        if attempt <= 3 { return .pause(milliseconds: 500) }
        if attempt <= 6 { return .pause(milliseconds: 1000) }
        return .resetLink
    }

    // MARK: - Which recording is whose

    /// Whether a recording that started at `recordingStart` belongs to a
    /// session that started at `sessionStart`: it began during the session's
    /// day, not before it. The H10's id holds whole seconds, so one armed in
    /// the session's first second reads back a little before it.
    static func recording(startedAt recordingStart: Date, belongsToSessionStartedAt sessionStart: Date) -> Bool {
        recordingStart >= sessionStart.addingTimeInterval(-StrapExerciseDecoder.idStampToleranceSeconds)
            && recordingStart < sessionStart.addingTimeInterval(sessionSpanLimitSeconds)
    }

    /// No session this app records runs a full day; a recording that began
    /// later than this after a session's start belongs to a later one.
    static let sessionSpanLimitSeconds: TimeInterval = 24 * 3600

    /// Whether the strap holds a recording the app does not have.
    ///
    /// The strap keeps its copy after a download on purpose (it is the
    /// backup until the next recording clears it), so a stored recording is
    /// not by itself missing data (`recordingIsSaved`). A recording the app
    /// cannot date is not this app's, and there is nothing to file it under.
    static func holdsUnrecoveredRecording(
        hasStoredRecording: Bool,
        storedRecordingStart: Date?,
        alreadyDownloaded: Bool,
        predatesDownloadRecord: Bool,
        archiveHasSessionNearStart: Bool
    ) -> Bool {
        guard hasStoredRecording, storedRecordingStart != nil else { return false }
        return !recordingIsSaved(
            alreadyDownloaded: alreadyDownloaded, predatesDownloadRecord: predatesDownloadRecord,
            archiveHasSessionNearStart: archiveHasSessionNearStart
        )
    }

    /// Whether the app already holds a recording the strap stores: it was
    /// downloaded, or it began before the app kept that record and the
    /// archive has a session that close to it. Only a saved recording may be
    /// cleared from the strap.
    static func recordingIsSaved(
        alreadyDownloaded: Bool, predatesDownloadRecord: Bool, archiveHasSessionNearStart: Bool
    ) -> Bool {
        alreadyDownloaded || (predatesDownloadRecord && archiveHasSessionNearStart)
    }

    // MARK: - Arming the strap's own recording

    /// Why the strap refused to start recording.
    enum StartRefusal: Equatable {
        /// The strap's battery is too low to record to its own memory. Its
        /// answer cannot change until the battery does.
        case batteryTooLow
        /// The strap holds a recording that could not be downloaded, and
        /// starting would delete it.
        case undownloadedRecordingOnStrap
        /// Anything that can clear up: not ready yet, a busy strap, a link
        /// that dropped.
        case retryable
    }

    static func startRefusal(for error: Error) -> StartRefusal {
        switch error as? PolarManager.PolarError {
        case .strapBatteryTooLow?: .batteryTooLow
        case .strapHoldsUndownloadedRecording?: .undownloadedRecordingOnStrap
        default: .retryable
        }
    }

    /// After a battery refusal, another attempt is only worth making once
    /// the strap reports more charge than it had when it refused (a new cell).
    /// With no reading at the refusal, the reading has to clear the low-
    /// battery warning level.
    static func mayRetryArming(afterBatteryRefusalAt refusedAt: Int?, batteryNow: Int?) -> Bool {
        guard let batteryNow else { return false }
        return batteryNow > (refusedAt ?? lowBatteryWarningPercent)
    }

    /// How often an arming that failed for a reason that can clear up is
    /// tried again on a link that does not change. The link's own changes
    /// (a reconnect, a readiness report) wake it sooner.
    static let armingRetryIntervalSeconds: TimeInterval = 180

    /// At or below this the H10 may refuse to record to its own memory
    /// (Polar PFTP `BATTERY_TOO_LOW`, seen at 10 % in the field).
    static let lowBatteryWarningPercent = 20

    /// Whether to warn, before a night that arms the H10's own recording,
    /// that the strap may refuse it. The night still starts.
    static func strapMayRefuseToRecord(batteryLevel: Int?, deviceType: PolarDeviceType?) -> Bool {
        guard deviceType != .veritySense, let batteryLevel else { return false }
        return batteryLevel <= lowBatteryWarningPercent
    }
}
