import Foundation

// Session-state conveniences: reset between recordings, the guards a new
// quick reading or strap recording and the strap-only Stop and Discard share,
// dismissing a device-refinement notice, and the archive-changed forwarder.

extension RRCollector {
    /// Reset current session state for new recording. The last error goes
    /// too: the Record screen raises its alert when the error changes, so a
    /// dismissed error left in place hid the same error the next time.
    /// Refused while a night's ending is in progress, which owns this state
    /// until it is done. The paused marker goes only with a paused session.
    func resetSession() {
        guard !streamingLifecycle.isEndingOvernight else {
            debugLog("[RRCollector] Not resetting the session: a night's ending is in progress", level: .warning)
            return
        }
        let resetsPause = streamingLifecycle.pausedSession != nil
        sessionState.currentSession = nil
        sessionState.collectedPoints = []
        sessionState.verificationResult = nil
        sessionState.recoveryWindow = nil
        sessionState.needsAcceptance = false
        sessionState.lastError = nil
        sessionState.isCollecting = false
        streamingLifecycle.isStreamingMode = false
        sessionStartTime = nil
        sessionState.forgetReviewedNight()
        sessionState.recordingPhase = .idle
        sessionState.baselineDeviation = nil
        streamingLifecycle.isPaused = false
        streamingLifecycle.pausedSession = nil
        if resetsPause { control.clearPausedSessionState() }
    }

    /// A quick reading or a strap-only recording may start only with the
    /// strap connected and no night paused or being ended: that night owns
    /// the current session and the recording phase until it is resumed,
    /// finished or saved, and an ending is still taking its recording off the
    /// strap. Throws `alreadyRecording` or `notConnected`; `what` names the
    /// start in the log.
    func requireConnectedWithNoNightHeld(starting what: String) throws {
        guard !streamingLifecycle.isPaused, !streamingLifecycle.isEndingOvernight else {
            debugLog("[RRCollector] Not starting \(what): a night is paused or being ended", level: .warning)
            throw CollectorError.alreadyRecording
        }
        guard polarManager.connectionState == .connected else { throw CollectorError.notConnected }
    }

    /// Whether the strap's recording belongs to a session the strap-only Stop
    /// and Discard must leave alone: a night being ended (its ending
    /// downloads the strap itself) or a live workout (the recording is its
    /// backup; `alreadyRecording` is shown). `action` names the caller in
    /// the log.
    func strapRecordingIsHeldElsewhere(_ action: String) -> Bool {
        if streamingLifecycle.isEndingOvernight {
            debugLog("[RRCollector] Not \(action) the strap recording: a night's ending is in progress")
            return true
        }
        guard recovery.strapRecordingBelongsToLiveWorkout else { return false }
        debugLog("[RRCollector] Not \(action) the strap recording: it is a live workout's backup", level: .warning)
        sessionState.lastError = CollectorError.alreadyRecording
        return true
    }

    /// Notify that the archive has changed.
    /// Forwards to `archiveSignal.notifyChanged()` which bumps the version and
    /// posts `.flowRecoveryArchiveChanged` for non-SwiftUI subscribers.
    func notifyArchiveChanged() {
        archiveSignal.notifyChanged()
    }
}
