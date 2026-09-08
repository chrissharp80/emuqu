import CoreLocation
import Foundation

// `WorkoutLiveNamespace`: the live in-workout fact namespace. It shares no
// state with the historical workout resolver and answers different questions.

// MARK: - workout.live.* namespace
//
// Live-workout facts sourced from `LiveWorkoutBroker`. Distinct from
// `workout.*` (archived past-session lookups) because this has to be
// queryable MID-workout — the whole point is that the AI can answer
// "what's my pace right now?" or "should I back off?" using real
// numbers rather than hallucinating. `LiveWorkoutBroker` already
// expires snapshots > 5 s old so a workout that ended without a clean
// `clear()` won't mislead the model into thinking you're still going.
//
// Availability is `.alwaysAvailable` rather than gated on active-state
// so the tool is exposed to the model even when no workout is running —
// otherwise the model can't ask "is a workout in progress?" at all.
// When no snapshot exists, every field resolves to
// `.missing(.notRecorded)` with a human-readable "no workout active"
// detail, which the provider surfaces back to the user verbatim.
struct WorkoutLiveNamespace: FactNamespaceResolver {
    let namespace = "workout.live"
    /// Needed by the per-route history baseline tool
    /// (`workout.live.route_history_baseline`) to look up past
    /// sessions tagged with the same `recognizedRouteName`.
    let archive: SessionArchive

    var snapshot: AssistantContext.LiveWorkoutSnapshot? {
        AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot()
    }

    func missing(_ detail: String = "no workout active") -> FactValue {
        .missing(reason: .notRecorded, detail: detail)
    }

    /// Live training-load read for AI tool surfaces inside this
    /// namespace.
    ///
    /// **Routed through `TrainingLoadRegistry.live()`**, NOT a
    /// separate code path reading
    /// `cache.sampleOn(today)` directly — because the daily-series
    /// EWMA replay can lag `cache.current` by up to ~4 s during cache
    /// refresh (see TrainingMetricsCache:184 detached task), a direct read
    /// returns a different number than the Dashboard during that
    /// window. User report: Dashboard CTL 35.9 / ATL 56.6 /
    /// TSB -20.7 while Grok via `workout.live.today_readiness` returned
    /// CTL 35.2 / ATL 53.1 / TSB -17.9 in the same minute. Routing
    /// through the registry makes `workout.live.today_readiness`,
    /// `training.load.*`, and the Dashboard share one source of truth.
    func liveTrainingLoad() -> (atl: Double, ctl: Double, tsb: Double)? {
        guard let load = MainActor.assumeIsolated({ TrainingLoadRegistry.live() }) else {
            return nil
        }
        return (load.atl, load.ctl, load.tsb)
    }

    /// Full snapshot rendered as a record so a single tool call returns
    /// everything the AI might want. The individual atomic keys below
    /// exist for models that prefer to minimise token usage.
    ///
    /// Serializer: one optional-unwrap per snapshot field.
    /// Same reasoning as `WorkoutAIContext.asFactSheet`; the per-section
    /// helpers below are field tables, not control flow.
    private func snapshotRecord() -> FactValue {
        guard let s = snapshot else { return missing() }
        var rec = Self.coreFields(s)
        rec.merge(Self.motionFields(s)) { current, _ in current }
        rec.merge(Self.trendFields(s)) { current, _ in current }
        rec.merge(Self.historicalFields(s)) { current, _ in current }
        rec.merge(readinessFields(s)) { current, _ in current }
        rec.merge(Self.zoneFields(s)) { current, _ in current }
        rec.merge(Self.racePredictionFields(s)) { current, _ in current }
        return .record(rec)
    }

    /// Always-present identity, timing, and strap/HR state.
    private static func coreFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "sport": .string(s.sport), "elapsed_sec": .integer(s.elapsedSeconds),
            "session_started_at": .date(s.sessionStartAt), "snapshot_at": .date(s.snapshotAt),
            "strap_connected": .boolean(s.strapConnected), "beat_count": .integer(s.beatCount),
            "distance_meters": .double(s.distanceMeters), "step_count": .integer(s.stepCount),
            "elevation_gain_meters": .double(s.elevationGainMeters),
            "user_max_hr": .integer(s.userMaxHR), "peak_hr": .integer(s.peakHR),
            "alpha1_band": .string(s.alpha1Band), "alpha1_status": .string(s.alpha1Status),
            "gps_fix_count": .integer(s.gpsFixCount), "units_preference": .string(s.unitsPreference),
            "recent_split_paces_sec_per_km": .list(s.recentSplitPaces.map { .double($0) })
        ]
        if let hr = s.heartRate { rec["hr"] = .integer(hr) }
        if let cad = s.cadenceStepsPerMin { rec["cadence_spm"] = .double(cad) }
        if let a1 = s.alpha1 { rec["alpha1"] = .double(a1) }
        if let r2 = s.alpha1FitQualityR2 { rec["alpha1_fit_r2"] = .double(r2) }
        if let silent = s.strapSilentSec { rec["strap_silent_sec"] = .double(silent) }
        return rec

    }

    /// Position, pace, power, and terrain.
    private static func motionFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        if let acc = s.gpsAccuracyMeters { rec["gps_accuracy_meters"] = .double(acc) }
        if let pace = s.currentPaceSecPerKm { rec["current_pace_sec_per_km"] = .double(pace) }
        if let speed = s.currentSpeedMS { rec["current_speed_m_per_s"] = .double(speed) }
        if let power = s.powerWatts { rec["power_watts"] = .integer(power) }
        if let mets = s.currentMETs { rec["current_mets"] = .double(mets) }
        if let lat = s.currentLatitude { rec["latitude"] = .double(lat) }
        if let lon = s.currentLongitude { rec["longitude"] = .double(lon) }
        if let alt = s.currentAltitudeMeters { rec["altitude_meters"] = .double(alt) }
        if let hdg = s.currentHeadingDegrees { rec["heading_degrees"] = .double(hdg) }
        if let grade = s.currentGradePercent { rec["grade_percent"] = .double(grade) }
        if let zone = s.targetZone { rec["target_zone"] = .integer(zone) }
        return rec
    }

    /// Live trend deltas (mid-workout self-comparison).
    /// These match the keys the AI sees in voice mode's fact sheet so a user
    /// who flips chat ↔ voice gets the same numbers.
    private static func trendFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        if let d = s.reverseSplitDeltaSecPerKm { rec["reverse_split_delta_sec_per_km"] = .double(d) }
        if let d = s.liveHRDriftPercent { rec["hr_drift_percent"] = .double(d) }
        if let d = s.aerobicDecouplingPercent { rec["aerobic_decoupling_percent"] = .double(d) }
        if let d = s.cadenceDriftSpm { rec["cadence_drift_spm"] = .double(d) }
        if let gap = s.gradeAdjustedPaceSecPerKm { rec["grade_adjusted_pace_sec_per_km"] = .double(gap) }
        if !s.recentSplitGradeAdjustedPaces.isEmpty {
            rec["recent_split_grade_adjusted_paces_sec_per_km"] = .list(s.recentSplitGradeAdjustedPaces.map { .double($0) })
        }
        if let fade = s.projectedMinutesUntilFade { rec["projected_minutes_until_fade"] = .double(fade) }
        return rec
    }

    /// Cross-workout historical baselines (sport-matched).
    private static func historicalFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        guard s.historicalSportSampleCount > 0 else { return [:] }
        var rec: [String: FactValue] = [
            "historical_sport_sample_count": .integer(s.historicalSportSampleCount)
        ]
        if let p = s.historicalSportAvgPaceSecPerKm { rec["historical_sport_avg_pace_sec_per_km"] = .double(p) }
        if let h = s.historicalSportAvgHR { rec["historical_sport_avg_hr"] = .double(h) }
        if let a = s.historicalSportAvgAlpha1 { rec["historical_sport_avg_alpha1"] = .double(a) }
        return rec
    }

    /// Today's readiness for "push or back off" framing.
    ///
    /// `recovery_score` / `training_readiness` stay frozen at workout start —
    /// those values represent the SCORE the user saw before pressing Start,
    /// which is the right anchor for the framing.
    ///
    /// ATL / CTL / TSB use LIVE values from TrainingMetricsCache so they match
    /// the Dashboard (mixing frozen + live numbers in the
    /// same conversation produces wildly swinging TSB readings —
    /// -9 → -17 → -29 across consecutive turns in one user's transcript —
    /// because some AI tool calls hit the frozen snapshot here while others
    /// hit the live `training.load.tsb` resolver).
    private func readinessFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        if let r = s.todayRecoveryScore { rec["today_recovery_score"] = .double(r) }
        if let r = s.todayTrainingReadiness { rec["today_training_readiness"] = .double(r) }
        if let live = liveTrainingLoad() {
            rec["today_atl"] = .double(live.atl)
            rec["today_ctl"] = .double(live.ctl)
            rec["today_tsb"] = .double(live.tsb)
        }
        if let d = s.projectedDaysUntilFresh { rec["projected_days_until_fresh"] = .integer(d) }
        if let t = s.projectedTSBTomorrowSteadyState { rec["projected_tsb_tomorrow_steady_state"] = .double(t) }
        if let h = s.recoveryHoursNeeded { rec["recovery_hours_needed"] = .double(h) }
        return rec
    }

    /// Time-in-zone — only emitted when there's HR data behind it.
    private static func zoneFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        let total = s.zone1Sec + s.zone2Sec + s.zone3Sec + s.zone4Sec + s.zone5Sec
        guard total > 0 else { return [:] }
        var rec: [String: FactValue] = [
            "zone1_sec": .integer(s.zone1Sec),
            "zone2_sec": .integer(s.zone2Sec),
            "zone3_sec": .integer(s.zone3Sec),
            "zone4_sec": .integer(s.zone4Sec),
            "zone5_sec": .integer(s.zone5Sec)
        ]
        if let dom = s.dominantZone { rec["dominant_zone"] = .integer(dom) }
        return rec
    }

    private static func racePredictionFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        if let r = s.predictedRaceTime5KSec { rec["predicted_race_time_5k_sec"] = .double(r) }
        if let r = s.predictedRaceTime10KSec { rec["predicted_race_time_10k_sec"] = .double(r) }
        if let r = s.predictedRaceTimeHalfSec { rec["predicted_race_time_half_marathon_sec"] = .double(r) }
        if let r = s.predictedRaceTimeMarathonSec { rec["predicted_race_time_marathon_sec"] = .double(r) }
        return rec
    }

    var entries: [FactEntry] {
        sensorEntries + derivedEntries
    }

    /// Raw per-tick sensor readings from the live snapshot.
    private var sensorEntries: [FactEntry] {
        [
            workoutLiveStateEntries,
            workoutLivePaceEntries,
            workoutLiveAlpha1Entries,
            workoutLiveOutputEntries
        ]
        .flatMap { $0 }
    }

    private var workoutLiveStateEntries: [FactEntry] {
        [
            workoutLiveActiveEntry,
            workoutLiveSnapshotEntry,
            workoutLiveSportEntry,
            workoutLiveElapsedSecEntry
        ]
    }

    private var workoutLivePaceEntries: [FactEntry] {
        [
            workoutLiveHrEntry,
            workoutLivePaceSecPerKmEntry,
            workoutLiveSpeedMPerSEntry,
            workoutLiveDistanceMetersEntry
        ]
    }

    private var workoutLiveAlpha1Entries: [FactEntry] {
        [
            workoutLiveAlpha1Entry,
            workoutLiveAlpha1BandEntry,
            workoutLiveAlpha1StatusEntry
        ]
    }

    private var workoutLiveOutputEntries: [FactEntry] {
        [
            workoutLiveCadenceSpmEntry,
            workoutLiveElevationGainMetersEntry,
            workoutLivePowerWattsEntry,
            workoutLiveLocationEntry,
            segmentLookbackEntry
        ]
    }

    private var workoutLiveActiveEntry: FactEntry {
        .fixed(
            key: "workout.live.active",
            description: "Whether a workout is currently being recorded. Check this first before calling other workout.live.* facts.",
            valueType: "Bool"
        ) {
            .boolean(self.snapshot != nil)
        }
    }

    private var workoutLiveSnapshotEntry: FactEntry {
        .fixed(
            key: "workout.live.snapshot",
            description: """
            Full live-workout state in one record: sport, elapsed, HR, pace, α1, distance, cadence, elevation gain, GPS position + heading + grade, units preference, strap status, plus today_atl/today_ctl/today_tsb and some forecasts. \
            Use this when answering any 'what's happening right now' question about the active workout. IMPORTANT for training load: `today_atl` / `today_ctl` / `today_tsb` are the CURRENT values the user sees on their Dashboard — those \
            are the answer to 'what's my TSB/ATL/CTL'. `projected_tsb_tomorrow_steady_state` is a FORECAST for tomorrow after rest — NEVER quote it as the current TSB (doing so makes the number look like it swung).
            """,
            valueType: "Record"
        ) {
            self.snapshotRecord()
        }
    }

    private var workoutLiveSportEntry: FactEntry {
        .fixed(
            key: "workout.live.sport",
            description: "Sport of the currently active workout (run, walk, bike, etc.).",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.sport) } ?? self.missing()
        }
    }

    private var workoutLiveElapsedSecEntry: FactEntry {
        .fixed(
            key: "workout.live.elapsed_sec",
            description: "Seconds elapsed since the active workout started.",
            valueType: "Int"
        ) {
            self.snapshot.map { .integer($0.elapsedSeconds) } ?? self.missing()
        }
    }

    private var workoutLiveHrEntry: FactEntry {
        .fixed(
            key: "workout.live.hr",
            description: "Current heart rate in bpm. Comes from the chest strap when connected, Apple Watch otherwise. Nil when no HR source is active.",
            valueType: "Int"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.heartRate.map { .integer($0) } ?? self.missing("no HR sample yet")
        }
    }

    private var workoutLivePaceSecPerKmEntry: FactEntry {
        .fixed(
            key: "workout.live.pace_sec_per_km",
            description: "Current pace in seconds per kilometre. Sourced from foot pod when connected, else GPS-distance / time. Nil if too slow / too little movement to compute.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.currentPaceSecPerKm.map { .double($0) } ?? self.missing("pace not yet resolvable")
        }
    }

    private var workoutLiveSpeedMPerSEntry: FactEntry {
        .fixed(
            key: "workout.live.speed_m_per_s",
            description: "Current speed in metres per second.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.currentSpeedMS.map { .double($0) } ?? self.missing("speed not yet resolvable")
        }
    }

    private var workoutLiveDistanceMetersEntry: FactEntry {
        .fixed(
            key: "workout.live.distance_meters",
            description: "Total distance covered in the active workout, in metres.",
            valueType: "Double"
        ) {
            self.snapshot.map { .double($0.distanceMeters) } ?? self.missing()
        }
    }

    private var workoutLiveAlpha1Entry: FactEntry {
        .fixed(
            key: "workout.live.alpha1",
            description: "Current DFA α1 (short-range detrended-fluctuation exponent), rolling 2-minute window with artifact filtering. ≥ 0.75 = below the aerobic threshold (the replicated finding); 0.50–0.75 = moderate-to-hard; < 0.50 = very hard. Do not call values under 0.50 \"above the anaerobic threshold\": that second-threshold association is weaker and less consistently reproduced.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.alpha1.map { .double($0) } ?? self.missing("α1 still warming up — " + s.alpha1Status)
        }
    }

    private var workoutLiveAlpha1BandEntry: FactEntry {
        .fixed(
            key: "workout.live.alpha1_band",
            description: "Human label for the current α1 band — 'belowAeT', 'nearAeT', 'aboveAT2'.",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.alpha1Band) } ?? self.missing()
        }
    }

    private var workoutLiveAlpha1StatusEntry: FactEntry {
        .fixed(
            key: "workout.live.alpha1_status",
            description: "Why α1 is / isn't visible. Values: 'ok', 'warming up (X%)', 'strap silent Ns', 'fit failed'. Surface this verbatim when the user asks why their α1 reading isn't updating — don't paraphrase.",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.alpha1Status) } ?? self.missing()
        }
    }

    private var workoutLiveCadenceSpmEntry: FactEntry {
        .fixed(
            key: "workout.live.cadence_spm",
            description: "Current cadence in steps per minute.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.cadenceStepsPerMin.map { .double($0) } ?? self.missing("cadence not yet resolvable")
        }
    }

    private var workoutLiveElevationGainMetersEntry: FactEntry {
        .fixed(
            key: "workout.live.elevation_gain_meters",
            description: "Cumulative elevation gain in metres since the workout started (barometer-smoothed).",
            valueType: "Double"
        ) {
            self.snapshot.map { .double($0.elevationGainMeters) } ?? self.missing()
        }
    }

    private var workoutLivePowerWattsEntry: FactEntry {
        .fixed(
            key: "workout.live.power_watts",
            description: "Current running power in watts. Only available when a Stryd-class foot pod is connected.",
            valueType: "Int"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.powerWatts.map { .integer($0) } ?? self.missing("no foot pod / no power")
        }
    }

    private var workoutLiveLocationEntry: FactEntry {
        .fixed(
            key: "workout.live.location",
            description: "Current GPS position + heading + grade. Returns lat / lon / altitude_meters / heading_degrees / grade_percent when a fix is available.",
            valueType: "Record"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            guard let lat = s.currentLatitude, let lon = s.currentLongitude else {
                return self.missing("no GPS fix")
            }
            var rec: [String: FactValue] = [
                "latitude": .double(lat),
                "longitude": .double(lon)
            ]
            if let alt = s.currentAltitudeMeters { rec["altitude_meters"] = .double(alt) }
            if let hdg = s.currentHeadingDegrees { rec["heading_degrees"] = .double(hdg) }
            if let grade = s.currentGradePercent { rec["grade_percent"] = .double(grade) }
            if let acc = s.gpsAccuracyMeters { rec["accuracy_meters"] = .double(acc) }
            return .record(rec)
        }
    }

    // workout itself is excluded by `sessionStartAt`.
    private var segmentLookbackEntry: FactEntry {
        .fixed(
            key: "workout.live.segment_lookback_at_current_position",
            description: Self.segmentLookbackDescription,
            valueType: "List"
        ) { self.resolveWorkoutLiveSegmentLookbackAtCurrentPosition() }
    }

    private func resolveWorkoutLiveSegmentLookbackAtCurrentPosition() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        guard let lat = s.currentLatitude, let lon = s.currentLongitude else {
            return self.missing("no GPS fix yet")
        }
        let target = CLLocation(latitude: lat, longitude: lon)
        let radius: Double = 50
        let matches = lookbackMatches(near: target, radius: radius, excluding: s.sessionStartAt)
        guard !matches.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no past workouts passed within \(Int(radius))m of the current position")
        }
        return .list(matches)
    }

    private func lookbackMatches(near target: CLLocation, radius: Double, excluding activeStart: Date) -> [FactValue] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        // Exclude the in-flight session by start-date match.
        let candidates = self.archive.entries
            .filter { $0.sessionType == .workout && abs($0.date.timeIntervalSince(activeStart)) > 1.0 }
            .sorted { $0.date > $1.date }
            .prefix(30)
            .compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
        return candidates.compactMap {
            lookbackMatch(in: $0, near: target, radius: radius, formatter: isoFormatter)
        }
    }

    private func lookbackMatch(
        in session: HRVSession,
        near target: CLLocation,
        radius: Double,
        formatter isoFormatter: ISO8601DateFormatter
    ) -> FactValue? {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return nil }
        let track = GPXExporter.decode(
            polyline: polyline,
            startDate: session.startDate,
            duration: session.duration
        )
        guard !track.isEmpty else { return nil }
        let (closestIdx, closestDist) = WorkoutGeometry.nearestFix(in: track, to: target)
        guard closestDist <= radius else { return nil }
        let offsetSec = Int(track[closestIdx].timestamp.timeIntervalSince(session.startDate))
        var rec: [String: FactValue] = [
            "date": .string(isoFormatter.string(from: session.startDate)),
            "sport": .string(session.workoutMetadata?.sport.rawValue ?? "unknown"),
            "offset_sec_at_point": .integer(offsetSec),
            "distance_to_point_m": .double(closestDist)
        ]
        if let p = WorkoutGeometry.localPace(in: track, at: closestIdx) { rec["pace_sec_per_km_at_point"] = .double(p) }
        addSampleFields(&rec, session: session, offsetSec: offsetSec)
        return .record(rec)
    }

    private func addSampleFields(
        _ rec: inout [String: FactValue],
        session: HRVSession,
        offsetSec: Int
    ) {
        guard let samples = session.workoutMetadata?.samples, !samples.isEmpty else { return }
        let (best, bestDelta) = nearestSample(samples, to: offsetSec)
        guard let smp = best, bestDelta <= 10 else { return }
        if let hr = smp.heartRate { rec["hr_bpm_at_point"] = .integer(hr) }
        if let watts = smp.powerWatts { rec["power_watts_at_point"] = .integer(watts) }
        if let cadence = smp.cadenceStepsPerMin { rec["cadence_spm_at_point"] = .double(cadence) }
        if let alt = smp.altitudeMeters { rec["altitude_m_at_point"] = .double(alt) }
        if let a1 = smp.alpha1 { rec["alpha1_at_point"] = .double(a1) }
    }

    private func nearestSample(_ samples: [WorkoutSample], to offsetSec: Int) -> (WorkoutSample?, Int) {
        var best: WorkoutSample?
        var bestDelta = Int.max
        for sample in samples {
            let delta = abs(sample.offsetSec - offsetSec)
            if delta < bestDelta {
                bestDelta = delta
                best = sample
            }
            if bestDelta == 0 { break }
            if delta > 10, best != nil { break }
        }
        return (best, bestDelta)
    }

    private static let segmentLookbackDescription = """
    [ACTION-FREE] At the user's CURRENT live-workout GPS position, looks back across the 30 most recent finished workouts and returns past pace + HR + power + cadence + altitude at that exact spot. Single call. Use when the \
    user asks 'how am I doing here vs last time' / 'what was my heart rate at this corner last Tuesday' / 'am I faster than I was on this hill before'. Returns a list of records: { date, sport, offset_sec_at_point, distance_to_point_m, \
    pace_sec_per_km_at_point?, hr_bpm_at_point?, power_watts_at_point?, cadence_spm_at_point?, altitude_m_at_point?, alpha1_at_point? }. Default radius 50 m; not user-tunable here (the live snapshot already knows where the user \
    is). Returns notRecorded when no GPS fix yet, no live workout active, or no past workout passed near the current position.
    """
}
