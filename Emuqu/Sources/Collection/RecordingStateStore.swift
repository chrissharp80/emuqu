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

    /// Forgets the Record screen's recording: it completed, was cancelled, or
    /// was recovered. The marker is one key shared with workouts, which write
    /// theirs only when it holds no Record screen recording and clear only
    /// their own. A workout's marker found here was written after this
    /// recording's (a workout started once a night was saved, while its card
    /// waits for Accept) and is that live or interrupted workout's, so it is
    /// kept: clearing it lost the workout's crash recovery.
    func clear() {
        guard PersistedRecordingState.load()?.sessionType != .workout else {
            debugLog("[RRCollector] Persisted recording state is a workout's, leaving it")
            return
        }
        PersistedRecordingState.clear()
        debugLog("[RRCollector] Cleared persisted recording state")
    }

    /// Forgets the marker only when it is `sessionId`'s: a recovery that
    /// awaited the strap or the disk finishes after another recording may
    /// have started and written its own.
    func clear(ifItIs sessionId: UUID) {
        guard PersistedRecordingState.load()?.sessionId == sessionId else { return }
        PersistedRecordingState.clear()
        debugLog("[RRCollector] Cleared persisted recording state of \(sessionId.uuidString.prefix(8))")
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
