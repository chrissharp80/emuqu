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
    /// A strap reporting *no* recording does NOT move the app out of whatever
    /// state it is in: this is polled while the app may be mid-`.starting` or
    /// mid-`.stopping`, and a "not yet" reading during either would otherwise
    /// yank the state machine backwards. Only the positive reading is
    /// actionable. That asymmetry is the behaviour the original code had, and
    /// it is preserved here on purpose.
    static func statusOutcome(ongoing: Bool) -> StatusOutcome {
        StatusOutcome(isRecordingOnDevice: ongoing, recordingState: ongoing ? .recording : nil)
    }

    /// Whether the H10's internal recording needs an explicit stop at session end.
    ///
    /// Verity Sense is excluded: its offline recording is stopped through the
    /// download path, and sending it the H10 stop is a no-op at best.
    /// What the morning download should do with the strap the app can see.
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

    static func shouldStopDeviceRecording(
        deviceType: PolarDeviceType?,
        hasAPI: Bool,
        hasDeviceId: Bool,
        isRecordingOnDevice: Bool
    ) -> Bool {
        guard deviceType != .veritySense else { return false }
        return hasAPI && hasDeviceId && isRecordingOnDevice
    }
}
