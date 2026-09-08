import Foundation

// Session-state conveniences: reset between recordings, the device-refinement
// accept/dismiss pair, and the archive-changed forwarder.

extension RRCollector {
    /// Reset current session state for new recording
    func resetSession() {
        currentSession = nil
        collectedPoints = []
        verificationResult = nil
        recoveryWindow = nil
        needsAcceptance = false
        recordingPhase = .idle
        baselineDeviation = nil
        isPaused = false
        pausedSession = nil
        deviceRefinement = nil
        isDeviceFetchInProgress = false
        clearPausedSessionState()
    }

    /// Apply the device refinement — replaces currentSession with the refined version
    /// and persists to archive so the choice survives a crash before accept.
    func applyDeviceRefinement() {
        guard let refinement = deviceRefinement else { return }
        currentSession = refinement.refinedSession
        baselineTracker.update(with: refinement.refinedSession, sleepSchedule: settingsManager.settings.sleepSchedule)
        do {
            try archive.archive(refinement.refinedSession)
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to persist refined session: \(error)")
        }
        deviceRefinement = nil
        debugLog("[RRCollector] Applied device refinement (readiness: \(String(format: "%.1f", refinement.originalReadiness)) → \(String(format: "%.1f", refinement.refinedReadiness)))")
    }

    /// Dismiss the device refinement — keep the original streaming result.
    func dismissDeviceRefinement() {
        deviceRefinement = nil
        debugLog("[RRCollector] Dismissed device refinement — keeping streaming result")
    }

    /// Notify that the archive has changed.
    /// Forwards to `archiveSignal.notifyChanged()` which bumps the version and
    /// posts `.flowRecoveryArchiveChanged` for non-SwiftUI subscribers.
    func notifyArchiveChanged() {
        archiveSignal.notifyChanged()
    }
}
