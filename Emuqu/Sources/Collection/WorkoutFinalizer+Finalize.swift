import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// Finalizing a workout: assembling the finished session and archiving it.

extension WorkoutFinalizer {
    /// Assemble the finished `HRVSession` from the captured RR series, the
    /// per-tick sample buffer and the sensor/context caches, then archive it.
    /// Returns the session with how its save came out, so the summary can say
    /// when it is not saved yet.
    ///
    /// The archive is kept SYNCHRONOUS. Detaching it to a background task
    /// would make the .finished phase transition appear instantly, but it is a
    /// data-loss risk: if iOS suspends or kills the app (e.g. a memory SIGKILL
    /// right after End) between `stop()` returning and the detached archive
    /// completing, the session is lost. With calculateTrainingLoad bounded by
    /// a 1.5 s timeout, the synchronous archive only adds ~200 ms — well
    /// inside the iOS background-task budget.
    func finalizeSession(
        rrPoints: [RRPoint],
        stopDate: Date,
        hrrSamples: [HRRSample]
    ) async -> (session: HRVSession, saveOutcome: WorkoutSaveOutcome) {
        guard var session = recording.session, let startDate = recording.startDate else {
            debugLog("[WorkoutRecorder.finalize] no current session or start date — nothing to finalize or archive", level: .warning)
            return (HRVSession(sessionType: .workout), .notArchived)
        }
        let analysis = analyzeWorkoutForFinalize(rrPoints: rrPoints, session: session, startDate: startDate)
        var metadata = makeBaseMetadata(session: session, sport: analysis.sport, computed: analysis.computed)
        await buildFinalizeMetadata(
            &metadata, analysis: analysis, rrPoints: rrPoints,
            startDate: startDate, stopDate: stopDate, hrrSamples: hrrSamples
        )
        classifySessionAndAttachData(
            session: &session, metadata: &metadata, series: analysis.series,
            rrPoints: rrPoints, stopDate: stopDate,
            activeSeconds: TimeInterval(recording.pauseTimeline.activeSeconds(sessionStart: startDate, now: stopDate))
        )
        attachAIContextSnapshot(to: &session, sport: analysis.sport, stopDate: stopDate)
        await attachTrainingSnapshot(to: &session, stopDate: stopDate)
        return (session, sessionLifecycle.archive(session: session))
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
        metadata.pauseSpans = WorkoutPauseSpan.spans(of: recording.pauseTimeline)
        applyPowerAggregates(to: &metadata, sport: analysis.sport, startDate: startDate, stopDate: stopDate)
        applyRouteTRIMPEstimate(to: &metadata, sport: analysis.sport)
        applyRowingTelemetry(to: &metadata, sport: analysis.sport)
        attachWeatherSnapshot(to: &metadata, sport: analysis.sport, weather: services.weatherService)
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
        let settings = settings
        let userMaxHR = settings.effectiveMaxHR
        let computed = WorkoutAnalyzer.analyze(
            sport: sport,
            rrPoints: rrPoints,
            startDate: startDate,
            track: recording.location?.track ?? [],
            userMaxHR: userMaxHR,
            userRestingHR: settings.effectiveRestingHR,
            userLTHR: settings.effectiveLTHR,
            sex: Self.banisterSex(for: settings.biologicalSex),
            splitDistanceMeters: Self.splitDistanceMeters(),
            pauses: recording.location?.trackPauses ?? WorkoutAnalyzer.TrackPauses()
        )
        return FinalizeAnalysis(series: series, sport: sport, userMaxHR: userMaxHR, computed: computed)
    }

    /// Split bucket size follows the user's unit preference: imperial users
    /// want mile splits, metric users want kilometre splits. Emitting km
    /// splits unconditionally gets them mislabelled as "mi" on imperial —
    /// a 6.35 km walk shows "mi 1..mi 6" for a 3.95 mi walk.
    private static func splitDistanceMeters() -> Double {
        UnitsPreferenceStore.current.resolved == .imperial ? UnitConstants.metersPerMile : 1000.0
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
    /// what accrued while paused. For a stop dated earlier than it arrived,
    /// the counters that ran on past it are capped at the distance shown then.
    private func finalDistanceMeters(sport: Sport, computed: WorkoutMetadata) -> Double {
        let cap = recording.distanceCapMeters ?? .infinity
        if sport == .row, let ergDistance = services.concept2Manager.distanceMeters {
            return min(ergDistance, cap)
        }
        let paused = recording.pausedMotion
        let gpsDistance = computed.distanceMeters ?? recording.location?.distanceMeters ?? 0
        let pedometerDistance = min(paused.pedometerDistance(recording.pedometerDistanceMeters), cap)
        let footPodDistance = min(paused.footPodDistance(recording.footPodDistanceMeters), cap)
        return max(gpsDistance, pedometerDistance, footPodDistance)
    }

    /// Finalize stage 3 — elevation gain/loss (barometric post-process, GPS-accumulator fallback).
    ///
    /// Elevation: post-hoc processing of the raw CMAltimeter sample
    /// buffer via BarometricAltitudeProcessor. The live
    /// `recording.location.elevationGainMeters` accumulator is only a ticker-
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
        let started = recording.location
        guard let location = started, location.barometerAvailable, !location.barometricSamples.isEmpty else {
            let gain = started?.elevationGainMeters ?? 0
            metadata.elevationGainMeters = gain
            metadata.elevationLossMeters = started?.elevationLossMeters ?? 0
            debugLog("[Elevation] no barometer available — using GPS-altitude accumulator: gain=\(Int(gain))m")
            return
        }
        let processed = BarometricAltitudeProcessor.process(samples: location.barometricSamples)
        metadata.elevationGainMeters = processed.gainMeters
        metadata.elevationLossMeters = processed.lossMeters
        debugLog("[Elevation] barometric post-processed: gain=\(Int(processed.gainMeters))m, loss=\(Int(processed.lossMeters))m from \(processed.smoothedSampleCount) samples")
    }

    /// Finalize stage 4 — analyzer-computed metrics, recognized-route name, HRR samples.
    private func applyAnalyzerMetrics(to metadata: inout WorkoutMetadata, computed: WorkoutMetadata, hrrSamples: [HRRSample]) {
        metadata.gpsPolyline = computed.gpsPolyline
        metadata.gpsFixTimes = computed.gpsFixTimes
        metadata.gpsSegmentStarts = computed.gpsSegmentStarts
        metadata.splits = computed.splits
        metadata.luciaTRIMP = computed.luciaTRIMP
        // Record the saved-library route name (if any)
        // so per-route history queries can filter past sessions for
        // "the same loop." Only set when a route was actually bound;
        // unbound / one-off GPX runs leave this nil so they don't
        // pollute "Daily 1" averages.
        metadata.recognizedRouteName = recording.routeName
        metadata.hrTSS = computed.hrTSS
        metadata.decouplingPercent = computed.decouplingPercent
        metadata.efficiencyFactor = computed.efficiencyFactor
        metadata.hrrSamples = hrrSamples.isEmpty ? nil : hrrSamples
    }

    /// Finalize stage 5 — Apple Watch HR backfill + per-second samples attach.
    ///
    /// Apple Watch HR fallback at finalize: when the strap drops mid-workout
    /// (e.g. an AirPods route change forces a BLE renegotiation) and the live
    /// Watch-HR bridge isn't streaming because the Watch app isn't open, the
    /// workout would otherwise finish with most heartRate fields nil.
    ///
    /// The Apple Watch generates HR samples to HealthKit every
    /// 5–10 s on the wrist regardless of whether our Watch app is
    /// running. We can't recover RR-level variability from those
    /// samples (HRV needs strap-grade RR), but we CAN fill in HR for
    /// every workout sample whose `heartRate` is nil — which fills the
    /// HR chart and everything read from the per-second rows (zone
    /// breakdown, sample-based HR figures) that would otherwise look
    /// mostly empty. It does not touch TRIMP or hrTSS: stage 1 computes
    /// those from the RR beats alone, and nothing recomputes them from the
    /// filled rows, so a workout short of beats is scored by the lower
    /// tiers of the training-load ladder (`TrainingLoadPrecedence`).
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
    /// strap was silent (`recording.wristHROffsets`), or the Watch's wrist HR
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
            samples: recording.samples, sessionStart: startDate, sessionEnd: stopDate,
            pauses: recording.pauseTimeline, heartRate: core.heartRate
        )
        let filledCount = backfillResult.filledOffsets.count
        let samples = filledCount > 0 ? backfillResult.samples : recording.samples
        if filledCount > 0 {
            debugLog("[WorkoutRecorder.finalize] Backfilled \(filledCount) HR samples from HealthKit (Apple Watch) — strap had \(backfillResult.strapCount), now \(backfillResult.strapCount + filledCount) of \(samples.count) rows have HR")
        }
        metadata.samples = samples.isEmpty ? nil : samples
        metadata.healthKitHROffsets = Self.healthKitHROffsets(
            samples: samples, backfilled: backfillResult.filledOffsets + recording.wristHROffsets,
            source: recording.activeHRSource
        )
        if let splits = metadata.splits, let samples = metadata.samples {
            metadata.splits = WorkoutAnalyzer.enrichSplitsWithAlpha1(
                splits: splits, samples: samples, startDate: startDate, track: recording.location?.track ?? []
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
        guard let avgPower = recording.power.average else { return }
        metadata.averagePowerWatts = avgPower
        metadata.peakPowerWatts = recording.power.peak
        // Normalized power reads power, which the HR backfill leaves alone.
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: recording.samples)
        metadata.normalizedPowerWatts = np
        if let np, np > 0, avgPower > 0 {
            metadata.variabilityIndex = np / avgPower
        }
        guard let ftp = WorkoutAIContextBuilder.sportFTP(for: sport, settings: settings), ftp > 0, let np else { return }
        applyFTPAnchoredMetrics(
            to: &metadata, ftp: ftp, np: np,
            durationSeconds: activeDurationSeconds(startDate: startDate, stopDate: stopDate)
        )
    }

    /// Recorded time with pauses left out: the ticker counts only while the
    /// workout runs. Wall-clock start to stop stands in when no tick counted.
    private func activeDurationSeconds(startDate: Date, stopDate: Date) -> TimeInterval {
        recording.elapsedSeconds > 0 ? Double(recording.elapsedSeconds) : stopDate.timeIntervalSince(startDate)
    }

    /// Finalize stage 7 — route-history TRIMP fallback estimate.
    ///
    /// Route-history TRIMP fallback. When the strap drops on a known daily
    /// route the recorded TRIMP can come out meaninglessly low (e.g. 2), so
    /// the load is inferred from (a) the GPS shape matching a saved route
    /// and (b) prior sessions on that same route. `WorkoutRecoveryService` does
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
            track: recording.location?.track ?? [],
            sport: sport,
            recordedTRIMP: metadata.luciaTRIMP,
            recordedDistance: metadata.distanceMeters,
            archive: core.archive,
            savedRouteStore: services.savedRouteStore
        ) else { return }
        metadata.extrapolatedTRIMP = estimate.estimatedTRIMP
        metadata.extrapolationConfidence = estimate.confidence
        metadata.extrapolationRouteName = estimate.routeName
        debugLog("[WorkoutRecorder.finalize] Route TRIMP estimate: \(String(format: "%.0f", estimate.estimatedTRIMP)) (recorded=\(metadata.luciaTRIMP.map { String(format: "%.0f", $0) } ?? "nil"), conf=\(String(format: "%.2f", estimate.confidence)), priorDominant=\(estimate.priorDominant))")
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
            let erg = services.concept2Manager
            metadata.strokeCount = erg.strokeCount
            metadata.dragFactor = erg.dragFactor
            metadata.averageSplitSecPer500m = Self.averageSplitSecPer500m(
                movingSeconds: recording.elapsedSeconds,
                distanceMeters: min(recording.motionDistanceMeters, recording.distanceCapMeters ?? .infinity)
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
            bodyWeightKg: settings.effectiveBodyWeightKg,
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
    /// A session under a minute of active time with no HR, no movement and
    /// few samples is a different case: almost certainly an accidental Start
    /// tap (`WorkoutAccidentalStart`). It goes to `.failed`, which
    /// `archive(session:)` does not write on its own: the summary says it was
    /// not saved and offers to save it. The time is the wall clock less the
    /// pauses (`activeSeconds`), so a long workout whose ticker was suspended
    /// with the phone locked is saved like any other, and that time is stored
    /// as its duration (`WorkoutMetadata.activeSeconds`).
    private func classifySessionAndAttachData(
        session: inout HRVSession,
        metadata: inout WorkoutMetadata,
        series: RRSeries?,
        rrPoints: [RRPoint],
        stopDate: Date,
        activeSeconds: TimeInterval
    ) {
        let accidental = WorkoutAccidentalStart.isAccidental(
            beats: rrPoints.count, distanceMeters: metadata.distanceMeters,
            sampleCount: metadata.samples?.count ?? 0, activeSeconds: activeSeconds
        )
        if accidental {
            session.state = .failed
        } else {
            session.state = .complete
            // A dropout needs a strap that sent something. A workout with no
            // beats at all never had one (no strap, or Watch heart rate), and
            // the summary already says strap data is unavailable.
            if !rrPoints.isEmpty, rrPoints.count < 60 {
                metadata.partialDataReason = .strapDisconnected
            }
        }
        metadata.activeSeconds = activeSeconds
        session.workoutMetadata = metadata
        session.rrSeries = series
        session.endDate = stopDate
    }

    /// Finalize stage 11 — flat AI-context snapshot from the live broker.
    private func attachAIContextSnapshot(to session: inout HRVSession, sport: Sport, stopDate: Date) {
        // The broker is cleared when stop() tears the live services down,
        // before finalize runs, so its last snapshot was kept for this at
        // that point. String-only values for third-party JSON-export
        // interop; not surfaced anywhere in the UI, included in the data
        // export so external integrators see exactly what the AI was reading
        // when it generated coaching for this session.
        if let liveSnap = recording.liveSnapshot {
            session.aiContext = sessionLifecycle.buildAiContextSnapshot(liveSnap, sport: sport, stopDate: stopDate)
        }
    }

    /// Finalize stage 12 — training-load snapshot attach, bounded by the 1.5 s timeout race.
    ///
    /// Attach training-load snapshot at finalize.
    /// Without this the post-workout PDF / Holistic Daily Report
    /// / Coach Report email show "no training-load snapshot" and
    /// can't deliver TSB/ACWR-aware recommendations. We intentionally
    /// use forMorningReading: false so today's earlier load contributions
    /// are included. This workout itself is not: the snapshot is taken
    /// before `archive(session:)` writes it (and before its Apple Health
    /// export), so neither the warm cache nor the cold archive + HealthKit
    /// merge has it yet. The stored ATL/CTL/TSB is the load the user
    /// brought into this workout. Mirrors the recovery-session attach in
    /// DeviceRecordingSession+Capture.swift, including the
    /// user's VO2max override / opt-out handling.
    private func attachTrainingSnapshot(to session: inout HRVSession, stopDate: Date) async {
        let s = settings
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
    /// That fallback is bounded with a 1.5 s timeout. HealthKit's 12-month
    /// training-load query has no time bound of its own, so a slow cold query
    /// would hold `stop()` mid-finalize with the lifecycle already at
    /// `.finalizing`: the End button silently no-ops and the UI looks frozen.
    /// If training-load doesn't complete in 1.5 s, the snapshot is skipped for
    /// this session; the next session (or any later view that calls
    /// calculateTrainingLoad) gets a fresh one. Strictly better than the user
    /// losing the workout entirely.
    private func resolveFinalizeTrainingContext(stopDate: Date) async -> TrainingContext? {
        if let live = services.trainingMetricsCache.current, live.atl > 0 || live.ctl > 0 {
            return Self.trainingContext(fromCached: live, relativeTo: stopDate)
        }
        let training = core.training
        guard let load = await Self.runWithTimeout(seconds: 1.5, {
            await training.calculateTrainingLoad(forMorningReading: false)
        }) else {
            debugLog("[WorkoutRecorder.finalize] cache cold AND cold calculateTrainingLoad timed out at 1.5s — saving without trainingSnapshot")
            return nil
        }
        return TrainingContext(from: load, relativeTo: stopDate)
    }

    /// The warm cache as a snapshot. `yesterdayTrimp` is the TRIMP of the day
    /// before `stopDate` from the cache's daily series: the same day the
    /// HealthKit path (`TrainingContext(from:relativeTo:)`) stores, so the
    /// field means one thing whichever path ran. The cache carries no
    /// days-since-hard-workout or recent-workout list, so those stay nil.
    private static func trainingContext(fromCached live: TrainingMetrics, relativeTo stopDate: Date) -> TrainingContext {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: stopDate))
        return TrainingContext(
            atl: live.atl, ctl: live.ctl, tsb: live.tsb,
            yesterdayTrimp: yesterday.flatMap { live.dailyTrimp[$0] } ?? 0,
            vo2Max: live.vo2MaxLatest, daysSinceHardWorkout: nil, recentWorkouts: nil
        )
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
        heartRate: HeartRateHealthQueries
    ) async -> (samples: [WorkoutSample], filledOffsets: [Int], strapCount: Int) {
        let strapCount = samples.filter { $0.heartRate != nil }.count
        // Nothing to fill — short-circuit before paying for the
        // HealthKit query.
        guard samples.count - strapCount > 0 else { return (samples, [], strapCount) }
        let healthKitSamples = await wristHRSamples(from: sessionStart, to: sessionEnd, heartRate: heartRate)
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

    /// A failed query (HealthKit locked or not authorized) and a timeout are
    /// logged as such, apart from a query that found no samples; each gives
    /// the backfill nothing to fill with.
    private static func wristHRSamples(
        from sessionStart: Date,
        to sessionEnd: Date,
        heartRate: HeartRateHealthQueries
    ) async -> [(date: Date, hr: Double)] {
        switch await wristHRQuery(from: sessionStart, to: sessionEnd, heartRate: heartRate) {
        case nil:
            debugLog("[WorkoutRecorder.backfill] HealthKit HR query timed out after 3 s — no wrist HR backfill")
            return []
        case let .failure(error)?:
            debugLog("[WorkoutRecorder.backfill] HealthKit HR query failed: \(error.localizedDescription) — no wrist HR backfill")
            return []
        case let .success(samples)?:
            if samples.isEmpty {
                debugLog("[WorkoutRecorder.backfill] HealthKit had 0 HR samples in [\(sessionStart), \(sessionEnd)] — wrist HR may be unavailable")
            }
            return samples
        }
    }

    /// The HealthKit heart-rate query, bounded at 3 s: nil when it timed out.
    private static func wristHRQuery(
        from sessionStart: Date,
        to sessionEnd: Date,
        heartRate: HeartRateHealthQueries
    ) async -> Result<[(date: Date, hr: Double)], any Error>? {
        await runWithTimeout(seconds: 3.0) { () async -> Result<[(date: Date, hr: Double)], any Error> in
            do {
                return .success(try await heartRate.fetchHeartRateSamples(from: sessionStart, to: sessionEnd))
            } catch {
                return .failure(error)
            }
        }
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
// Each names no member of `WorkoutRecorder` and calls nothing on it, so
// none needs to be inside the type.

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
/// (`WeatherService.current`, refreshed each ~30 min during the
/// workout); this is purely wiring it into the archived record before
/// it evaporates. Outdoor sports only — indoor sessions carry no heat
/// stimulus and would otherwise capture stale ambient weather.
private func attachWeatherSnapshot(to metadata: inout WorkoutMetadata, sport: Sport, weather: WeatherService) {
    guard sport.usesGPS, let live = weather.current else { return }
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
