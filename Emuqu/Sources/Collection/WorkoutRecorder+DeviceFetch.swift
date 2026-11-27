import Foundation

// Finalize's side: fetching the strap's recording and merging it.

extension WorkoutRecorder {
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
    /// would be neither stopped nor downloaded and would keep recording
    /// off-body. The recording counts from the moment it was armed, which can
    /// be well into the workout (arming waits for the link, and may first
    /// clear an old recording); its own start places it on the workout's clock
    /// before the window bound and the merge, as crash recovery places it.
    /// Unshifted, every strap beat would sit that many seconds early and the
    /// merge's 50 ms duplicate check would keep both copies of the same beat.
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
        guard let recording = await core.strapRecorder.fetchRecordingIfAvailable(recordedSince: startDate),
              !recording.points.isEmpty
        else {
            debugLog("[Recorder.finalize] H10 fetch returned no points — using streaming only (\(streamingPoints.count) beats)")
            return streamingPoints
        }
        let onClock = recording.points(onClockOf: startDate, fallbackStart: lifecycle.deviceBackupArmedAt)
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
        let recorder = core.strapRecorder
        guard lifecycle.activeHRSource == .strap, lifecycle.deviceBackupArmedAt != nil || recorder.device.isRecordingOnDevice else { return false }
        recorder.beginTransfer()
        guard await recorder.reconnectForTransfer() else {
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
    /// CRITICAL: skipping the DOWNLOAD must NOT skip the STOP. Otherwise
    /// every high-density workout ends with the H10 internal recording
    /// running off-body for hours (the user removed the strap; it keeps
    /// recording, then blocks the next session as "strap used by another
    /// session"). Stopping is
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
            await core.strapRecorder.stopDeviceRecordingIfNeeded(streamHoldsIt: true)
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
    /// hit a `strapBusy` throw because `strapStream.isStreaming == true`.
    /// An accidental start the user leaves without saving has its backups
    /// retired here (`WorkoutSessionLifecycle.discardNotArchived`): leaving
    /// the summary that said it was not saved is the user's choice.
    ///
    /// Calling `stopStreaming()` here is safe — the HRR task is already
    /// holding any samples it captured before this point, so the data
    /// in the archive is whatever was recoverable in the time window
    /// the user gave us.
    ///
    /// Only this recorder's own stream is stopped (its start matches
    /// `ownedStrapStreamStart`). The summary can be dismissed long after the
    /// HRR window closed, from the Watch, while an overnight or quick reading
    /// started since is buffering on the same manager; stopping that stream
    /// would drop the rest of its beats.
    func acknowledgeFinished() {
        guard lifecycle.phase == .finished else { return }
        session.discardNotArchived()
        lifecycle.finishedSession = nil
        lifecycle.saveOutcome = nil
        lifecycle.phase = .idle
        let stream = core.strapStream
        guard stream.isStreaming else { return }
        guard let ownStart = lifecycle.ownedStrapStreamStart, stream.streamingStartTime == ownStart else {
            debugLog("[WorkoutRecorder] acknowledgeFinished — the strap is buffering for another session; leaving it running")
            return
        }
        _ = stream.stopStreaming()
        debugLog("[WorkoutRecorder] acknowledgeFinished — stopped lingering Polar stream")
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `WorkoutRecorder` and calls nothing on it, so none needs
// to be inside the type.

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
/// Time-bound to the workout window, each beat at its real start
/// (`BeatTimeline`): a Verity Sense recording's beat clock leaves out its
/// rejected intervals, so by `t_ms` its beats from after the stop still fit.
/// The beats are already on the workout's clock
/// (`StrapRecording.points(onClockOf:)` shifted them by the arming delay);
/// a 60 s tolerance absorbs the residual timing slack at either end.
///
/// This is also a paranoia guard for the case where
/// `clearAnyExistingExercises()` failed before this workout and the H10
/// still has unrelated samples (e.g. last night's overnight) attached to
/// the same fetch.
func boundedToWorkoutWindow(_ devicePoints: [RRPoint], startDate: Date, stopDate: Date) -> [RRPoint] {
    let workoutDurationMs = MillisecondOffset.between(stopDate, and: startDate, fallback: 0)
    let toleranceMs = WorkoutRecorder.DeviceFetchDecision.deviceWindowToleranceMs
    let bounded = zip(devicePoints, BeatTimeline.ms(devicePoints))
        .filter { $0.1 >= 0 && $0.1 <= workoutDurationMs + toleranceMs }
        .map(\.0)
    if bounded.count != devicePoints.count {
        debugLog("[Recorder.finalize] H10 fetch returned \(devicePoints.count) points, \(devicePoints.count - bounded.count) outside workout window — discarded")
    }
    return bounded
}
