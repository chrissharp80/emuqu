import Foundation

/// What a recording leaves on disk so a crash or relaunch can recover it: the
/// marker for the recording in progress (`PersistedRecordingState`), and the
/// paused night's id and capture choice. Read at launch and by recovery,
/// written by every start, pause, resume and stop.
@MainActor
struct RecordingStateStore {
    let sessionState: SessionState
    let overnightRun: OvernightRunState

    static let pausedSessionIdKey = UserDefaultsKeys.pausedSessionId
    /// The paused night's capture choice. The recording marker that also
    /// holds it is cleared at pause, and Resume arms the strap by it.
    private static let pausedCaptureModeKey = "pausedSessionUsesDeviceBackup"

    // MARK: - The recording in progress

    /// Saves the recording's start and kind so a crash can offer it at launch.
    func persist(sessionId: UUID, startTime: Date, sessionType: SessionType) {
        let state = PersistedRecordingState(
            sessionId: sessionId,
            startTime: startTime,
            sessionType: sessionType,
            phase: sessionState.recordingPhase.description,
            useDeviceInternalBackup: overnightRun.usesDeviceBackup
        )
        guard PersistedRecordingState.save(state) else {
            debugLog("[RRCollector] Could not persist recording state for session \(sessionId.uuidString.prefix(8)) — a crash now would not offer it at launch", level: .error)
            return
        }
        debugLog("[RRCollector] Persisted recording state: session=\(sessionId.uuidString.prefix(8)), start=\(startTime), phase=\(sessionState.recordingPhase)")
    }

    /// Forgets the recording: it completed, was cancelled, or was recovered.
    func clear() {
        PersistedRecordingState.clear()
        debugLog("[RRCollector] Cleared persisted recording state")
    }

    /// The recording a crash or disconnect left, if any.
    func load() -> (sessionId: UUID, startTime: Date, sessionType: SessionType)? {
        guard let state = PersistedRecordingState.load() else {
            return nil
        }
        return (state.sessionId, state.startTime, state.sessionType)
    }

    var hasRecording: Bool {
        load() != nil
    }

    /// Whether the strap's internal recording backed the recording up, else
    /// the paused night (whose recording marker is cleared at pause). Nil
    /// when neither holds one.
    func captureMode() -> Bool? {
        PersistedRecordingState.load()?.useDeviceInternalBackup ?? pausedCaptureMode()
    }

    // MARK: - The paused night

    func persistPaused(sessionId: UUID) {
        UserDefaults.standard.set(sessionId.uuidString, forKey: Self.pausedSessionIdKey)
        UserDefaults.standard.set(overnightRun.usesDeviceBackup, forKey: Self.pausedCaptureModeKey)
    }

    func clearPaused() {
        UserDefaults.standard.removeObject(forKey: Self.pausedSessionIdKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedCaptureModeKey)
    }

    /// Whether the paused night used the strap's internal recording; nil
    /// when no night is paused or it was paused before this was kept.
    func pausedCaptureMode() -> Bool? {
        UserDefaults.standard.object(forKey: Self.pausedCaptureModeKey) as? Bool
    }

    func pausedSessionId() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.pausedSessionIdKey) else { return nil }
        return UUID(uuidString: str)
    }
}
