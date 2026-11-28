import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// The workout ticker's per-tick work.

extension WorkoutTicker {
    // MARK: - Internal

    /// No tick batching. A tick fires `lifecycle.elapsedSeconds`,
    /// and inside `incrementalBackupTick` `workoutHR.beatCount` plus
    /// motion fields when fresh samples land, but SwiftUI's runloop-level
    /// coalescing means N observable assignments in one
    /// `Task { @MainActor }` block produce ONE body re-eval, not N.
    /// So the user-visible cost on
    /// iPhone 12+ is one body eval per tick, dominated by the
    /// body's own work, not by the number of properties written. Hand-rolled
    /// batching — writing to `@ObservationIgnored` storage and publishing once
    /// at the end of the tick — would buy nothing measurable and risk subtle
    /// race conditions on a 1 Hz path.
    ///
    /// Without the explicit run-loop mode the elapsed clock can freeze
    /// for tens of seconds, because `Timer.scheduledTimer(withTimeInterval:repeats:)`
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
        tickTimer?.invalidate()
        signals.hrFromWrist = false
        capture.wristHROffsets = []
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// One 1 Hz tick of the recording loop.
    ///
    /// Auto-pause / auto-resume is evaluated BEFORE elapsed gets bumped so a
    /// pause that fires on this very tick doesn't still advance the clock by
    /// one. Tick work (samples, live broker, watch push) still runs while
    /// paused — we want the Watch to see "paused" state and for the AI context
    /// to know — but `incrementalBackupTick` itself skips sample-append when
    /// paused.
    ///
    /// The clock is the wall clock less the pauses
    /// (`PauseTimeline.activeSeconds`), not a count of ticks: a repeating
    /// `Timer` does not replay the fires it missed while the app was
    /// suspended (a locked phone with no sensor keeping it awake) or the main
    /// actor was busy, and counting ticks would lose that time from the workout. It
    /// moves at least one second a tick, so every tick's sample has an offset
    /// of its own; after a gap it jumps to the real time, and the seconds in
    /// the gap have no sample, as none was taken.
    private func runTick() {
        guard case .recording = lifecycle.phase else { return }
        evaluateAutoPauseResume()
        if !lifecycle.isPaused {
            let wallActive = lifecycle.sessionStartDate.map {
                lifecycle.pauseTimeline.activeSeconds(sessionStart: $0, now: Date())
            } ?? 0
            lifecycle.elapsedSeconds = max(lifecycle.elapsedSeconds + 1, wallActive)
        } else {
            pauseControl.notePausedMotion(at: Date())
        }
        incrementalBackupTick()
    }

    /// Look at the current movement signals and decide whether to
    /// auto-pause or auto-resume. Runs every tick while recording.
    func evaluateAutoPauseResume() {
        guard let sport = lifecycle.currentSession?.sport else { return }
        if !lifecycle.isPaused {
            accrueStationaryAndMaybeAutoPause(sport: sport)
        } else if lifecycle.autoPaused {
            accrueMovingAndMaybeAutoResume(sport: sport)
        }
    }

    /// Signal precedence for "stopped":
    ///   1. GPS-sport + CoreLocation `.speed` < 0.3 m/s (1 km/h floor).
    ///      Negative speed = no fix / invalid — treated as unknown rather
    ///      than "stopped" so we don't pause during a GPS warm-up at the
    ///      start of a run.
    ///   2. Indoor-sport + cadence == 0 (treadmill stop, stationary
    ///      bike coast), read through `indoorCadence`: the pedometer keeps
    ///      its last cadence when CoreMotion stops sending one, so a
    ///      pedometer cadence whose step count has stopped moving reads as
    ///      0. nil cadence (too early to read) is NOT stopped — avoids a
    ///      spurious auto-pause in the first few seconds.
    private func isStopped(sport: Sport) -> Bool {
        guard sport.usesGPS else {
            guard let cadence = indoorCadence(sport: sport) else { return false }
            return cadence <= 1
        }
        let speed = sensors.location.currentLocation?.speed ?? -1
        guard speed >= 0 else { return false }
        return speed < 0.3
    }

    /// Signal precedence for "moving again" (auto-resume only, and
    /// only when we paused ourselves — manual pause stays put):
    ///   - GPS speed ≥ 0.8 m/s (slow walk), or cadence ≥ 60 spm indoors.
    private func isMovingAgain(sport: Sport) -> Bool {
        guard sport.usesGPS else {
            guard let cadence = indoorCadence(sport: sport) else { return false }
            return cadence >= 60
        }
        return (sensors.location.currentLocation?.speed ?? -1) >= 0.8
    }

    /// Seconds without a new pedometer step after which the pedometer's
    /// cadence is taken as stale. CoreMotion sends updates every few seconds
    /// while steps accrue.
    private static let pedometerCadenceStaleSeconds: TimeInterval = 6

    /// The live cadence for the indoor auto-pause rules. `WorkoutPedometer`
    /// only overwrites its cadence when CoreMotion supplies one, so after a
    /// treadmill stop the last walking cadence stays in place. For a
    /// pedometer sport whose cadence is the pedometer's (no foot pod), a step
    /// count unchanged for `pedometerCadenceStaleSeconds` reads as cadence 0.
    /// Records the step count each tick to tell when it last moved.
    private func indoorCadence(sport: Sport) -> Double? {
        let steps = sensors.pedometer.stepCount
        let now = Date()
        if steps != sensors.lastPedometerStepAdvance.count {
            sensors.lastPedometerStepAdvance = (steps, now)
        }
        guard let cadence = motion.cadenceStepsPerMin else { return nil }
        guard WorkoutSessionLifecycle.pedometerSports.contains(sport),
              sensors.footPod.currentCadenceStepsPerMin(now: now) == nil,
              let advancedAt = sensors.lastPedometerStepAdvance.at,
              now.timeIntervalSince(advancedAt) > Self.pedometerCadenceStaleSeconds
        else { return cadence }
        return 0
    }

    private func accrueStationaryAndMaybeAutoPause(sport: Sport) {
        if pauseControl.autoPause.accrueStationary(isStopped: isStopped(sport: sport)) {
            pauseControl.pause(isAuto: true)
        }
    }

    private func accrueMovingAndMaybeAutoResume(sport: Sport) {
        if pauseControl.autoPause.accrueMoving(isMoving: isMovingAgain(sport: sport)) {
            pauseControl.resume()
        }
    }

    func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// The strap link already publishes a heart rate the HRV path consumes.
    /// Observe it through `ObservationLoop` and mirror the latest value into
    /// `workoutHR` for the UI. Changes arrive as a main-actor hop rather than
    /// through a run-loop mode, so the mirror keeps updating while the user is
    /// touching the screen.
    func observeHeartRate() {
        hrSubscription = ObservationLoop.observe(self, initial: true, read: { $0.core.strapLink.currentHeartRate }, onChange: { ticker, newHR in
            ticker.mirrorStrapHeartRate(newHR)
        })
    }

    /// Ends the strap-HR observation `observeHeartRate` started.
    func stopObservingHeartRate() {
        hrSubscription?.cancel()
        hrSubscription = nil
    }

    private func mirrorStrapHeartRate(_ newHR: Int?) {
        workoutHR.currentHR = newHR
        signals.hrFromWrist = false
        guard let newHR, newHR > workoutHR.peakHR else { return }
        workoutHR.peakHR = newHR
    }

    /// Feed any newly-arrived RR points into the live DFA analyzer. The
    /// Polar streaming buffer grows as beats arrive; we only hand the new
    /// slice to the DFA each tick to avoid reprocessing the whole session.
    ///
    /// Why derive HR from RR here instead of subscribing to
    /// StrapLinkState.currentHeartRate: the strap broadcasts HR on a
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
    ///
    /// The strap buffer is read only for a strap workout: a stopped stream
    /// keeps its points, so for a Watch or no-HR workout it may hold a
    /// previous session's beats, which must not be backed up, counted or
    /// turned into heart rate under this workout's id.
    func incrementalBackupTick() {
        let buffer = WorkoutRRMerge.liveStrapBuffer(source: lifecycle.activeHRSource, streaming: core.strapStream.streamedRRPoints)
        workoutHR.beatCount = buffer.count

        runIncrementalBackup(buffer: buffer)
        ingestStrapBeatsAndDeriveHR(buffer: buffer)
        adoptStrapHeartRateReading()
        consumeWatchRoutedStrapFallback()
        arbitrateHRSource()
        mirrorMotionAndPowerSensors()
        updateLivePace()
        capturePerSecondSample()
        if settingsProvider().enableAIAssistant {
            publishLiveWorkoutSnapshot()
        }
        if let sport = lifecycle.currentSession?.sport {
            runSportScopedTickWork(sport: sport)
        }
        advanceIntervalPlanUnlessPaused()
    }

    /// Advance the interval plan (if any). Transitions fire via the
    /// controller's onStepChange hook wired in start(). Not while paused:
    /// a step must not advance or be announced during a rest stop.
    private func advanceIntervalPlanUnlessPaused() {
        guard !lifecycle.isPaused else { return }
        _ = intervalController.tick(totalDistanceMeters: motion.distanceMeters)
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
        aiContext.updateThresholdBreaches(sport: sport)
        attemptRouteDetectionIfEligible(sport: sport)
        pushZwiftBroadcasterUpdate()
        refreshEnvironmentContextIfNeeded(sport: sport)
        refreshPlaceMemory(sport: sport)
        tickVoiceCoach(sport: sport)
    }

    /// Tick stage — past workouts' view of the ground ahead and of this spot,
    /// for a GPS sport. The work runs off the main actor (`LivePlaceMemory`).
    private func refreshPlaceMemory(sport: Sport) {
        guard sport.usesGPS, !lifecycle.isPaused else { return }
        let location = sensors.startedLocation?.currentLocation
        routeGuidance.places.update(
            location: location, heading: Self.validCourse(location),
            sessionStart: lifecycle.sessionStartDate ?? Date(), archive: services.sessionArchive
        )
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
        guard let session = lifecycle.currentSession else { return }
        let sessionId = session.id
        let startDate = session.startDate
        let deviceId = core.strapLink.connectedDeviceId
        let bufferSnapshot = buffer  // copy before handing off
        let backup = core.rawBackup
        let cloudSyncManager = core.cloudSyncManager
        Task.detached(priority: .utility) {
            let didBackup = backup.incrementalBackup(
                points: bufferSnapshot, sessionId: sessionId, deviceId: deviceId, captureDate: startDate
            )
            guard didBackup else { return }
            await cloudSyncManager.uploadLiveBackup(
                sessionId: sessionId, points: bufferSnapshot, recordingStart: startDate, deviceId: deviceId
            )
        }
        persistWorkoutTrackIfChanged(session: session, sessionId: sessionId)
    }

    /// Tick stage: the pause and resume events into the crash backup, when
    /// one was added since the last tick. Apart from the track watermark,
    /// which skips while paused: a pause is written as it begins, so a
    /// workout lost while paused still knows it was paused.
    private func persistPauseEventsIfChanged(sessionId: UUID) {
        let events = lifecycle.pauseTimeline.events
        guard capture.pauseEventsBackedUp[sessionId] != events.count else { return }
        capture.pauseEventsBackedUp = [sessionId: events.count]
        let trackBackup = services.workoutTrackBackup
        Task.detached(priority: .utility) {
            trackBackup.appendPauses(sessionId: sessionId, events: events)
        }
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
    /// While recording, a sample row lands every unpaused second, so the
    /// watermark skips mostly while paused; the track and barometer rows are
    /// therefore extended incrementally rather than re-mapped each tick.
    ///
    /// The samples mark is the newest row's `offsetSec`, not the row count:
    /// past 12 h `capWorkoutSampleMemory` drops a row for each one added, so
    /// the count stops changing while new rows still need backing up.
    private func persistWorkoutTrackIfChanged(session: HRVSession, sessionId: UUID) {
        persistPauseEventsIfChanged(sessionId: sessionId)
        guard capture.trackBackupWatermark.advanceIfChanged(
            trackCount: sensors.startedLocation?.track.count ?? 0,
            baroCount: sensors.startedLocation?.barometricSamples.count ?? 0,
            samplesCount: capture.workoutSamples.last?.offsetSec ?? 0
        ) else { return }
        appendTrackSnapshot(session: session, sessionId: sessionId)
    }

    /// Conversion to value types is done on the MainActor so the
    /// detached task only sees `Sendable` payloads — `CLLocation`
    /// is non-Sendable in Swift 6 and would otherwise warn on
    /// capture. The rows are kept on the capture and extended by what
    /// arrived since the last snapshot (`TrackBackupRows`), not re-mapped
    /// whole each tick.
    private func appendTrackSnapshot(session: HRVSession, sessionId: UUID) {
        let sport = session.sport ?? .run
        let startDate = lifecycle.sessionStartDate ?? session.startDate
        let location = sensors.startedLocation
        capture.trackBackupRows.sync(sessionId: sessionId, track: location?.track ?? [], baro: location?.barometricSamples ?? [])
        let fixSnapshot = capture.trackBackupRows.fixes
        let baroSnapshot = capture.trackBackupRows.baro
        let samplesSnapshot = capture.workoutSamples
        let wristOffsetsSnapshot = capture.wristHROffsets
        let trackBackup = services.workoutTrackBackup
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
        guard buffer.count > capture.lastIngestedPointCount else {
            // No new beats this tick. Still advance the analyzer's clock so
            // its status can report "strap silent for N seconds" — otherwise
            // the UI would read "warming up" forever after a strap drop.
            dfa.tick()
            return
        }
        dfa.ingest(points: Array(buffer[capture.lastIngestedPointCount ..< buffer.count]))
        if let derivedHR = Array(buffer.suffix(8)).medianHeartRateBPM {
            workoutHR.currentHR = derivedHR
            signals.hrFromWrist = false
            if derivedHR > workoutHR.peakHR { workoutHR.peakHR = derivedHR }
            signals.lastStrapHRAt = Date()  // strap is alive
        }
        capture.lastIngestedPointCount = buffer.count
    }

    /// Tick stage: the strap's own heart rate, when it sent one no buffered
    /// beat accounts for.
    ///
    /// A Verity Sense keeps sending its heart rate while `StrapPPIFilter`
    /// rejects every PPI interval (motion-flagged, high error estimate:
    /// common while running). No beat reaches the buffer then, so the strap
    /// would read as silent after `HRArbitration.wristFallbackSilenceSec`
    /// and the live HR and the samples would lose a heart rate the strap is
    /// still sending. Its reading keeps the strap live from the time it
    /// arrived and is the heart rate on display; only accepted intervals
    /// feed RR and HRV. A strap workout only: on any other, the linked
    /// strap's reading is not the workout's heart rate.
    private func adoptStrapHeartRateReading() {
        guard lifecycle.activeHRSource == .strap,
              let reading = Self.newStrapReading(
                  hr: core.strapLink.currentHeartRate, at: core.strapLink.currentHeartRateAt, lastStrapHRAt: signals.lastStrapHRAt
              )
        else { return }
        signals.lastStrapHRAt = reading.at
        workoutHR.currentHR = reading.hr
        signals.hrFromWrist = false
        if reading.hr > workoutHR.peakHR { workoutHR.peakHR = reading.hr }
    }

    /// The strap's reading when it is newer than the last strap heart rate
    /// the workout took (from a beat or an earlier reading); nil otherwise.
    static func newStrapReading(hr: Int?, at readingAt: Date?, lastStrapHRAt: Date?) -> (hr: Int, at: Date)? {
        guard let hr, hr > 0, let readingAt, readingAt > (lastStrapHRAt ?? .distantPast) else { return nil }
        return (hr, readingAt)
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
    /// same beats; taking the Watch's as well would count every beat twice. The
    /// queue is still drained, so beats from a stretch the phone covered are
    /// not replayed when it next drops.
    ///
    /// Each queued beat carries when it ended by the Watch's clock
    /// (`WatchStrapBeat`), so beats from several samples keep the time
    /// between them. Beats left from a batch more than 10 s old (the ticks
    /// stopped while the app was suspended) are kept at their own times and
    /// go into the series, but not into the live α1 or the live heart rate,
    /// which they no longer describe.
    private func consumeWatchRoutedStrapFallback() {
        guard let watchStrapAt = watchBridge.latestWatchStrapAt else { return }
        let drainedWatchRR = watchBridge.drainPendingWatchStrapRR()
        guard !drainedWatchRR.isEmpty, !phoneStrapIsLive else { return }
        let newPoints = synthesizeWatchRoutedPoints(drainedWatchRR)
        guard !newPoints.isEmpty else { return }
        capture.watchRouted.points.append(contentsOf: newPoints)
        guard Date().timeIntervalSince(watchStrapAt) < 10 else { return }
        dfa.ingest(points: newPoints)
        applyWatchRoutedHR()
    }

    /// Moves the Watch beats' clock up to the batch's place in the workout.
    private func alignWatchClock(toWallMs wallMs: Int64) {
        guard let start = lifecycle.sessionStartDate else { return }
        let sinceStart = wallMs - Int64(start.timeIntervalSince1970 * 1000)
        capture.watchRouted.cumulativeMs = max(capture.watchRouted.cumulativeMs, sinceStart)
    }

    /// When the phone's strap stream started, in epoch milliseconds: the zero
    /// of the phone beats' `wallClockMs`. The workout start stands in when
    /// no stream ran.
    private var streamClockBaseEpochMs: Int64 {
        let base = core.strapStream.streamingStartTime ?? lifecycle.sessionStartDate
        return Int64((base?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private var phoneStrapIsLive: Bool {
        signals.lastStrapHRAt.map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// Synthesize RRPoints for the beats the Watch carried, each starting
    /// where the Watch's clock puts it (`WatchStrapBeat.endEpochMs` less its
    /// interval), never before the beat ahead of it ended. A gap between two
    /// samples stays in both clocks, so the break check
    /// (`TimeDomainAnalyzer.isRecordingBreak`) sees it. `t_ms` here is only
    /// for the live readout; `WorkoutRRMerge` orders the finished series by
    /// wall clock and rebuilds it.
    ///
    /// `wallClockMs` is milliseconds since the strap stream started, the
    /// clock the phone's own beats carry, so the two can be interleaved.
    ///
    /// Every beat has been through `WatchPayloadBounds.plausibleRRMillis`,
    /// so every value is finite and inside the RR band before `Int(...)`;
    /// the ones it rejected yield no beat and mark the next one
    /// (`WatchStrapBeat.placed`).
    private func synthesizeWatchRoutedPoints(_ beats: [WatchStrapBeat]) -> [RRPoint] {
        let base = streamClockBaseEpochMs
        let hr = WatchPayloadBounds.plausibleHeartRate(watchBridge.latestWatchStrapHR)
        let lastEnd = capture.watchRouted.lastEndEpochMs
        let placed = WatchStrapBeat.placed(beats, after: lastEnd, removedBefore: &capture.watchRouted.removedSinceLastBeat)
        return placed.map { beat in
            alignWatchClock(toWallMs: beat.startEpochMs)
            let point = RRPoint(
                t_ms: capture.watchRouted.cumulativeMs, rr_ms: beat.rrMs, wallClockMs: beat.startEpochMs - base,
                hr: hr, followsRemovedBeat: beat.followsRemovedBeat
            )
            capture.watchRouted.cumulativeMs += Int64(beat.rrMs)
            capture.watchRouted.lastEndEpochMs = beat.startEpochMs + Int64(beat.rrMs)
            return point
        }
    }

    /// Fold the Watch-routed strap HR into the live display +
    /// peak tracking when this path produces beats. Without this, a Polar
    /// drop with Watch-routed RR ingestion still leaves the user staring at a
    /// stale HR number, because the wrist-HR fallback in
    /// `arbitrateHRSourceAndRunWatchdog` only fires when `signals.lastStrapHRAt` is
    /// older than 10 s — and we'd want it FRESH (so the cache survives) but
    /// also need the display to update.
    ///
    /// `capture.watchRouted.lastAt` is a separate freshness timestamp so the
    /// silent-strap detector treats Polar-direct and Watch-routed channels as
    /// independent. Reusing `signals.lastStrapHRAt` would mask a true Polar drop with
    /// stale freshness from the Watch path and break the wrist-HR tier.
    private func applyWatchRoutedHR() {
        if let strapHR = WatchPayloadBounds.plausibleHeartRate(watchBridge.latestWatchStrapHR) {
            workoutHR.currentHR = strapHR
            signals.hrFromWrist = false
            if strapHR > workoutHR.peakHR { workoutHR.peakHR = strapHR }
        }
        capture.watchRouted.lastAt = Date()
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
    /// `signals.hrFromWrist` follows the decision (`HRArbitration.displayIsWrist`),
    /// so the per-second sample knows its heart rate came from Apple Health.
    private func arbitrateHRSource() {
        let arbitration = HRArbitration.decide(HRArbitration.Inputs(
            sourceMode: lifecycle.activeHRSource,
            recordingElapsedSeconds: lifecycle.elapsedSeconds,
            strapSilentFor: signals.lastStrapHRAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            watchRoutedSilentFor: capture.watchRouted.lastAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            latestWatchHR: watchBridge.freshWristHR(now: Date()),
            strapFeed: core.strapLink.feedStatus
        ))
        applyDisplayHR(arbitration)
        if lifecycle.strapNotice != arbitration.strapNotice {
            lifecycle.strapNotice = arbitration.strapNotice
            if let notice = arbitration.strapNotice {
                debugLog("[Recorder] Strap notice raised \(lifecycle.elapsedSeconds)s in: \(notice)", level: .warning)
            }
        }
    }

    private func applyDisplayHR(_ arbitration: HRArbitration.Decision) {
        if let watchHR = arbitration.displayHRUpdate {
            workoutHR.currentHR = watchHR
            if watchHR > workoutHR.peakHR { workoutHR.peakHR = watchHR }
        } else if arbitration.clearDisplayHR {
            workoutHR.currentHR = nil
        }
        signals.hrFromWrist = HRArbitration.displayIsWrist(arbitration, wasWrist: signals.hrFromWrist)
    }

    /// Tick stage — mirrors location / pedometer / foot pod / PM5 into the motion observable + power tallies.
    ///
    /// Distance: there is no precedence order. The live value is the
    /// LARGEST of foot pod, GPS and pedometer distance (`max(...)`), so no
    /// source gets clipped — GPS reads zero indoors, where a treadmill's
    /// foot pod or the pedometer still measures. A connected foot pod wins
    /// only when it reports the most distance.
    ///
    /// Cadence precedence:
    ///   1. Foot pod (direct stride measurement)
    ///   2. Pedometer (iPhone motion coprocessor estimate)
    ///
    /// Rower sport: the PM5's distance, cadence (stroke rate) and power win
    /// over the other sources whenever it reports them. Power comes only
    /// from the PM5 on `.row`. Distance and cadence do not: while the PM5
    /// reports no distance (not linked yet, or dropped) the usual
    /// max-of-sources distance stands in, and while it reports no stroke
    /// rate the foot-pod / pedometer cadence does. Stroke rate surfaces in
    /// the same field used by the live UI — the cadence label flips to
    /// "spm" on the row sport in the recording view.
    private func mirrorMotionAndPowerSensors() {
        motion.footPodActive = sensors.footPod.connectionState == .connected
        let isRow = lifecycle.currentSession?.sport == .row
        let erg = isRow ? services.concept2Manager : nil
        if isRow, let ergDist = erg?.distanceMeters {
            motion.distanceMeters = ergDist
        } else {
            let paused = lifecycle.pausedMotion
            motion.distanceMeters = max(
                paused.footPodDistance(sensors.footPodDistanceMeters()),
                max(sensors.startedLocation?.distanceMeters ?? 0, paused.pedometerDistance(sensors.pedometer.distanceMeters))
            )
        }
        motion.elevationGainMeters = sensors.startedLocation?.elevationGainMeters ?? 0
        mirrorLiveTrackIfChanged()
        motion.stepCount = sensors.pedometer.stepCount
        motion.cadenceStepsPerMin = (isRow ? erg?.currentStrokeRateSPM() : nil)
            ?? sensors.footPod.currentCadenceStepsPerMin()
            ?? sensors.pedometer.cadenceStepsPerMin
        tallyPower(isRow ? erg?.currentPowerWatts() : sensors.footPod.currentPowerWatts())
    }

    /// The map's track, set only when a fix was added or replaced: setting
    /// the observed array each second would redraw the whole polyline of a long
    /// workout even while standing still.
    private func mirrorLiveTrackIfChanged() {
        let track = sensors.startedLocation?.track ?? []
        let shown = motion.liveTrack
        guard shown.count != track.count || shown.last !== track.last else { return }
        motion.liveTrack = track
    }

    /// Power (watts). Captures running totals for the post-summary's
    /// avg / normalized / peak figures. Normalized power is computed on
    /// finalize from the full sample series, not here. Rower power
    /// comes from the PM5; foot-pod power covers run / walk / hike;
    /// FTMS bike trainers route through the foot-pod manager too.
    ///
    /// While paused the live reading is still shown but not tallied, the
    /// same rule as the per-second samples, so an idle 0 W during a rest
    /// stop does not dilute the stored average power. While recording, 0 W
    /// (coasting) is a reading and counts; a foot-pod reading older than
    /// `FootPodManager.readingStaleAfter`, or a PM5 stroke older than
    /// `Concept2Manager.strokeStaleAfter`, is no reading (each manager's
    /// `currentPowerWatts`), so a meter that went quiet, or an erg resting
    /// after its last stroke, does not have its last watts counted every
    /// second.
    private func tallyPower(_ liveWatts: Int?) {
        guard let w = liveWatts else {
            motion.powerWatts = nil
            return
        }
        motion.powerWatts = w
        guard !lifecycle.isPaused else { return }
        capture.power.add(w)
    }

    /// Tick stage — per-second WorkoutSample capture (skipped while paused).
    ///
    /// Sampled 1 Hz. Persisted to WorkoutMetadata.samples on finalize so
    /// post-summary can render real charts (HR over time, pace, cadence)
    /// AND exports can attach per-row metrics instead of just GPS.
    ///
    /// Skipped while paused — otherwise the chart would have a flat-line
    /// valley during a rest stop that looks like the user crashed to 0
    /// pace. Paused samples intentionally fall off the series so the
    /// resume point sits right up against the pre-pause sample.
    ///
    /// A row whose heart rate is the Watch's wrist HR has its offset added to
    /// `capture.wristHROffsets`.
    private func capturePerSecondSample() {
        guard !lifecycle.isPaused, let sport = lifecycle.currentSession?.sport else { return }
        capture.workoutSamples.append(makeSample(sport: sport, paceSecPerKm: signals.currentPaceSecPerKm))
        if signals.hrFromWrist, workoutHR.currentHR != nil {
            capture.wristHROffsets.append(lifecycle.elapsedSeconds)
        }
        capWorkoutSampleMemory()
    }

    /// Values that are not finite numbers are recorded as missing
    /// (`finiteValuesOnly`): the archive cannot encode NaN or infinity.
    private func makeSample(sport: Sport, paceSecPerKm: Double?) -> WorkoutSample {
        WorkoutSample(
            offsetSec: lifecycle.elapsedSeconds, heartRate: workoutHR.currentHR,
            distanceMeters: motion.distanceMeters > 0 ? motion.distanceMeters : nil,
            paceSecPerKm: paceSecPerKm, cadenceStepsPerMin: motion.cadenceStepsPerMin,
            altitudeMeters: sensors.startedLocation?.currentLocation?.altitude, alpha1: dfa.currentAlpha1,
            mets: WorkoutSessionLifecycle.estimateMETs(
                sport: sport, paceSecPerKm: paceSecPerKm, heartRate: workoutHR.currentHR,
                userMaxHR: settingsProvider().effectiveMaxHR
            ),
            powerWatts: motion.powerWatts
        ).finiteValuesOnly
    }

    /// Tick stage — feeds this tick's distances and speeds to `signals.livePace`.
    ///
    /// A paused tick clears it: a pause is not a pace, and the window must not
    /// span it. The rower's odometer is its only distance.
    private func updateLivePace() {
        guard !lifecycle.isPaused, let sport = lifecycle.currentSession?.sport else {
            signals.livePace.reset()
            return
        }
        let paused = lifecycle.pausedMotion
        let outdoors = sport.usesGPS
        signals.livePace.update(LivePaceEstimator.Reading(
            now: Date(), distanceMeters: motion.distanceMeters,
            gpsMeters: outdoors ? sensors.location.distanceMeters : nil,
            pedometerMeters: LivePaceEstimator.countsSteps(sport) ? paused.pedometerDistance(sensors.pedometer.distanceMeters) : nil,
            footPodSpeedMS: sensors.footPod.currentSpeedMS(),
            gps: outdoors ? sensors.location.currentLocation.map(LivePaceEstimator.GPSSpeed.init) : nil
        ))
    }

    /// Defensive memory cap, mirroring the strap stream's RR streaming
    /// buffer. One WorkoutSample is appended ~1 Hz, so 12h of samples
    /// is the ceiling; a normal-length workout never reaches it. If
    /// exceeded (e.g. a session left running for days), drop the
    /// oldest so memory stays bounded. Each sample carries an absolute
    /// `offsetSec`, so dropping the head doesn't corrupt the rest, and the
    /// crash-recovery backup finds the rows it has not written by that key,
    /// so it keeps every row, the dropped ones included. The drop is marked
    /// (`WorkoutCapture.sampleHeadTrimmed`), so finalize reads the dropped
    /// rows back from that backup before the archive write.
    private func capWorkoutSampleMemory() {
        let maxWorkoutSamples = 60 * 60 * 12 // 12h at 1 sample/sec
        guard capture.workoutSamples.count > maxWorkoutSamples else { return }
        capture.workoutSamples.removeFirst(capture.workoutSamples.count - maxWorkoutSamples)
        capture.sampleHeadTrimmed = true
        capture.wristHROffsets = Self.offsets(capture.wristHROffsets, keptFrom: capture.workoutSamples.first?.offsetSec)
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
        guard let sport = lifecycle.currentSession?.sport else { return }
        let loc = sensors.startedLocation?.currentLocation
        let heading = Self.validCourse(loc)
        services.liveWorkoutBroker.publish(
            buildBrokerSnapshot(
                sport: sport,
                loc: loc,
                heading: heading,
                speedMS: signals.currentSpeedMS,
                lastSample: capture.workoutSamples.last,
                strapSilent: signals.strapSilentSeconds(source: lifecycle.activeHRSource),
                liveZoneBreakdown: capture.liveZoneBreakdown(userMaxHR: settingsProvider().effectiveMaxHR)
            )
        )
    }

    /// CoreLocation reports a negative course when it has no valid reading;
    /// surface that as nil rather than as a heading of -1°.
    static func validCourse(_ loc: CLLocation?) -> Double? {
        guard let c = loc?.course, c >= 0 else { return nil }
        return c
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
    /// `services.roadGeocodingService.current` seven times.
    ///
    /// Both this type and `RoadGeocodingService` are `@MainActor` and this
    /// function is synchronous, so all seven reads would observe the same
    /// value anyway; reading once states the snapshot's dependency on the
    /// geocoder at the top rather than seven times in an argument list.
    ///
    /// The live trends, historical baselines and readiness
    /// fields carry the same data fed to the voice path, mirrored here so
    /// chat-mode tool calls (`workout.live.snapshot`) see what voice's
    /// `asFactSheet` sees. The trends come from the tally kept as the buffer
    /// grows (`syncedLiveTrends`), read after `liveZoneBreakdown` updated it.
    private func buildBrokerSnapshot(
        sport: Sport,
        loc: CLLocation?,
        heading: Double?,
        speedMS: Double?,
        lastSample: WorkoutSample?,
        strapSilent: Double?,
        liveZoneBreakdown: WorkoutZoneBreakdown
    ) -> AssistantContext.LiveWorkoutSnapshot {
        let (road, trends) = (services.roadGeocodingService.current, capture.syncedLiveTrends())
        return withGroundAhead(AssistantContext.LiveWorkoutSnapshot(
            sport: sport.displayName, snapshotAt: Date(), sessionStartAt: lifecycle.sessionStartDate ?? Date(), elapsedSeconds: lifecycle.elapsedSeconds, heartRate: workoutHR.currentHR, peakHR: workoutHR.peakHR, userMaxHR: settingsProvider().effectiveMaxHR,
            beatCount: workoutHR.beatCount, distanceMeters: motion.distanceMeters, stepCount: motion.stepCount, cadenceStepsPerMin: motion.cadenceStepsPerMin, elevationGainMeters: motion.elevationGainMeters, alpha1: dfa.currentAlpha1,
            alpha1Band: dfa.currentBand.label, alpha1Status: dfa.status.label, alpha1FitQualityR2: dfa.fitQuality, strapConnected: core.strapLink.connectionState == .connected, strapSilentSec: strapSilent, gpsFixCount: motion.liveTrack.count,
            gpsAccuracyMeters: sensors.startedLocation?.lastHorizontalAccuracy, currentPaceSecPerKm: signals.currentPaceSecPerKm, currentSpeedMS: speedMS, powerWatts: motion.powerWatts, currentMETs: lastSample?.mets, recentSplitPaces: aiContext.recentSplitPacesSecPerKm(),
            currentLatitude: loc?.coordinate.latitude, currentLongitude: loc?.coordinate.longitude, currentAltitudeMeters: loc?.altitude, currentHeadingDegrees: heading, currentHeadingCardinal: heading.map(Self.cardinal(fromCourse:)),
            currentGradePercent: aiContext.computeCurrentGradePercent(), unitsPreference: UnitsPreferenceStore.current.rawValue, targetZone: lifecycle.targetZone, recognizedRouteName: routeGuidance.planned?.name, recognizedRouteWasAutoDetected: routeGuidance.wasAutoDetected,
            recognizedRouteDirection: recognizedRouteDirectionLabel(), routeTotalDistanceMeters: routeGuidance.planned?.totalDistanceMeters, routeClimbCount: routeGuidance.planned?.climbs.count, currentRoadName: road?.road, currentLocality: road?.locality,
            currentAdministrativeArea: road?.administrativeArea, currentCountry: road?.country, currentCountryCode: road?.countryCode, currentCompactAddress: road?.compactAddress, currentNearestCrossStreet: road?.nearestCrossStreet,
            routeTopology: aiContext.liveRouteTopologySnapshot(currentLocation: loc), weather: aiContext.liveWeatherSnapshot(), reverseSplitDeltaSecPerKm: trends.reverseSplitDeltaSecPerKm,
            liveHRDriftPercent: trends.hrDriftPercent, aerobicDecouplingPercent: trends.aerobicDecouplingPercent, cadenceDriftSpm: trends.cadenceDriftSpm,
            gradeAdjustedPaceSecPerKm: liveGradeAdjustedPace(), recentSplitGradeAdjustedPaces: trends.recentSplitGradeAdjustedPaces, projectedMinutesUntilFade: trends.projectedMinutesUntilFade,
            historicalSportAvgPaceSecPerKm: coaching.startContext.historicalBaselines.avgPaceSecPerKm, historicalSportAvgHR: coaching.startContext.historicalBaselines.avgHR, historicalSportAvgAlpha1: coaching.startContext.historicalBaselines.avgAlpha1,
            historicalSportSampleCount: coaching.startContext.historicalBaselines.sampleCount, todayRecoveryScore: coaching.startContext.todayReadiness.recoveryScore, todayTrainingReadiness: coaching.startContext.todayReadiness.trainingReadiness, todayATL: coaching.startContext.todayReadiness.atl,
            todayCTL: coaching.startContext.todayReadiness.ctl, todayTSB: coaching.startContext.todayReadiness.tsb, projectedDaysUntilFresh: coaching.startContext.trainingProjection.daysUntilFresh, projectedTSBTomorrowSteadyState: coaching.startContext.trainingProjection.tsbTomorrowSteadyState,
            recoveryHoursNeeded: coaching.startContext.recoveryHoursNeeded, zone1Sec: liveZoneBreakdown.z1Sec, zone2Sec: liveZoneBreakdown.z2Sec, zone3Sec: liveZoneBreakdown.z3Sec, zone4Sec: liveZoneBreakdown.z4Sec, zone5Sec: liveZoneBreakdown.z5Sec, dominantZone: liveZoneBreakdown.dominantZone,
            predictedRaceTime5KSec: coaching.startContext.racePredictionsByDistance[5_000], predictedRaceTime10KSec: coaching.startContext.racePredictionsByDistance[10_000], predictedRaceTimeHalfSec: coaching.startContext.racePredictionsByDistance[21_097.5],
            predictedRaceTimeMarathonSec: coaching.startContext.racePredictionsByDistance[42_195], activeThresholds: activeThresholdSnapshots(), thresholdBreachSec: thresholdBreachSecByID(), intervalProgress: intervalController.liveProgressSnapshot()
        ))
    }

    /// What past workouts say about the ground ahead and this spot, and the
    /// threshold heart rate the answers measure against.
    private func withGroundAhead(_ snapshot: AssistantContext.LiveWorkoutSnapshot) -> AssistantContext.LiveWorkoutSnapshot {
        var snapshot = snapshot
        let settings = settingsProvider()
        snapshot.historyClimbAhead = routeGuidance.places.climbAhead
        snapshot.visitsHere = routeGuidance.places.visitsHere
        snapshot.thresholdHeartRate = settings.effectiveLTHR
        snapshot.thresholdHeartRateIsUserSet = settings.hasUserLTHR
        return snapshot
    }

    /// Direction is only meaningful for a route we recognised ourselves — a
    /// user-chosen route is always run in its stored direction.
    private func recognizedRouteDirectionLabel() -> String? {
        guard routeGuidance.wasAutoDetected else { return nil }
        return routeGuidance.direction == .reverse ? "reverse" : "forward"
    }

    private func liveGradeAdjustedPace() -> Double? {
        WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(
            pace: signals.currentPaceSecPerKm,
            gradePercent: aiContext.computeCurrentGradePercent()
        )
    }

    private func activeThresholdSnapshots() -> [AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot] {
        coaching.thresholds.thresholds.map {
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
        Dictionary(uniqueKeysWithValues: coaching.thresholds.breachSec.map { ($0.key.uuidString, $0.value) })
    }

    /// Tick stage — Watch live-state push (pace display + zone/pause state).
    private func pushLiveStateToWatch(sport: Sport) {
        let units = UnitsPreferenceStore.current.resolved
        let pace = signals.currentPaceSecPerKm
        let paceDisplay = pace.flatMap { units.formatPace(secondsPerMeter: $0 / 1000) }
        let settings = settingsProvider()
        watchBridge.sendLiveState(WatchConnectivityBridge.LiveState(
            sport: sport, heartRate: workoutHR.currentHR, peakHR: workoutHR.peakHR, userMaxHR: settings.effectiveMaxHR,
            totals: WatchConnectivityBridge.LiveTotals(
                elapsedSec: lifecycle.elapsedSeconds, distanceMeters: motion.distanceMeters,
                elevationGainMeters: motion.elevationGainMeters
            ),
            paceDisplay: paceDisplay, alpha1: dfa.currentAlpha1, band: dfa.currentBand.localizedLabel,
            cadenceSpm: motion.cadenceStepsPerMin, targetZone: lifecycle.targetZone, unitsPreference: units.rawValue,
            isRecording: true, isPaused: lifecycle.isPaused, autoPaused: lifecycle.autoPaused,
            paceSecPerKm: pace, alpha1Status: dfa.status
        ))
    }

    /// Tick stage — one-shot auto route detection gate.
    private func attemptRouteDetectionIfEligible(sport: Sport) {
        // Auto-detect a familiar route once we've covered enough
        // ground for shape comparison to mean something. Only fires
        // when the user didn't already pick a route — a manual GPX
        // pick always wins — and stops once one is bound. Between
        // attempts `attemptAutoRouteDetection` returns at once until the
        // track reaches `routeGuidance.nextDetectionAtMeters`.
        if routeGuidance.planned == nil, sport.usesGPS {
            aiContext.attemptAutoRouteDetection(sport: sport)
        }
    }

    /// Tick stage — live HR + power push to the Zwift BLE broadcaster.
    /// The setting is read each tick, so a broadcast whose setting went off
    /// any way (the Settings switch, an iCloud settings restore) stops here.
    private func pushZwiftBroadcasterUpdate() {
        // Push live HR + power to the Zwift broadcaster (no-op when
        // user hasn't enabled it). One source of truth for both the
        // app's own analysis and any indoor-trainer game pairing.
        let allowed = BroadcasterDisclosure.allowsBroadcast(settingEnabled: settingsProvider().enableZwiftBroadcast)
        guard services.zwiftPeripheralBroadcaster.stopUnlessAllowed(allowed) else { return }
        services.zwiftPeripheralBroadcaster.update(
            heartRate: workoutHR.currentHR,
            powerWatts: motion.powerWatts
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
        let settings = settingsProvider()
        let location = sensors.startedLocation?.currentLocation
        if settings.enableAIAssistant || (settings.heatTrackingEnabled && sport.usesGPS) {
            services.weatherService.refreshIfNeeded(for: location)
        }
        guard settings.enableAIAssistant else { return }
        services.roadGeocodingService.refreshIfNeeded(for: location)
    }

    /// Tick stage — builds the AI context snapshot and lets the voice coach evaluate triggers.
    private func tickVoiceCoach(sport: Sport) {
        // Build a factual context snapshot and let the voice coach decide
        // whether any trigger rules fire. The coach enforces cooldowns
        // and mute/quiet-mode internally.
        let context = aiContext.buildContext(sport: sport)
        voiceCoach.tick(context: context)
    }
}

/// The track and barometer rows the crash backup is handed each tick, kept
/// between ticks and extended by the fixes and samples that arrived since:
/// mapping the whole growing arrays every second copied them every second.
/// Rebuilt for a new session, or when either source shrank (reset).
struct TrackBackupRows {
    private(set) var sessionId: UUID?
    private(set) var fixes: [WorkoutTrackBackup.PersistedFix] = []
    private(set) var baro: [WorkoutTrackBackup.PersistedBaro] = []

    init(sessionId: UUID? = nil) {
        self.sessionId = sessionId
    }

    mutating func sync(sessionId: UUID, track: [CLLocation], baro samples: [(timestamp: Date, altitudeMeters: Double)]) {
        if self.sessionId != sessionId || fixes.count > track.count || baro.count > samples.count {
            self = TrackBackupRows(sessionId: sessionId)
        }
        fixes.append(contentsOf: track[fixes.count...].map(WorkoutTrackBackup.PersistedFix.init))
        baro.append(contentsOf: samples[baro.count...].map {
            WorkoutTrackBackup.PersistedBaro(timestamp: $0.timestamp, altitudeMeters: $0.altitudeMeters)
        })
    }
}
