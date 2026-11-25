import Foundation

// Resetting the session between recordings.

extension CollectorSessionControl {
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
        streamingLifecycle.sessionStartTime = nil
        sessionState.forgetReviewedNight()
        sessionState.recordingPhase = .idle
        sessionState.baselineDeviation = nil
        streamingLifecycle.isPaused = false
        streamingLifecycle.pausedSession = nil
        if resetsPause { recordingStore.clearPaused() }
    }
}
