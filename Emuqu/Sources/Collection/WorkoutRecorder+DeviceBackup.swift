import Foundation

// MARK: - Device-internal RR backup (H10)
//
// Split out of `WorkoutRecorder.swift`: that file sits hard against
// the 2,000-line SwiftLint error tier, and this section is the cleanest seam in
// it — a self-contained subsystem with its own lifecycle that nothing else in
// the recorder reaches into.

extension WorkoutRecorder {
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
        guard core.polarManager.connectedDeviceType != .veritySense else {
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
        let manager = core.polarManager
        do {
            try await manager.link.whenFeatureUsable(
                .h10Recording, until: nil, while: { [weak self] in self?.isRecording(workoutId) == true },
                perform: { [weak self] in try await self?.armBackup(for: workoutId, manager: manager) }
            )
        } catch {
            guard phase == .recording else { return }
            debugLog("[Recorder.start] device-internal backup did NOT start (\(error.localizedDescription)) — workout is STREAMING ONLY, strap will be empty", level: .warning)
        }
    }

    /// Whether the workout that armed the backup is still the one recording.
    private func isRecording(_ workoutId: UUID) -> Bool {
        phase == .recording && currentSession?.id == workoutId
    }

    private func keepOrStopArmedBackup(for workoutId: UUID, manager: PolarManager) async {
        guard isRecording(workoutId) else {
            debugLog("[Recorder.start] device-internal backup armed after its workout ended — stopping it", level: .warning)
            await manager.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
            return
        }
        deviceBackupArmedAt = Date()
    }

    /// `stillWanted` is asked before each destructive step, so a workout
    /// that ended meanwhile never has the strap cleared or started.
    private func armBackup(for workoutId: UUID, manager: PolarManager) async throws {
        try await Self.startH10Backup(manager, while: { isRecording(workoutId) })
        await keepOrStopArmedBackup(for: workoutId, manager: manager)
    }

    private static func startH10Backup(_ manager: PolarManager, while stillWanted: () -> Bool) async throws {
        guard manager.connectedDeviceType != .veritySense else { return }
        try await manager.recording.startFreshRecording(while: stillWanted)
        debugLog("[Recorder.start] device-internal backup started (H10)")
    }

    /// Result of the pure gate deciding whether workout finalize needs the
    /// H10 device-internal recording at all, or whether the BLE streaming
    /// buffer is already dense enough on its own.
    enum DeviceFetchDecision: Equatable {
        /// Streaming captured at least this fraction of expected beats →
        /// the device fetch would be pure waiting for a near-duplicate.
        static let skipFetchDensityThreshold = 0.95
        /// Mean RR must exceed this (ms) for the density estimate to be
        /// trusted. An integer mean RR ≤ 300 ms means avg HR ≥ 200 bpm —
        /// an artifact-dominated buffer, not a usable density baseline.
        static let minPlausibleAvgRRMs = 300
        /// Workouts at or under this many seconds always fetch — too little
        /// data for the density estimate to mean anything.
        static let minElapsedSecForDensityCheck: TimeInterval = 60
        /// Workout-window tolerance (ms) for bounding device-internal
        /// `t_ms` values once they are on the workout's clock — absorbs the
        /// residual timing slack. Used by the merge shell.
        static let deviceWindowToleranceMs: Int64 = 60_000

        /// Streaming density ≥ threshold — return the streaming buffer
        /// as-is. Payload feeds the shell's skip log line.
        case skipFetch(density: Double, expectedBeats: Double)
        /// Pull the device recording. `belowThresholdDensity` is non-nil
        /// when the density math ran and came in under the threshold (the
        /// shell logs it); nil when the check wasn't applicable (short
        /// workout, empty buffer, or implausible mean RR).
        case fetch(belowThresholdDensity: Double?)
    }

    /// Skip the H10 internal-recording fetch when the
    /// BLE streaming buffer already captured ≥95% of expected beats.
    /// The Polar firmware paces the exercise-data download at
    /// ~1-2 minutes per 30-min recording; the user perceives that
    /// wait as "workout takes forever to stop" because the
    /// "Finalizing…" spinner stays up the whole time. The device
    /// fetch exists to fill streaming gaps; when there
    /// are no gaps it's pure waiting for a near-duplicate stream.
    ///
    /// Expected beats = elapsed_sec × (avg_hr / 60). Average HR
    /// derived from the streaming buffer's mean RR (integer division,
    /// matching the original inline math).
    ///
    /// Pure: no clock, no BLE, no logging — the caller measures elapsed
    /// time and sums `rr_ms`, this decides `.skipFetch` vs `.fetch`.
    static func deviceFetchDecision(
        streamingPointCount: Int,
        elapsedSec: TimeInterval,
        summedRRMs: Int
    ) -> DeviceFetchDecision {
        guard elapsedSec > DeviceFetchDecision.minElapsedSecForDensityCheck,
              streamingPointCount > 0
        else { return .fetch(belowThresholdDensity: nil) }
        let avgRR = summedRRMs / streamingPointCount
        guard avgRR > DeviceFetchDecision.minPlausibleAvgRRMs else {
            return .fetch(belowThresholdDensity: nil)
        }
        let avgHR = 60_000.0 / Double(avgRR)
        let expectedBeats = elapsedSec * (avgHR / 60.0)
        let density = Double(streamingPointCount) / expectedBeats
        if density >= DeviceFetchDecision.skipFetchDensityThreshold {
            return .skipFetch(density: density, expectedBeats: expectedBeats)
        }
        return .fetch(belowThresholdDensity: density)
    }

    /// Fetch the H10's internal recording (if any) and merge with the
    /// BLE-streamed beats. Returns the streaming buffer untouched when
    /// no internal recording exists or the merge can't produce more
    /// data than streaming alone.
    ///
    /// A strap whose link dropped before the stop is reconnected first
    /// (bounded), the same as the overnight morning: without it the strap
    /// was neither stopped nor downloaded and kept recording off-body. The
    /// recording counts from the moment it was armed, which can be well into
    /// the workout (arming waits for the link, and may first clear an old
    /// recording); its own start places it on the workout's clock before the
    /// window bound and the merge, as crash recovery places it. Unshifted,
    /// every strap beat sat that many seconds early and the merge's 50 ms
    /// duplicate check kept both copies of the same beat.
    func mergeWorkoutRRWithDeviceFetch(
        session: HRVSession?,
        streamingPoints: [RRPoint],
        startDate: Date,
        stopDate: Date
    ) async -> [RRPoint] {
        guard await strapHoldsThisWorkout(),
              await shouldFetchDeviceRecording(streamingPoints: streamingPoints, startDate: startDate, stopDate: stopDate)
        else { return streamingPoints }
        debugLog("[Recorder.finalize] fetching H10 internal RR for workout merge…")
        guard let recording = await core.polarManager.fetchRecordingIfAvailable(recordedSince: startDate),
              !recording.points.isEmpty
        else {
            debugLog("[Recorder.finalize] H10 fetch returned no points — using streaming only (\(streamingPoints.count) beats)")
            return streamingPoints
        }
        let onClock = recording.points(onClockOf: startDate, fallbackStart: deviceBackupArmedAt)
        let bounded = boundedToWorkoutWindow(onClock, startDate: startDate, stopDate: stopDate)
        guard !bounded.isEmpty else {
            debugLog("[Recorder.finalize] no H10 points fell inside workout window — using streaming only (\(streamingPoints.count) beats)")
            return streamingPoints
        }
        return selectMergedWorkoutRR(
            streamingPoints: streamingPoints, bounded: bounded, session: session, startDate: startDate
        )
    }

    /// A strap workout whose backup was armed: the strap is brought back if
    /// the link dropped, so it can be stopped or downloaded at all.
    private func strapHoldsThisWorkout() async -> Bool {
        let manager = core.polarManager
        guard activeHRSource == .strap, deviceBackupArmedAt != nil || manager.isRecordingOnDevice else { return false }
        manager.beginTransfer()
        guard await manager.reconnectForTransfer() else {
            debugLogExternal("The strap didn't come back after the workout, so its own recording couldn't be stopped or read — using the live stream. The strap keeps recording until it is next connected, when the Record screen offers to recover it.", cause: .strap)
            return false
        }
        return true
    }

    /// Density gate is pure — see `deviceFetchDecision` for the
    /// rationale (skip the slow H10 download when streaming
    /// already captured ≥95% of expected beats). This shell measures
    /// the window, sums the buffer, and logs the decision.
    ///
    /// CRITICAL: skipping the DOWNLOAD must NOT skip the
    /// STOP. Field logs showed every high-density workout end with this
    /// skip and leave the H10 internal recording running off-body for
    /// hours (the user removed the strap; it kept recording, then blocked
    /// the next session as "strap used by another session"). Stopping is
    /// a fast BLE op, decoupled from the download we're rightly skipping.
    private func shouldFetchDeviceRecording(
        streamingPoints: [RRPoint],
        startDate: Date,
        stopDate: Date
    ) async -> Bool {
        switch Self.deviceFetchDecision(
            streamingPointCount: streamingPoints.count,
            elapsedSec: stopDate.timeIntervalSince(startDate),
            summedRRMs: streamingPoints.reduce(0) { $0 + $1.rr_ms }
        ) {
        case let .skipFetch(density, expectedBeats):
            debugLog("[Recorder.finalize] skipping H10 fetch — streaming density \(String(format: "%.0f%%", density * 100)) (\(streamingPoints.count) beats / \(Int(expectedBeats)) expected) — saves ~30-60s of BLE wait")
            await core.polarManager.stopDeviceRecordingIfNeeded(streamHoldsIt: true)
            return false
        case let .fetch(belowThresholdDensity):
            if let density = belowThresholdDensity {
                debugLog("[Recorder.finalize] streaming density \(String(format: "%.0f%%", density * 100)) below 95% threshold — pulling H10 internal recording to fill gaps")
            }
            return true
        }
    }

    /// Reset to idle after the user dismisses the post-workout summary.
    ///
    /// Also stops the Polar streaming session if it's still alive — the
    /// post-stop HRR capture task keeps the stream open for up to 120 s
    /// to sample HR at +60 / +120 s, which means a user who closes the
    /// summary and immediately starts another workout would otherwise
    /// hit a `strapBusy` throw because `polarManager.isStreaming == true`.
    /// Calling `stopStreaming()` here is safe — the HRR task is already
    /// holding any samples it captured before this point, so the data
    /// in the archive is whatever was recoverable in the time window
    /// the user gave us. (User-facing complaint: "the strap
    /// is currently used by another session — that session was already
    /// ended and discarded.")
    func acknowledgeFinished() {
        if phase == .finished {
            lifecycle.finishedSession = nil
            lifecycle.phase = .idle
            if core.polarManager.isStreaming {
                _ = core.polarManager.stopStreaming()
                debugLog("[WorkoutRecorder] acknowledgeFinished — stopped lingering Polar stream")
            }
        }
    }
}

// MARK: - File-scope helpers
//
// Kept out of WorkoutRecorder. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

@MainActor
private func selectMergedWorkoutRR(
    streamingPoints: [RRPoint],
    bounded: [RRPoint],
    session: HRVSession?,
    startDate: Date
) -> [RRPoint] {
    let sessionId = (session ?? HRVSession(startDate: startDate, sessionType: .workout)).id
    guard let selection = DataSourceSelector.selectBestSource(
        streamingPoints: streamingPoints, internalPoints: bounded,
        sessionId: sessionId, sessionStart: startDate
    ) else {
        debugLog("[Recorder.finalize] DataSourceSelector returned nil — keeping streaming buffer (\(streamingPoints.count) beats)")
        return streamingPoints
    }
    debugLog("[Recorder.finalize] workout RR merged: streaming=\(streamingPoints.count) device=\(bounded.count) → \(selection.points.count) (\(selection.normalizedSource))")
    return selection.points
}

@MainActor
/// Time-bound to the workout window. `t_ms` is already on the workout's
/// clock (`StrapRecording.points(onClockOf:)` shifted it by the arming
/// delay); a 60 s tolerance absorbs the residual timing slack at either end.
///
/// This is also a paranoia guard for the case where
/// `clearAnyExistingExercises()` failed before this workout and the H10
/// still has unrelated samples (e.g. last night's overnight) attached to
/// the same fetch.
private func boundedToWorkoutWindow(_ devicePoints: [RRPoint], startDate: Date, stopDate: Date) -> [RRPoint] {
    let workoutDurationMs = MillisecondOffset.between(stopDate, and: startDate, fallback: 0)
    let toleranceMs = WorkoutRecorder.DeviceFetchDecision.deviceWindowToleranceMs
    let bounded = devicePoints.filter { $0.t_ms >= 0 && $0.t_ms <= workoutDurationMs + toleranceMs }
    if bounded.count != devicePoints.count {
        debugLog("[Recorder.finalize] H10 fetch returned \(devicePoints.count) points, \(devicePoints.count - bounded.count) outside workout window — discarded")
    }
    return bounded
}
