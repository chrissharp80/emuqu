import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// Split out of WorkoutRecorder.swift into its own FILE to satisfy the
// 1500-line file budget, and off the TYPE (which is what the aggregate
// type-size gate counts): the largest single file on the recorder.

extension WorkoutTicker {
    // MARK: - Internal

    /// Tick-batching analysis. "3+ observable updates per tick" looks
    /// like a P2 but is not. Verified by tracing:
    /// a tick fires `recorder.lifecycle.elapsedSeconds`, and inside
    /// `incrementalBackupTick` `recorder.workoutHR.beatCount` plus motion
    /// fields when fresh samples land. SwiftUI's runloop-level
    /// coalescing means N observable assignments in one
    /// `Task { @MainActor }` block produce ONE body re-eval, not N.
    /// So the user-visible cost on
    /// iPhone 12+ is one body eval per tick, dominated by the
    /// body's own work, not by the number of properties written. Hand-rolled
    /// batching — writing to `@ObservationIgnored` storage and publishing once
    /// at the end of the tick — would buy nothing measurable and risks subtle
    /// race conditions on a 1Hz path that's currently correct;
    /// not worth it without a measurable regression to fix.
    ///
    /// Without the explicit run-loop mode the elapsed clock can freeze
    /// (a user log showed `0:05` for ~22 wall-clock seconds while the user
    /// watched). Root cause: `Timer.scheduledTimer(withTimeInterval:repeats:)`
    /// adds the timer to the current run loop in `.default` mode, and
    /// `.default` is PAUSED while the user is interacting with the UI
    /// (scrolling, holding the Hold-to-end button, etc.). Use
    /// `Timer(timeInterval:repeats:block:)` and add it explicitly in
    /// `.common` mode so the timer continues firing during UI tracking.
    ///
    /// Starting the ticker starts a workout, so the wrist-HR row markers
    /// begin empty.
    /// Source: https://www.hackingwithswift.com/articles/117/the-ultimate-guide-to-timer
    func startTicker() {
        recorder.tickTimer?.invalidate()
        recorder.hrFromWrist = false
        recorder.wristHROffsets = []
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak recorder] _ in
            Task { @MainActor in
                recorder?.ticker.runTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        recorder.tickTimer = timer
    }

    /// One 1 Hz tick of the recording loop.
    ///
    /// Auto-pause / auto-resume is evaluated BEFORE elapsed gets bumped so a
    /// pause that fires on this very tick doesn't still advance the clock by
    /// one. Tick work (samples, live broker, watch push) still runs while
    /// paused — we want the Watch to see "paused" state and for the AI context
    /// to know — but `incrementalBackupTick` itself skips sample-append when
    /// paused.
    private func runTick() {
        guard case .recording = recorder.phase else { return }
        evaluateAutoPauseResume()
        if !recorder.lifecycle.isPaused {
            recorder.lifecycle.elapsedSeconds += 1
        }
        incrementalBackupTick()
    }

    /// Look at the current movement signals and decide whether to
    /// auto-pause or auto-resume. Runs every tick while recording.
    func evaluateAutoPauseResume() {
        guard let sport = recorder.currentSession?.sport else { return }
        if !recorder.lifecycle.isPaused {
            accrueStationaryAndMaybeAutoPause(sport: sport)
        } else if recorder.lifecycle.autoPaused {
            accrueMovingAndMaybeAutoResume(sport: sport)
        }
    }

    /// Signal precedence for "stopped":
    ///   1. GPS-sport + CoreLocation `.speed` < 0.3 m/s (1 km/h floor).
    ///      Negative speed = no fix / invalid — treated as unknown rather
    ///      than "stopped" so we don't pause during a GPS warm-up at the
    ///      start of a run.
    ///   2. Indoor-sport + cadence == 0 (treadmill stop, stationary
    ///      bike coast). Cadence is pedometer-derived indoors, which
    ///      goes to zero within a few seconds of the user actually
    ///      stopping. nil cadence (too early to read) is NOT stopped —
    ///      avoids a spurious auto-pause in the first few seconds.
    private func isStopped(sport: Sport) -> Bool {
        guard sport.usesGPS else {
            guard let cadence = recorder.cadenceStepsPerMin else { return false }
            return cadence <= 1
        }
        let speed = recorder.location.currentLocation?.speed ?? -1
        guard speed >= 0 else { return false }
        return speed < 0.3
    }

    /// Signal precedence for "moving again" (auto-resume only, and
    /// only when we paused ourselves — manual pause stays put):
    ///   - GPS speed ≥ 0.8 m/s (slow walk), or cadence ≥ 60 spm indoors.
    private func isMovingAgain(sport: Sport) -> Bool {
        guard sport.usesGPS else {
            guard let cadence = recorder.cadenceStepsPerMin else { return false }
            return cadence >= 60
        }
        return (recorder.location.currentLocation?.speed ?? -1) >= 0.8
    }

    private func accrueStationaryAndMaybeAutoPause(sport: Sport) {
        if recorder.autoPause.accrueStationary(isStopped: isStopped(sport: sport)) {
            recorder.pause(isAuto: true)
        }
    }

    private func accrueMovingAndMaybeAutoResume(sport: Sport) {
        if recorder.autoPause.accrueMoving(isMoving: isMovingAgain(sport: sport)) {
            recorder.resume()
        }
    }

    func stopTicker() {
        recorder.tickTimer?.invalidate()
        recorder.tickTimer = nil
    }

    /// PolarManager already publishes a heart rate the HRV path consumes.
    /// Observe it through `ObservationLoop` and mirror the latest value into
    /// `workoutHR` for the UI. Changes arrive as a main-actor hop rather than
    /// through a run-loop mode, so the mirror keeps updating while the user is
    /// touching the screen.
    func observeHeartRate() {
        recorder.hrSubscription = ObservationLoop.observe(recorder, initial: true, read: { $0.core.polarManager.currentHeartRate }, onChange: { recorder, newHR in
            recorder.ticker.mirrorStrapHeartRate(newHR)
        })
    }

    private func mirrorStrapHeartRate(_ newHR: Int?) {
        recorder.workoutHR.currentHR = newHR
        recorder.hrFromWrist = false
        guard let newHR, newHR > recorder.workoutHR.peakHR else { return }
        recorder.workoutHR.peakHR = newHR
    }

    /// Feed any newly-arrived RR points into the live DFA analyzer. The
    /// Polar streaming buffer grows as beats arrive; we only hand the new
    /// slice to the DFA each tick to avoid reprocessing the whole session.
    ///
    /// Why derive HR from RR here instead of subscribing to
    /// PolarManager.currentHeartRate: the strap broadcasts HR on a
    /// separate BLE service from RR. That HR publisher is flaky — drops
    /// silently, doesn't republish when the value is unchanged. Users see
    /// this during overnight recordings ("beats stacking but the HR
    /// number never refreshes"). The RR stream is what we depend on for
    /// analysis anyway, so deriving HR = 60000/rr_ms from the most recent
    /// beats gives a display that tracks the actual data.
    ///
    /// The live snapshot only feeds the AI assistant,
    /// so the per-tick build is skipped when the assistant is off (matches
    /// the geocode gate in `refreshEnvironmentContextIfNeeded`).
    func incrementalBackupTick() {
        let buffer = recorder.core.polarManager.streamedRRPoints
        recorder.workoutHR.beatCount = buffer.count

        runIncrementalBackup(buffer: buffer)
        ingestStrapBeatsAndDeriveHR(buffer: buffer)
        consumeWatchRoutedStrapFallback()
        arbitrateHRSource()
        mirrorMotionAndPowerSensors()
        updateLivePace()
        capturePerSecondSample()
        if recorder.settingsProvider().enableAIAssistant {
            publishLiveWorkoutSnapshot()
        }
        if let sport = recorder.currentSession?.sport {
            runSportScopedTickWork(sport: sport)
        }
        // Advance the interval plan (if any). Transitions fire via the
        // controller's onStepChange hook wired in start().
        _ = recorder.intervalController.tick(totalDistanceMeters: recorder.distanceMeters)
    }

    /// The half of the tick that needs a sport: Watch push, threshold
    /// breaches, route detection, Zwift, AI environment, voice coach.
    ///
    /// Threshold-breach durations update FIRST so the context the voice coach
    /// gets reflects the right "we've been over the line for N seconds" state.
    /// This is what powers the ambient-coach experience: the user pre-set
    /// "don't exceed 135 bpm for 30s", and we maintain a per-threshold counter
    /// that increments while breached and resets the moment the metric is back
    /// inside.
    private func runSportScopedTickWork(sport: Sport) {
        // Push a live state snapshot to the paired Watch (no-op if unpaired).
        pushLiveStateToWatch(sport: sport)
        recorder.updateThresholdBreaches(sport: sport)
        attemptRouteDetectionIfEligible(sport: sport)
        pushZwiftBroadcasterUpdate()
        refreshEnvironmentContextIfNeeded(sport: sport)
        tickVoiceCoach(sport: sport)
    }

    /// Tick stage — incremental RR backup + cloud upload; track persistence delegates to `persistWorkoutTrackIfChanged`.
    ///
    /// "Don't lose my 4-mile walk." Both fire on a background Task so the
    /// main-actor ticker never blocks on disk I/O: RawRRBackup self-throttles
    /// to ~60 s cadence, so most ticks do nothing, but the once-a-minute
    /// actual write is a ~100 ms freeze if it runs on main — felt as UI
    /// stutter during recording. Buffer/sessionId/deviceId are captured
    /// as value types into the detached task.
    private func runIncrementalBackup(buffer: [RRPoint]) {
        guard let session = recorder.currentSession else { return }
        let sessionId = session.id
        let deviceId = recorder.core.polarManager.connectedDeviceId
        let bufferSnapshot = buffer  // copy before handing off
        let backup = recorder.core.rawBackup
        let cloudSyncManager = recorder.core.cloudSyncManager
        Task.detached(priority: .utility) {
            let didBackup = backup.incrementalBackup(
                points: bufferSnapshot,
                sessionId: sessionId,
                deviceId: deviceId
            )
            guard didBackup else { return }
            await cloudSyncManager.uploadLiveBackup(
                sessionId: sessionId,
                points: bufferSnapshot,
                deviceId: deviceId
            )
        }
        persistWorkoutTrackIfChanged(session: session, sessionId: sessionId)
    }

    /// Tick stage — GPS/baro/samples track persistence with the no-new-work skip.
    ///
    /// Workout-side persistence: GPS fixes, per-tick samples, and
    /// barometric altitude. Every tick — the per-stream cursor in
    /// `WorkoutTrackBackup` short-circuits no-op writes, so most
    /// ticks do nothing on disk. Crash mid-workout = the recovery
    /// path can rebuild a real workout (route, distance, splits,
    /// elevation) instead of just an HR-only fragment.
    ///
    /// Skip the whole `.map` snapshot if no new
    /// fixes / samples / baro entries arrived since the last
    /// snapshot. The internal cursor still protects the disk path,
    /// but the allocation churn from copying the whole growing
    /// array every tick (`.map` materializes a new array of the
    /// SAME size, not the delta) is wasted CPU + memory.
    ///
    /// The samples mark is the newest row's `offsetSec`, not the row count:
    /// past 12 h `capWorkoutSampleMemory` drops a row for each one added, so
    /// the count stops changing while new rows still need backing up.
    private func persistWorkoutTrackIfChanged(session: HRVSession, sessionId: UUID) {
        guard recorder.trackBackupWatermark.advanceIfChanged(
            trackCount: recorder.location.track.count,
            baroCount: recorder.location.barometricSamples.count,
            samplesCount: recorder.workoutSamples.last?.offsetSec ?? 0
        ) else { return }
        appendTrackSnapshot(session: session, sessionId: sessionId)
    }

    /// Conversion to value types is done on the MainActor so the
    /// detached task only sees `Sendable` payloads — `CLLocation`
    /// is non-Sendable in Swift 6 and would otherwise warn on
    /// capture.
    private func appendTrackSnapshot(session: HRVSession, sessionId: UUID) {
        let sport = session.sport ?? .run
        let startDate = recorder.sessionStartDate ?? session.startDate
        let fixSnapshot = recorder.location.track.map(WorkoutTrackBackup.PersistedFix.init)
        let baroSnapshot = recorder.location.barometricSamples.map {
            WorkoutTrackBackup.PersistedBaro(timestamp: $0.timestamp, altitudeMeters: $0.altitudeMeters)
        }
        let samplesSnapshot = recorder.workoutSamples
        let wristOffsetsSnapshot = recorder.wristHROffsets
        let trackBackup = AppDependencies.current.storage.workoutTrackBackup
        Task.detached(priority: .utility) {
            trackBackup.appendIncremental(
                sessionId: sessionId,
                sport: sport,
                startDate: startDate,
                track: fixSnapshot,
                samples: samplesSnapshot,
                healthKitHROffsets: wristOffsetsSnapshot,
                barometricSamples: baroSnapshot
            )
        }
    }

    /// Tick stage — DFA ingest of the new RR slice + median-smoothed HR derivation (or analyzer clock tick).
    private func ingestStrapBeatsAndDeriveHR(buffer: [RRPoint]) {
        guard buffer.count > recorder.lastIngestedPointCount else {
            // No new beats this tick. Still advance the analyzer's clock so
            // its status can report "strap silent for N seconds" — otherwise
            // the UI would read "warming up" forever after a strap drop.
            recorder.dfa.tick()
            return
        }
        recorder.dfa.ingest(points: Array(buffer[recorder.lastIngestedPointCount ..< buffer.count]))
        if let derivedHR = Self.medianSmoothedHR(recent: buffer.suffix(8)) {
            recorder.workoutHR.currentHR = derivedHR
            recorder.hrFromWrist = false
            if derivedHR > recorder.workoutHR.peakHR { recorder.workoutHR.peakHR = derivedHR }
            recorder.lastStrapHRAt = Date()  // strap is alive
        }
        recorder.lastIngestedPointCount = buffer.count
    }

    /// Smoothed HR: median of the last ~8 beats. Raw rr_ms swings
    /// wildly with normal RR variation (a single beat might read
    /// 48 or 92 from the same heart rate). The median reads like a
    /// real heart rate rather than a jittering number.
    private static func medianSmoothedHR(recent: ArraySlice<RRPoint>) -> Int? {
        let rrValues = recent.filter { $0.rr_ms > 0 }.map { Double($0.rr_ms) }.sorted()
        guard !rrValues.isEmpty else { return nil }
        let median = rrValues.count.isMultiple(of: 2)
            ? (rrValues[rrValues.count / 2 - 1] + rrValues[rrValues.count / 2]) / 2
            : rrValues[rrValues.count / 2]
        return Int(60_000.0 / median)
    }

    /// Tick stage — Watch direct-strap fallback: drain queued RR, synthesize points, feed DFA + live HR.
    ///
    /// Watch direct-strap fallback. When the iPhone-paired
    /// Polar is silent BUT the Watch is paired directly to a chest
    /// strap (`WatchStrapConnector` forwards HR + RR over WCSession),
    /// consume those samples here. They feed both the live HR display
    /// AND the DFA pipeline so HRV metrics still resolve when the
    /// phone can't see the strap directly. Drains a queue (see the
    /// bridge's `drainPendingWatchStrapRR`) so dense beat bursts
    /// don't lose samples to a simple overwrite.
    ///
    /// Only while the phone's own strap stream is silent. A strap holds a link
    /// to the phone and one to the Watch at once, so both streams carry the
    /// same beats; taking the Watch's as well counted every beat twice. The
    /// queue is still drained, so beats from a stretch the phone covered are
    /// not replayed when it next drops.
    private func consumeWatchRoutedStrapFallback() {
        guard let watchStrapAt = recorder.watchBridge.latestWatchStrapAt,
              Date().timeIntervalSince(watchStrapAt) < 10
        else { return }
        let drainedWatchRR = WatchPayloadBounds.plausibleRRMillis(recorder.watchBridge.drainPendingWatchStrapRR())
        guard !drainedWatchRR.isEmpty, !phoneStrapIsLive else { return }
        recorder.lastConsumedWatchStrapAt = watchStrapAt
        let newPoints = synthesizeWatchRoutedPoints(drainedWatchRR, arrivedAt: watchStrapAt)
        guard !newPoints.isEmpty else { return }
        recorder.watchRoutedRRBuffer.append(contentsOf: newPoints)
        recorder.dfa.ingest(points: newPoints)
        applyWatchRoutedHR()
    }

    /// Moves the Watch beats' clock up to the batch's place in the workout.
    private func alignWatchClock(toWallMs wallMs: Int64) {
        guard let start = recorder.sessionStartDate else { return }
        let sinceStart = wallMs - Int64(start.timeIntervalSince1970 * 1000)
        recorder.watchRoutedCumulativeMs = max(recorder.watchRoutedCumulativeMs, sinceStart)
    }

    /// When the phone's strap stream started, in epoch milliseconds: the zero
    /// of the phone beats' `wallClockMs`. The workout start stands in when
    /// no stream ran.
    private var streamClockBaseEpochMs: Int64 {
        let base = recorder.core.polarManager.streamingStartTime ?? recorder.sessionStartDate
        return Int64((base?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private var phoneStrapIsLive: Bool {
        recorder.lastStrapHRAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// Synthesize RRPoints for the beats the Watch carried. Wall-clock comes
    /// from the bridge timestamp adjusted backward by the cumulative duration
    /// of this sample batch — best-effort, since we don't know the exact
    /// arrival times of individual beats inside the payload. `t_ms` here is
    /// only for the live readout; `WorkoutRRMerge` orders the finished series
    /// by wall clock and rebuilds it.
    ///
    /// `wallClockMs` is milliseconds since the strap stream started, the
    /// clock the phone's own beats carry, so the two can be interleaved.
    ///
    /// `drainedWatchRR` has been through `WatchPayloadBounds.plausibleRRMillis`,
    /// so every value is finite and inside the RR band before `Int(...)`.
    private func synthesizeWatchRoutedPoints(_ drainedWatchRR: [Double], arrivedAt: Date) -> [RRPoint] {
        let payloadDurMs = drainedWatchRR.reduce(0.0, +)
        let batchStartEpochMs = Int64((arrivedAt.timeIntervalSince1970 * 1000) - payloadDurMs)
        alignWatchClock(toWallMs: batchStartEpochMs)
        var batchStartWallMs = batchStartEpochMs - streamClockBaseEpochMs
        var newPoints: [RRPoint] = []
        newPoints.reserveCapacity(drainedWatchRR.count)
        for rr in drainedWatchRR {
            let rrMs = Int(rr.rounded())
            newPoints.append(RRPoint(
                t_ms: recorder.watchRoutedCumulativeMs, rr_ms: rrMs,
                wallClockMs: batchStartWallMs, hr: WatchPayloadBounds.plausibleHeartRate(recorder.watchBridge.latestWatchStrapHR)
            ))
            recorder.watchRoutedCumulativeMs += Int64(rrMs)
            batchStartWallMs += Int64(rrMs)
        }
        return newPoints
    }

    /// Fold the Watch-routed strap HR into the live display +
    /// peak tracking when this path produces beats. Without this, a Polar
    /// drop with Watch-routed RR ingestion still leaves the user staring at a
    /// stale HR number, because the wrist-HR fallback in
    /// `arbitrateHRSourceAndRunWatchdog` only fires when `recorder.lastStrapHRAt` is
    /// older than 10 s — and we'd want it FRESH (so the cache survives) but
    /// also need the display to update.
    ///
    /// `recorder.lastWatchRoutedHRAt` is a separate freshness timestamp so the
    /// silent-strap detector treats Polar-direct and Watch-routed channels as
    /// independent. Reusing `recorder.lastStrapHRAt` would mask a true Polar drop with
    /// stale freshness from the Watch path and break the wrist-HR tier.
    private func applyWatchRoutedHR() {
        if let strapHR = WatchPayloadBounds.plausibleHeartRate(recorder.watchBridge.latestWatchStrapHR) {
            recorder.workoutHR.currentHR = strapHR
            recorder.hrFromWrist = false
            if strapHR > recorder.workoutHR.peakHR { recorder.workoutHR.peakHR = strapHR }
        }
        recorder.lastWatchRoutedHRAt = Date()
    }

    /// Tick stage — HR-source arbitration (`HRArbitration.decide`).
    ///
    /// The decision is pure — `HRArbitration.decide` (bottom of this file)
    /// holds the source-priority cascade and when the user is told why there
    /// is no strap heart rate. This shell only measures channel silences and
    /// applies the result. Recovering a silent strap is not the ticker's job:
    /// the strap link owns it (`StrapFeedHealth`), so there is one owner and no
    /// second schedule tearing the link down.
    ///
    /// `recorder.hrFromWrist` follows the decision (`HRArbitration.displayIsWrist`),
    /// so the per-second sample knows its heart rate came from Apple Health.
    private func arbitrateHRSource() {
        let arbitration = HRArbitration.decide(HRArbitration.Inputs(
            sourceMode: recorder.activeHRSource,
            recordingElapsedSeconds: recorder.elapsedSeconds,
            strapSilentFor: recorder.lastStrapHRAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            watchRoutedSilentFor: recorder.lastWatchRoutedHRAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            latestWatchHR: freshWristHR(now: Date()),
            strapFeed: recorder.core.polarManager.feedStatus
        ))
        applyDisplayHR(arbitration)
        if recorder.lifecycle.strapNotice != arbitration.strapNotice {
            recorder.lifecycle.strapNotice = arbitration.strapNotice
            if let notice = arbitration.strapNotice {
                debugLog("[Recorder] Strap notice raised \(recorder.elapsedSeconds)s in: \(notice)", level: .warning)
            }
        }
    }

    private func applyDisplayHR(_ arbitration: HRArbitration.Decision) {
        if let watchHR = arbitration.displayHRUpdate {
            recorder.workoutHR.currentHR = watchHR
            if watchHR > recorder.workoutHR.peakHR { recorder.workoutHR.peakHR = watchHR }
        } else if arbitration.clearDisplayHR {
            recorder.workoutHR.currentHR = nil
        }
        recorder.hrFromWrist = HRArbitration.displayIsWrist(arbitration, wasWrist: recorder.hrFromWrist)
    }

    /// The Watch's wrist HR while it is still arriving, else nil. A reading
    /// the Watch sent more than `wristHRMaxAgeSec` ago is what a Watch that
    /// stopped sending leaves behind; recording it every second would write a
    /// flat, false heart rate into the samples. A steady heart rate the Watch
    /// keeps sending stays fresh.
    private func freshWristHR(now: Date) -> Int? {
        let bridge = recorder.watchBridge
        guard let wrist = WatchPayloadBounds.plausibleHeartRate(bridge.latestWatchHR),
              let receivedAt = bridge.latestWatchHRAt else { return nil }
        return now.timeIntervalSince(receivedAt) <= HRArbitration.wristHRMaxAgeSec ? wrist : nil
    }

    /// Tick stage — mirrors location / pedometer / foot pod / PM5 into the motion observable + power tallies.
    ///
    /// Distance precedence:
    ///   1. Foot pod (when connected — most accurate for running,
    ///      unaffected by GPS and treadmill)
    ///   2. GPS
    ///   3. Pedometer
    /// `max(...)` picks the largest registered so no source gets clipped.
    ///
    /// Cadence precedence:
    ///   1. Foot pod (direct stride measurement)
    ///   2. Pedometer (iPhone motion coprocessor estimate)
    ///
    /// Rower sport: PM5 owns distance, cadence (stroke rate), and power
    /// outright — GPS / pedometer / foot-pod values are all noise here.
    /// The precedence chain is overridden when the sport is `.row` so the
    /// rower's odometer / SPM / watts win over irrelevant sources. Stroke
    /// rate surfaces in the same field used by the live UI — the cadence
    /// label flips to "spm" on the row sport in the recording view.
    private func mirrorMotionAndPowerSensors() {
        recorder.motion.footPodActive = recorder.footPod.connectionState == .connected
        let isRow = recorder.currentSession?.sport == .row
        let erg = isRow ? AppDependencies.current.collection.concept2Manager : nil
        if isRow, let ergDist = erg?.distanceMeters {
            recorder.motion.distanceMeters = ergDist
        } else {
            let paused = recorder.lifecycle.pausedMotion
            recorder.motion.distanceMeters = max(
                paused.footPodDistance(recorder.footPodDistanceMeters()),
                max(recorder.location.distanceMeters, paused.pedometerDistance(recorder.pedometer.distanceMeters))
            )
        }
        recorder.motion.elevationGainMeters = recorder.location.elevationGainMeters
        recorder.motion.liveTrack = recorder.location.track
        recorder.motion.stepCount = recorder.pedometer.stepCount
        recorder.motion.cadenceStepsPerMin = (isRow ? erg?.strokeRateSPM : nil)
            ?? recorder.footPod.cadenceStepsPerMin
            ?? recorder.pedometer.cadenceStepsPerMin
        tallyPower(isRow ? erg?.instantaneousPowerWatts : recorder.footPod.instantaneousPowerWatts)
    }

    /// Power (watts). Captures running totals for the post-summary's
    /// avg / normalized / peak figures. Normalized power is computed on
    /// finalize from the full sample series, not here. Rower power
    /// comes from the PM5; foot-pod power covers run / walk / hike;
    /// FTMS bike trainers route through the foot-pod manager too.
    private func tallyPower(_ liveWatts: Int?) {
        guard let w = liveWatts else {
            recorder.motion.powerWatts = nil
            return
        }
        recorder.motion.powerWatts = w
        recorder.powerSampleSum += w
        recorder.powerSampleCount += 1
        if w > recorder.maxPowerObserved { recorder.maxPowerObserved = w }
    }

    /// Tick stage — per-second WorkoutSample capture (skipped while paused).
    ///
    /// Sampled 1 Hz. Persisted to WorkoutMetadata.samples on finalize so
    /// post-summary can render real charts (HR over time, pace, cadence)
    /// AND exports can attach per-row metrics instead of just GPS. Without
    /// this the CSV was lat/lon only and charts couldn't exist.
    ///
    /// Skipped while paused — otherwise the chart would have a flat-line
    /// valley during a rest stop that looks like the user crashed to 0
    /// pace. Paused samples intentionally fall off the series so the
    /// resume point sits right up against the pre-pause sample.
    ///
    /// A row whose heart rate is the Watch's wrist HR has its offset added to
    /// `recorder.wristHROffsets`.
    private func capturePerSecondSample() {
        guard !recorder.lifecycle.isPaused, let sport = recorder.currentSession?.sport else { return }
        recorder.workoutSamples.append(makeSample(sport: sport, paceSecPerKm: recorder.currentPaceSecPerKm))
        if recorder.hrFromWrist, recorder.currentHR != nil {
            recorder.wristHROffsets.append(recorder.elapsedSeconds)
        }
        capWorkoutSampleMemory()
    }

    private func makeSample(sport: Sport, paceSecPerKm: Double?) -> WorkoutSample {
        WorkoutSample(
            offsetSec: recorder.elapsedSeconds, heartRate: recorder.currentHR,
            distanceMeters: recorder.distanceMeters > 0 ? recorder.distanceMeters : nil,
            paceSecPerKm: paceSecPerKm, cadenceStepsPerMin: recorder.cadenceStepsPerMin,
            altitudeMeters: recorder.location.currentLocation?.altitude, alpha1: recorder.dfa.currentAlpha1,
            mets: WorkoutRecorder.estimateMETs(
                sport: sport, paceSecPerKm: paceSecPerKm, heartRate: recorder.currentHR,
                userMaxHR: recorder.settingsProvider().effectiveMaxHR
            ),
            powerWatts: recorder.powerWatts
        )
    }

    /// Tick stage — feeds this tick's distances and speeds to `recorder.livePace`.
    ///
    /// A paused tick clears it: a pause is not a pace, and the window must not
    /// span it. The rower's odometer is its only distance.
    private func updateLivePace() {
        guard !recorder.lifecycle.isPaused, let sport = recorder.currentSession?.sport else {
            recorder.livePace.reset()
            return
        }
        let paused = recorder.lifecycle.pausedMotion
        let outdoors = sport.usesGPS
        recorder.livePace.update(LivePaceEstimator.Reading(
            now: Date(), distanceMeters: recorder.distanceMeters,
            gpsMeters: outdoors ? recorder.location.distanceMeters : nil,
            pedometerMeters: LivePaceEstimator.countsSteps(sport) ? paused.pedometerDistance(recorder.pedometer.distanceMeters) : nil,
            footPodSpeedMS: recorder.footPod.instantaneousSpeedMS,
            gps: outdoors ? recorder.location.currentLocation.map(LivePaceEstimator.GPSSpeed.init) : nil
        ))
    }

    /// Defensive memory cap, mirroring PolarManager's RR streaming
    /// buffer. One WorkoutSample is appended ~1 Hz, so 12h of samples
    /// is the ceiling; a normal-length workout never reaches it. If
    /// exceeded (e.g. a session left running for days), drop the
    /// oldest so memory stays bounded. Each sample carries an absolute
    /// `offsetSec`, so dropping the head doesn't corrupt the rest, and the
    /// crash-recovery backup finds the rows it has not written by that key,
    /// so it keeps every row, the dropped ones included.
    private func capWorkoutSampleMemory() {
        let maxWorkoutSamples = 60 * 60 * 12 // 12h at 1 sample/sec
        guard recorder.workoutSamples.count > maxWorkoutSamples else { return }
        recorder.workoutSamples.removeFirst(recorder.workoutSamples.count - maxWorkoutSamples)
        recorder.wristHROffsets = Self.offsets(recorder.wristHROffsets, keptFrom: recorder.workoutSamples.first?.offsetSec)
    }

    /// The offsets at or after the first row still held; all of them when
    /// no row is.
    static func offsets(_ offsets: [Int], keptFrom firstOffset: Int?) -> [Int] {
        guard let firstOffset else { return offsets }
        return offsets.filter { $0 >= firstOffset }
    }

    /// Tick stage — computes the live-snapshot locals and publishes to LiveWorkoutBroker (literal in `buildBrokerSnapshot`).
    ///
    /// Publish live snapshot for the AI context. When the user is in a
    /// workout and asks "what's my HR?" / "where am I?" / "why no α1?"
    /// the Assistant gets a direct answer instead of guessing. The
    /// snapshot carries wall-clock timestamps, GPS position, heading,
    /// grade, units preference, and α1 diagnostic status — every piece
    /// of state the AI might need to sound like a real coach.
    private func publishLiveWorkoutSnapshot() {
        guard let sport = recorder.currentSession?.sport else { return }
        let loc = recorder.location.currentLocation
        let heading = Self.validCourse(loc)
        AppDependencies.current.assistant.liveWorkoutBroker.publish(
            buildBrokerSnapshot(
                sport: sport,
                loc: loc,
                heading: heading,
                speedMS: recorder.currentSpeedMS,
                lastSample: recorder.workoutSamples.last,
                strapSilent: strapSilentSeconds(),
                liveZoneBreakdown: liveZoneBreakdown()
            )
        )
    }

    /// CoreLocation reports a negative course when it has no valid reading;
    /// surface that as nil rather than as a heading of -1°.
    static func validCourse(_ loc: CLLocation?) -> Double? {
        guard let c = loc?.course, c >= 0 else { return nil }
        return c
    }

    /// Only meaningful when the strap is the selected source — on watch/none
    /// there is no strap silence to report.
    func strapSilentSeconds() -> Double? {
        guard recorder.activeHRSource == .strap, let last = recorder.lastStrapHRAt else { return nil }
        return Date().timeIntervalSince(last)
    }

    private func liveZoneBreakdown() -> WorkoutZoneBreakdown {
        WorkoutZoneBreakdown.compute(
            samples: recorder.workoutSamples,
            userMaxHR: recorder.settingsProvider().effectiveMaxHR
        )
    }

    /// Cardinal derived from GPS course so the AI can
    /// say "heading east on Maple" without having to interpret
    /// degrees. 8-point compass; 22.5° per slice centred on each
    /// cardinal so a reading of 80° still resolves to "E" and not
    /// "ENE" (we deliberately don't emit half-quadrants — the AI
    /// verbalises better with the simpler 8-point set).
    private static func cardinal(fromCourse deg: Double) -> String {
        let normalized = (deg.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
        return labels[Int(((normalized + 22.5) / 45.0).rounded(.down)) % 8]
    }

    /// Tick stage — the broker-snapshot struct literal; pure construction, no side effects.
    ///
    /// Resolve the geocode ONCE instead of reading
    /// `AppDependencies.current.location.roadGeocodingService.current` seven times.
    ///
    /// NOT a race fix, despite appearances: both this type and
    /// `RoadGeocodingService` are `@MainActor` and this function is
    /// synchronous, so there is no suspension point between the reads and
    /// all seven observe the same value. The win is smaller and duller —
    /// one property read instead of seven, and the snapshot's dependency
    /// on the geocoder is stated once at the top rather than buried seven
    /// times in an argument list.
    ///
    /// The live trends, historical baselines and readiness
    /// fields carry the same data fed to the voice path, mirrored here so
    /// chat-mode tool calls (`workout.live.snapshot`) see what voice's
    /// `asFactSheet` sees.
    private func buildBrokerSnapshot(
        sport: Sport,
        loc: CLLocation?,
        heading: Double?,
        speedMS: Double?,
        lastSample: WorkoutSample?,
        strapSilent: Double?,
        liveZoneBreakdown: WorkoutZoneBreakdown
    ) -> AssistantContext.LiveWorkoutSnapshot {
        let road = AppDependencies.current.location.roadGeocodingService.current
        return AssistantContext.LiveWorkoutSnapshot(
            sport: sport.displayName, snapshotAt: Date(), sessionStartAt: recorder.sessionStartDate ?? Date(), elapsedSeconds: recorder.elapsedSeconds, heartRate: recorder.currentHR, peakHR: recorder.peakHR, userMaxHR: recorder.settingsProvider().effectiveMaxHR,
            beatCount: recorder.beatCount, distanceMeters: recorder.distanceMeters, stepCount: recorder.stepCount, cadenceStepsPerMin: recorder.cadenceStepsPerMin, elevationGainMeters: recorder.elevationGainMeters, alpha1: recorder.dfa.currentAlpha1,
            alpha1Band: recorder.dfa.currentBand.label, alpha1Status: recorder.dfa.status.label, alpha1FitQualityR2: recorder.dfa.fitQuality, strapConnected: recorder.core.polarManager.connectionState == .connected, strapSilentSec: strapSilent, gpsFixCount: recorder.liveTrack.count,
            gpsAccuracyMeters: recorder.location.lastHorizontalAccuracy, currentPaceSecPerKm: recorder.currentPaceSecPerKm, currentSpeedMS: speedMS, powerWatts: recorder.powerWatts, currentMETs: lastSample?.mets, recentSplitPaces: recorder.recentSplitPacesSecPerKm(),
            currentLatitude: loc?.coordinate.latitude, currentLongitude: loc?.coordinate.longitude, currentAltitudeMeters: loc?.altitude, currentHeadingDegrees: heading, currentHeadingCardinal: heading.map(Self.cardinal(fromCourse:)),
            currentGradePercent: recorder.computeCurrentGradePercent(), unitsPreference: UnitsPreferenceStore.current.rawValue, targetZone: recorder.targetZone, recognizedRouteName: recorder.plannedRoute?.name, recognizedRouteWasAutoDetected: recorder.plannedRouteWasAutoDetected,
            recognizedRouteDirection: recognizedRouteDirectionLabel(), routeTotalDistanceMeters: recorder.plannedRoute?.totalDistanceMeters, routeClimbCount: recorder.plannedRoute?.climbs.count, currentRoadName: road?.road, currentLocality: road?.locality,
            currentAdministrativeArea: road?.administrativeArea, currentCountry: road?.country, currentCountryCode: road?.countryCode, currentCompactAddress: road?.compactAddress, currentNearestCrossStreet: road?.nearestCrossStreet,
            routeTopology: recorder.liveRouteTopologySnapshot(currentLocation: loc), weather: recorder.liveWeatherSnapshot(), reverseSplitDeltaSecPerKm: WorkoutLiveTrends.reverseSplitDeltaSecPerKm(samples: recorder.workoutSamples),
            liveHRDriftPercent: WorkoutLiveTrends.hrDriftPercent(samples: recorder.workoutSamples), aerobicDecouplingPercent: WorkoutLiveTrends.aerobicDecouplingPercent(samples: recorder.workoutSamples), cadenceDriftSpm: WorkoutLiveTrends.cadenceDriftSpm(samples: recorder.workoutSamples),
            gradeAdjustedPaceSecPerKm: liveGradeAdjustedPace(), recentSplitGradeAdjustedPaces: WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: recorder.workoutSamples), projectedMinutesUntilFade: liveProjectedMinutesUntilFade(),
            historicalSportAvgPaceSecPerKm: recorder.cachedHistoricalBaselines.avgPaceSecPerKm, historicalSportAvgHR: recorder.cachedHistoricalBaselines.avgHR, historicalSportAvgAlpha1: recorder.cachedHistoricalBaselines.avgAlpha1,
            historicalSportSampleCount: recorder.cachedHistoricalBaselines.sampleCount, todayRecoveryScore: recorder.cachedTodayReadiness.recoveryScore, todayTrainingReadiness: recorder.cachedTodayReadiness.trainingReadiness, todayATL: recorder.cachedTodayReadiness.atl,
            todayCTL: recorder.cachedTodayReadiness.ctl, todayTSB: recorder.cachedTodayReadiness.tsb, projectedDaysUntilFresh: recorder.cachedTrainingProjection.daysUntilFresh, projectedTSBTomorrowSteadyState: recorder.cachedTrainingProjection.tsbTomorrowSteadyState,
            recoveryHoursNeeded: liveRecoveryHoursNeeded(), zone1Sec: liveZoneBreakdown.z1Sec, zone2Sec: liveZoneBreakdown.z2Sec, zone3Sec: liveZoneBreakdown.z3Sec, zone4Sec: liveZoneBreakdown.z4Sec, zone5Sec: liveZoneBreakdown.z5Sec, dominantZone: liveZoneBreakdown.dominantZone,
            predictedRaceTime5KSec: recorder.cachedRacePredictionsByDistance[5_000], predictedRaceTime10KSec: recorder.cachedRacePredictionsByDistance[10_000], predictedRaceTimeHalfSec: recorder.cachedRacePredictionsByDistance[21_097.5],
            predictedRaceTimeMarathonSec: recorder.cachedRacePredictionsByDistance[42_195], activeThresholds: activeThresholdSnapshots(), thresholdBreachSec: thresholdBreachSecByID(), intervalProgress: recorder.liveIntervalProgressSnapshot()
        )
    }

    /// Direction is only meaningful for a route we recognised ourselves — a
    /// user-chosen route is always run in its stored direction.
    private func recognizedRouteDirectionLabel() -> String? {
        guard recorder.plannedRouteWasAutoDetected else { return nil }
        return recorder.plannedRouteDirection == .reverse ? "reverse" : "forward"
    }

    private func liveGradeAdjustedPace() -> Double? {
        WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(
            pace: recorder.currentPaceSecPerKm,
            gradePercent: recorder.computeCurrentGradePercent()
        )
    }

    func liveProjectedMinutesUntilFade() -> Double? {
        WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: recorder.workoutSamples,
            currentDriftPercent: WorkoutLiveTrends.hrDriftPercent(samples: recorder.workoutSamples)
        )
    }

    func liveRecoveryHoursNeeded() -> Double? {
        RecoveryTimeEstimate.hoursFromTrainingLoad(
            atl: recorder.cachedTodayReadiness.atl,
            ctl: recorder.cachedTodayReadiness.ctl
        )
    }

    private func activeThresholdSnapshots() -> [AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot] {
        recorder.userThresholds.map {
            AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot(
                id: $0.id.uuidString,
                metric: $0.metric.rawValue,
                condition: $0.condition.rawValue,
                value: $0.value,
                debounceSec: $0.debounceSec,
                cooldownSec: $0.cooldownSec,
                userCue: $0.userCue
            )
        }
    }

    private func thresholdBreachSecByID() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: recorder.thresholdBreachSec.map { ($0.key.uuidString, $0.value) })
    }

    /// Tick stage — Watch live-state push (pace display + zone/pause state).
    private func pushLiveStateToWatch(sport: Sport) {
        let units = UnitsPreferenceStore.current.resolved
        let pace = recorder.currentPaceSecPerKm
        let paceDisplay = pace.flatMap { units.formatPace(secondsPerMeter: $0 / 1000) }
        let settings = recorder.settingsProvider()
        recorder.watchBridge.sendLiveState(WatchConnectivityBridge.LiveState(
            sport: sport, heartRate: recorder.currentHR, peakHR: recorder.peakHR, userMaxHR: settings.effectiveMaxHR,
            totals: WatchConnectivityBridge.LiveTotals(
                elapsedSec: recorder.elapsedSeconds, distanceMeters: recorder.distanceMeters,
                elevationGainMeters: recorder.elevationGainMeters
            ),
            paceDisplay: paceDisplay, alpha1: recorder.dfa.currentAlpha1, band: recorder.dfa.currentBand.localizedLabel,
            cadenceSpm: recorder.cadenceStepsPerMin, targetZone: recorder.targetZone, unitsPreference: units.rawValue,
            isRecording: true, isPaused: recorder.lifecycle.isPaused, autoPaused: recorder.lifecycle.autoPaused,
            paceSecPerKm: pace, alpha1Status: recorder.dfa.status
        ))
    }

    /// Tick stage — one-shot auto route detection gate.
    private func attemptRouteDetectionIfEligible(sport: Sport) {
        // Auto-detect a familiar route once we've covered enough
        // ground for shape comparison to mean something. Only fires
        // when the user didn't already pick a route — a manual GPX
        // pick always wins. The detector is one-shot per session;
        // setting `recorder.routeDetectionAttempted = true` regardless of
        // outcome stops us from re-scanning every tick.
        if recorder.plannedRoute == nil, !recorder.routeDetectionAttempted, sport.usesGPS {
            recorder.attemptAutoRouteDetection(sport: sport)
        }
    }

    /// Tick stage — live HR + power push to the Zwift BLE broadcaster.
    private func pushZwiftBroadcasterUpdate() {
        // Push live HR + power to the Zwift broadcaster (no-op when
        // user hasn't enabled it). One source of truth for both the
        // app's own analysis and any indoor-trainer game pairing.
        AppDependencies.current.collection.zwiftPeripheralBroadcaster.update(
            heartRate: recorder.workoutHR.currentHR,
            powerWatts: recorder.motion.powerWatts
        )
    }

    /// Tick stage — weather + reverse-geocode refresh, each only when
    /// something will use it.
    ///
    /// Weather feeds the AI coach and, for outdoor sports, the snapshot saved
    /// with the workout that heat tracking reads, so it refreshes when the
    /// assistant is on or heat tracking is on for a GPS sport. Road context is
    /// read only by the AI coach, so it refreshes only with the assistant on.
    /// With neither in use the services stay idle (no allocations, no
    /// network); on a cold cellular start the geocoding pipeline (tile search
    /// + CLGeocoder + cross-street MKLocalSearch chain) would otherwise show
    /// up as a slow workout start.
    ///
    /// Weather is internally throttled (30-min cache); the first call after
    /// location lock fetches, later calls no-op until TTL. Reverse-geocoding
    /// turns current GPS into a road / locality / country tuple so the AI
    /// coach can say "you're on Elm Street" instead of reading raw lat/lon —
    /// internally rate-limited (>15 m movement OR >60 s elapsed gates each
    /// lookup), and pre-warmed at app launch, so per-tick calls are cheap
    /// after the first one.
    private func refreshEnvironmentContextIfNeeded(sport: Sport) {
        let settings = recorder.settingsProvider()
        let location = recorder.location.currentLocation
        if settings.enableAIAssistant || (settings.heatTrackingEnabled && sport.usesGPS) {
            AppDependencies.current.location.weatherService.refreshIfNeeded(for: location)
        }
        guard settings.enableAIAssistant else { return }
        AppDependencies.current.location.roadGeocodingService.refreshIfNeeded(for: location)
    }

    /// Tick stage — builds the AI context snapshot and lets the voice coach evaluate triggers.
    private func tickVoiceCoach(sport: Sport) {
        // Build a factual context snapshot and let the voice coach decide
        // whether any trigger rules fire. The coach enforces cooldowns
        // and mute/quiet-mode internally.
        let context = recorder.buildContext(sport: sport)
        recorder.voiceCoach.tick(context: context)
    }

    // MARK: - HR-source arbitration (pure decision core)

    /// HR source priority by `recorder.activeHRSource`:
    ///
    ///   - .strap  : strap is primary. Watch is the silent-strap fallback.
    ///               Order: (a) iPhone-paired strap (already in workoutHR
    ///               from RR derivation earlier in the tick), (b) Watch
    ///               direct-strap (also already applied in the tick when
    ///               the route is fresh), (c) Watch wrist HR.
    ///   - .watch  : Watch is primary. Always use Watch wrist HR.
    ///   - .none   : no HR at all.
    ///
    /// When the user is told (`strapNotice`):
    ///   • only in `.strap` mode;
    ///   • only past `strapNoticeGraceSec` of recording, so a strap still
    ///     connecting at the start is not an alarm;
    ///   • only while both strap channels are silent;
    ///   • "not connected" when there is no link, "silent" when the link
    ///     judges the feed stalled. A strap still setting up raises nothing.
    ///
    /// Pure: inputs in, `Decision` out. No clocks, no logging, no state.
    enum HRArbitration {
        /// Both strap channels silent past this → fall through to wrist HR.
        static let wristFallbackSilenceSec: TimeInterval = 10
        /// Recording time before a missing strap is worth telling the user about.
        static let strapNoticeGraceSec: TimeInterval = 15
        /// Wrist HR the Watch sent longer ago than this is treated as no
        /// longer arriving. The Watch sends a new reading every few seconds.
        static let wristHRMaxAgeSec: TimeInterval = 30

        /// Everything the per-tick cascade reads, snapshotted by the shell.
        /// The silence intervals are `.infinity` when that channel has never
        /// produced an event this workout (nil timestamp).
        struct Inputs {
            /// Which HR source the user picked for this workout.
            var sourceMode: WorkoutRecorder.HRSource
            /// Seconds of recording elapsed (frozen while paused, like the
            /// clock the user sees).
            var recordingElapsedSeconds: Int
            /// Seconds since the iPhone-paired Polar last produced a beat.
            var strapSilentFor: TimeInterval
            /// Seconds since the Watch-routed strap path last produced beats.
            /// Deliberately a separate channel from `strapSilentFor` — reusing
            /// one timestamp would mask a true Polar drop with stale freshness
            /// from the Watch path and break the wrist-HR tier (see
            /// `recorder.lastWatchRoutedHRAt`).
            var watchRoutedSilentFor: TimeInterval
            /// Watch wrist HR (optical), if the Watch is still reporting one.
            var latestWatchHR: Int?
            /// The strap's heart-rate feed as its link sees it.
            var strapFeed: StrapFeedHealth.Status
        }

        /// What the shell must apply. Pure data — no side effects here.
        struct Decision: Equatable {
            /// Wrist HR to copy into the live display (+ peak tracking), or
            /// nil to leave the display exactly as the RR-derived paths set it.
            var displayHRUpdate: Int?
            /// Why the strap is not supplying heart rate, when the user should know.
            var strapNotice: WorkoutStrapNotice?
            /// Every source the mode relies on is silent: the display drops
            /// its last value rather than recording it as current.
            var clearDisplayHR = false
        }

        /// Whether the heart rate on display after `decision` is the Watch's
        /// wrist HR: yes once wrist HR is copied in, no once the display is
        /// cleared, otherwise unchanged (the strap paths clear it when they
        /// write a reading).
        static func displayIsWrist(_ decision: Decision, wasWrist: Bool) -> Bool {
            if decision.displayHRUpdate != nil { return true }
            if decision.clearDisplayHR { return false }
            return wasWrist
        }

        static func decide(_ inputs: Inputs) -> Decision {
            let update = displayHRUpdate(inputs)
            return Decision(
                displayHRUpdate: update, strapNotice: strapNotice(inputs),
                clearDisplayHR: update == nil && allSourcesSilent(inputs)
            )
        }

        private static func allSourcesSilent(_ inputs: Inputs) -> Bool {
            switch inputs.sourceMode {
            case .strap:
                inputs.strapSilentFor > wristFallbackSilenceSec
                    && inputs.watchRoutedSilentFor > wristFallbackSilenceSec
                    && inputs.latestWatchHR == nil
            case .watch: inputs.latestWatchHR == nil
            case .none: false
            }
        }

        /// In `.strap` mode, both strap channels going silent falls through to
        /// Watch wrist HR — the chest-strap path earlier in the tick already
        /// handled the case where Watch-routed strap is fresh. nil wrist HR →
        /// no update here (`allSourcesSilent` decides whether to clear).
        private static func displayHRUpdate(_ inputs: Inputs) -> Int? {
            switch inputs.sourceMode {
            case .strap:
                guard inputs.strapSilentFor > wristFallbackSilenceSec,
                      inputs.watchRoutedSilentFor > wristFallbackSilenceSec
                else { return nil }
                return inputs.latestWatchHR
            case .watch:
                return inputs.latestWatchHR
            case .none:
                return nil
            }
        }

        private static func strapNotice(_ inputs: Inputs) -> WorkoutStrapNotice? {
            guard inputs.sourceMode == .strap,
                  TimeInterval(inputs.recordingElapsedSeconds) > strapNoticeGraceSec,
                  inputs.strapSilentFor > wristFallbackSilenceSec,
                  inputs.watchRoutedSilentFor > wristFallbackSilenceSec
            else { return nil }
            switch inputs.strapFeed {
            case .waitingForStrap: return .strapNotConnected
            case .stalled: return .strapSilent
            case .settingUp, .live: return nil
            }
        }
    }

}
