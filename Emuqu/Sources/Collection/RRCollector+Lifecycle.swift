import Foundation
import UIKit

// MARK: - Lifecycle & Persisted State

extension RRCollector {
    // MARK: - Persisted Recording State

    /// Persist recording start time and session info to survive app crashes
    func persistRecordingState(sessionId: UUID, startTime: Date, sessionType: SessionType) {
        let state = PersistedRecordingState(
            sessionId: sessionId,
            startTime: startTime,
            sessionType: sessionType,
            phase: recordingPhase.description,
            useDeviceInternalBackup: useDeviceBackupForOvernight
        )
        PersistedRecordingState.save(state)
        debugLog("[RRCollector] Persisted recording state: session=\(sessionId.uuidString.prefix(8)), start=\(startTime), phase=\(recordingPhase)")
    }

    /// Clear persisted recording state (call on successful completion or explicit cancel)
    func clearPersistedRecordingState() {
        PersistedRecordingState.clear()
        debugLog("[RRCollector] Cleared persisted recording state")
    }

    /// Retrieve persisted recording state (for recovery after crash/disconnect)
    func getPersistedRecordingState() -> (sessionId: UUID, startTime: Date, sessionType: SessionType)? {
        guard let state = PersistedRecordingState.load() else {
            return nil
        }
        return (state.sessionId, state.startTime, state.sessionType)
    }

    /// Retrieve the persisted capture mode preference (device internal backup flag).
    /// Returns nil when no persisted state exists or state was saved before this field was added.
    func getPersistedCaptureMode() -> Bool? {
        PersistedRecordingState.load()?.useDeviceInternalBackup
    }

    /// Check if there's a persisted recording that needs recovery
    var hasPersistedRecordingState: Bool {
        getPersistedRecordingState() != nil
    }

    /// Clear persisted recording state after recovery or dismissal from app launch alert.
    /// Separate from the private method so the app layer can clear it after handling.
    func clearPersistedRecordingStatePublic() {
        clearPersistedRecordingState()
    }

    // MARK: - Data Rescue Callback

    /// Hook PolarManager's rescue callback so a recording taken off the strap
    /// for no session (the rescue before arming, a download that turned out
    /// to be another session's) is backed up and recoverable from Lost
    /// Sessions instead of dropped, and so the strap's start sequence asks
    /// the archive-aware question of which stored recordings the app holds.
    func setupDataRescueCallback() {
        polarManager.onUnrecoveredDataRescued = { [weak self] recording in
            self?.backUpRescuedRecording(recording)
        }
        polarManager.savedRecordingCheck = { [weak self] start in
            self?.isStrapRecordingSaved(startedAt: start) ?? false
        }
    }

    /// RawRRBackup is not thread-safe, so this stays on the main actor; the
    /// brief I/O (JSON + SHA256 + write) runs inside an operation the user is
    /// already waiting on. Dated by the recording's own start: recovery takes
    /// the capture date as the session start, and "now" would file last
    /// night's beats under tonight.
    private func backUpRescuedRecording(_ recording: StrapRecording) {
        let rescueId = UUID()
        debugLog("[RRCollector] Rescuing \(recording.points.count) unrecovered points from device → backup \(rescueId.uuidString.prefix(8))")
        do {
            try rawBackup.backup(
                points: recording.points, sessionId: rescueId, deviceId: polarManager.connectedDeviceId,
                captureDate: recording.startedAt.flatMap { $0 <= Date() ? $0 : nil }
            )
            debugLog("[RRCollector] Rescued \(recording.points.count) points to RawRRBackup (recoverable via Lost Sessions)")
        } catch {
            debugLog("[RRCollector] Failed to rescue device data: \(error)", level: .error)
        }
    }

    // MARK: - Emergency Backup

    /// Force-flush streaming data to disk and iCloud immediately.
    /// Called on app lifecycle events (background, terminate) so iOS jetsam
    /// kills never lose more than the last few heartbeats.
    /// Debounced: willResignActive and didEnterBackground fire back-to-back;
    /// only the first flush within 2 seconds actually runs.
    /// Pass `force: true` from willTerminate to bypass debounce (last chance to save).
    ///
    /// This does NOT launch CloudKit uploads. It runs during willResignActive /
    /// didEnterBackground / willTerminate; firing async network requests without
    /// a UIApplication background task causes iOS to kill the app when the ~30-
    /// second background window expires. The disk backup below is synchronous
    /// and safe, and iCloud catches up on the next regular 5-minute cycle.
    func emergencyBackupFlush(force: Bool = false) {
        // Debounce: willResignActive + didEnterBackground fire within milliseconds.
        // Skip debounce for willTerminate — it's our last chance before the process dies.
        if !force, let last = lastEmergencyFlush, Date().timeIntervalSince(last) < 2 { return }
        guard let session = currentSession, isOvernightStreaming || isStreamingMode else { return }
        let buffer = polarManager.streamedRRPoints
        guard !buffer.isEmpty else { return }
        lastEmergencyFlush = Date()
        rawBackup.incrementalBackup(
            points: buffer,
            sessionId: session.id,
            deviceId: polarManager.connectedDeviceId,
            force: true
        )
        debugLog("[RRCollector] 🛟 Emergency backup flush: \(buffer.count) beats saved to disk")
    }

    /// Register for app lifecycle notifications so we flush data before iOS can kill us.
    ///
    /// Tokens are stored in `notificationObservers` so `deinit` removes
    /// them — block-based observers are NOT auto-removed on dealloc and would
    /// otherwise linger in `NotificationCenter` for every collector built
    /// (tests/previews build many). Mirrors the `+Reanalysis` observer pattern.
    /// The flush runs inline, not in a `Task`: UIKit exits as soon as the
    /// termination notification returns, so a deferred flush never ran and up
    /// to a minute of beats went with it. Observers on `.main` make
    /// `assumeIsolated` sound.
    func setupLifecycleObservers() {
        let center = NotificationCenter.default
        notificationObservers.add(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emergencyBackupFlush() }
        })
        notificationObservers.add(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emergencyBackupFlush() }
        })
        notificationObservers.add(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emergencyBackupFlush(force: true) }
        })
    }

    // MARK: - Deferred one-shot migrations

    /// Run the one-shot session-data repairs.
    ///
    /// The repairs themselves live in `SessionDataMigrations`.
    /// They use nothing of the collector's beyond these five
    /// dependencies, and keeping them here would make `RRCollector` 504 lines larger
    /// for no reason other than that the reference is already in scope.
    func runDeferredSessionMigrationsIfNeeded() async {
        await SessionDataMigrations(
            archive: archive,
            healthKit: healthKit,
            settingsManager: settingsManager,
            baselineTracker: baselineTracker,
            reanalysisService: reanalysisService
        ).runAllIfNeeded()
    }
}
