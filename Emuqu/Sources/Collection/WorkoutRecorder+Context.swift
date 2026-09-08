import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// Split out from WorkoutRecorder.swift. Holds AI
// context builders (workout, route topology, weather, interval
// progress), route auto-detection, climb/turn computation, threshold
// breach evaluation, breadcrumb archival, split paces, and grade.
//
// Its own type rather than an extension on `WorkoutRecorder`, same reasoning
// as the `RRCollector` splits: ~500 lines reading ~44 recorder members. Those
// reads are `recorder.` and countable rather than looking like this type's own state.

extension WorkoutAIContextBuilder {
    /// The per-turn locals `buildContext` derives before assembling the snapshot.
    /// Grouped so the assembly itself stays a single readable expression.
    struct ContextInputs {
        let userMaxHR: Int
        let startDate: Date
        let loc: CLLocation?
        let heading: Double?
        let grade: Double?
        let lastSample: WorkoutSample?
        let road: RoadGeocodingService.RoadContext?
        let zones: WorkoutZoneBreakdown
    }

    private func contextInputs() -> ContextInputs {
        let loc = recorder.location.currentLocation
        let userMaxHR = recorder.settingsProvider().effectiveMaxHR
        return ContextInputs(
            userMaxHR: userMaxHR,
            startDate: recorder.sessionStartDate ?? Date(),
            loc: loc,
            heading: WorkoutRecorder.validCourse(loc),
            grade: computeCurrentGradePercent(),
            lastSample: recorder.samplesView.last,
            road: AppDependencies.current.location.roadGeocodingService.current,
            zones: WorkoutZoneBreakdown.compute(
                samples: recorder.workoutSamples,
                userMaxHR: userMaxHR,
                userRestingHR: recorder.settingsProvider().effectiveRestingHR
            )
        )
    }

    /// The factual live-workout snapshot handed to the AI coach each turn.
    ///
    /// `userMaxHR` is the physiological ceiling (user override, else 220-age,
    /// else 180). NEVER use session recorder.peakHR as the denominator for zones —
    /// that produces "Zone 5 at 100 bpm" when peak is only 105.
    ///
    /// `hrDriftPercent` is nil here: it's computed on finalize and isn't cheap
    /// to recompute live.
    ///
    /// The resolved address is mirrored in so `asFactSheet()` can
    /// emit a human-readable recorder.location. Source: RoadGeocodingService runs the
    /// throttled (25 m / 60 s) reverse-geocode and caches the latest
    /// RoadContext on `.current`.
    ///
    /// Live trend metrics (mid-workout self-comparison) all return
    /// nil before enough samples are buffered; the AI skips the corresponding
    /// line of the fact sheet rather than narrating a half-cooked number. The
    /// cross-workout baselines and today's frozen readiness are computed once at
    /// workout start (see `start()`), so the numbers match what the user saw on
    /// the dashboard ring. Days-until-fresh is the rest forecast (zero added
    /// load); steady-state TSB is the "if I do today's load every day" forecast.
    func buildContext(sport: Sport) -> WorkoutAIContext {
        let inputs = contextInputs()
        return WorkoutAIContext(
            sport: sport, nowAt: Date(), sessionStart: inputs.startDate, elapsedSeconds: recorder.elapsedSeconds, heartRate: recorder.currentHR, peakHR: recorder.peakHR, userMaxHR: inputs.userMaxHR, hrDriftPercent: nil, alpha1: recorder.dfa.currentAlpha1,
            band: recorder.dfa.currentBand, alpha1FitQuality: recorder.dfa.fitQuality, alpha1Status: recorder.dfa.status, distanceMeters: recorder.location.distanceMeters, currentPaceSecPerKm: livePaceSecPerKm(lastSample: inputs.lastSample),
            currentSpeedMS: WorkoutRecorder.validSpeed(inputs.loc), cadenceStepsPerMin: recorder.cadenceStepsPerMin, powerWatts: recorder.powerWatts, footPodActive: recorder.footPodActive, currentMETs: inputs.lastSample?.mets, recentSplitPaces: recentSplitPacesSecPerKm(),
            currentLatitude: inputs.loc?.coordinate.latitude, currentLongitude: inputs.loc?.coordinate.longitude, currentAltitudeMeters: inputs.loc?.altitude, currentHeadingDegrees: inputs.heading, gpsAccuracyMeters: recorder.location.lastHorizontalAccuracy,
            elevationGainMeters: recorder.elevationGainMeters, currentGradePercent: inputs.grade, upcomingClimb: computeUpcomingClimb(currentLocation: inputs.loc), routeTopology: computeRouteTopology(currentLocation: inputs.loc), weather: AppDependencies.current.location.weatherService.current,
            strapConnected: recorder.core.polarManager.connectionState == .connected, strapSilentSec: recorder.strapSilentSeconds(), currentRoadName: inputs.road?.road, currentLocality: inputs.road?.locality, currentAdministrativeArea: inputs.road?.administrativeArea,
            currentCountryCode: inputs.road?.countryCode, currentCompactAddress: inputs.road?.compactAddress, currentNearestCrossStreet: inputs.road?.nearestCrossStreet, currentNearestIntersection: inputs.road?.nearestIntersection, sessionAverageHR: sessionAverageHR(),
            reverseSplitDeltaSecPerKm: WorkoutLiveTrends.reverseSplitDeltaSecPerKm(samples: recorder.workoutSamples), liveHRDriftPercent: WorkoutLiveTrends.hrDriftPercent(samples: recorder.workoutSamples),
            recentHRSlopeBpm: WorkoutLiveTrends.recentHRSlopeBpm(samples: recorder.workoutSamples), aerobicDecouplingPercent: WorkoutLiveTrends.aerobicDecouplingPercent(samples: recorder.workoutSamples),
            cadenceDriftSpm: WorkoutLiveTrends.cadenceDriftSpm(samples: recorder.workoutSamples), gradeAdjustedPaceSecPerKm: WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: livePaceSecPerKm(lastSample: inputs.lastSample), gradePercent: inputs.grade),
            recentSplitGradeAdjustedPaces: WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: recorder.workoutSamples), projectedMinutesUntilFade: recorder.liveProjectedMinutesUntilFade(), historicalSportAvgPaceSecPerKm: recorder.cachedHistoricalBaselines.avgPaceSecPerKm,
            historicalSportAvgHR: recorder.cachedHistoricalBaselines.avgHR, historicalSportAvgAlpha1: recorder.cachedHistoricalBaselines.avgAlpha1, historicalSportSampleCount: recorder.cachedHistoricalBaselines.sampleCount,
            todayRecoveryScore: recorder.cachedTodayReadiness.recoveryScore, todayTrainingReadiness: recorder.cachedTodayReadiness.trainingReadiness, todayATL: recorder.cachedTodayReadiness.atl, todayCTL: recorder.cachedTodayReadiness.ctl, todayTSB: recorder.cachedTodayReadiness.tsb,
            projectedDaysUntilFresh: recorder.cachedTrainingProjection.daysUntilFresh, projectedTSBTomorrowSteadyState: recorder.cachedTrainingProjection.tsbTomorrowSteadyState, recoveryHoursNeeded: recorder.liveRecoveryHoursNeeded(), zone1Sec: inputs.zones.z1Sec,
            zone2Sec: inputs.zones.z2Sec, zone3Sec: inputs.zones.z3Sec, zone4Sec: inputs.zones.z4Sec, zone5Sec: inputs.zones.z5Sec, dominantZone: inputs.zones.dominantZone, predictedRaceTime5KSec: recorder.cachedRacePredictionsByDistance[5_000],
            predictedRaceTime10KSec: recorder.cachedRacePredictionsByDistance[10_000], predictedRaceTimeHalfSec: recorder.cachedRacePredictionsByDistance[21_097.5], predictedRaceTimeMarathonSec: recorder.cachedRacePredictionsByDistance[42_195], userUnits: UnitsPreferenceStore.current,
            targetZone: recorder.targetZone, activeThresholds: recorder.userThresholds, thresholdBreachSec: recorder.thresholdBreachSec
        )
    }

    /// Running session average HR from the live HR
    /// sample buffer. Computed inline so we don't allocate a
    /// running-mean accumulator. Cheap (typical session = a few
    /// hundred samples; even a 6 h ride is ~21 K samples and
    /// a sum/count is ~50 µs — invisible against the per-tick
    /// GPS / DFA work `buildContext` already does).

    /// The most recent pace we actually have — the newest sample when it carries
    /// one, else the last sample that did.
    private func livePaceSecPerKm(lastSample: WorkoutSample?) -> Double? {
        lastSample?.paceSecPerKm ?? recorder.samplesView.last(where: { $0.paceSecPerKm != nil })?.paceSecPerKm
    }

    /// Running session average HR from the live HR
    /// sample buffer. Computed inline so we don't allocate a
    /// running-mean accumulator. Cheap (typical session = a few
    /// hundred samples; even a 6 h ride is ~21 K samples and
    /// a sum/count is ~50 µs — invisible against the per-tick
    /// GPS / DFA work `buildContext` already does).
    private func sessionAverageHR() -> Double? {
        let hrs = recorder.workoutSamples.compactMap { $0.heartRate }
        guard !hrs.isEmpty else { return nil }
        return Double(hrs.reduce(0, +)) / Double(hrs.count)
    }

    /// Recognise a route the user has explicitly saved to their library.
    /// Match is direction-agnostic: a saved "Daily 1" loop matches whether
    /// the user is walking it the same way as the day they saved it OR in
    /// reverse. Sets `recorder.plannedRoute` + the direction flag so the banner +
    /// AI coach speak about it correctly. Single-shot per workout.
    ///
    /// We deliberately do NOT auto-mine random history — only the user's
    /// curated saved library. Surprise auto-binds against random old
    /// workouts created false positives in earlier iterations and made
    /// the "what is the app doing right now" question harder to answer.
    func attemptAutoRouteDetection(sport: Sport) {
        let track = recorder.location.track
        let traveled = recorder.trackLengthMeters(track)
        guard traveled >= RouteLibrary.detectionTriggerMeters else { return }

        recorder.routeDetectionAttempted = true
        guard let match = RouteLibrary.findMatch(
            currentTrack: track,
            sport: sport,
            store: AppDependencies.current.location.savedRouteStore
        ) else {
            return
        }
        recorder.plannedRoute = match.route
        recorder.plannedRouteWasAutoDetected = true
        recorder.plannedRouteDirection = match.direction
        debugLog("[WorkoutRecorder] auto-bound saved route '\(match.savedRoute.name)' \(match.direction == .reverse ? "(reverse)" : "") fit \(Int(match.meanFitMeters.rounded())) m")
    }

    /// Project the user's current GPS position onto the bound route and
    /// return the next climb's distance + grade. Returns nil when no route
    /// is bound, the user is too far off-course to project, or no climb
    /// remains ahead. This populates `WorkoutAIContext.upcomingClimb`,
    /// which the trigger engine (and the LLM context) can read to fire
    /// pre-emptive cues like "big climb in 400 m, save power".
    func computeUpcomingClimb(currentLocation: CLLocation?) -> WorkoutAIContext.UpcomingClimb? {
        guard let route = recorder.plannedRoute, let loc = currentLocation else { return nil }
        guard let progress = RouteProgress.compute(currentLocation: loc, route: route) else {
            return nil
        }
        guard let next = progress.nextClimb,
              let distance = progress.metersToNextClimb,
              distance < 2_000  // only flag climbs within 2 km — beyond that the cue is useless
        else { return nil }
        return WorkoutAIContext.UpcomingClimb(
            distanceMeters: distance,
            gradePercent: next.averageGradePercent,
            lengthMeters: next.lengthMeters,
            gainMeters: next.gainMeters
        )
    }

    /// Build the rich RouteTopology snapshot — every climb the AI coach
    /// should know about ahead, total ascent remaining, peak altitude,
    /// steepest grade. Returns nil when no route is bound or we can't
    /// project the user's position onto it. Cheap to compute (one
    /// linear scan over a few hundred trackpoints).
    ///
    /// Turns ahead walk the polyline from the user's current position and flag
    /// recorder.bearing changes ≥30° within ~30 m windows, capped at 5.
    func computeRouteTopology(currentLocation: CLLocation?) -> WorkoutAIContext.RouteTopology? {
        guard let route = recorder.plannedRoute, let loc = currentLocation,
              let progress = RouteProgress.compute(currentLocation: loc, route: route)
        else { return nil }
        let climbsAhead = Self.climbsAhead(on: route, pastDistance: progress.distanceAlongMeters)
        let altitudes = route.trackpoints.map(\.altitudeMeters)
        let routeMax = altitudes.max() ?? 0
        return WorkoutAIContext.RouteTopology(
            climbsAhead: climbsAhead,
            totalAscentRemainingMeters: climbsAhead.reduce(0.0) { $0 + $1.gainMeters },
            peakAltitudeMeters: routeMax,
            altitudeAboveRouteMinMeters: max(0, loc.altitude - (altitudes.min() ?? 0)),
            steepestGradeAheadPercent: climbsAhead.map(\.gradePercent).max(),
            metersToPeak: Self.metersToPeak(route: route, altitudes: altitudes, routeMax: routeMax, progress: progress),
            turnsAhead: computeUpcomingTurns(route: route, fromDistanceAlongMeters: progress.distanceAlongMeters)
        )
    }

    /// Climbs queue — everything ahead, capped at 5 to keep the AI
    /// context budget manageable. Most loops have 1–3 climbs anyway.
    private static func climbsAhead(on route: Route, pastDistance: Double) -> [WorkoutAIContext.UpcomingClimb] {
        route.climbs
            .filter { $0.startDistanceMeters > pastDistance }
            .prefix(5)
            .map { climb in
                WorkoutAIContext.UpcomingClimb(
                    distanceMeters: max(0, climb.startDistanceMeters - pastDistance),
                    gradePercent: climb.averageGradePercent,
                    lengthMeters: climb.lengthMeters,
                    gainMeters: climb.gainMeters,
                    roadName: climb.roadName
                )
            }
    }

    /// Distance from the user's projected position to the route's high point.
    private static func metersToPeak(
        route: Route,
        altitudes: [Double],
        routeMax: Double,
        progress: RouteProgress
    ) -> Double {
        let peakIdx = altitudes.firstIndex(where: { $0 == routeMax }) ?? 0
        let peakAlongMeters = peakIdx < route.cumulativeDistanceMeters.count
            ? route.cumulativeDistanceMeters[peakIdx]
            : 0
        return peakAlongMeters - progress.distanceAlongMeters
    }

    /// Walk the route polyline from `fromDistanceAlongMeters` and detect
    /// up to 5 upcoming meaningful direction changes. A "turn" is a
    /// point where the recorder.bearing into the segment differs from the
    /// recorder.bearing out of the segment by ≥30°. We sample bearings over
    /// roughly-15 m windows (3-4 trackpoints typically) so single-point
    /// GPS noise doesn't register as a turn. Below 30° it's drift.
    ///
    /// After a turn is recorded we skip past it before looking for the next,
    /// so a long sweeping curve isn't double-counted.
    ///
    /// Defensive bound. `cumulativeDistanceMeters` is
    /// documented as parallel to `trackpoints` but the contract isn't
    /// enforced. The SHORTER count drives all index operations so
    /// a corrupt route (older saved data, partial decode) can't
    /// out-of-bounds-crash here on the workout-start tick path.
    func computeUpcomingTurns(
        route: Route,
        fromDistanceAlongMeters startDistance: Double
    ) -> [WorkoutAIContext.UpcomingTurn] {
        let pts = route.trackpoints
        let dists = route.cumulativeDistanceMeters
        let safeCount = min(pts.count, dists.count)
        // Start from the first trackpoint past the user's current position.
        guard safeCount >= 4,
              let rawStartIdx = dists.firstIndex(where: { $0 > startDistance }),
              rawStartIdx < safeCount
        else { return [] }
        var turns: [WorkoutAIContext.UpcomingTurn] = []
        var i = rawStartIdx
        while i < safeCount - 2, turns.count < 5 {
            guard let step = turnStep(from: i, pts: pts, dists: dists, safeCount: safeCount) else { break }
            let isTurn = abs(step.delta) >= 30
            if isTurn { turns.append(Self.upcomingTurn(step, dists: dists, startDistance: startDistance, label: recorder.turnLabel(deltaDegrees: step.delta))) }
            i = isTurn ? step.endIdx : step.midIdx
        }
        return turns
    }

    private static func upcomingTurn(
        _ step: (midIdx: Int, endIdx: Int, delta: Double),
        dists: [Double],
        startDistance: Double,
        label: String
    ) -> WorkoutAIContext.UpcomingTurn {
        WorkoutAIContext.UpcomingTurn(
            distanceMeters: max(0, dists[step.midIdx] - startDistance),
            bearingChangeDegrees: step.delta,
            direction: label
        )
    }

    /// One ~15 m in / ~15 m out recorder.bearing comparison starting at `i`. Nil when
    /// the route runs out before both windows can be measured.
    private func turnStep(
        from i: Int,
        pts: [Route.Point],
        dists: [Double],
        safeCount: Int
    ) -> (midIdx: Int, endIdx: Int, delta: Double)? {
        guard let midIdx = recorder.nextIndex(after: i, atDistance: 15, in: dists), midIdx < safeCount,
              let endIdx = recorder.nextIndex(after: midIdx, atDistance: 15, in: dists), endIdx < safeCount
        else { return nil }
        let bearingIn = recorder.bearing(from: pts[i], to: pts[midIdx])
        let bearingOut = recorder.bearing(from: pts[midIdx], to: pts[endIdx])
        return (midIdx, endIdx, recorder.signedBearingDelta(from: bearingIn, to: bearingOut))
    }

    /// Map the trigger-engine RouteTopology onto the LiveWorkoutSnapshot's
    /// flavour. Two structs because the trigger engine and the AI fact
    /// catalog have different audiences: the engine sees structured Swift
    /// types; the catalog needs Codable for JSON serialization to the
    /// model. Same data, two skins.
    func liveRouteTopologySnapshot(currentLocation: CLLocation?) -> AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot? {
        guard let topo = computeRouteTopology(currentLocation: currentLocation) else { return nil }
        return AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot(
            climbsAhead: topo.climbsAhead.map {
                .init(
                    distanceToStartMeters: $0.distanceMeters, lengthMeters: $0.lengthMeters,
                    gainMeters: $0.gainMeters, gradePercent: $0.gradePercent, roadName: $0.roadName
                )
            },
            totalAscentRemainingMeters: topo.totalAscentRemainingMeters,
            peakAltitudeMeters: topo.peakAltitudeMeters,
            altitudeAboveRouteMinMeters: topo.altitudeAboveRouteMinMeters,
            steepestGradeAheadPercent: topo.steepestGradeAheadPercent,
            metersToPeak: topo.metersToPeak,
            turnsAhead: topo.turnsAhead.map {
                .init(distanceMeters: $0.distanceMeters, bearingChangeDegrees: $0.bearingChangeDegrees, direction: $0.direction)
            }
        )
    }

    func liveWeatherSnapshot() -> AssistantContext.LiveWorkoutSnapshot.WeatherSnapshot? {
        guard let w = AppDependencies.current.location.weatherService.current else { return nil }
        return AssistantContext.LiveWorkoutSnapshot.WeatherSnapshot(
            temperatureC: w.temperatureC,
            apparentTemperatureC: w.apparentTemperatureC,
            windKMH: w.windKMH,
            windDirectionDegrees: w.windDirectionDegrees,
            humidityPercent: w.humidityPercent,
            conditions: w.conditions,
            observedAt: w.observedAt
        )
    }

    /// Snapshot the IntervalController's current state for the AI broker
    /// each tick. Returns nil when no plan is bound or the plan has
    /// finished (so the AI doesn't see a stale step from a prior plan).
    /// `nextStepLabel` peeks one ahead so the assistant can answer "what's
    /// after this?" without needing the whole plan.
    func liveIntervalProgressSnapshot() -> AssistantContext.LiveWorkoutSnapshot.IntervalProgressSnapshot? {
        let ic = recorder.intervalController
        guard let step = ic.currentStep, !ic.isFinished else { return nil }
        let stepLabel = step.intervalAILabel
        // Peek the next step. The controller doesn't expose its
        // flat-step list directly; we infer the next step by checking
        // whether `currentStepNumber < totalSteps`. The label of the
        // next is best-effort — we ask the controller via a small public
        // helper added below if available, otherwise we leave it nil.
        let nextLabel: String? = ic.peekNextStep()?.intervalAILabel
        let remaining: Int? = step.durationSec.map { max(0, $0 - ic.stepElapsedSec) }
        return AssistantContext.LiveWorkoutSnapshot.IntervalProgressSnapshot(
            currentStepNumber: ic.stepNumber,
            totalSteps: ic.totalSteps,
            currentStepLabel: stepLabel,
            stepElapsedSec: ic.stepElapsedSec,
            stepRemainingSec: remaining,
            nextStepLabel: nextLabel,
            isFinished: ic.isFinished
        )
    }

    /// Walk every user-declared threshold once per second, count up the
    /// breach duration when out-of-band, reset to 0 when back in. This is
    /// the state machine the AI coach reads to decide whether to interrupt
    /// the audiobook. We DON'T speak from here — the trigger engine owns
    /// the cooldown / cue policy.
    ///
    /// NL thresholds are evaluated by a separate AI path on a ~60s cadence
    /// (see `evaluateNaturalLanguageThresholds`); the per-tick breach state
    /// machine ignores them entirely.
    func updateThresholdBreaches(sport: Sport) {
        guard !recorder.userThresholds.isEmpty else {
            if !recorder.thresholdBreachSec.isEmpty { recorder.thresholdBreachSec.removeAll() }
            return
        }
        let signals = thresholdSignals(sport: sport)
        for threshold in recorder.userThresholds where threshold.metric != .naturalLanguage {
            applyBreachTick(threshold, signals: signals)
        }
    }

    /// Every metric a threshold can be declared against, sampled once per tick
    /// so N thresholds don't each recompute them.
    struct ThresholdSignals {
        let hrBPM: Int?
        let hrZone: Int?
        let powerWatts: Int?
        let ftpWatts: Int?
        let paceSecPerKm: Double?
        let alpha1: Double?
        let cadenceSPM: Double?
        let distanceMeters: Double
        let elapsedSec: Int?
        let elevationGainMeters: Double
        let gradePercent: Double?
    }

    /// Distance comes from the recorder's authoritative `recorder.distanceMeters`
    /// (max of GPS / pedometer / foot-pod / PM5). elapsed = wall-clock since
    /// recorder.sessionStartDate.
    ///
    /// Elevation uses the recorder's canonical recorder.motion-side accumulator
    /// so the threshold check sees the same number the live ticker
    /// and the AI snapshot do. The recorder.location-manager's GPS-altitude
    /// gain is an internal fallback signal for devices without a
    /// barometer; mixing the two sources here would have the
    /// threshold fire on numbers the user can't see in the UI.
    /// `currentGrade` is the same trailing ~100 m delta the AI context uses.
    private func thresholdSignals(sport: Sport) -> ThresholdSignals {
        let settings = recorder.settingsProvider()
        let hr = recorder.workoutHR.currentHR
        return ThresholdSignals(
            hrBPM: hr,
            hrZone: WorkoutGeometry.karvonenZone(hr: hr, maxHR: settings.effectiveMaxHR, restingHR: settings.effectiveRestingHR),
            powerWatts: recorder.motion.powerWatts,
            ftpWatts: Self.sportFTP(for: sport, settings: recorder.settingsProvider()),
            paceSecPerKm: recorder.workoutSamples.last(where: { $0.paceSecPerKm != nil })?.paceSecPerKm,
            alpha1: recorder.dfa.currentAlpha1,
            cadenceSPM: recorder.motion.cadenceStepsPerMin,
            distanceMeters: recorder.distanceMeters,
            elapsedSec: recorder.sessionStartDate.map { Int(Date().timeIntervalSince($0)) },
            elevationGainMeters: recorder.elevationGainMeters,
            gradePercent: computeCurrentGradePercent()
        )
    }

    /// Running and cycling FTP are physiologically distinct, so a power
    /// threshold anchors to whichever the sport uses: running FTP is typically
    /// 5-15% higher than cycling FTP for the same person, because of the
    /// muscle-mass and weight-recorder.bearing differences.
    static func sportFTP(for sport: Sport, settings: UserSettings) -> Int? {
        switch sport {
        case .run, .trailRun, .walk, .hike, .treadmill: return settings.effectiveRunningFTP
        case .bike, .indoorBike: return settings.effectiveCyclingFTP
        default: return nil
        }
    }

    /// Advance one threshold's breach counter for this tick.
    ///
    /// Coming back inside the band resets the counter, so the user gets credit
    /// for self-correcting and a future breach starts fresh. A metric that
    /// isn't available right now (e.g. an HR threshold while the strap is
    /// silent) leaves the counter untouched — neither grow nor reset until we
    /// have signal again.
    private func applyBreachTick(_ threshold: WorkoutThreshold, signals: ThresholdSignals) {
        let breached = threshold.evaluate(
            hrBPM: signals.hrBPM, hrZone: signals.hrZone,
            powerWatts: signals.powerWatts, ftpWatts: signals.ftpWatts,
            paceSecPerKm: signals.paceSecPerKm, alpha1: signals.alpha1,
            cadenceSPM: signals.cadenceSPM, distanceMeters: signals.distanceMeters,
            elapsedSec: signals.elapsedSec, elevationGainMeters: signals.elevationGainMeters,
            gradePercent: signals.gradePercent
        )
        switch breached {
        case .some(true): recorder.thresholdBreachSec[threshold.id, default: 0] += 1
        case .some(false): recorder.thresholdBreachSec[threshold.id] = 0
        case .none: break
        }
    }

    /// Auto-archive a finished GPS-recorder.bearing workout's track
    /// as a breadcrumb trail. Origin = first track fix (where the user
    /// started — typically where they parked / left the trailhead /
    /// stepped out the door). Subsequent fixes are decimated to ~25 m
    /// granularity so a long workout doesn't bloat the archive: that's
    /// the same threshold the live recorder uses for committing a
    /// breadcrumb fix during Get Me Back mode, so the storage shape
    /// matches.
    func archiveWorkoutTrackAsBreadcrumbTrail(
        track: [CLLocation],
        sport: Sport,
        start: Date
    ) {
        guard let first = track.first else { return }
        let origin = BreadcrumbFix(from: first)
        let fixes = WorkoutGeometry.decimatedBreadcrumbFixes(track: track, origin: origin)
        // No useful trail if we only have the origin — likely the
        // workout was stationary or GPS never produced a second fix.
        guard fixes.count >= 2 else { return }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let trail = BreadcrumbTrail(
            startedAt: start,
            origin: origin,
            fixes: fixes,
            label: "\(sport.displayName) on \(df.string(from: start))",
            resolvedOriginLabel: nil
        )
        AppDependencies.current.location.breadcrumbStore.archive(trail)
        debugLog("[Recorder] auto-archived workout track as breadcrumb trail (\(fixes.count) fixes, label=\"\(trail.label ?? "")\")")
    }

    /// Pull the last few per-split paces out of the captured sample series.
    /// Used to detect pace-vs-HR mismatches in the trigger engine. Index 0
    /// = most recent split.
    ///
    /// Computed on the fly from the sample stream: the series is divided into
    /// non-overlapping 1 km chunks using cumulative distance, and the average
    /// pace of the last up-to-3 completed chunks is returned.
    func recentSplitPacesSecPerKm() -> [Double] {
        guard !recorder.workoutSamples.isEmpty else { return [] }
        return WorkoutGeometry.kilometreChunks(recorder.workoutSamples).suffix(3).reversed().compactMap { chunk in
            let dist = chunk.distEnd - chunk.distStart
            let dur = Double(chunk.tEnd - chunk.tStart)
            guard dist > 0, dur > 0 else { return nil }
            return dur / (dist / 1_000)
        }
    }

    /// Estimate current grade from the tail end of the captured track. Uses
    /// the most recent ~100 m of cumulative distance and its elevation delta.
    /// Returns nil when the window doesn't cover enough ground or the
    /// elevation noise floor hasn't been cleared. This is deliberately coarse
    /// — one GPS sample's altitude swings ±5 m, so short windows are noise.
    ///
    /// `track.last` is always non-nil past the count guard.
    /// Optional binding is used for the refactor-spec "zero magic" rule rather
    /// than a force-unwrap.
    func computeCurrentGradePercent() -> Double? {
        let track = recorder.location.track
        guard track.count >= 2 else { return nil }
        let window = WorkoutGeometry.trailingGradeWindow(track: track)
        guard window.meters >= 50 else { return nil }   // too short to trust
        guard let endFix = track.last else { return nil }
        let rise = endFix.altitude - track[window.startIdx].altitude
        // Ignore altitude deltas below the known jitter floor so flat
        // segments don't report "+2.3% grade" from GPS noise.
        guard abs(rise) >= 2.0 else { return 0 }
        return (rise / window.meters) * 100.0
    }

}
