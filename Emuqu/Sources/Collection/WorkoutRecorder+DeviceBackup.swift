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
    func startDeviceInternalBackupIfPossible() {
        guard core.polarManager.connectedDeviceType != .veritySense else {
            debugLog("[Recorder.start] device-internal backup skipped — Verity Sense can't record + stream simultaneously")
            return
        }
        Task { [weak self] in
            await self?.armDeviceInternalBackup()
        }
    }

    /// A stale recording from an earlier session is stopped (and rescued)
    /// before the fresh one starts, so the fetch at workout end pulls THIS
    /// workout's beats only — skipping the backup because something is already
    /// recording would leave the workout streaming-only with the old file on
    /// the strap.
    private func armDeviceInternalBackup() async {
        let manager = core.polarManager
        do {
            try await manager.link.whenFeatureUsable(
                .h10Recording, until: nil, while: { [weak self] in self?.phase == .recording },
                perform: { [weak self] in
                    try await Self.startH10Backup(manager)
                    self?.deviceBackupArmedAt = Date()
                }
            )
        } catch {
            guard phase == .recording else { return }
            debugLog("[Recorder.start] device-internal backup did NOT start (\(error.localizedDescription)) — workout is STREAMING ONLY, strap will be empty", level: .warning)
        }
    }

    private static func startH10Backup(_ manager: PolarManager) async throws {
        guard manager.connectedDeviceType != .veritySense else { return }
        try await manager.recording.startFreshRecording()
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
        /// `t_ms` values — absorbs the small lag between `startStreaming()`
        /// and `startRecording()` completing. Used by the merge shell.
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
    /// `startDate`/`stopDate` define the workout window. The internal
    /// recording's `t_ms` is relative to the moment `startRecording()`
    /// ran — which lines up with `startDate` because we start the
    /// device recording immediately after `startStreaming()`.
    func mergeWorkoutRRWithDeviceFetch(
        session: HRVSession?,
        streamingPoints: [RRPoint],
        startDate: Date,
        stopDate: Date
    ) async -> [RRPoint] {
        guard activeHRSource == .strap, core.polarManager.isRecordingOnDevice,
              await shouldFetchDeviceRecording(streamingPoints: streamingPoints, startDate: startDate, stopDate: stopDate)
        else { return streamingPoints }
        debugLog("[Recorder.finalize] fetching H10 internal RR for workout merge…")
        guard let devicePoints = await core.polarManager.fetchExerciseDataQuick(recordedSince: startDate),
              !devicePoints.isEmpty
        else {
            debugLog("[Recorder.finalize] H10 fetch returned no points — using streaming only (\(streamingPoints.count) beats)")
            return streamingPoints
        }
        let bounded = boundedToWorkoutWindow(
            onWorkoutClock(devicePoints, startDate: startDate), startDate: startDate, stopDate: stopDate
        )
        guard !bounded.isEmpty else {
            debugLog("[Recorder.finalize] no H10 points fell inside workout window — using streaming only (\(streamingPoints.count) beats)")
            return streamingPoints
        }
        return selectMergedWorkoutRR(
            streamingPoints: streamingPoints, bounded: bounded, session: session, startDate: startDate
        )
    }

    /// The strap's recording counts from the moment it was armed, which can
    /// be well into the workout: arming waits for the link, and may first
    /// clear an old recording. Its beats are moved onto the workout's clock
    /// before they meet the streamed ones. Unshifted, the merge placed every
    /// strap beat that many seconds early, and its duplicate check, which
    /// allows 50 ms, kept both copies of the same beat.
    private func onWorkoutClock(_ devicePoints: [RRPoint], startDate: Date) -> [RRPoint] {
        guard let armed = deviceBackupArmedAt else { return devicePoints }
        let offsetMs = MillisecondOffset.between(armed, and: startDate, fallback: 0)
        guard offsetMs > 0 else { return devicePoints }
        debugLog("[Recorder.finalize] H10 recording armed \(offsetMs / 1_000)s into the workout — shifting its beats onto the workout clock")
        return devicePoints.map { $0.shifted(by: offsetMs) }
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
            await core.polarManager.stopDeviceRecordingIfNeeded()
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
/// Time-bound to the workout window. `t_ms` is relative to the
/// recording start, which we triggered right after streaming
/// start. A 60 s tolerance absorbs the small lag between
/// `startStreaming()` and `startRecording()` completing.
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
