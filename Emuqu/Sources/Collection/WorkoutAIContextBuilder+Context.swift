import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// AI context builders (workout, route topology, weather), route
// auto-detection, climb/turn computation, threshold breach evaluation,
// breadcrumb archival, split paces, and grade.

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
        let loc = sensors.startedLocation?.currentLocation
        let userMaxHR = settingsProvider().effectiveMaxHR
        return ContextInputs(
            userMaxHR: userMaxHR,
            startDate: lifecycle.sessionStartDate ?? Date(),
            loc: loc,
            heading: WorkoutTicker.validCourse(loc),
            grade: computeCurrentGradePercent(),
            lastSample: capture.workoutSamples.last,
            road: services.roadGeocodingService.current,
            zones: capture.liveZoneBreakdown(userMaxHR: userMaxHR)
        )
    }

    /// The factual live-workout snapshot handed to the AI coach each turn.
    ///
    /// `userMaxHR` is the physiological ceiling (user override, else 208 − 0.7 × age,
    /// else 180). NEVER use session peakHR as the denominator for zones —
    /// that produces "Zone 5 at 100 bpm" when peak is only 105.
    ///
    /// `hrDriftPercent` is nil here: it's computed on finalize and isn't cheap
    /// to recompute live.
    ///
    /// The resolved address is mirrored in so `asFactSheet()` can
    /// emit a human-readable location. Source: RoadGeocodingService runs the
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
    /// The live trends come from the capture's tally (`syncedLiveTrends`),
    /// read after `contextInputs` updated its zone fold.
    func buildContext(sport: Sport) -> WorkoutAIContext {
        let (inputs, trends, start) = (contextInputs(), capture.syncedLiveTrends(), coaching.startContext)
        return withGroundAhead(WorkoutAIContext(
            sport: sport, nowAt: Date(), sessionStart: inputs.startDate, elapsedSeconds: lifecycle.elapsedSeconds, heartRate: workoutHR.currentHR, peakHR: workoutHR.peakHR, userMaxHR: inputs.userMaxHR, hrDriftPercent: nil, alpha1: dfa.currentAlpha1, band: dfa.currentBand,
            alpha1FitQuality: dfa.fitQuality, alpha1Status: dfa.status, distanceMeters: motion.distanceMeters, currentPaceSecPerKm: signals.currentPaceSecPerKm, currentSpeedMS: signals.currentSpeedMS, cadenceStepsPerMin: motion.cadenceStepsPerMin, powerWatts: motion.powerWatts,
            footPodActive: motion.footPodActive, currentMETs: inputs.lastSample?.mets, recentSplitPaces: recentSplitPacesSecPerKm(), currentLatitude: inputs.loc?.coordinate.latitude, currentLongitude: inputs.loc?.coordinate.longitude, currentAltitudeMeters: inputs.loc?.altitude,
            currentHeadingDegrees: inputs.heading, gpsAccuracyMeters: sensors.startedLocation?.lastHorizontalAccuracy, elevationGainMeters: motion.elevationGainMeters, currentGradePercent: inputs.grade, upcomingClimb: computeUpcomingClimb(currentLocation: inputs.loc),
            routeTopology: computeRouteTopology(currentLocation: inputs.loc), weather: services.weatherService.current, strapConnected: core.strapLink.connectionState == .connected, strapSilentSec: signals.strapSilentSeconds(source: lifecycle.activeHRSource),
            wristHeartRateLive: services.watchConnectivityBridge.freshWristHR(now: Date()) != nil, currentRoadName: inputs.road?.road, currentLocality: inputs.road?.locality, currentAdministrativeArea: inputs.road?.administrativeArea, currentCountryCode: inputs.road?.countryCode,
            currentCompactAddress: inputs.road?.compactAddress, currentNearestCrossStreet: inputs.road?.nearestCrossStreet, currentNearestIntersection: inputs.road?.nearestIntersection, sessionAverageHR: trends.sessionAverageHR, reverseSplitDeltaSecPerKm: trends.reverseSplitDeltaSecPerKm,
            liveHRDriftPercent: trends.hrDriftPercent, recentHRSlopeBpm: trends.recentHRSlopeBpm, aerobicDecouplingPercent: trends.aerobicDecouplingPercent, cadenceDriftSpm: trends.cadenceDriftSpm,
            gradeAdjustedPaceSecPerKm: WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: signals.currentPaceSecPerKm, gradePercent: inputs.grade), recentSplitGradeAdjustedPaces: trends.recentSplitGradeAdjustedPaces, projectedMinutesUntilFade: trends.projectedMinutesUntilFade,
            historicalSportAvgPaceSecPerKm: start.historicalBaselines.avgPaceSecPerKm, historicalSportAvgHR: start.historicalBaselines.avgHR, historicalSportAvgAlpha1: start.historicalBaselines.avgAlpha1, historicalSportSampleCount: start.historicalBaselines.sampleCount,
            todayRecoveryScore: start.todayReadiness.recoveryScore, todayTrainingReadiness: start.todayReadiness.trainingReadiness, todayATL: start.todayReadiness.atl, todayCTL: start.todayReadiness.ctl, todayTSB: start.todayReadiness.tsb,
            projectedDaysUntilFresh: start.trainingProjection.daysUntilFresh, projectedTSBTomorrowSteadyState: start.trainingProjection.tsbTomorrowSteadyState, recoveryHoursNeeded: start.recoveryHoursNeeded, zone1Sec: inputs.zones.z1Sec, zone2Sec: inputs.zones.z2Sec,
            zone3Sec: inputs.zones.z3Sec, zone4Sec: inputs.zones.z4Sec, zone5Sec: inputs.zones.z5Sec, dominantZone: inputs.zones.dominantZone, predictedRaceTime5KSec: start.racePredictionsByDistance[5_000], predictedRaceTime10KSec: start.racePredictionsByDistance[10_000],
            predictedRaceTimeHalfSec: start.racePredictionsByDistance[21_097.5], predictedRaceTimeMarathonSec: start.racePredictionsByDistance[42_195], userUnits: UnitsPreferenceStore.current,
            targetZone: lifecycle.targetZone, activeThresholds: coaching.thresholds.thresholds, thresholdBreachSec: coaching.thresholds.breachSec
        ))
    }

    /// The climb ahead from past workouts, and the threshold heart rate the
    /// hill forecast measures it against.
    private func withGroundAhead(_ context: WorkoutAIContext) -> WorkoutAIContext {
        var context = context
        let settings = settingsProvider()
        context.historyClimbAhead = routeGuidance.places.climbAhead
        context.thresholdHeartRate = settings.effectiveLTHR
        context.thresholdHeartRateIsUserSet = settings.hasUserLTHR
        return context
    }

    /// Recognise a route the user has explicitly saved to their library.
    /// Match is direction-agnostic: a saved "Daily 1" loop matches whether
    /// the user is walking it the same way as the day they saved it OR in
    /// reverse. Sets `routeGuidance.planned` + the direction flag so the banner +
    /// AI coach speak about it correctly. Runs first at
    /// `RouteLibrary.detectionTriggerMeters` of GPS distance, then, while
    /// nothing matches, after each further stretch of that length, so a loop
    /// joined after a warm-up leg is still recognised. The distance is the
    /// one the location manager keeps as fixes arrive, so the ticks between
    /// attempts cost nothing; measuring the whole track each second did not.
    ///
    /// We deliberately do NOT auto-mine random history — only the user's
    /// curated saved library. Surprise auto-binds against random old
    /// workouts created false positives in earlier iterations and made
    /// the "what is the app doing right now" question harder to answer.
    func attemptAutoRouteDetection(sport: Sport) {
        let traveled = sensors.location.distanceMeters
        guard traveled >= max(RouteLibrary.detectionTriggerMeters, routeGuidance.nextDetectionAtMeters) else { return }

        routeGuidance.nextDetectionAtMeters = traveled + RouteLibrary.detectionTriggerMeters
        guard let match = RouteLibrary.findMatch(
            currentTrack: sensors.location.track,
            sport: sport,
            store: services.savedRouteStore
        ) else {
            return
        }
        routeGuidance.planned = match.route
        routeGuidance.savedRouteId = match.savedRoute.id
        routeGuidance.wasAutoDetected = true
        routeGuidance.direction = match.direction
        debugLog("[WorkoutRecorder] auto-bound saved route \(match.savedRoute.id.uuidString.prefix(8)) \(match.direction == .reverse ? "(reverse)" : "") fit \(Int(match.meanFitMeters.rounded())) m")
    }

    /// Projects `location` onto `route`, continuing from the last tick's point.
    func routeProgress(at location: CLLocation, on route: Route) -> RouteProgress? {
        let progress = RouteProgress.compute(
            currentLocation: location, route: route, previousIndex: routeGuidance.lastProgressIndex
        )
        if let progress { routeGuidance.lastProgressIndex = progress.nearestPointIndex }
        return progress
    }

    /// Project the user's current GPS position onto the bound route and
    /// return the next climb's distance + grade. Returns nil when no route
    /// is bound, the user is too far off-course to project, or no climb
    /// remains ahead. This populates `WorkoutAIContext.upcomingClimb`,
    /// which the trigger engine (and the LLM context) can read to fire
    /// pre-emptive cues like "big climb in 400 m, save power".
    func computeUpcomingClimb(currentLocation: CLLocation?) -> WorkoutAIContext.UpcomingClimb? {
        guard let route = routeGuidance.planned, let loc = currentLocation else { return nil }
        guard let progress = routeProgress(at: loc, on: route) else { return nil }
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
    /// bearing changes ≥30° within ~30 m windows, capped at 5.
    func computeRouteTopology(currentLocation: CLLocation?) -> WorkoutAIContext.RouteTopology? {
        guard let route = routeGuidance.planned, let loc = currentLocation,
              let progress = routeProgress(at: loc, on: route)
        else { return nil }
        let climbsAhead = Self.climbsAhead(on: route, pastDistance: progress.distanceAlongMeters)
        let onClimb = Self.climbInProgress(on: route, pastDistance: progress.distanceAlongMeters)
        let altitudes = route.trackpoints.map(\.altitudeMeters)
        let routeMax = altitudes.max() ?? 0
        return WorkoutAIContext.RouteTopology(
            climbsAhead: climbsAhead,
            totalAscentRemainingMeters: climbsAhead.reduce(onClimb?.remainingGainMeters ?? 0) { $0 + $1.gainMeters },
            peakAltitudeMeters: routeMax,
            altitudeAboveRouteMinMeters: max(0, loc.altitude - (altitudes.min() ?? 0)),
            steepestGradeAheadPercent: (climbsAhead.map(\.gradePercent) + [onClimb?.gradePercent].compactMap { $0 }).max(),
            metersToPeak: Self.metersToPeak(route: route, altitudes: altitudes, routeMax: routeMax, progress: progress),
            turnsAhead: Self.computeUpcomingTurns(route: route, fromDistanceAlongMeters: progress.distanceAlongMeters)
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

    /// The climb the user is part-way up, if any: its gain pro-rated to the
    /// length still ahead, and its grade. `climbsAhead` lists only climbs
    /// that start beyond the user, so without this the ascent remaining and
    /// the steepest grade ahead left out the rest of the current climb.
    private static func climbInProgress(on route: Route, pastDistance: Double) -> (remainingGainMeters: Double, gradePercent: Double)? {
        guard let climb = route.climbs.first(where: { $0.startDistanceMeters <= pastDistance && pastDistance < $0.endDistanceMeters }),
              climb.lengthMeters > 0 else { return nil }
        let shareAhead = (climb.endDistanceMeters - pastDistance) / climb.lengthMeters
        return (climb.gainMeters * shareAhead, climb.averageGradePercent)
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
    /// point where the bearing into the segment differs from the
    /// bearing out of the segment by ≥30°. We sample bearings over
    /// roughly-15 m windows (3-4 trackpoints typically) so single-point
    /// GPS noise doesn't register as a turn. Below 30° it's drift.
    ///
    /// After a turn is recorded we skip past it before looking for the next,
    /// so a long sweeping curve isn't double-counted. No bearing is taken
    /// across a join between recorded segments (`Route.segmentStart(in:)`):
    /// the line between them was never walked, so the search resumes at the
    /// next segment's first point.
    ///
    /// Defensive bound. `cumulativeDistanceMeters` is
    /// documented as parallel to `trackpoints` but the contract isn't
    /// enforced. The SHORTER count drives all index operations so
    /// a corrupt route (older saved data, partial decode) can't
    /// out-of-bounds-crash here on the workout-start tick path.
    static func computeUpcomingTurns(
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
            if let join = route.segmentStart(in: (i + 1) ... step.endIdx) { i = join; continue }
            let isTurn = abs(step.delta) >= 30
            if isTurn { turns.append(Self.upcomingTurn(step, dists: dists, startDistance: startDistance, label: WorkoutGeometry.turnLabel(deltaDegrees: step.delta))) }
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

    /// One ~15 m in / ~15 m out bearing comparison starting at `i`. Nil when
    /// the route runs out before both windows can be measured.
    private static func turnStep(
        from i: Int,
        pts: [Route.Point],
        dists: [Double],
        safeCount: Int
    ) -> (midIdx: Int, endIdx: Int, delta: Double)? {
        guard let midIdx = WorkoutGeometry.nextIndex(after: i, atDistance: 15, in: dists), midIdx < safeCount,
              let endIdx = WorkoutGeometry.nextIndex(after: midIdx, atDistance: 15, in: dists), endIdx < safeCount
        else { return nil }
        let bearingIn = WorkoutGeometry.bearing(from: pts[i], to: pts[midIdx])
        let bearingOut = WorkoutGeometry.bearing(from: pts[midIdx], to: pts[endIdx])
        return (midIdx, endIdx, WorkoutGeometry.signedBearingDelta(from: bearingIn, to: bearingOut))
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
        guard let w = services.weatherService.current else { return nil }
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
        guard !coaching.thresholds.thresholds.isEmpty else { return }
        let signals = thresholdSignals(sport: sport)
        for threshold in coaching.thresholds.thresholds where threshold.metric != .naturalLanguage {
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

    /// Distance comes from the recorder's authoritative `motion.distanceMeters`
    /// (max of GPS / pedometer / foot-pod / PM5). Elapsed is the workout
    /// clock the user sees (`lifecycle.elapsedSeconds`, stopped while paused),
    /// nil before the session has a start date.
    ///
    /// Elevation uses the recorder's canonical motion-side accumulator
    /// so the threshold check sees the same number the live ticker
    /// and the AI snapshot do. The location-manager's GPS-altitude
    /// gain is an internal fallback signal for devices without a
    /// barometer; mixing the two sources here would have the
    /// threshold fire on numbers the user can't see in the UI.
    /// `currentGrade` is the same trailing ~100 m delta the AI context uses.
    private func thresholdSignals(sport: Sport) -> ThresholdSignals {
        let settings = settingsProvider()
        let hr = workoutHR.currentHR
        return ThresholdSignals(
            hrBPM: hr,
            hrZone: WorkoutGeometry.hrMaxZone(hr: hr, maxHR: settings.effectiveMaxHR),
            powerWatts: motion.powerWatts,
            ftpWatts: Self.sportFTP(for: sport, settings: settingsProvider()),
            paceSecPerKm: signals.currentPaceSecPerKm,
            alpha1: dfa.currentAlpha1,
            cadenceSPM: motion.cadenceStepsPerMin,
            distanceMeters: motion.distanceMeters,
            elapsedSec: lifecycle.sessionStartDate.map { _ in lifecycle.elapsedSeconds },
            elevationGainMeters: motion.elevationGainMeters,
            gradePercent: computeCurrentGradePercent()
        )
    }

    /// Running and cycling FTP are physiologically distinct, so a power
    /// threshold anchors to whichever the sport uses: running FTP is typically
    /// 5-15% higher than cycling FTP for the same person, because of the
    /// muscle-mass and weight-bearing differences.
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
        coaching.thresholds.record(threshold, breached: breached)
    }

    /// Auto-archive a finished GPS-bearing workout's track
    /// as a breadcrumb trail. Origin = first track fix (where the user
    /// started — typically where they parked / left the trailhead /
    /// stepped out the door). Subsequent fixes are decimated to ~25 m
    /// granularity so a long workout doesn't bloat the archive: that's
    /// the same threshold the live recorder uses for committing a
    /// breadcrumb fix during Get Me Back mode, so the storage shape
    /// matches. Filed as a workout track (`isWorkoutTrack`, which the archive
    /// cap evicts first) with its session id, so deleting the workout forever
    /// removes it (`BreadcrumbStore.removeTrails(ofSession:)`).
    func archiveWorkoutTrackAsBreadcrumbTrail(
        track: [CLLocation],
        sport: Sport,
        start: Date,
        sessionId: UUID
    ) {
        guard let first = track.first else { return }
        let origin = BreadcrumbFix(from: first)
        let fixes = WorkoutGeometry.decimatedBreadcrumbFixes(track: track, origin: origin)
        // No useful trail if we only have the origin — likely the
        // workout was stationary or GPS never produced a second fix.
        guard fixes.count >= 2 else { return }
        let trail = BreadcrumbTrail(
            startedAt: start, origin: origin, fixes: fixes,
            label: Self.breadcrumbLabel(sport: sport, start: start), resolvedOriginLabel: nil,
            isWorkoutTrack: true, sessionId: sessionId
        )
        services.breadcrumbStore.archive(trail)
        debugLog("[Recorder] auto-archived workout track as breadcrumb trail (\(fixes.count) fixes, label=\"\(trail.label ?? "")\")")
    }

    /// The trail's saved name, shown to the user ("Back to …"), in the app's
    /// language and date style.
    static func breadcrumbLabel(sport: Sport, start: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.appLocale
        df.dateStyle = .medium
        df.timeStyle = .short
        return String(localized: "\(sport.localizedName) on \(df.string(from: start))", bundle: LanguageManager.appBundle)
    }

    /// Pull the last few per-split paces out of the captured sample series.
    /// Used to detect pace-vs-HR mismatches in the trigger engine. Index 0
    /// = most recent split.
    ///
    /// Computed on the fly from the sample stream: the series is divided into
    /// non-overlapping 1 km chunks using cumulative distance, and the average
    /// pace of the last up-to-3 completed chunks is returned. The chunks are
    /// kept as the buffer grows (`WorkoutLiveTrends.Tally.kilometreChunks`).
    func recentSplitPacesSecPerKm() -> [Double] {
        capture.syncedLiveTrends().kilometreChunks.suffix(3).reversed().compactMap { chunk in
            let dist = chunk.distEnd - chunk.distStart
            let dur = Double(chunk.tEnd - chunk.tStart)
            guard dist > 0, dur > 0 else { return nil }
            return dur / (dist / 1_000)
        }
    }

    /// Estimate current grade from the tail end of the captured track. Uses
    /// the most recent ~100 m of cumulative distance and its elevation delta
    /// (`gradeWindowRise`). Returns nil when the window doesn't cover enough
    /// ground; a rise under the 2 m noise floor reads as flat.
    ///
    /// `track.last` is always non-nil past the count guard.
    /// Optional binding is used for the refactor-spec "zero magic" rule rather
    /// than a force-unwrap.
    ///
    /// A tick reads the grade several times (the coach context, the live
    /// snapshot, the threshold signals, the grade-adjusted pace); it is worked
    /// out once per new fix or barometer sample (`coaching.gradeMemo`) and
    /// read back until the next.
    func computeCurrentGradePercent() -> Double? {
        guard let location = sensors.startedLocation else { return nil }
        let key = WorkoutCoachingInputs.GradeMemo.Key(
            fixCount: location.track.count,
            lastFixAt: location.track.last?.timestamp,
            baroCount: location.barometricSamples.count
        )
        if let memo = coaching.gradeMemo, memo.key == key { return memo.grade }
        let grade = gradeFromTrack(location)
        coaching.gradeMemo = WorkoutCoachingInputs.GradeMemo(key: key, grade: grade)
        return grade
    }

    /// The grade over the trailing window of the track as it stands.
    private func gradeFromTrack(_ location: WorkoutLocationManager) -> Double? {
        let track = location.track
        guard track.count >= 2 else { return nil }
        let window = WorkoutGeometry.trailingGradeWindow(track: track)
        guard window.meters >= 50 else { return nil }   // too short to trust
        guard let endFix = track.last else { return nil }
        let rise = gradeWindowRise(from: track[window.startIdx], to: endFix)
        // Ignore altitude deltas below the known jitter floor so flat
        // segments don't report "+2.3% grade" from GPS noise.
        guard abs(rise) >= 2.0 else { return 0 }
        return (rise / window.meters) * 100.0
    }

    /// Altitude change across the grade window. From the barometer when it
    /// has a sample at or before the window's first fix (about ±0.5 m, the
    /// source the elevation gain uses), measured to its newest sample.
    /// Otherwise from the two GPS fixes, whose altitude swings ±5–10 m each,
    /// so a single noisy fix would read as several percent of grade.
    private func gradeWindowRise(from startFix: CLLocation, to endFix: CLLocation) -> Double {
        let baro = sensors.location.barometricSamples
        guard let startBaro = baro.last(where: { $0.timestamp <= startFix.timestamp }),
              let endBaro = baro.last else { return endFix.altitude - startFix.altitude }
        return endBaro.altitudeMeters - startBaro.altitudeMeters
    }
}
