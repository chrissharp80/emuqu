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
    /// taps Stop. The previous implementation awaited HRR capture for up to
    /// 120 seconds — that's not acceptable; users tap Stop and wait.
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
    /// debug log. If a future hang report comes back, the user's log shows
    /// EXACTLY which step ate the budget. Without this stamp, a hang inside
    /// the very first synchronous call (cancelling sensors, tearing down the
    /// strap) is invisible.
    ///
    /// The workout correlation scope is closed LAST. Everything before it —
    /// the merge, the archive write, the sync hand-off — belongs to this
    /// workout and reads better tagged with it. The detached HRR task
    /// deliberately outlives the scope: it can run for two minutes after the
    /// user has moved on, and tagging its lines as part of a finished workout
    /// would misrepresent when they happened.
    ///
    /// The finalize runs under a `BackgroundTaskAssertion`. A termination
    /// report showed: user tapped End during a workout, iOS SIGKILL'd the app
    /// 19 s later at 228 MB phys footprint — once `stop()` tears the session
    /// down, nothing keeps the app scheduled, leaving the training-load and
    /// archive work with no background budget. The assertion asks for the full budget (~30 s); its
    /// expiration handler ends the task, so running out suspends the app
    /// rather than getting it killed. A free no-op in the foreground.
    func stop() async {
        guard case .recording = phase else { return }
        let finalizeStartedAt = Date()
        debugLog("[Recorder.stop] entry — phase flipping to .finalizing")
        let bgTask = BackgroundTaskAssertion(name: "WorkoutRecorder.stop")
        defer { bgTask.end() }
        lifecycle.phase = .finalizing
        tearDownLiveWorkoutServices()
        let stopDate = Date()
        let endHR = heartRateAtStop()
        collectedPoints = await gatherFinalRRPoints(stopDate: stopDate)
        cancelStrapSubscriptionsAfterStop()
        let finished = await runFinalize(
            rrPoints: collectedPoints, stopDate: stopDate, startedAt: finalizeStartedAt
        )
        await settleAfterFinalize(finished: finished, startedAt: finalizeStartedAt)
        launchHRRCaptureAndRearchive(stopDate: stopDate, endHR: endHR, finished: finished)
        endWorkoutCorrelation()
    }

    /// The reference heart-rate recovery is measured from: the rate when
    /// exercise stopped, not the session's highest. Cole 1999 (NEJM), the
    /// source of the 12 bpm threshold, takes the rate at peak exercise of a
    /// maximal test, which is where that test ends; after intervals and a
    /// cool-down the session maximum was minutes earlier, and recovery from
    /// it read as an 80 bpm drop when the last minute fell 15. The live
    /// reading, else the last sampled one; 0 (no reading) skips the capture.
    private func heartRateAtStop() -> Int {
        if let current = currentHR, current > 0 { return current }
        return workoutSamples.last(where: { $0.heartRate != nil })?.heartRate ?? 0
    }

    /// Post-finalize housekeeping: battery accounting, breadcrumb archive,
    /// state reset, and the flip to `.finished` that reveals the summary.
    private func settleAfterFinalize(finished: HRVSession, startedAt: Date) async {
        await chargeStrapBatteryUsage()
        archiveBreadcrumbTrailIfNeeded(finished: finished)
        resetRecorderStateAfterStop()
        lifecycle.finishedSession = finished
        lifecycle.phase = .finished
        debugLog("[Recorder.stop] phase=.finished (total elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
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
    private func gatherFinalRRPoints(stopDate: Date) async -> [RRPoint] {
        await mergeWorkoutRRWithDeviceFetch(
            session: lifecycle.currentSession,
            streamingPoints: snapshotAndMergeRRBuffers(),
            startDate: sessionStartDate ?? stopDate,
            stopDate: stopDate
        )
    }

    /// `hrrSamples` is empty here — it's populated asynchronously after the
    /// archive by `launchHRRCaptureAndRearchive`.
    private func runFinalize(rrPoints: [RRPoint], stopDate: Date, startedAt: Date) async -> HRVSession {
        debugLog("[Recorder.stop] step=finalizeSession (rrPoints=\(rrPoints.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
        let finished = await finalizeSession(rrPoints: rrPoints, stopDate: stopDate, hrrSamples: [])
        debugLog("[Recorder.stop] step=finalizeSession done (elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)")
        return finished
    }

    /// stop() — teardown fan-out: ticker, GPS, pedometer, Zwift advertisement, Watch session, live broker, AI cache, cue audio session, diagnostics sampler.
    ///
    /// Voice conversation lifecycle is INDEPENDENT of workout
    /// lifecycle. The recorder never starts voice (the user opens
    /// it manually via the chat mic button), so it shouldn't stop
    /// it either. Tearing voice down here cut the user off
    /// mid-sentence when they were debriefing the workout. The user
    /// closes voice when they're done.
    func tearDownLiveWorkoutServices() {
        stopTicker()
        location.stopTracking()
        pedometer.stop()
        // Stop the BLE peripheral advertisement so we don't continue to
        // appear as a sensor for trainer apps after the workout ends.
        AppDependencies.current.collection.zwiftPeripheralBroadcaster.stopBroadcasting()
        // End the Watch's parallel HKWorkoutSession so the ring on the wrist
        // closes (no duplicate workout — the Watch never finalises a
        // standalone HKWorkout; the phone writes the canonical one).
        watchBridge.stopWatchWorkoutSession()
        // Clear the live-workout broker so the AI context no longer includes
        // stale "you're still running" state after the workout ends. Its last
        // snapshot is kept first for the session's `aiContext`.
        let broker = AppDependencies.current.assistant.liveWorkoutBroker
        liveSnapshotAtStop = broker.currentSnapshot()
        broker.clear()
        releaseWorkoutCueAudioAndDiagnostics()
    }

    /// Leave the audio session inactive once the workout is over: with no cue
    /// speaking it is deactivated now, unless a voice chat or the breathing
    /// guide still holds it; a cue still speaking deactivates it when it
    /// finishes. Then stop the diagnostics sampler started in `start()` so it
    /// doesn't keep sampling memory in the foreground app indefinitely.
    private func releaseWorkoutCueAudioAndDiagnostics() {
        AppDependencies.current.collection.backgroundAudioManager.stopBackgroundAudio()
        AppDependencies.current.app.systemDiagnosticsManager.stopSamplingAfterRecording()
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
    /// Watch direct-strap fallback path (`watchRoutedRRBuffer`), sorted by
    /// t_ms so a workout that bounced between iPhone-paired and Watch-routed
    /// strap connections still produces a single coherent RR series.
    func snapshotAndMergeRRBuffers() -> [RRPoint] {
        let merged = WorkoutRRMerge.merged(
            source: activeHRSource,
            streaming: core.polarManager.streamedRRPoints,
            watchRouted: watchRoutedRRBuffer
        )
        if !watchRoutedRRBuffer.isEmpty {
            debugLog("[Recorder.finalize] merged \(watchRoutedRRBuffer.count) Watch-routed RR points (total now \(merged.count))")
        }
        return merged
    }

    /// stop() — cancels the HR subscription and clears the strap notice.
    func cancelStrapSubscriptionsAfterStop() {
        hrSubscription?.cancel()
        hrSubscription = nil
        lifecycle.strapNotice = nil
    }

    /// stop() — charges the strap battery-usage counter with this workout's elapsed hours (strap source only).
    func chargeStrapBatteryUsage() async {
        // Charge the strap's battery-usage counter with this workout's
        // elapsed time. Only when the workout actually used the strap —
        // .watch / .none sources don't drain the H10. Captured before the
        // reset below so the value isn't lost.
        if activeHRSource == .strap {
            let workoutHoursForBattery = Double(lifecycle.elapsedSeconds) / 3600.0
            await MainActor.run {
                core.polarManager.recordRecordingHours(workoutHoursForBattery)
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
            archiveWorkoutTrackAsBreadcrumbTrail(
                track: location.track,
                sport: sport,
                start: finished.startDate
            )
        }
    }

    /// stop() — clears per-workout recorder state after finalize.
    func resetRecorderStateAfterStop() {
        lifecycle.currentSession = nil
        sessionStartDate = nil
        lifecycle.elapsedSeconds = 0
        workoutHR.reset()
        motion.reset()
        lastIngestedPointCount = 0
        location.reset()
        pedometer.reset()
        lifecycle.targetZone = nil
        intervalController.clear()
    }

    /// stop() — post-workout foot-pod disconnect (strap stays up for HRR).
    func disconnectFootPodPostWorkout() {
        // Secondary-sensor cleanup. The user's spec:
        // "disconnect the footpod after the exercise. not the strap
        // because you need HRR." Footpod doesn't participate in HRR
        // (cadence + power are session-only), so we drop it the moment
        // recording phase is `.finished`. The strap stays connected
        // through the HRR window — the detached HRR-capture task
        // below tears it down when the +120 s window completes.
        AppDependencies.current.collection.concept2Manager.holdLinkForWorkout(false)
        AppDependencies.current.collection.footPodManager.holdLinkForWorkout(false)
        if AppDependencies.current.collection.footPodManager.connectionState == .connected
            || AppDependencies.current.collection.footPodManager.connectionState == .connecting {
            debugLog("[Recorder.stop] step=footpod.disconnect (post-workout)")
            AppDependencies.current.collection.footPodManager.disconnect()
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
    /// waits, which made HRR capture silently fail whenever iOS
    /// decided to deprioritise it (user-visible as "no signal" in
    /// the summary even when the strap was clearly still producing
    /// beats). `.userInitiated` tells the scheduler this work
    /// directly maps to a user-visible number they're waiting for.
    func launchHRRCaptureAndRearchive(stopDate: Date, endHR: Int, finished: HRVSession) {
        let captureService = HRRCaptureService(
            polarManager: core.polarManager,
            healthKit: core.healthKit,
            captureWindowSec: 120
        )
        let sessionId = finished.id
        let archive = core.archive
        let wasStrap = (activeHRSource == .strap)
        let polarRef = core.polarManager
        Task.detached(priority: .userInitiated) {
            await self.captureHRRAndRearchive(
                captureService: captureService, stopDate: stopDate, endHR: endHR,
                wasStrap: wasStrap, polarRef: polarRef, archive: archive, sessionId: sessionId
            )
        }
    }

    /// stop() — body of the detached HRR-capture closure: capture samples, tear down the strap stream, re-archive with hrrSamples, fire the voice interjection + optional Coach Report.
    ///
    /// The write-back always happens, even when capture produced an empty
    /// array — that tells the UI "we tried and got nothing" instead of leaving
    /// the HRR card stuck on "capturing…" forever. An empty array is
    /// a meaningful signal (strap disconnected in the window, or no
    /// Watch HR samples for the minute after stop).
    nonisolated private func captureHRRAndRearchive(
        captureService: HRRCaptureService,
        stopDate: Date,
        endHR: Int,
        wasStrap: Bool,
        polarRef: PolarManager,
        archive: SessionArchive,
        sessionId: UUID
    ) async {
        let samples = await captureService.captureHRR(stopDate: stopDate, stopHR: endHR)
        if wasStrap {
            await releaseStrapAfterHRR(polarRef)
        }
        do {
            guard let finalSession = try Self.rearchiveWithHRR(samples, archive: archive, sessionId: sessionId) else {
                return
            }
            await MainActor.run {
                self.announceHRRAndStageReport(samples: samples, finalSession: finalSession)
            }
            debugLog("[WorkoutRecorder] HRR capture complete: \(samples.count) samples")
        } catch {
            debugLog("[WorkoutRecorder] HRR post-archive update failed: \(error)", level: .warning)
        }
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
        guard archive.exists(sessionId) else { return nil }
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
    /// `polarManager.isStreaming == true` to sample HR at +60s / +120s.
    ///
    /// The strap's BLE connection is released
    /// now that HRR is captured. User's spec: drop the
    /// strap after HRR even if voice chat is going. The
    /// chat continues without live HR (the AI handles
    /// "no current HR" gracefully via the missingReason
    /// envelope on `workout.live.hr.current`), and the
    /// user's strap battery stops draining. They can
    /// re-pair next session via the auto-reconnect at
    /// workout start.
    ///
    /// Not when another workout has started inside the capture window: that
    /// workout's session is the one buffering now, and stopping it here would
    /// end its heart rate a couple of minutes in.
    @MainActor
    private func releaseStrapAfterHRR(_ polarRef: PolarManager) {
        guard phase != .recording, phase != .finalizing else {
            debugLog("[WorkoutRecorder] HRR window closed during a new workout — leaving the strap session running")
            return
        }
        _ = polarRef.stopStreaming()
        polarRef.disconnect()
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
        let anotherWorkoutOwnsTheScreen = phase == .recording || phase == .finalizing
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
        Self.scheduleCoachReportEmail(for: finalSession, settings: settingsProvider())
    }

    /// Voice path enqueues if chat is busy (round 17 trigger queue). Skipped
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
    /// stop() cleared ~60–120 s ago. So a "look it up via
    /// the workout.most_recent + session.* tools" wording leaves
    /// the model with no way to see the value: it announced "no
    /// data" on every walk where Tier-1 capture actually
    /// succeeded (user report — treadmill walks,
    /// where the stationary strap reliably samples at +60/+120 s,
    /// so this fired daily). Pass the figures inline; no lookup.
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
