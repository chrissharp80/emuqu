import Foundation

// Resetting the session between recordings.

extension CollectorSessionControl {
    /// Reset current session state for new recording. The last error goes
    /// too: the Record screen raises its alert when the error changes, so a
    /// dismissed error left in place hid the same error the next time.
    /// Refused while a night's ending is in progress, which owns this state
    /// until it is done. The paused marker goes only with a paused session.
    func resetSession() {
        guard !collector.streamingLifecycle.isEndingOvernight else {
            debugLog("[RRCollector] Not resetting the session: a night's ending is in progress", level: .warning)
            return
        }
        let resetsPause = collector.streamingLifecycle.pausedSession != nil
        collector.sessionState.currentSession = nil
        collector.sessionState.collectedPoints = []
        collector.sessionState.verificationResult = nil
        collector.sessionState.recoveryWindow = nil
        collector.sessionState.needsAcceptance = false
        collector.sessionState.lastError = nil
        collector.sessionState.isCollecting = false
        collector.streamingLifecycle.isStreamingMode = false
        collector.streamingLifecycle.sessionStartTime = nil
        collector.sessionState.forgetReviewedNight()
        collector.sessionState.recordingPhase = .idle
        collector.sessionState.baselineDeviation = nil
        collector.streamingLifecycle.isPaused = false
        collector.streamingLifecycle.pausedSession = nil
        if resetsPause { collector.recordingStore.clearPaused() }
    }
}
