import Foundation

// Session-state conveniences: reset between recordings, dismissing a
// device-refinement notice, and the archive-changed forwarder.

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
        let resetsPause = pausedSession != nil
        currentSession = nil
        collectedPoints = []
        verificationResult = nil
        recoveryWindow = nil
        needsAcceptance = false
        lastError = nil
        isCollecting = false
        isStreamingMode = false
        sessionStartTime = nil
        sessionState.reviewArchivedSessionId = nil
        recordingPhase = .idle
        baselineDeviation = nil
        isPaused = false
        pausedSession = nil
        if resetsPause { clearPausedSessionState() }
    }

    /// Notify that the archive has changed.
    /// Forwards to `archiveSignal.notifyChanged()` which bumps the version and
    /// posts `.flowRecoveryArchiveChanged` for non-SwiftUI subscribers.
    func notifyArchiveChanged() {
        archiveSignal.notifyChanged()
    }
}
