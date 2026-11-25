import Foundation

// MARK: - Device-internal RR backup (H10)
//
// A self-contained subsystem: start arms it (the session lifecycle) and stop
// fetches and merges what it recorded (the recorder, in
// `WorkoutRecorder+DeviceFetch.swift`); the two share only the
// lifecycle's `deviceBackupArmedAt`.

extension WorkoutSessionLifecycle {
    //
    // The H10 records RR continuously to internal memory once
    // `startRecording()` is called, independent of the BLE streaming
    // connection. This survives BLE drops, phone-in-backpack range
    // failures, and short app suspensions. At workout stop we fetch
    // whatever the device wrote and merge it with the BLE-streamed
    // beats — the same composite logic the overnight flow uses.
    //
    // Verity Sense is intentionally excluded: its offline PPI
    // recording mode and live PPI streaming are mutually exclusive,
    // so we can't have both without losing the live HR display the
    // user expects during a workout.

    /// Fire-and-forget start of H10 device-internal recording. Streaming is
    /// the primary path and the workout never blocks on this.
    ///
    /// It does not need the strap connected yet: the arming waits on the link
    /// for as long as the workout is recording, and arms once the strap's
    /// recording feature is usable — which on a cold connect can be well past
    /// the workout's first minute.
    func startDeviceInternalBackupIfPossible(workoutId: UUID) {
        guard core.strapLink.connectedDeviceType != .veritySense else {
            debugLog("[Recorder.start] device-internal backup skipped — Verity Sense can't record + stream simultaneously")
            return
        }
        Task { [weak self] in
            await self?.armDeviceInternalBackup(for: workoutId)
        }
    }

    /// A stale recording from an earlier session is stopped (and rescued)
    /// before the fresh one starts, so the fetch at workout end pulls THIS
    /// workout's beats only — skipping the backup because something is already
    /// recording would leave the workout streaming-only with the old file on
    /// the strap.
    ///
    /// That rescue can take minutes, so the workout may have stopped (and
    /// another started) by the time the strap starts recording. Finalize then
    /// saw no recording and skipped the stop, leaving the strap recording
    /// off-body and blocking the next session. The arming is tied to the
    /// workout that asked for it, and a recording that started after that
    /// workout ended is stopped at once.
    private func armDeviceInternalBackup(for workoutId: UUID) async {
        let recorder = core.strapRecorder
        do {
            try await recorder.link.whenFeatureUsable(
                .h10Recording, until: nil, while: { [weak self] in self?.isRecording(workoutId) == true },
                perform: { [weak self] in try await self?.armBackup(for: workoutId, recorder: recorder) }
            )
        } catch {
            guard lifecycle.phase == .recording else { return }
            debugLog("[Recorder.start] device-internal backup did NOT start (\(error.localizedDescription)) — workout is STREAMING ONLY, strap will be empty", level: .warning)
        }
    }

    /// Whether the workout that armed the backup is still the one recording.
    private func isRecording(_ workoutId: UUID) -> Bool {
        lifecycle.phase == .recording && lifecycle.currentSession?.id == workoutId
    }

    private func keepOrStopArmedBackup(for workoutId: UUID, recorder: StrapRecordingCoordinator) async {
        guard isRecording(workoutId) else {
            debugLog("[Recorder.start] device-internal backup armed after its workout ended — stopping it", level: .warning)
            await recorder.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
            return
        }
        lifecycle.deviceBackupArmedAt = Date()
    }

    /// `stillWanted` is asked before each destructive step, so a workout
    /// that ended meanwhile never has the strap cleared or started.
    private func armBackup(for workoutId: UUID, recorder: StrapRecordingCoordinator) async throws {
        try await Self.startH10Backup(recorder, while: { isRecording(workoutId) })
        await keepOrStopArmedBackup(for: workoutId, recorder: recorder)
    }

    private static func startH10Backup(_ recorder: StrapRecordingCoordinator, while stillWanted: () -> Bool) async throws {
        guard recorder.linkState.connectedDeviceType != .veritySense else { return }
        try await recorder.startFreshRecording(while: stillWanted)
        debugLog("[Recorder.start] device-internal backup started (H10)")
    }
}
