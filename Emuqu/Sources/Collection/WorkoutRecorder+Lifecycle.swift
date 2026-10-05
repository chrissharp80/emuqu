import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// Split out of WorkoutRecorder.swift and off the TYPE (which is what the
// aggregate type-size gate measures): 600 lines reading 25 recorder members,
// the same coordinator split used for the overnight-streaming, AI-context,
// tool-runner and archive-migration extractions.

extension WorkoutFinalizer {
    /// Assemble the finished `HRVSession` from the captured RR series, the
    /// per-tick sample buffer and the sensor/context caches, then archive it.
    ///
    /// The archive is kept SYNCHRONOUS. Detaching it to a
    /// background task would make the .finished
    /// phase transition appear instantly, but a user's
    /// termination report (iOS SIGKILL at 228 MB phys_footprint right
    /// after tapping End) showed the detached path is a data-loss risk: if
    /// iOS suspends the app between `stop()` returning and the
    /// detached archive completing, the session is lost. With
    /// calculateTrainingLoad now bounded by a 1.5 s timeout, the
    /// synchronous archive only adds ~200 ms — well inside the iOS
    /// background-task budget — and keeps the session-persistence
    /// guarantee intact.
    func finalizeSession(
        rrPoints: [RRPoint],
        stopDate: Date,
        hrrSamples: [HRRSample]
    ) async -> HRVSession {
        guard var session = recorder.currentSession, let startDate = recorder.sessionStartDate else {
            return HRVSession(sessionType: .workout)
        }
        let analysis = analyzeWorkoutForFinalize(rrPoints: rrPoints, session: session, startDate: startDate)
        var metadata = makeBaseMetadata(session: session, sport: analysis.sport, computed: analysis.computed)
        await buildFinalizeMetadata(
            &metadata, analysis: analysis, rrPoints: rrPoints,
            startDate: startDate, stopDate: stopDate, hrrSamples: hrrSamples
        )
        classifySessionAndAttachData(
            session: &session, metadata: &metadata, series: analysis.series,
            rrPoints: rrPoints, stopDate: stopDate
        )
        attachAIContextSnapshot(to: &session, sport: analysis.sport, stopDate: stopDate)
        await attachTrainingSnapshot(to: &session, stopDate: stopDate)
        await recorder.archive(session: session)
        return session
    }

    /// Finalize stages 2–11 — every metadata mutation between the base
    /// metadata and session classification, in dependency order.
    private func buildFinalizeMetadata(
        _ metadata: inout WorkoutMetadata,
        analysis: FinalizeAnalysis,
        rrPoints: [RRPoint],
        startDate: Date,
        stopDate: Date,
        hrrSamples: [HRRSample]
    ) async {
        applyElevationMetrics(to: &metadata)
        applyAnalyzerMetrics(to: &metadata, computed: analysis.computed, hrrSamples: hrrSamples)
        await backfillHRAndAttachSamples(metadata: &metadata, startDate: startDate, stopDate: stopDate)
        applyPowerAggregates(to: &metadata, sport: analysis.sport, startDate: startDate, stopDate: stopDate)
        applyRouteTRIMPEstimate(to: &metadata, sport: analysis.sport)
        applyRowingTelemetry(to: &metadata, sport: analysis.sport)
        attachWeatherSnapshot(to: &metadata, sport: analysis.sport)
        attachAnalysisSnapshot(
            to: &metadata, sport: analysis.sport, rrPoints: rrPoints,
            startDate: startDate, stopDate: stopDate, userMaxHR: analysis.userMaxHR
        )
    }

    /// Carries the analyzer-stage outputs into the later finalize stages.
    private struct FinalizeAnalysis {
        let series: RRSeries?
        let sport: Sport
        let userMaxHR: Int
        let computed: WorkoutMetadata
    }

    /// Finalize stage 1 — RR series construction + WorkoutAnalyzer pass.
    ///
    /// Runs WorkoutAnalyzer against the captured inputs to produce metrics.
    /// The user's physiological max HR is passed so TRIMP / hrTSS normalise
    /// against the true ceiling rather than session peak — otherwise a hot /
    /// fast walk inflates %HRmax fractions and scores like an interval set.
    private func analyzeWorkoutForFinalize(rrPoints: [RRPoint], session: HRVSession, startDate: Date) -> FinalizeAnalysis {
        let series = rrPoints.isEmpty
            ? nil
            : RRSeries(points: rrPoints, sessionId: session.id, startDate: startDate)
        let sport = session.sport ?? .run
        let settings = recorder.settingsProvider()
        let userMaxHR = settings.effectiveMaxHR
        let computed = WorkoutAnalyzer.analyze(
            sport: sport,
            rrPoints: rrPoints,
            startDate: startDate,
            track: recorder.location.track,
            userMaxHR: userMaxHR,
            userRestingHR: settings.effectiveRestingHR,
            userLTHR: settings.effectiveLTHR,
            sex: Self.banisterSex(for: settings.biologicalSex),
            splitDistanceMeters: Self.splitDistanceMeters(),
            pauses: recorder.location.trackPauses
        )
        return FinalizeAnalysis(series: series, sport: sport, userMaxHR: userMaxHR, computed: computed)
    }

    /// Split bucket size follows the user's unit preference: imperial users
    /// want mile splits, metric users want kilometre splits. Emitting km
    /// splits unconditionally gets them mislabelled as "mi" on imperial —
    /// a 6.35 km walk shows "mi 1..mi 6" for a 3.95 mi walk.
    private static func splitDistanceMeters() -> Double {
        UnitsPreferenceStore.current.resolved == .imperial ? 1609.344 : 1000.0
    }

    /// Banister's original work gave different exponents for men vs
    /// women. Map the settings enum; `.other` → male coefficients (the
    /// historical default in the literature when sex is unspecified).
    private static func banisterSex(for biologicalSex: UserSettings.BiologicalSex?) -> WorkoutAnalyzer.BanisterSex {
        switch biologicalSex {
        case .female: return .female
        default: return .male
        }
    }

    /// Finalize stage 2 — base metadata + the session's distance.
    private func makeBaseMetadata(session: HRVSession, sport: Sport, computed: WorkoutMetadata) -> WorkoutMetadata {
        // Merge computed metrics with any pre-existing metadata (sport came in
        // at start). HRR samples are tacked on from the capture service.
        var metadata = session.workoutMetadata ?? WorkoutMetadata(sport: sport)
        metadata.distanceMeters = finalDistanceMeters(sport: sport, computed: computed)
        return metadata
    }

    /// The live tick's precedence, so the saved distance is the one the user
    /// watched: the PM5's odometer owns a row; otherwise the largest of GPS,
    /// pedometer and foot pod (GPS reads zero indoors, where a treadmill's
    /// foot pod or the pedometer still measures). The track runs through any
    /// pause so the map stays whole; the analyzer leaves the paused stretch
    /// out of the GPS distance, and the pedometer and foot-pod readings drop
    /// what accrued while paused.
    private func finalDistanceMeters(sport: Sport, computed: WorkoutMetadata) -> Double {
        if sport == .row, let ergDistance = AppDependencies.current.collection.concept2Manager.distanceMeters {
            return ergDistance
        }
        let paused = recorder.lifecycle.pausedMotion
        let gpsDistance = computed.distanceMeters ?? recorder.location.distanceMeters
        let pedometerDistance = paused.pedometerDistance(recorder.pedometer.distanceMeters)
        let footPodDistance = paused.footPodDistance(recorder.footPodDistanceMeters())
        return max(gpsDistance, pedometerDistance, footPodDistance)
    }

    /// Finalize stage 3 — elevation gain/loss (barometric post-process, GPS-accumulator fallback).
    ///
    /// Elevation: post-hoc processing of the raw CMAltimeter sample
    /// buffer via BarometricAltitudeProcessor. The live
    /// `recorder.location.elevationGainMeters` accumulator is only a ticker-
    /// display estimate — the authoritative persisted value comes
    /// from running the full algorithm once at finalize (symmetric
    /// moving-average smoother, then a 2 m hysteresis threshold on the
    /// smoothed signal, matching Strava's published barometer rule).
    ///
    /// When the barometer ran for the session, use the processed
    /// value. When it didn't (pre-iPhone-6 device, simulator,
    /// permission denied), fall back to the GPS-altitude accumulator
    /// that the location manager maintained internally — less
    /// accurate but non-zero.
    private func applyElevationMetrics(to metadata: inout WorkoutMetadata) {
        guard recorder.location.barometerAvailable, !recorder.location.barometricSamples.isEmpty else {
            metadata.elevationGainMeters = recorder.location.elevationGainMeters
            metadata.elevationLossMeters = recorder.location.elevationLossMeters
            debugLog("[Elevation] no barometer available — using GPS-altitude accumulator: gain=\(Int(recorder.location.elevationGainMeters))m")
            return
        }
        let processed = BarometricAltitudeProcessor.process(samples: recorder.location.barometricSamples)
        metadata.elevationGainMeters = processed.gainMeters
        metadata.elevationLossMeters = processed.lossMeters
        debugLog("[Elevation] barometric post-processed: gain=\(Int(processed.gainMeters))m, loss=\(Int(processed.lossMeters))m from \(processed.smoothedSampleCount) samples")
    }

    /// Finalize stage 4 — analyzer-computed metrics, recognized-route name, HRR samples.
    private func applyAnalyzerMetrics(to metadata: inout WorkoutMetadata, computed: WorkoutMetadata, hrrSamples: [HRRSample]) {
        metadata.gpsPolyline = computed.gpsPolyline
        metadata.splits = computed.splits
        metadata.luciaTRIMP = computed.luciaTRIMP
        // Record the saved-library route name (if any)
        // so per-route history queries can filter past sessions for
        // "the same loop." Only set when a route was actually bound;
        // unbound / one-off GPX runs leave this nil so they don't
        // pollute "Daily 1" averages.
        metadata.recognizedRouteName = recorder.plannedRoute?.name
        metadata.hrTSS = computed.hrTSS
        metadata.decouplingPercent = computed.decouplingPercent
        metadata.efficiencyFactor = computed.efficiencyFactor
        metadata.hrrSamples = hrrSamples.isEmpty ? nil : hrrSamples
    }

    /// Finalize stage 5 — Apple Watch HR backfill + per-second samples attach.
    ///
    /// Apple Watch HR fallback at finalize.
    ///
    /// User report: strap dropped mid-workout (AirPods route change
    /// forced a BLE renegotiation), the live Watch-HR bridge wasn't
    /// streaming because the Watch app wasn't open, and the workout
    /// finished with most heartRate fields = nil. Their request:
    /// "at the worst it should have fell back on apple."
    ///
    /// The Apple Watch generates HR samples to HealthKit every
    /// 5–10 s on the wrist regardless of whether our Watch app is
    /// running. We can't recover RR-level variability from those
    /// samples (HRV needs strap-grade RR), but we CAN fill in HR for
    /// every workout sample whose `heartRate` is nil — which fixes
    /// average HR, peak HR, zone distribution, TRIMP, and the HR
    /// chart that would otherwise look mostly empty.
    ///
    /// Backfill rules:
    ///   • only fill nil heartRate values (don't overwrite real
    ///     strap data with smoothed wrist HR)
    ///   • only accept HealthKit samples within ±15 s of the row's
    ///     timestamp (Watch HR is sparse; further away is guesswork)
    ///   • only run when the row count is large enough to matter
    ///     (skip quick walks where there'd be nothing to fix)
    ///
    /// The per-second time series is then persisted so the post-summary can
    /// draw real HR / pace / cadence charts and CSV/TCX exports can emit
    /// per-row metrics instead of just GPS. An empty array means "no data
    /// captured at all" — stored as nil so older sessions without the field
    /// look identical.
    ///
    /// Every row whose heart rate came from Apple Health — the HealthKit
    /// backfill here, the Watch's wrist HR shown live while a strap workout's
    /// strap was silent (`recorder.wristHROffsets`), or the Watch's wrist HR
    /// for a Watch-sourced workout — is listed in `healthKitHROffsets`, so the
    /// iCloud upload leaves it out.
    ///
    /// With the samples attached, each split gets its mean α1
    /// (`WorkoutAnalyzer.enrichSplitsWithAlpha1`, the step
    /// `splitsEnrichedWithAlpha1` runs after α1 re-analysis). The split windows
    /// are walked along the recorded track itself, the one the splits were cut
    /// from, rather than the stored polyline.
    private func backfillHRAndAttachSamples(metadata: inout WorkoutMetadata, startDate: Date, stopDate: Date) async {
        let backfillResult = await Self.backfillWorkoutHRFromHealthKit(
            samples: recorder.workoutSamples, sessionStart: startDate, sessionEnd: stopDate,
            pauses: recorder.lifecycle.pauseTimeline, healthKit: recorder.core.healthKit
        )
        let filledCount = backfillResult.filledOffsets.count
        if filledCount > 0 {
            recorder.workoutSamples = backfillResult.samples
            debugLog("[WorkoutRecorder.finalize] Backfilled \(filledCount) HR samples from HealthKit (Apple Watch) — strap had \(backfillResult.strapCount), now \(backfillResult.strapCount + filledCount) of \(recorder.workoutSamples.count) rows have HR")
        }
        metadata.samples = recorder.workoutSamples.isEmpty ? nil : recorder.workoutSamples
        metadata.healthKitHROffsets = Self.healthKitHROffsets(
            samples: recorder.workoutSamples, backfilled: backfillResult.filledOffsets + recorder.wristHROffsets,
            source: recorder.activeHRSource
        )
        recorder.wristHROffsets = []
        if let splits = metadata.splits, let samples = metadata.samples {
            metadata.splits = WorkoutAnalyzer.enrichSplitsWithAlpha1(
                splits: splits, samples: samples, startDate: startDate, track: recorder.location.track
            )
        }
    }

    /// Finalize stage 6 — power aggregates: average, NP, VI, IF, power-TSS.
    ///
    /// Power aggregates (nil if no foot-pod power was captured). Average
    /// is a plain mean of per-tick watts; normalized is the 4th-root
    /// mean-4th-power of a 30 s rolling mean — standard TrainingPeaks
    /// definition. Peak is the single highest instantaneous reading.
    ///
    /// Variability Index = NP / Avg. 1.00 = steady-state TT, > 1.10
    /// = real surges (intervals, rolling course). Adds context to
    /// every NP reading without needing an FTP anchor.
    private func applyPowerAggregates(to metadata: inout WorkoutMetadata, sport: Sport, startDate: Date, stopDate: Date) {
        guard recorder.powerSampleCount > 0 else { return }
        let avgPower = Double(recorder.powerSampleSum) / Double(recorder.powerSampleCount)
        metadata.averagePowerWatts = avgPower
        metadata.peakPowerWatts = recorder.maxPowerObserved
        let np = WorkoutRecorder.computeNormalizedPower(samples: recorder.workoutSamples)
        metadata.normalizedPowerWatts = np
        if let np, np > 0, avgPower > 0 {
            metadata.variabilityIndex = np / avgPower
        }
        guard let ftp = WorkoutRecorder.sportFTP(for: sport, settings: recorder.settingsProvider()), ftp > 0, let np else { return }
        applyFTPAnchoredMetrics(
            to: &metadata, ftp: ftp, np: np,
            durationSeconds: activeDurationSeconds(startDate: startDate, stopDate: stopDate)
        )
    }

    /// Recorded time with pauses left out: the ticker counts only while the
    /// workout runs. Wall-clock start to stop stands in when no tick counted.
    private func activeDurationSeconds(startDate: Date, stopDate: Date) -> TimeInterval {
        recorder.elapsedSeconds > 0 ? Double(recorder.elapsedSeconds) : stopDate.timeIntervalSince(startDate)
    }

    /// Finalize stage 7 — route-history TRIMP fallback estimate.
    ///
    /// Route-history TRIMP fallback. User report:
    /// strap dropped on a known daily route and the recorded
    /// TRIMP came out as 2 — meaningless. They asked why we
    /// can't notice a familiar effort and infer the load from
    /// (a) the GPS shape matching a saved route and (b) prior
    /// sessions on that same route. `WorkoutRecoveryService` does
    /// the same for crash-recovered workouts; sessions that finalize
    /// cleanly with bad HR data need it too, so it runs on every
    /// finalize: if the saved
    /// route matches and either recorded TRIMP is missing or
    /// suspiciously low vs prior runs, surface an estimate
    /// alongside the measured value. The summary UI already
    /// renders `extrapolatedTRIMP` + confidence + route name.
    ///
    /// (When a power meter is attached we already compute Coggan
    /// powerTSS in `applyPowerAggregates` — that's the more accurate
    /// HR-free intensity proxy and runs independently of this estimator.)
    private func applyRouteTRIMPEstimate(to metadata: inout WorkoutMetadata, sport: Sport) {
        guard let estimate = RouteTRIMPEstimator.estimate(
            track: recorder.location.track,
            sport: sport,
            recordedTRIMP: metadata.luciaTRIMP,
            recordedDistance: metadata.distanceMeters,
            archive: recorder.core.archive,
            savedRouteStore: AppDependencies.current.location.savedRouteStore
        ) else { return }
        metadata.extrapolatedTRIMP = estimate.estimatedTRIMP
        metadata.extrapolationConfidence = estimate.confidence
        metadata.extrapolationRouteName = estimate.routeName
        debugLog("[WorkoutRecorder.finalize] Route TRIMP estimate: \(String(format: "%.0f", estimate.estimatedTRIMP)) (recorded=\(metadata.luciaTRIMP.map { String(format: "%.0f", $0) } ?? "nil"), route=\(estimate.routeName), conf=\(String(format: "%.2f", estimate.confidence)), priorDominant=\(estimate.priorDominant))")
    }

    /// Finalize stage 8 — Concept2 PM5 rowing telemetry.
    private func applyRowingTelemetry(to metadata: inout WorkoutMetadata, sport: Sport) {
        // Rowing-specific telemetry from Concept2 PM5. Captured here at
        // finalize time rather than per-tick because these fields are
        // session-summary in nature — strokeCount is monotonic, drag
        // factor stable, average split is whatever the PM5 reports at
        // the end. Without persisting these, the rower's most-meaningful
        // numbers (split pace, total strokes, drag setting they used)
        // would evaporate the moment they tap Stop.
        if sport == .row {
            let erg = AppDependencies.current.collection.concept2Manager
            metadata.strokeCount = erg.strokeCount
            metadata.dragFactor = erg.dragFactor
            metadata.averageSplitSecPer500m = Self.averageSplitSecPer500m(
                movingSeconds: recorder.elapsedSeconds, distanceMeters: recorder.distanceMeters
            )
        }
    }

    /// Moving time over distance, per 500 m. A mean of the per-second paces
    /// over-weighted the slow stretches.
    static func averageSplitSecPer500m(movingSeconds: Int, distanceMeters: Double) -> Double? {
        guard movingSeconds > 0, distanceMeters > 0 else { return nil }
        return Double(movingSeconds) / distanceMeters * 500
    }

    /// Finalize stage 9 — one-shot analysis snapshot build.
    private func attachAnalysisSnapshot(
        to metadata: inout WorkoutMetadata,
        sport: Sport,
        rrPoints: [RRPoint],
        startDate: Date,
        stopDate: Date,
        userMaxHR: Int
    ) {
        // Build the one-shot analysis snapshot. This pre-computes every
        // derivation the summary UI + PDF + AI context would otherwise
        // re-run on each render (α1 stats, zone distribution, splits
        // bests, derived economy metrics, narratives). Stored on the
        // session so subsequent reads are pure lookups.
        let snapshotInputs = WorkoutAnalysisSnapshotBuilder.Inputs(
            sport: sport,
            durationSec: activeDurationSeconds(startDate: startDate, stopDate: stopDate),
            distanceMeters: metadata.distanceMeters,
            elevationGainMeters: metadata.elevationGainMeters,
            elevationLossMeters: metadata.elevationLossMeters,
            meanHR: rrPoints.isEmpty ? nil : 60_000.0 / (rrPoints.reduce(0.0) { $0 + Double($1.rr_ms) } / Double(rrPoints.count)),
            userMaxHR: userMaxHR,
            bodyWeightKg: recorder.settingsProvider().effectiveBodyWeightKg,
            samples: metadata.samples ?? [],
            splits: metadata.splits ?? [],
            trimp: metadata.luciaTRIMP,
            decouplingPercent: metadata.decouplingPercent
        )
        metadata.analysisSnapshot = WorkoutAnalysisSnapshotBuilder.build(snapshotInputs)
    }

    /// Finalize stage 10 — session-state classification + metadata/series/endDate attach.
    ///
    /// Workouts always reach the archive as `.complete`, with a
    /// `partialDataReason` flag when HR coverage is below the
    /// 60-beat usefulness floor. Landing sub-60-beat workouts as
    /// `.failed` hides them from the dashboard and blocks iCloud
    /// sync — a strap-died-mid-walk produces a session that exists
    /// on disk but is invisible everywhere a user would look for
    /// it. Surfacing them with the
    /// "Estimated — strap dropout" badge is more honest than
    /// silently dropping the data.
    ///
    /// Sessions with no HR AND no GPS movement are a different case:
    /// they're almost certainly accidental Start taps, not real
    /// recordings. Those still go to `.failed` so the archive isn't
    /// littered with ghost rows.
    private func classifySessionAndAttachData(
        session: inout HRVSession,
        metadata: inout WorkoutMetadata,
        series: RRSeries?,
        rrPoints: [RRPoint],
        stopDate: Date
    ) {
        let hasMeaningfulData = rrPoints.count >= 60
            || (metadata.distanceMeters ?? 0) > 50
            || (metadata.samples?.count ?? 0) >= 30
        if hasMeaningfulData {
            session.state = .complete
            // A dropout needs a strap that sent something. A workout with no
            // beats at all never had one (no strap, or Watch heart rate), and
            // the summary already says strap data is unavailable.
            if !rrPoints.isEmpty, rrPoints.count < 60 {
                metadata.partialDataReason = .strapDisconnected
            }
        } else {
            session.state = .failed
        }
        session.workoutMetadata = metadata
        session.rrSeries = series
        session.endDate = stopDate
    }

    /// Finalize stage 11 — flat AI-context snapshot from the live broker.
    private func attachAIContextSnapshot(to session: inout HRVSession, sport: Sport, stopDate: Date) {
        // The broker is cleared when stop() tears the live services down,
        // before finalize runs, so its last snapshot was kept on the recorder
        // at that point. String-only values for third-party JSON-export
        // interop; not surfaced anywhere in the UI, included in the data
        // export so external integrators see exactly what the AI was reading
        // when it generated coaching for this session.
        defer { recorder.liveSnapshotAtStop = nil }
        if let liveSnap = recorder.liveSnapshotAtStop {
            session.aiContext = recorder.buildAiContextSnapshot(liveSnap, sport: sport, stopDate: stopDate)
        }
    }

    /// Finalize stage 12 — training-load snapshot attach, bounded by the 1.5 s timeout race.
    ///
    /// Attach training-load snapshot at finalize.
    /// Without this the post-workout PDF / Holistic Daily Report
    /// / Coach Report email show "no training-load snapshot" and
    /// can't deliver TSB/ACWR-aware recommendations. We intentionally
    /// use forMorningReading: false so today's load contributions
    /// (this very workout) are included — the snapshot represents
    /// the post-session state, the canonical thing to display next
    /// to the workout. Mirrors the recovery-session attach in
    /// RRCollector+DeviceRecording.swift, including the
    /// user's VO2max override / opt-out handling.
    private func attachTrainingSnapshot(to session: inout HRVSession, stopDate: Date) async {
        let s = recorder.settingsProvider()
        guard s.enableTrainingLoadIntegration else { return }
        guard var context = await resolveFinalizeTrainingContext(stopDate: stopDate) else { return }
        if let override = s.vo2MaxOverride {
            context.vo2Max = override
        } else if !s.useHealthKitVO2Max {
            context.vo2Max = nil
        }
        session.trainingSnapshot = context
    }

    /// Prefer the warm incremental TrainingMetricsCache
    /// (instant) over a COLD `calculateTrainingLoad` racing a 1.5s wall
    /// clock. That race drops the training snapshot on ~every
    /// workout finalize (and the HRR/training context with it), because a
    /// cold 180-day HealthKit fetch rarely finishes in 1.5s at stop time.
    /// `current` is the app's now-anchored value (forMorningReading:false
    /// semantics — includes today) and is kept warm by the dashboard/AI.
    /// Only fall back to the bounded cold fetch when the cache is cold.
    ///
    /// That fallback is bounded with a 1.5 s timeout. Bug
    /// report: user tapped End on a workout, UI froze, force-quit was the
    /// only exit. Trace pointed at this exact call: HealthKit's
    /// 12-month training-load query was synchronous-await with
    /// no time bound, so a slow cold HealthKit query held `stop()`
    /// mid-finalize. The lifecycle phase had already flipped to
    /// `.finalizing` so the End button silently no-op'd. So: race
    /// against a timeout. If training-load doesn't complete in
    /// 1.5 s, skip the snapshot for this session. The next session
    /// (or any later view that calls calculateTrainingLoad) gets
    /// a fresh snapshot. Strictly better than the user losing the
    /// workout entirely.
    private func resolveFinalizeTrainingContext(stopDate: Date) async -> TrainingContext? {
        if let live = AppDependencies.current.analysis.trainingMetricsCache.current, live.atl > 0 || live.ctl > 0 {
            return TrainingContext(
                atl: live.atl, ctl: live.ctl, tsb: live.tsb, yesterdayTrimp: live.todayTrimp,
                vo2Max: live.vo2MaxLatest, daysSinceHardWorkout: nil, recentWorkouts: nil
            )
        }
        let healthKit = recorder.core.healthKit
        guard let load = await Self.runWithTimeout(seconds: 1.5, {
            await healthKit.calculateTrainingLoad(forMorningReading: false)
        }) else {
            debugLog("[WorkoutRecorder.finalize] cache cold AND cold calculateTrainingLoad timed out at 1.5s — saving without trainingSnapshot")
            return nil
        }
        return TrainingContext(from: load, relativeTo: stopDate)
    }

    /// Race a value-returning async operation against a timeout.
    /// Returns the operation's result if it completes in time, or
    /// nil if the timeout fires first. The caller stops waiting at the
    /// timeout; the operation runs on unawaited (Swift can't cancel a
    /// HealthKit query). Not a task group, which waits for every child
    /// before it returns and so would hold the End button for the full
    /// HealthKit cold start. Used to bound `finalizeSession`.
    static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @Sendable @escaping () async -> T
    ) async -> T? {
        await Emuqu.runWithTimeout(seconds: seconds, operation: operation)
    }

    /// Splice Apple Watch HR (via HealthKit) into a
    /// workout's per-second sample series wherever the strap was silent.
    ///
    /// Returns the modified samples, the `offsetSec` of each row it filled,
    /// and the strap's row count, so the caller can mark the filled rows and
    /// log what happened. The raw `samples` array is preserved when there's
    /// nothing to fill (HealthKit returned empty, no nil rows, etc.) so
    /// the existing analyses are deterministic for the strap-only case.
    ///
    /// Each row is matched at its wall-clock time (`pauses` adds back the
    /// paused stretches its `offsetSec` leaves out).
    ///
    /// The HealthKit fetch is bounded by a 3 s timeout. The HealthKit
    /// cold-start can take hundreds of ms; we'd rather skip backfill than
    /// hold up the finalize path (which already faces an iOS
    /// background-task budget).
    static func backfillWorkoutHRFromHealthKit(
        samples: [WorkoutSample],
        sessionStart: Date,
        sessionEnd: Date,
        pauses: PauseTimeline = PauseTimeline(),
        healthKit: HealthKitManager
    ) async -> (samples: [WorkoutSample], filledOffsets: [Int], strapCount: Int) {
        let strapCount = samples.filter { $0.heartRate != nil }.count
        // Nothing to fill — short-circuit before paying for the
        // HealthKit query.
        guard samples.count - strapCount > 0 else { return (samples, [], strapCount) }
        let healthKitSamples = await wristHRSamples(from: sessionStart, to: sessionEnd, healthKit: healthKit)
        guard !healthKitSamples.isEmpty else { return (samples, [], strapCount) }

        var filledOffsets: [Int] = []
        var output = samples
        for (idx, row) in samples.enumerated() where row.heartRate == nil {
            let rowTime = pauses.wallClock(forOffset: row.offsetSec, sessionStart: sessionStart)
            guard let hr = Self.nearestHealthKitHR(to: rowTime, in: healthKitSamples) else { continue }
            output[idx] = row.withHeartRate(Int(hr.rounded()))
            filledOffsets.append(row.offsetSec)
        }
        return (output, filledOffsets, strapCount)
    }

    /// The `offsetSec` of every row whose heart rate came from Apple Health,
    /// sorted, or nil when none did. A Watch-sourced workout's live heart rate
    /// is the Watch's wrist HR, read from its HealthKit workout session, so
    /// every row with a heart rate counts; a strap workout counts only the
    /// rows the HealthKit backfill filled.
    static func healthKitHROffsets(
        samples: [WorkoutSample],
        backfilled: [Int],
        source: WorkoutRecorder.HRSource
    ) -> [Int]? {
        var offsets = Set(backfilled)
        if source == .watch {
            offsets.formUnion(samples.lazy.filter { $0.heartRate != nil }.map(\.offsetSec))
        }
        return offsets.isEmpty ? nil : offsets.sorted()
    }

    private static func wristHRSamples(
        from sessionStart: Date,
        to sessionEnd: Date,
        healthKit: HealthKitManager
    ) async -> [(date: Date, hr: Double)] {
        let samples: [(date: Date, hr: Double)] = await runWithTimeout(seconds: 3.0) {
            (try? await healthKit.fetchHeartRateSamples(from: sessionStart, to: sessionEnd)) ?? []
        } ?? []
        if samples.isEmpty {
            debugLog("[WorkoutRecorder.backfill] HealthKit had 0 HR samples in [\(sessionStart), \(sessionEnd)] — wrist HR may be unavailable")
        }
        return samples
    }

    /// Find nearest HealthKit sample within ±15 s. Watch wrist HR
    /// is typically every 5–10 s during activity, so 15 s lets us
    /// bridge a single missed sample without inventing data when
    /// there's a real gap.
    private static func nearestHealthKitHR(to rowTime: Date, in healthKitSamples: [(date: Date, hr: Double)]) -> Double? {
        var bestHR: Double?
        var bestDelta: TimeInterval = 15.0
        for hkSample in healthKitSamples {
            let delta = abs(hkSample.date.timeIntervalSince(rowTime))
            if delta < bestDelta {
                bestDelta = delta
                bestHR = hkSample.hr
            }
        }
        return bestHR
    }
}

// MARK: - File-scope helpers
//
// Moved out of WorkoutRecorder. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

@MainActor
/// IF = NP/FTP — Allen & Coggan, Training and Racing with a Power Meter.
///
/// Coggan power-TSS: (NP/FTP)² × duration_hours × 100. 100 is calibrated
/// so 1 hour at FTP = 100 TSS.
/// TSS = (t·NP·IF)/(FTP·3600)·100 = IF²·hours·100 — Allen & Coggan.
/// `durationSeconds` is the recorded time without pauses: a paused stretch
/// carries no power and must not add load.
private func applyFTPAnchoredMetrics(
    to metadata: inout WorkoutMetadata,
    ftp: Int,
    np: Double,
    durationSeconds: TimeInterval
) {
    let durationHours = durationSeconds / 3600.0
    let intensityFactor = np / Double(ftp)
    metadata.intensityFactor = intensityFactor
    metadata.powerTSS = intensityFactor * intensityFactor * durationHours * 100.0
    metadata.ftpAtTimeOfSession = ftp
}

@MainActor
/// Finalize stage — persist the live weather snapshot for the
/// heat-acclimatization model. The weather is already in memory
/// (`AppDependencies.current.location.weatherService.current`, refreshed each ~30 min during the
/// workout); this is purely wiring it into the archived record before
/// it evaporates. Outdoor sports only — indoor sessions carry no heat
/// stimulus and would otherwise capture stale ambient weather.
private func attachWeatherSnapshot(to metadata: inout WorkoutMetadata, sport: Sport) {
    guard sport.usesGPS, let live = AppDependencies.current.location.weatherService.current else { return }
    metadata.weatherSnapshot = WorkoutWeatherSnapshot(
        temperatureC: live.temperatureC,
        apparentTemperatureC: live.apparentTemperatureC,
        relativeHumidityPercent: live.humidityPercent,
        windKMH: live.windKMH,
        conditions: live.conditions,
        observedAt: live.observedAt,
        backfilled: false
    )
}
