import Foundation
import UIKit

// The stop and finalize path. `stop()` and its helpers are the second half of
// the recorder's lifecycle: tear down live services, merge the RR buffers,
// archive, and hand off to the detached HRR capture. The two halves share
// stored state but no logic.

extension WorkoutRecorder {

    /// Stop the session, archive immediately, and transition to `.finished`.
    ///
    /// Critical UX point: the summary must appear **instantly** when the user
    /// taps Stop. HRR capture takes up to 120 seconds, so it never runs on
    /// that path.
    ///
    /// Flow:
    ///   1. Stop the strap + location immediately.
    ///   2. Build + archive the session with whatever we have.
    ///   3. Show the summary (state = .finished).
    ///   4. HRR capture runs in a DETACHED background task; when samples
    ///      arrive it re-archives the session with hrrSamples populated,
    ///      and the notifier bumps the archive version so the summary view
    ///      can refresh if still open.
    ///
    /// The finalize is entry-stamped. Combined
    /// with the per-step `[Recorder.stop] step=…` lines and the
    /// "[WorkoutRecorder] archived session …" line at the end of
    /// `archive()`, we get a complete "where did the time go" trail in the
    /// debug log, down to the step a hang is in. Without this stamp, a hang
    /// inside the very first synchronous call (cancelling sensors, tearing down
    /// the strap) is invisible.
    ///
    /// The workout correlation scope is closed LAST. Everything before it —
    /// the merge, the archive write, the sync hand-off — belongs to this
    /// workout and reads better tagged with it. The detached HRR task
    /// deliberately outlives the scope: it can run for two minutes after the
    /// user has moved on, and tagging its lines as part of a finished workout
    /// would misrepresent when they happened.
    ///
    /// The finalize runs under a `BackgroundTaskAssertion`: once `stop()` tears
    /// the session down, nothing keeps the app scheduled, leaving the
    /// training-load and archive work with no background budget, and iOS can
    /// SIGKILL the app seconds after End. The assertion asks for the full
    /// budget (~30 s); its expiration handler ends the task, so running out
    /// suspends the app rather than getting it killed. A free no-op in the
    /// foreground.
    ///
    /// Stopped while paused (by hand or by auto-pause), the pause ends at the
    /// stop, so it is saved with the others and Apple Health counts the
    /// paused tail as paused, not as moving.
    ///
    /// `requestedStop` is when the user ended the workout, for an End that
    /// can reach the phone after it (a Watch End queued out of range); nil
    /// ends it now. The workout ends at that time, held between its start
    /// and now (`stopDate(requested:startedAt:now:)`), and what was recorded
    /// after it is left out (`settleStopTime`).
    func stop(requestedStop: Date? = nil) async {
        guard case .recording = lifecycle.phase else { return }
        let finalizeStartedAt = Date()
        debugLog("[Recorder.stop] entry — phase flipping to .finalizing")
        let bgTask = BackgroundTaskAssertion(name: "WorkoutRecorder.stop")
        defer { bgTask.end() }
        lifecycle.phase = .finalizing
        tearDownLiveWorkoutServices()
        let stopDate = Self.stopDate(requested: requestedStop, startedAt: lifecycle.sessionStartDate, now: finalizeStartedAt)
        let cut = settleStopTime(stopDate, now: finalizeStartedAt)
        let endHR = heartRateAtStop(stopDate: stopDate, now: finalizeStartedAt)
        capture.collectedPoints = await gatherFinalRRPoints(stopDate: stopDate, cut: cut)
        cancelStrapSubscriptionsAfterStop()
        let finished = await runFinalize(
            rrPoints: capture.collectedPoints, stopDate: stopDate, startedAt: finalizeStartedAt
        )
        await settleAfterFinalize(finished: finished.session, saveOutcome: finished.saveOutcome, startedAt: finalizeStartedAt)
        launchHRRCaptureAndRearchive(stopDate: stopDate, endHR: endHR, finished: finished.session)
        lifecycle.endWorkoutCorrelation()
    }

    /// The reference heart-rate recovery is measured from: the rate when
    /// exercise stopped, not the session's highest. Cole 1999 (NEJM), the
    /// source of the 12 bpm threshold, takes the rate at peak exercise of a
    /// maximal test, which is where that test ends; after intervals and a
    /// cool-down the session maximum was minutes earlier, and recovery from
    /// it read as an 80 bpm drop when the last minute fell 15.
    private func heartRateAtStop(stopDate: Date, now: Date) -> Int {
        let readingTimes = [signals.lastStrapHRAt, capture.watchRouted.lastAt, watchBridge.latestWatchHRAt]
        return Self.heartRateAtStop(
            live: workoutHR.currentHR,
            lastSampled: capture.workoutSamples.last(where: { $0.heartRate != nil })?.heartRate,
            lastReadingAt: readingTimes.compactMap { $0 }.max(),
            stopDate: stopDate,
            now: now
        )
    }

    /// How old the newest heart-rate reading may be at Stop and still count
    /// as the rate at Stop: the silence after which the recorder itself stops
    /// treating the strap as live (`HRArbitration.wristFallbackSilenceSec`,
    /// 10 s). The strap sends a reading about every second and the Watch's
    /// wrist HR every few seconds, so a live source is always inside it; the
    /// heart rate falls fastest in the first seconds after exercise, so a
    /// reading much older than that is not the rate at Stop.
    nonisolated static let stopHRMaxAgeSec: TimeInterval = WorkoutTicker.HRArbitration.wristFallbackSilenceSec

    /// The rate at Stop: the live reading, else the last per-second sample
    /// with one, but only while some source (the strap, the Watch-routed
    /// strap, the Watch's wrist HR) sent a reading within `stopHRMaxAgeSec`
    /// of Stop. Otherwise 0, which skips the capture: a recovery measured
    /// from a rate the strap stopped sending minutes earlier is not one.
    /// Also 0 for a stop dated more than `stopHRMaxAgeSec` before `now` (a
    /// Watch End that arrived late): the rate on display is the one at
    /// arrival, and the recovery window after the stop has already passed.
    nonisolated static func heartRateAtStop(live: Int?, lastSampled: Int?, lastReadingAt: Date?, stopDate: Date, now: Date) -> Int {
        guard now.timeIntervalSince(stopDate) <= stopHRMaxAgeSec else {
            debugLog("[Recorder.stop] stop dated \(Int(now.timeIntervalSince(stopDate))) s ago: heart-rate recovery is not measured")
            return 0
        }
        guard let lastReadingAt, stopDate.timeIntervalSince(lastReadingAt) <= stopHRMaxAgeSec else {
            debugLog("[Recorder.stop] no heart rate within \(Int(stopHRMaxAgeSec)) s of Stop: heart-rate recovery is not measured")
            return 0
        }
        if let live, live > 0 { return live }
        return lastSampled ?? 0
    }

    /// Post-finalize housekeeping: battery accounting, breadcrumb archive,
    /// state reset, and the flip to `.finished` that reveals the summary,
    /// which shows `saveOutcome` (a workout not saved yet says so).
    private func settleAfterFinalize(finished: HRVSession, saveOutcome: WorkoutSaveOutcome, startedAt: Date) async {
        await chargeStrapBatteryUsage()
        archiveBreadcrumbTrailIfNeeded(finished: finished)
        resetRecorderStateAfterStop()
        lifecycle.finishedSession = finished
        lifecycle.saveOutcome = saveOutcome
        lifecycle.phase = .finished
        debugLog("[Recorder.stop] phase=.finished save=\(saveOutcome) (total elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
        disconnectFootPodPostWorkout()
    }

    /// Pull the H10's internal exercise recording for this workout and use
    /// it to fill BLE-streaming gaps, through the same composite path the
    /// overnight pipeline uses (DataSourceSelector). Strap source only, and
    /// only when this workout armed the strap's backup — a Verity Sense
    /// can't record and stream at once, so none is armed there. Only a
    /// recording that started after the workout did is taken, and its beats
    /// are moved onto the workout's clock by the recording's own start; the
    /// window bound inside the merge drops anything past the workout's end.
    ///
    /// For a stop dated earlier than it arrived (`cut`), the streamed beats
    /// after the stop are left out (`WorkoutAnalyzer.rrPoints(_:endingAt:sessionStart:)`).
    private func gatherFinalRRPoints(stopDate: Date, cut: Bool) async -> [RRPoint] {
        let startDate = lifecycle.sessionStartDate ?? stopDate
        let streamed = snapshotAndMergeRRBuffers()
        return await mergeWorkoutRRWithDeviceFetch(
            session: lifecycle.currentSession,
            streamingPoints: cut ? WorkoutAnalyzer.rrPoints(streamed, endingAt: stopDate, sessionStart: startDate) : streamed,
            startDate: startDate,
            stopDate: stopDate
        )
    }

    /// `hrrSamples` is empty here — it's populated asynchronously after the
    /// archive by `launchHRRCaptureAndRearchive`.
    private func runFinalize(
        rrPoints: [RRPoint], stopDate: Date, startedAt: Date
    ) async -> (session: HRVSession, saveOutcome: WorkoutSaveOutcome) {
        debugLog("[Recorder.stop] step=finalizeSession (rrPoints=\(rrPoints.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
        let finished = await finalizer.finalizeSession(rrPoints: rrPoints, stopDate: stopDate, hrrSamples: [])
        noteOwnStrapDownloadSaved(finished.saveOutcome, stopDate: stopDate)
        // Used once, by this finalize.
        capture.wristHROffsets = []
        lifecycle.liveSnapshotAtStop = nil
        debugLog("[Recorder.stop] step=finalizeSession done (elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
        return finished
    }

    /// The strap recording downloaded for a saved strap workout is in the
    /// archive. A Watch or no-HR workout armed none: a recording downloaded
    /// since its start is another session's (a strap-only nap beside it),
    /// still to be saved, and marking it saved let the next arming clear the
    /// strap's only copy.
    func noteOwnStrapDownloadSaved(_ outcome: WorkoutSaveOutcome, stopDate: Date) {
        guard outcome == .saved, lifecycle.activeHRSource == .strap else { return }
        core.strapRecorder.device.noteDownloadsSaved(recordedSince: lifecycle.sessionStartDate ?? stopDate)
    }

    /// stop() — teardown fan-out: ticker, GPS, pedometer, Zwift advertisement, Watch session, live broker, AI cache, cue audio session, diagnostics sampler.
    ///
    /// Voice conversation lifecycle is INDEPENDENT of workout
    /// lifecycle. The recorder never starts voice (the user opens
    /// it manually via the chat mic button), so it shouldn't stop
    /// it either. Tearing voice down here would cut the user off
    /// mid-sentence while they debrief the workout. The user
    /// closes voice when they're done.
    func tearDownLiveWorkoutServices() {
        ticker.stopTicker()
        startedLocation?.stopTracking()
        pedometer.stop()
        // Stop the BLE peripheral advertisement so we don't continue to
        // appear as a sensor for trainer apps after the workout ends.
        services.zwiftPeripheralBroadcaster.stopBroadcasting()
        // End the Watch's parallel HKWorkoutSession so the ring on the wrist
        // closes (no duplicate workout — the Watch never finalises a
        // standalone HKWorkout; the phone writes the canonical one).
        watchBridge.stopWatchWorkoutSession()
        // Clear the live-workout broker so the AI context no longer includes
        // stale "you're still running" state after the workout ends. Its last
        // snapshot is kept first for the session's `aiContext`.
        let broker = services.liveWorkoutBroker
        lifecycle.liveSnapshotAtStop = broker.currentSnapshot()
        broker.clear()
        releaseWorkoutCueAudioAndDiagnostics()
    }

    /// Leave the audio session inactive once the workout is over: with no cue
    /// speaking it is deactivated now, unless a voice chat or the breathing
    /// guide still holds it; a cue still speaking deactivates it when it
    /// finishes. Then stop the diagnostics sampler started in `start()` so it
    /// doesn't keep sampling memory in the foreground app indefinitely.
    private func releaseWorkoutCueAudioAndDiagnostics() {
        services.backgroundAudioManager.stopBackgroundAudio()
        services.systemDiagnosticsManager.stopSamplingAfterRecording(for: .workout)
    }

    /// stop() — RR snapshot: streaming buffer + Watch-routed merge (sorted by t_ms).
    ///
    /// Snapshots the RR buffer for analysis WITHOUT stopping the Polar
    /// stream. Calling stopStreaming() here makes the detached HRR capture
    /// Tier 1 fail its `isStreaming` check, which leaves the "Heart Rate
    /// Recovery" card at "capturing…" indefinitely on strap-only sessions.
    /// Streaming stays alive across the 60-s HRR window and only stops at
    /// the very end of the capture task.
    ///
    /// Watch and none sources never started a stream; the snapshot is skipped.
    ///
    /// Also merges in any RR samples that arrived via the
    /// Watch direct-strap fallback path (`capture.watchRouted.points`), sorted by
    /// t_ms so a workout that bounced between iPhone-paired and Watch-routed
    /// strap connections still produces a single coherent RR series.
    func snapshotAndMergeRRBuffers() -> [RRPoint] {
        let merged = WorkoutRRMerge.merged(
            source: lifecycle.activeHRSource,
            streaming: core.strapStream.streamedRRPoints,
            watchRouted: capture.watchRouted.points
        )
        if !capture.watchRouted.points.isEmpty {
            debugLog("[Recorder.finalize] merged \(capture.watchRouted.points.count) Watch-routed RR points (total now \(merged.count))")
        }
        return merged
    }

    /// stop() — cancels the HR subscription and clears the strap notice.
    func cancelStrapSubscriptionsAfterStop() {
        ticker.stopObservingHeartRate()
        lifecycle.strapNotice = nil
    }

    /// stop() — charges the strap battery-usage counter with this workout's elapsed hours (strap source only).
    func chargeStrapBatteryUsage() async {
        // Charge the strap's battery-usage counter with this workout's
        // elapsed time. Only when the workout actually used the strap —
        // .watch / .none sources don't drain the H10. Captured before the
        // reset below so the value isn't lost.
        if lifecycle.activeHRSource == .strap {
            let workoutHoursForBattery = Double(lifecycle.elapsedSeconds) / 3600.0
            await MainActor.run {
                core.strapBattery.recordRecordingHours(workoutHoursForBattery)
            }
        }
    }

    /// stop() — archives the GPS track as a breadcrumb trail for GPS sports.
    func archiveBreadcrumbTrailIfNeeded(finished: HRVSession) {
        // Auto-archive the workout's GPS track as a
        // breadcrumb trail BEFORE the location manager is reset. The
        // user can later say "lead me back to where I parked for my
        // morning run" and the AI's `directions.routeTo origin` will
        // find the workout's start fix even if Get Me Back was never
        // explicitly engaged. Sport-name labelled, dated. Indoor
        // workouts (no GPS) skip this — empty track produces nothing
        // useful.
        if let sport = finished.workoutMetadata?.sport,
           sport.usesGPS {
            aiContext.archiveWorkoutTrackAsBreadcrumbTrail(
                track: location.track,
                sport: sport,
                start: finished.startDate,
                sessionId: finished.id
            )
        }
    }

    /// stop() — clears per-workout recorder state after finalize.
    func resetRecorderStateAfterStop() {
        lifecycle.currentSession = nil
        lifecycle.sessionStartDate = nil
        lifecycle.elapsedSeconds = 0
        workoutHR.reset()
        motion.reset()
        capture.lastIngestedPointCount = 0
        startedLocation?.reset()
        pedometer.reset()
        lifecycle.targetZone = nil
        intervalController.clear()
    }

    /// stop() — post-workout foot-pod disconnect (strap stays up for HRR).
    func disconnectFootPodPostWorkout() {
        // Secondary-sensor cleanup: the foot pod goes after the exercise,
        // the strap stays for HRR. Footpod doesn't participate in HRR
        // (cadence + power are session-only), so we drop it the moment
        // recording phase is `.finished`. The strap stays connected
        // through the HRR window — the detached HRR-capture task
        // below tears it down when the +120 s window completes.
        // The recorder's own foot-pod manager (injected at init), the one
        // the workout read from.
        services.concept2Manager.holdLinkForWorkout(false)
        footPod.holdLinkForWorkout(false)
        if footPod.connectionState == .connected || footPod.connectionState == .connecting {
            debugLog("[Recorder.stop] step=footpod.disconnect (post-workout)")
            footPod.disconnect()
        }
    }

    /// stop() — builds the HRR capture service and launches the detached capture/re-archive task (body in `captureHRRAndRearchive`).
    ///
    /// Background HRR capture. The sheet is already showing the summary
    /// at this point; when samples arrive we re-archive so the numbers
    /// appear on next view refresh. If the user dismisses the summary
    /// before HRR completes, the data is still written to history.
    ///
    /// Captures at +60s AND +120s — the clinical HRR literature values
    /// BOTH markers (1-min drop is autonomic reactivation; 2-min drop
    /// indicates broader recovery).
    ///
    /// Priority is `.userInitiated` rather than `.background`. Background
    /// tasks get aggressively throttled / suspended for 60-120 s
    /// waits, which makes HRR capture silently fail whenever iOS
    /// decides to deprioritise it (user-visible as "no signal" in
    /// the summary even when the strap was clearly still producing
    /// beats). `.userInitiated` tells the scheduler this work
    /// directly maps to a user-visible number they're waiting for.
    ///
    /// The strap's tier reads only this workout's own stream (the start it
    /// recorded, `ownedStrapStreamStart`): a Watch workout has none, and a
    /// stream started since (the next workout, a quick reading) is another
    /// session's heart rate, not this one's recovery.
    func launchHRRCaptureAndRearchive(stopDate: Date, endHR: Int, finished: HRVSession) {
        let ownStreamStart = lifecycle.activeHRSource == .strap ? lifecycle.ownedStrapStreamStart : nil
        let captureService = HRRCaptureService(
            strapLink: core.strapLink, strapStream: core.strapStream,
            ownStreamStart: ownStreamStart,
            access: core.healthAccess,
            heartRate: core.heartRate,
            captureWindowSec: 120
        )
        let sessionId = finished.id
        let archive = core.archive
        let strap = lifecycle.activeHRSource == .strap
            ? StrapAfterHRR(stream: core.strapStream, recording: core.strapRecording, discovery: core.strapDiscovery, streamStart: ownStreamStart) : nil
        Task.detached(priority: .userInitiated) {
            await self.captureHRRAndRearchive(
                captureService: captureService, stopDate: stopDate, endHR: endHR,
                strap: strap, archive: archive, sessionId: sessionId
            )
        }
    }

    /// stop() — body of the detached HRR-capture closure: capture samples, tear down the strap stream, re-archive with hrrSamples, fire the voice interjection + optional Coach Report.
    ///
    /// The write-back always happens, even when capture produced an empty
    /// array — that tells the UI "we tried and got nothing" instead of leaving
    /// the HRR card stuck on "capturing…" forever. An empty array is
    /// a meaningful signal (strap disconnected in the window, or no
    /// Watch HR samples for the minute after stop). When the archive copy
    /// cannot take them (the update throws, or the session is not in the
    /// archive) the samples still reach the summary on screen
    /// (`showUnsavedHRR`), so the card never stays on "capturing…".
    /// `strap` is nil when the workout's heart rate did not come from the
    /// strap; otherwise it is released once the samples are in.
    nonisolated private func captureHRRAndRearchive(
        captureService: HRRCaptureService,
        stopDate: Date,
        endHR: Int,
        strap: StrapAfterHRR?,
        archive: SessionArchive,
        sessionId: UUID
    ) async {
        let captured = await captureService.captureHRR(stopDate: stopDate, stopHR: endHR)
        let nextStart = await MainActor.run { self.startOfWorkout(after: sessionId) }
        let samples = Self.hrrSamples(captured, stopDate: stopDate, before: nextStart)
        if let strap {
            await releaseStrapAfterHRR(strap)
        }
        guard let finalSession = Self.rearchiveLoggingFailure(samples, archive: archive, sessionId: sessionId) else {
            await MainActor.run { self.showUnsavedHRR(samples, sessionId: sessionId) }
            return
        }
        await MainActor.run {
            self.announceHRRAndStageReport(samples: samples, finalSession: finalSession)
        }
        debugLog("[WorkoutRecorder] HRR capture complete: \(samples.count) samples")
    }

    /// The start of a workout begun after `sessionId` stopped, recording or
    /// already finished; nil when none has.
    @MainActor
    func startOfWorkout(after sessionId: UUID) -> Date? {
        let later = [lifecycle.currentSession, lifecycle.finishedSession].compactMap { $0 }
        return later.first { $0.id != sessionId }?.startDate
    }

    /// The samples taken before the next workout began. The Watch's heart
    /// rate in the minutes after a Stop is the next workout's exertion once
    /// that workout has started, not this one's recovery.
    nonisolated static func hrrSamples(_ samples: [HRRSample], stopDate: Date, before nextStart: Date?) -> [HRRSample] {
        guard let nextStart else { return samples }
        return samples.filter { stopDate.addingTimeInterval(TimeInterval($0.offsetSec)) < nextStart }
    }

    /// What the HRR capture lets go of once its window closes: the strap
    /// workout's own stream (by the start it recorded), and the link when
    /// nothing else uses it.
    struct StrapAfterHRR: Sendable {
        let stream: StrapStreamSession
        let recording: StrapRecordingState
        let discovery: StrapDiscoveryCoordinator
        let streamStart: Date?
    }

    /// `rearchiveWithHRR` with each way it can come back empty logged: nil
    /// when the update threw or the session is not in the archive.
    nonisolated private static func rearchiveLoggingFailure(
        _ samples: [HRRSample],
        archive: SessionArchive,
        sessionId: UUID
    ) -> HRVSession? {
        do {
            guard let updated = try rearchiveWithHRR(samples, archive: archive, sessionId: sessionId) else {
                debugLog("[WorkoutRecorder] HRR capture complete but the session is not in the archive — shown, not saved")
                return nil
            }
            return updated
        } catch {
            debugLog("[WorkoutRecorder] HRR post-archive update failed: \(error)", level: .warning)
            return nil
        }
    }

    /// HRR samples the archive did not take still reach the summary, if it
    /// is still showing this session, and the copy kept for a save retry.
    @MainActor
    private func showUnsavedHRR(_ samples: [HRRSample], sessionId: UUID) {
        session.keepHRRSamples(samples, for: sessionId)
        guard var shown = lifecycle.finishedSession, shown.id == sessionId else { return }
        shown.workoutMetadata?.hrrSamples = samples
        lifecycle.finishedSession = shown
    }

    /// The session is re-bound to a `let` before it leaves here so Swift 6
    /// strict concurrency doesn't warn about a `var` being captured by the
    /// MainActor hop closure — `HRVSession` is a Codable value type, so the
    /// rebind is a plain copy.
    nonisolated private static func rearchiveWithHRR(
        _ samples: [HRRSample],
        archive: SessionArchive,
        sessionId: UUID
    ) throws -> HRVSession? {
        guard archive.store.exists(sessionId) else { return nil }
        var updated: HRVSession?
        // In place, under the archive lock, so the Health export stamp
        // written meanwhile on another thread is kept.
        try archive.update(sessionId) {
            $0.workoutMetadata?.hrrSamples = samples
            updated = $0
        }
        return updated
    }

    /// Now that HRR capture is done, finally tear down the strap
    /// stream. Doing it here (rather than at stop()) is what makes
    /// Tier 1 actually work — the capture loop needs
    /// `strapStream.isStreaming == true` to sample HR at +60s / +120s.
    ///
    /// The strap's BLE connection is released
    /// now that HRR is captured, even if voice chat is going. The
    /// chat continues without live HR (the AI handles
    /// "no current HR" gracefully via the missingReason
    /// envelope on `workout.live.hr.current`), and the
    /// user's strap battery stops draining. They can
    /// re-pair next session via the auto-reconnect at
    /// workout start.
    ///
    /// Not when another workout has started inside the capture window: that
    /// workout's session is the one buffering now, and stopping it here would
    /// end its heart rate a couple of minutes in. Nor when the live stream is
    /// not this workout's (its start differs from `workoutStreamStart`): a
    /// second workout that started and already finished inside the window is
    /// in its own HRR capture, and an RRCollector overnight or quick reading
    /// started meanwhile is buffering on the same manager.
    ///
    /// The link is released only when nothing else uses the strap
    /// (`StrapStreamSession.mayReleaseLink`): a strap-only recording or a
    /// download started after the summary was dismissed needs it, and a
    /// recording whose stop was never confirmed still has to be stopped.
    @MainActor
    func releaseStrapAfterHRR(_ strap: StrapAfterHRR) {
        guard lifecycle.phase != .recording, lifecycle.phase != .finalizing else {
            debugLog("[WorkoutRecorder] HRR window closed during a new workout — leaving the strap session running")
            return
        }
        if strap.stream.isBuffering(startedAt: strap.streamStart) { _ = strap.stream.stopStreaming() }
        guard strap.stream.mayReleaseLink(after: strap.streamStart, recording: strap.recording) else {
            debugLog("[WorkoutRecorder] HRR window closed while another session uses the strap, leaving it linked")
            return
        }
        strap.discovery.disconnect()
    }

    /// Auto-interject the HRR summary when the capture window
    /// closes, then stage the auto Coach Report.
    ///
    /// A second workout can start, and even finish, inside the 120 s capture
    /// window. The summary on screen is replaced only when it is this
    /// session's, and the result is not spoken over another workout.
    @MainActor
    private func announceHRRAndStageReport(samples: [HRRSample], finalSession: HRVSession) {
        let summaryShowsThisSession = lifecycle.finishedSession?.id == finalSession.id
        if summaryShowsThisSession { lifecycle.finishedSession = finalSession }
        let anotherWorkoutOwnsTheScreen = lifecycle.phase == .recording || lifecycle.phase == .finalizing
            || (lifecycle.finishedSession != nil && !summaryShowsThisSession)
        if !anotherWorkoutOwnsTheScreen { speakHRRInterjection(samples: samples) }
        // Auto Coach Report. With HRR in
        // the session, generate the comprehensive Markdown
        // report and stage an email draft. The chat tab's
        // existing email-bridge sheet picks it up; for
        // users not on the chat tab, the EmuquApp
        // root observer also catches it. The toggle gates the
        // auto-fire; on-demand generation from the post-summary
        // button always works regardless.
        guard settingsProvider().enableAutoCoachReport else { return }
        Self.scheduleCoachReportEmail(for: finalSession, settings: settingsProvider(), services: services)
    }

    /// Voice path enqueues if chat is busy (the trigger queue). Skipped
    /// when we got nothing — silence is more honest than narrating an empty
    /// result.
    ///
    /// Bake the ACTUAL HRR numbers into the prompt
    /// instead of telling the model to fetch them. This
    /// interjection runs through the voice controller's
    /// single-turn path (startAIInterjectionStream), which by
    /// design IGNORES tool calls AND gets an empty context
    /// snapshot once the session has ended — the
    /// contextSnapshotProvider keys off `currentSession`, which
    /// stop() cleared ~60–120 s earlier. A "look it up via
    /// the workout.most_recent + session.* tools" wording leaves
    /// the model with no way to see the value, so it announces "no
    /// data" even when Tier-1 capture succeeded. Pass the figures inline;
    /// no lookup.
    @MainActor
    private func speakHRRInterjection(samples: [HRRSample]) {
        guard !samples.isEmpty, let one = samples.bestAtOneMinute else { return }
        let twoClause = samples.bestAtTwoMinutes.map { " The 2-minute drop was \($0.drop) bpm." } ?? ""
        conversation.speakAIResponse(
            toPrompt: "The post-workout heart-rate recovery window " +
                "just finished. The 1-minute HRR dropped \(one.drop) bpm " +
                "(from \(one.peakHR) bpm when the workout ended, down to \(one.hr) bpm).\(twoClause) " +
                "Speak ONE short, natural coaching sentence about the " +
                "1-minute drop and what it suggests about today's " +
                "autonomic recovery — a bigger drop means better " +
                "recovery. Only compare to the user's typical HRR if you " +
                "already know it; never invent a baseline. Don't recite " +
                "the raw numbers like a robot."
        )
    }
}
