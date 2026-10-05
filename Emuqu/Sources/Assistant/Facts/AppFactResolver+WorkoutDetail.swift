import CoreLocation
import CoreMotion
import Foundation
import os

// The bulk of `WorkoutNamespace`'s fact catalog, split out of
// `AppFactResolver+Workout.swift` when that struct's body passed the
// 500-line limit. The namespace's own plumbing — the archive lookups and the
// by-date / history entries — stays behind; the per-metric detail facts, the
// live-workout facts and the timeline downsampler live here.
//
// Only the file boundary changed. The plumbing those entries call widened from
// `private` to internal because Swift's `private` does not reach across files.

extension WorkoutNamespace {
    /// Per-metric detail facts and the `workout.live.*` namespace.
    var detailEntries: [FactEntry] {
        [
            workoutLiveEntries,
            hrvPeakEntries,
            hrvWindowEntries,
            userProfileEntries,
            workoutFeelingEntries,
            workoutStreakEntries
        ]
        .flatMap { $0 }
    }

    private var workoutLiveEntries: [FactEntry] {
        [
            workoutLiveRouteTopologyEntry,
            workoutLiveWeatherEntry,
            workoutLiveRecognizedRouteEntry
        ]
    }

    private var hrvPeakEntries: [FactEntry] {
        [
            hrvPeakTotalPowerMs2Entry,
            hrvPeakRmssdMsEntry
        ]
    }

    private var hrvWindowEntries: [FactEntry] {
        [
            hrvWindowClassificationEntry,
            hrvWindowIsOrganizedRecoveryEntry,
            hrvWindowIsConsolidatedEntry
        ]
    }

    private var userProfileEntries: [FactEntry] {
        [
            userProfileRunningFtpEntry,
            userProfileCyclingFtpEntry
        ]
    }

    private var workoutFeelingEntries: [FactEntry] {
        [
            workoutFeelingByDateDateEntry,
            workoutFeelingNoteByDateDateEntry,
            workoutSegmentCompareParamsEntry,
            workoutMostRecentSnapshotEntry,
            workoutDeepDiveByDateDateEntry
        ]
    }

    private var workoutStreakEntries: [FactEntry] {
        [
            workoutStreakConsecutiveDaysEntry,
            workoutStreakThisWeekCountEntry
        ]
    }

    private var workoutLiveRouteTopologyEntry: FactEntry {
        .fixed(
            key: "workout.live.route_topology",
            description: Self.workoutLiveRouteTopologyDescription,
            valueType: "Record",
            resolve: { self.resolveWorkoutLiveRouteTopology() }
        )
    }

    private func resolveWorkoutLiveRouteTopology() -> FactValue {
        guard let snap = AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() else {
            return .missing(reason: .notRecorded, detail: "no live workout")
        }
        guard let topo = snap.routeTopology else {
            return .missing(reason: .notYetComputed, detail: "no route bound")
        }
        return .record(routeTopologyRecord(topo))
    }

    private func routeTopologyRecord(_ topo: AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot) -> [String: FactValue] {
        var record: [String: FactValue] = [
            "climbs_ahead": .list(topo.climbsAhead.map { climbRecord($0) }),
            "turns_ahead": .list(topo.turnsAhead.map { turnRecord($0) }),
            "total_ascent_remaining_meters": .double(topo.totalAscentRemainingMeters),
            "peak_altitude_meters": .double(topo.peakAltitudeMeters),
            "current_altitude_above_route_min_meters": .double(topo.altitudeAboveRouteMinMeters),
            "meters_to_peak": .double(topo.metersToPeak)
        ]
        if let steepest = topo.steepestGradeAheadPercent {
            record["steepest_grade_ahead_percent"] = .double(steepest)
        }
        return record
    }

    private func climbRecord(_ climb: AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot.ClimbSnapshot) -> FactValue {
        var rec: [String: FactValue] = [
            "distance_to_start_meters": .double(climb.distanceToStartMeters),
            "grade_percent": .double(climb.gradePercent)
        ]
        if climb.lengthMeters > 0 { rec["length_meters"] = .double(climb.lengthMeters) }
        if climb.gainMeters > 0 { rec["gain_meters"] = .double(climb.gainMeters) }
        // Reverse-geocoded street name where this climb
        // starts, populated by the SavedRouteStore enrich
        // pass. When present, the assistant should use it
        // verbatim ("the climb on Elm Street") instead of
        // saying "the climb at distance 412 m."
        if let road = climb.roadName, !road.isEmpty {
            rec["road_name"] = .string(road)
        }
        return .record(rec)
    }

    // Turns ahead — direction-change points on the route
    // polyline. Each entry has distance, signed bearing
    // change (positive=right, negative=left), and a
    // human-readable label.
    private func turnRecord(_ turn: AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot.TurnSnapshot) -> FactValue {
        .record([
            "distance_meters": .double(turn.distanceMeters),
            "bearing_change_degrees": .double(turn.bearingChangeDegrees),
            "direction": .string(turn.direction)
        ])
    }

    private static let workoutLiveRouteTopologyDescription = """
    Full topography of the route bound to the live workout: climbs queue ahead (each with distance to start, length, gain, grade), TURNS queue ahead (each with distance, signed bearing change, and a human-readable label like \
    'right' / 'soft left' / 'hard right' / 'U-turn'), total ascent remaining, peak altitude, current altitude above route minimum, steepest grade ahead, distance to peak. Lets the assistant answer 'how many climbs left?', 'how \
    much uphill?', 'am I about to turn?', 'sharp turn coming up?' precisely. Returns missing when no route is bound or the recogniser hasn't fired yet.
    """

    private var workoutLiveWeatherEntry: FactEntry {
        .fixed(
            key: "workout.live.weather",
            description: """
            Current weather at the user's GPS coordinate, refreshed every ~30 minutes during the workout. Returns temperature (C), wind speed (kph) + direction (degrees true), humidity (%), and a plain-English \
            conditions string ('Clear', 'Light rain', 'Thunderstorm', 'Snow', etc.). Use this to advise on hydration, layering, pacing in heat or wind. Returns missing for indoor workouts or before first GPS lock.
            """,
            valueType: "Record",
            resolve: { self.resolveWorkoutLiveWeather() }
        )
    }

    private func resolveWorkoutLiveWeather() -> FactValue {
        guard let snap = AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() else {
            return .missing(reason: .notRecorded, detail: "no live workout")
        }
        guard let w = snap.weather else {
            return .missing(reason: .notYetComputed, detail: "weather fetch hasn't returned yet (or is offline)")
        }
        var record: [String: FactValue] = [
            "temperature_c": .double(w.temperatureC),
            "wind_speed_kmh": .double(w.windKMH),
            "wind_direction_degrees": .double(w.windDirectionDegrees),
            "humidity_percent": .double(w.humidityPercent),
            "conditions": .string(w.conditions),
            "observed_at": .date(w.observedAt)
        ]
        if let apparent = w.apparentTemperatureC { record["apparent_temperature_c"] = .double(apparent) }
        return .record(record)
    }

    private var workoutLiveRecognizedRouteEntry: FactEntry {
        .fixed(
            key: "workout.live.recognized_route",
            description: Self.workoutLiveRecognizedRouteDescription,
            valueType: "Record",
            resolve: { self.resolveWorkoutLiveRecognizedRoute() }
        )
    }

    private func resolveWorkoutLiveRecognizedRoute() -> FactValue {
        guard let snap = AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() else {
            return .missing(reason: .notRecorded, detail: "no live workout")
        }
        // Matched path — return the same fields as before.
        if let routeName = snap.recognizedRouteName {
            return .record(matchedRouteRecord(snap, routeName: routeName))
        }
        return unmatchedRouteRecord(snap)
    }

    private func matchedRouteRecord(_ snap: AssistantContext.LiveWorkoutSnapshot, routeName: String) -> [String: FactValue] {
        var record: [String: FactValue] = [
            "status": .string("matched"),
            "name": .string(routeName),
            "auto_detected": .boolean(snap.recognizedRouteWasAutoDetected)
        ]
        if let direction = snap.recognizedRouteDirection {
            record["direction"] = .string(direction)
        }
        if let dist = snap.routeTotalDistanceMeters { record["total_distance_meters"] = .double(dist) }
        if let climbs = snap.routeClimbCount { record["climbs_ahead_total"] = .integer(climbs) }
        return record
    }

    // Diagnostic record. Counts the user's saved-route library
    // + the live distance covered so the AI can communicate WHY
    // no match exists yet. (Per-sport filtering lives in
    // `RouteLibrary.findMatch` itself; this fact reports the
    // gross library size so the AI can distinguish 'empty
    // library' from 'library has routes but none fit'.)
    // `detectionTriggerMeters` and the saved-route store are on
    // @MainActor types; the reads are wrapped in
    // `MainActor.assumeIsolated` to satisfy Swift 6 strict
    // concurrency.
    private func unmatchedRouteRecord(_ snap: AssistantContext.LiveWorkoutSnapshot) -> FactValue {
        let coveredMeters = snap.distanceMeters
        let triggerMeters: Double = MainActor.assumeIsolated {
            RouteLibrary.detectionTriggerMeters
        }
        let savedCount: Int = MainActor.assumeIsolated {
            AppDependencies.current.location.savedRouteStore.routes.count
        }
        let (status, detail) = recognizerStatus(
            coveredMeters: coveredMeters,
            triggerMeters: triggerMeters,
            savedCount: savedCount
        )
        return .record([
            "status": .string(status),
            "saved_route_count": .integer(savedCount),
            "covered_meters": .double(coveredMeters),
            "trigger_meters": .double(triggerMeters),
            "detail": .string(detail)
        ])
    }

    private func recognizerStatus(
        coveredMeters: Double,
        triggerMeters: Double,
        savedCount: Int
    ) -> (String, String) {
        let status: String
        let detail: String
        if savedCount == 0 {
            status = "no_saved_routes"
            detail = "user has no saved routes in their library — recognizer has nothing to match against. Suggest they save the current workout from the post-summary screen if it's a route they walk regularly."
        } else if coveredMeters < triggerMeters {
            status = "awaiting_distance"
            let remaining = triggerMeters - coveredMeters
            detail = "recognizer needs ≥\(Int(triggerMeters)) m of GPS movement before it attempts a match — covered \(Int(coveredMeters)) m so far, \(Int(remaining)) m to go. Recognition will fire automatically once the threshold is crossed."
        } else {
            status = "no_match"
            detail = "covered \(Int(coveredMeters)) m, \(savedCount) saved route(s) in library, none fit current path within tolerance (mean point-to-track distance > 30 m). Current path may be a new route, or only partially overlaps a saved one."
        }
        return (status, detail)
    }

    private static let workoutLiveRecognizedRouteDescription = """
    Live route-recognition status. When the GPS track has matched a route in the user's saved library, returns: status='matched', name (e.g. 'Daily 1'), auto_detected (bool), direction ('forward'/'reverse')?, total_distance_meters?, \
    climbs_ahead_total?. When NOT matched yet, still returns a diagnostic record so the model can communicate WHY: status='no_saved_routes' (the library has no routes at all), 'awaiting_distance' (the recognizer needs \
    trigger_meters of movement before it tries; covered_meters shows progress), or 'no_match' (enough distance covered, attempted, no saved route fits). The diagnostic record also carries saved_route_count (all saved routes, \
    every sport) and a plain-language detail, so the model can say 'you have 3 saved routes but none match your current path' vs 'you haven't saved any routes yet' instead of a bare 'no route'.
    """

    // Peak nightly total power.
    // Total spectral power (VLF + LF + HF) at the night's peak
    // capacity window — the highest sustained autonomic-power
    // burst observed during the recording. Read as a trend against
    // the user's own baseline (Plews 2013). The description tells the
    // model not to present it as an illness forecast: no rule in this
    // app has been evaluated against illness outcomes.
    private var hrvPeakTotalPowerMs2Entry: FactEntry {
        .fixed(
            key: "hrv.peak.total_power_ms2",
            description: """
            Peak total HRV power (VLF + LF + HF, ms²) observed in last night's most-organized window. A sharp drop vs the user's recent typical peak power is context for accumulated load, short sleep, alcohol or stress; \
            it is not a forecast, so never present it as predicting illness. Use this when the user asks 'why do I feel off' or how last night compared. Returns nil for sessions where peak-capacity analysis didn't complete (short recordings).
            """,
            valueType: "Double",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: {
                guard let session = OvernightArchive.latest(self.archive) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session")
                }
                return .from(session.analysisResult?.peakCapacity?.peakTotalPower, detail: "peak-capacity analysis not present on this session")
            }
        )
    }

    private var hrvPeakRmssdMsEntry: FactEntry {
        .fixed(
            key: "hrv.peak.rmssd_ms",
            description: "Peak RMSSD (ms) at the night's most-organized window. Use alongside hrv.peak.total_power_ms2 when assessing whether the user's autonomic ceiling is dropping.",
            valueType: "Double",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: {
                guard let session = OvernightArchive.latest(self.archive) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session")
                }
                return .from(session.analysisResult?.peakCapacity?.peakRMSSD, detail: "peak-capacity analysis not present")
            }
        )
    }

    private var hrvWindowClassificationEntry: FactEntry {
        .fixed(
            key: "hrv.window.classification",
            description: """
            Classification of last night's analysis window — a label for HOW the window was selected, not a verdict on the reading. Possible values: 'Organized Recovery' (sustained plateau + stable HR), 'Flexible / Unconsolidated' (DFA α1 just below \
            that band), 'High Variability' (high RMSSD without that stability), 'Peak Capacity' (the best window came from the peak-capacity search rather than a consolidated stretch), 'Insufficient Data' (too little clean data to classify). \
            Describe which window was used; do not tell the user one kind of reading is more real than another.
            """,
            valueType: "String",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: {
                guard let session = OvernightArchive.latest(self.archive) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session")
                }
                return .from(session.analysisResult?.windowClassification, detail: "no classification on this analysis")
            }
        )
    }

    private var hrvWindowIsOrganizedRecoveryEntry: FactEntry {
        .fixed(
            key: "hrv.window.is_organized_recovery",
            description: """
            True if last night's analysis window met the organized-recovery test: DFA α1 in the ~0.75–1.0 band plus a low LF/HF ratio or stable heart rate (heart-rate stability alone when α1 couldn't be computed). It describes how \
            the window behaved, not whether the reading counts: when FALSE, HRV may still be high, just without that steady pattern. Do not tell the user one kind of reading is more real than another.
            """,
            valueType: "Bool",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: {
                guard let session = OvernightArchive.latest(self.archive) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session")
                }
                return .from(session.analysisResult?.isOrganizedRecovery, detail: "no organization flag on this analysis")
            }
        )
    }

    private var hrvWindowIsConsolidatedEntry: FactEntry {
        .fixed(
            key: "hrv.window.is_consolidated",
            description: "True when last night's window represents sustained consolidated recovery (plateau AND stable HR). Stricter than is_organized_recovery — distinguishes true high-readiness windows from one-off RMSSD spikes.",
            valueType: "Bool",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: {
                guard let session = OvernightArchive.latest(self.archive) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session")
                }
                return .from(session.analysisResult?.isConsolidated, detail: "no consolidation flag on this analysis")
            }
        )
    }

    private var userProfileRunningFtpEntry: FactEntry {
        .fixed(
            key: "user.profile.running_ftp",
            description: """
                User's running FTP in watts (Stryd / running power FTP). Anchors power-based training load, intensity factor, \
                and power zones for run / walk / hike / treadmill sports. Nil when the user hasn't set it AND the archive \
                doesn't have a long-enough Stryd workout to auto-estimate from.
                """,
            valueType: "Int"
        ) {
            // `effectiveRunningFTP` is MainActor
            // (touches FTPAutoEstimator's UserDefaults cache).
            let ftp = MainActor.assumeIsolated { AppDependencies.current.app.settingsManager.settings.effectiveRunningFTP }
            return .from(ftp, detail: "running FTP not set; no archived ≥20 min Stryd workout to auto-estimate from")
        }
    }

    private var userProfileCyclingFtpEntry: FactEntry {
        .fixed(
            key: "user.profile.cycling_ftp",
            description: "User's cycling FTP in watts (CPS / FTMS bike power meter FTP). Anchors power-based training load, intensity factor, and power zones for bike / indoor bike sports. Nil when the user hasn't set it.",
            valueType: "Int"
        ) {
            .from(AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveCyclingFTP, detail: "cycling FTP not set in Biometrics settings")
        }
    }

    private var workoutFeelingByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.feeling.by_date($date)",
            paramExample: "2026-04-21",
            description: "Subjective workout feeling rating (1-5: terrible to great) for a workout on a given date.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.workoutFeeling, detail: "user has not rated this workout")
            }
        )
    }

    private var workoutFeelingNoteByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.feeling_note.by_date($date)",
            paramExample: "2026-04-21",
            description: "Free-text note attached to the subjective workout-feeling rating for a workout on a given date.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.workoutFeelingNote, detail: "user has not attached a note")
            }
        )
    }

    // Segment-by-coordinate comparison. Walks past workouts' GPS
    // polylines, finds the closest fix to the requested lat/lon,
    // and returns one record per matching session. Coordinate
    // match drives the comparison (NOT total distance) — a 1-loop day and a 2-loop day on
    // the same route are comparable on the shared segment.
    //
    // Param format: "lat,lon" or "lat,lon,radius_m". Default
    // radius 50 m. Capped at 30 most-recent GPS-bearing
    // workouts to keep the tool fast.
    private var workoutSegmentCompareParamsEntry: FactEntry {
        .parameterized(
            pattern: "workout.segment_compare($params)",
            paramExample: "39.781,-89.652",
            description: Self.workoutSegmentCompareParamsDescription,
            resolve: { rawParams, _ in self.resolveWorkoutSegmentCompareParams(rawParams) }
        )
    }

    private func resolveWorkoutSegmentCompareParams(_ rawParams: String) -> FactValue {
        let parts = rawParams.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              let lat = Double(parts[0]),
              let lon = Double(parts[1])
        else {
            return .missing(reason: .invalidParameter, detail: "expected 'lat,lon' or 'lat,lon,radius_m'")
        }
        let radius: Double = parts.count == 3 ? (Double(parts[2]) ?? 50) : 50
        let target = CLLocation(latitude: lat, longitude: lon)
        let matches = segmentMatches(near: target, radius: radius)
        guard !matches.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no past workouts passed within \(Int(radius))m of (\(lat), \(lon))")
        }
        return .list(matches)
    }

    private func segmentMatches(near target: CLLocation, radius: Double) -> [FactValue] {
        let archive = self.archive
        let candidates = archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
            .prefix(30)
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        return candidates.compactMap { SegmentPointSampler.match(in: $0, near: target, radius: radius) }
    }

    private static let workoutSegmentCompareParamsDescription = """
    Segment-by-coordinate comparison: given a GPS coordinate (lat,lon) and optional radius (default 50 m), returns past workouts that passed near that point with the user's pace, HR, power, cadence and altitude at THAT exact \
    point. Single-call answer to 'how am I doing at this point vs last time'. Param format: 'lat,lon' or 'lat,lon,radius_m'. Returns a list of records: { date, sport, offset_sec_at_point, distance_to_point_m, pace_sec_per_km_at_point?, \
    hr_bpm_at_point?, power_watts_at_point?, cadence_spm_at_point?, altitude_m_at_point?, alpha1_at_point? }. The HR / power / cadence / altitude / alpha1 fields are sampled from the per-second WorkoutMetadata.samples nearest \
    to the matching offset (within ±10 sec). Coordinate match drives the comparison NOT total distance — a 1-loop day and a 2-loop day match on the shared segment. Returns notRecorded when no past workout passes within radius.
    """

    // The most recent workout's analysis snapshot, bundled into
    // one record so a single tool call gets the AI everything for
    // narrative coaching.
    private var workoutMostRecentSnapshotEntry: FactEntry {
        .fixed(
            key: "workout.most_recent.snapshot",
            description: """
            All-in-one snapshot of the user's most recent workout: TRIMP, hrTSS, decoupling, efficiency factor, intensity factor, variability index, time-in-α1-regime per zone (easy/threshold/hard, in seconds), first AT1 crossing offset \
            + HR (validated aerobic-threshold proxy), grade-adjusted pace, VAM, estimated calories, calorie rate, dominant α1 band, dominant HR zone, recognized route name, partial-data reason if recovered, and the relative-effort label. \
            Use for 'how was my workout' / 'how hard did I push' / 'what was the effort quality'. Single call replaces ~12 individual lookups. Returns notRecorded when no workouts exist.
            """,
            valueType: "Record",
            availability: { self.workoutAvailability() },
            resolve: {
                guard let entry = self.workoutEntries().first,
                      let session = self.archive.retrieveLightweightOrLog(entry.sessionId)
                else {
                    return .missing(reason: .notRecorded, detail: "no workouts recorded")
                }
                return Self.deepDiveRecord(for: session)
            }
        )
    }

    // Same rich snapshot, parameterised by date. Without it,
    // "what was my workout last Tuesday?" resolves poorly under
    // `workout.by_date` (a sparser record) — the AI has to call
    // ~12 separate tools to reconstruct the deep-dive picture
    // for a non-most-recent date.
    private var workoutDeepDiveByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.deep_dive.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            All-in-one composite snapshot for a workout on a specific date (yyyy-MM-dd, local) — same shape as `workout.most_recent.snapshot`. TRIMP, hrTSS, decoupling, efficiency factor, intensity factor, variability index, time-in-α1-regime \
            per zone (easy/threshold/hard, in seconds), first AT1 crossing, dominant α1 band, dominant HR zone, calories, calorie rate, VAM, grade-adjusted pace, relative-effort label, recognized route name, elevation loss. Single call \
            replaces ~12 individual `*.by_date($date)` lookups. Returns notRecorded when no workout is recorded for that date.
            """,
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout recorded for \(param)")
                }
                return Self.deepDiveRecord(for: session)
            }
        )
    }

    private var workoutStreakConsecutiveDaysEntry: FactEntry {
        .fixed(
            key: "workout.streak.consecutive_days",
            description: "Number of consecutive days ending today with at least one recorded workout. 0 = no workout today (streak broken). Use to answer 'how long have I kept my streak going?' or to celebrate consistency milestones.",
            valueType: "Int",
            availability: { self.workoutAvailability() },
            resolve: { .integer(self.consecutiveWorkoutDays()) }
        )
    }

    private func consecutiveWorkoutDays() -> Int {
        let cal = Calendar.current
        let workoutDays: Set<Date> = Set(self.workoutEntries().map { cal.startOfDay(for: $0.date) })
        var streak = 0
        var probe = cal.startOfDay(for: Date())
        while workoutDays.contains(probe) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: probe) else { break }
            probe = prev
        }
        return streak
    }

    private var workoutStreakThisWeekCountEntry: FactEntry {
        .fixed(
            key: "workout.streak.this_week_count",
            description: "Number of workouts recorded so far this calendar week (the week starts on the first weekday of the device's region, e.g. Sunday in the US, Monday in most of Europe). Use for 'how many workouts have I done this week?'",
            valueType: "Int",
            availability: { self.workoutAvailability() },
            resolve: {
                let cal = Calendar.current
                let now = Date()
                guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else {
                    return .missing(reason: .internalError, detail: "couldn't resolve week boundary")
                }
                let count = self.workoutEntries().filter { $0.date >= weekStart && $0.date <= now }.count
                return .integer(count)
            }
        )
    }

    /// The downsampled per-second sample stream.
    var timelineEntries: [FactEntry] {
        return [
            workoutTimelineByDateDateEntry
        ]
    }

    // ── Workout timeline (downsampled per-second stream) ──────────
    //
    // The general-purpose tool for ANY question that requires
    // reasoning over the per-second sample stream — HR / pace /
    // cadence / altitude / grade / α1 / power per bucket.
    // With only aggregates (avg HR, TRIMP, duration) in the
    // catalog, questions like "did my HR spike when I was
    // flat or going downhill" or "where did my pace drop on the
    // climb" have nowhere to land — the LLM either guesses or
    // refuses.
    //
    // This tool returns a downsampled timeline (~200 buckets max,
    // bucket size scales to workout length) so the LLM can walk
    // the array, correlate fields, and answer arbitrary
    // analytical questions WITHOUT pre-computed special cases.
    //
    // Why a fixed 200-bucket cap: a 1-hour run with 30s buckets
    // is 120 records ≈ 12 KB of JSON — well within any provider's
    // tool-result budget and small enough that the LLM can
    // reason over the whole thing. A 6-hour ultra would be too
    // big at 30s buckets, so we scale: the bucket_sec field in
    // the response tells the LLM the actual time per bucket.
    private var workoutTimelineByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.timeline.by_date($date)",
            paramExample: "2026-04-21",
            description: Self.workoutTimelineByDateDateDescription,
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                guard let samples = session.workoutMetadata?.samples, !samples.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no per-second sample stream on this workout (older session, or sport that didn't capture samples)")
                }
                return WorkoutNamespace.timelineRecord(for: session, samples: samples)
            }
        )
    }

    private static let workoutTimelineByDateDateDescription = """
    [ANALYSIS-PRIMITIVE] Downsampled per-second timeline for a workout on the given date. Returns up to 200 time buckets, each carrying median HR, pace, cadence, altitude, computed grade percent, α1, and power for that bucket. \
    Use this for ANY analytical question that needs the time-series shape (not just aggregates): 'did my HR spike when I was flat or going downhill', 'where did pace drop on the climb', 'was α1 still healthy in the second half', \
    'where did cadence fall off as I tired', 'were there moments where power dropped but HR didn't'. The bucket_sec field in the response tells you the time span per bucket (varies by workout length so the cap stays at ~200 \
    records). Walk the array yourself — you have the resolution to find spikes, correlations, and segments without us pre-computing them. Returns notRecorded when the workout has no per-second stream (older sessions before late-April \
    2026 only have aggregates).
    """

    // MARK: - Timeline downsampler

    /// Bucket-aggregate a workout's sample stream so the LLM can reason
    /// over the time-series without us picking which questions matter.
    /// Caps the response at ~200 buckets — bucket size scales with
    /// workout duration so a 30-min run gets 9s resolution and a 4-hour
    /// ride gets 72s resolution. Records the actual `bucket_sec` in
    /// the envelope so the LLM knows the granularity.
    private static func timelineRecord(for session: HRVSession, samples: [WorkoutSample]) -> FactValue {
        let maxBuckets = 200
        let sortedSamples = samples.sorted { $0.offsetSec < $1.offsetSec }
        let durationSec = max(sortedSamples.last?.offsetSec ?? 1, 1)
        let bucketSec = max(1, Int(ceil(Double(durationSec) / Double(maxBuckets))))
        var grouped: [Int: [WorkoutSample]] = [:]
        for s in sortedSamples { grouped[s.offsetSec / bucketSec, default: []].append(s) }
        let bucketRecords: [FactValue] = grouped.keys.sorted().compactMap { idx in
            guard let bucket = grouped[idx], !bucket.isEmpty else { return nil }
            return .record(bucketRecord(bucket, startingAt: idx * bucketSec))
        }
        var envelope: [String: FactValue] = [
            "date": .date(session.startDate), "duration_sec": .integer(durationSec),
            "bucket_sec": .integer(bucketSec), "bucket_count": .integer(bucketRecords.count),
            "buckets": .list(bucketRecords)
        ]
        if let sport = session.workoutMetadata?.sport.displayName {
            envelope["sport"] = .string(sport)
        }
        return .record(envelope)
    }

    /// One bucket's median metrics, keyed by its start offset.
    private static func bucketRecord(_ bucket: [WorkoutSample], startingAt offset: Int) -> [String: FactValue] {
        var rec: [String: FactValue] = ["offset_sec": .integer(offset)]
        if let hr = median(bucket.compactMap(\.heartRate).map(Double.init)) {
            rec["hr"] = .integer(Int(hr.rounded()))
        }
        if let pace = median(bucket.compactMap(\.paceSecPerKm)) { rec["pace_sec_per_km"] = .double(pace) }
        if let cadence = median(bucket.compactMap(\.cadenceStepsPerMin)) { rec["cadence_spm"] = .double(cadence) }
        if let alt = median(bucket.compactMap(\.altitudeMeters)) { rec["altitude_m"] = .double(alt) }
        if let alpha = median(bucket.compactMap(\.alpha1)) { rec["alpha1"] = .double(alpha) }
        if let powerVals = bucket.compactMap(\.powerWatts).nilIfEmpty,
           let pw = median(powerVals.map(Double.init)) {
            rec["power_w"] = .integer(Int(pw.rounded()))
        }
        if let gradePct = bucketGrade(bucket) { rec["grade_pct"] = .double(gradePct) }
        return rec
    }

    /// Grade across the bucket: altitude rise / horizontal distance. Robust
    /// against missing fields — only computed when both ends have distance +
    /// altitude AND we covered ≥ 5 m horizontally.
    private static func bucketGrade(_ bucket: [WorkoutSample]) -> Double? {
        guard let firstAlt = bucket.first?.altitudeMeters,
              let lastAlt = bucket.last?.altitudeMeters,
              let firstDist = bucket.first?.distanceMeters,
              let lastDist = bucket.last?.distanceMeters,
              lastDist - firstDist >= 5
        else { return nil }
        return ((lastAlt - firstAlt) / (lastDist - firstDist)) * 100.0
    }

    /// Median of a non-empty Double array; nil for empty input. Cheap
    /// O(n log n) sort — buckets are small (worst case ~70 samples at
    /// max-bucket size) so this is well within the resolver budget.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

// `Array.nilIfEmpty` is also defined `fileprivate` in
// Emuqu/Sources/Models/WorkoutThreshold.swift. Keeping this one
// fileprivate too avoids a redeclaration collision.
fileprivate extension Array {
    /// Returns nil when empty, the array otherwise. Saves an explicit
    /// `isEmpty` guard at every callsite.
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// Shared by `workout.segment_compare` and the live segment lookback:
/// finds where a past workout passed a coordinate and reads pace plus the
/// per-second physiology at that moment.
enum SegmentPointSampler {
    /// A sample further than this from the GPS-fix offset would mix
    /// different physiology, so no sample fields are emitted.
    static let maxSampleDeltaSec = 10

    static func match(in session: HRVSession, near target: CLLocation, radius: Double) -> FactValue? {
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
            "date": .string(FactValue.localISO8601(session.startDate)),
            "sport": .string(session.workoutMetadata?.sport.rawValue ?? "unknown"),
            "offset_sec_at_point": .integer(offsetSec),
            "distance_to_point_m": .double(closestDist)
        ]
        if let p = WorkoutGeometry.localPace(in: track, at: closestIdx) { rec["pace_sec_per_km_at_point"] = .double(p) }
        addSampleFields(&rec, samples: session.workoutMetadata?.samples ?? [], offsetSec: offsetSec)
        return .record(rec)
    }

    /// HR / power / cadence / altitude / α1 from the per-second sample
    /// nearest the matching offset, so one tool call answers "how fast was
    /// my heart going here last Tuesday" with physiology, not just pace.
    static func addSampleFields(_ rec: inout [String: FactValue], samples: [WorkoutSample], offsetSec: Int) {
        guard let s = nearestSample(samples, to: offsetSec),
              abs(s.offsetSec - offsetSec) <= maxSampleDeltaSec
        else { return }
        if let hr = s.heartRate { rec["hr_bpm_at_point"] = .integer(hr) }
        if let watts = s.powerWatts { rec["power_watts_at_point"] = .integer(watts) }
        if let cadence = s.cadenceStepsPerMin { rec["cadence_spm_at_point"] = .double(cadence) }
        if let alt = s.altitudeMeters { rec["altitude_m_at_point"] = .double(alt) }
        if let a1 = s.alpha1 { rec["alpha1_at_point"] = .double(a1) }
    }

    /// Sample whose offset is closest to `offsetSec`. A full scan, so it
    /// does not depend on the samples being stored in offset order.
    static func nearestSample(_ samples: [WorkoutSample], to offsetSec: Int) -> WorkoutSample? {
        samples.min { abs($0.offsetSec - offsetSec) < abs($1.offsetSec - offsetSec) }
    }
}
