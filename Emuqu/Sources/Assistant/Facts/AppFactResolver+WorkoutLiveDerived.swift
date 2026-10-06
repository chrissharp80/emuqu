import CoreLocation
import Foundation

// The derived half of `WorkoutLiveNamespace`, split out of
// `AppFactResolver+WorkoutLive.swift` to keep that struct's body under
// the 500-line limit. The raw per-tick sensor facts stay there; the derived
// and cross-referenced ones live here.
//
// Anything these entries call in the other file is internal rather than
// `private`, because Swift's `private` does not reach across files.

extension WorkoutLiveNamespace {
    /// Facts derived from the tick stream or cross-referenced against history.
    var derivedEntries: [FactEntry] {
        [
            [workoutLiveUnitsPreferenceEntry],
            liveTrendEntries,
            [workoutLiveTimelineSecondsEntry, workoutLiveLocationBundleEntry]
        ]
        .flatMap { $0 }
    }

    // Dedicated tools for the live trend metrics and
    // cross-workout baselines. Each is also accessible via
    // `workout.live.snapshot`, but exposing them as first-class
    // tools lets the AI ask for a single number instead of pulling
    // the full record (cheaper payload, more focused intent).
    private var liveTrendEntries: [FactEntry] {
        [
            workoutLiveHrDriftPercentEntry,
            workoutLiveAerobicDecouplingPercentEntry,
            reverseSplitDeltaEntry,
            workoutLiveCadenceDriftSpmEntry,
            gradeAdjustedPaceEntry,
            workoutLiveHistoricalBaselineEntry,
            workoutLiveRouteHistoryBaselineEntry,
            workoutLiveTrainingPaceZonesEntry,
            workoutLiveTodayReadinessEntry
        ]
    }

    private var workoutLiveUnitsPreferenceEntry: FactEntry {
        .fixed(
            key: "workout.live.units_preference",
            description: "User's resolved units preference string — 'metric' or 'imperial'. Render pace, distance, and elevation in this unit when answering; 'auto' is already resolved.",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.unitsPreference) } ?? self.missing()
        }
    }

    private var workoutLiveHrDriftPercentEntry: FactEntry {
        .fixed(
            key: "workout.live.hr_drift_percent",
            description: """
            Cardiac drift: average HR in the most recent quarter of the workout vs the first quarter, expressed as a percentage of the first-quarter baseline. Positive = HR creeping up at the same workload (fatigue, dehydration, heat). \
            Greater than +5% sustained is a 'consider easing off' signal. Returns notRecorded for the first ~7 minutes (not enough data) or when no HR samples are present.
            """,
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.liveHRDriftPercent.map { .double($0) } ?? self.missing("not enough samples yet")
        }
    }

    private var workoutLiveAerobicDecouplingPercentEntry: FactEntry {
        .fixed(
            key: "workout.live.aerobic_decoupling_percent",
            description: """
            Aerobic decoupling Pa:Hr — first-half pace/HR efficiency vs second-half pace/HR efficiency, expressed as a percentage drop. Positive = decoupling has occurred (efficiency degrading). Same metric the post-workout summary \
            uses, computed live mid-workout. Returns notRecorded before half-time or when one half lacks paired pace+HR samples.
            """,
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.aerobicDecouplingPercent.map { .double($0) } ?? self.missing("not enough samples yet")
        }
    }

    private var reverseSplitDeltaEntry: FactEntry {
        .fixed(
            key: "workout.live.reverse_split_delta_sec_per_km",
            description: "Second-half average pace minus first-half average pace, in seconds per kilometre. Negative = running FASTER in the second half (true negative split). Positive = slowing down. Returns notRecorded for the first ~10 minutes of the workout.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.reverseSplitDeltaSecPerKm.map { .double($0) } ?? self.missing("not enough samples yet")
        }
    }

    private var workoutLiveCadenceDriftSpmEntry: FactEntry {
        .fixed(
            key: "workout.live.cadence_drift_spm",
            description: "Cadence delta in steps-per-minute: current quarter average minus first-quarter average. Negative = stride breaking down with fatigue. Returns notRecorded before ~7 minutes or when no cadence source is connected.",
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.cadenceDriftSpm.map { .double($0) } ?? self.missing("no cadence source or not enough samples")
        }
    }

    private var gradeAdjustedPaceEntry: FactEntry {
        .fixed(
            key: "workout.live.grade_adjusted_pace_sec_per_km",
            description: """
            Grade-adjusted pace: current pace mathematically corrected to a flat-equivalent using the Minetti et al. (2002) energy-cost curve. Sec/km. Lets the user know they're 'really' running 5:10/km flat-equivalent even though they're actually \
            at 4:20/km on a 6% downhill. Returns notRecorded when current pace or grade is missing.
            """,
            valueType: "Double"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.gradeAdjustedPaceSecPerKm.map { .double($0) } ?? self.missing("missing current pace or grade")
        }
    }

    private var workoutLiveHistoricalBaselineEntry: FactEntry {
        .fixed(
            key: "workout.live.historical_baseline",
            description: Self.workoutLiveHistoricalBaselineDescription,
            valueType: "Record"
        ) { self.resolveWorkoutLiveHistoricalBaseline() }
    }

    private func resolveWorkoutLiveHistoricalBaseline() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        guard s.historicalSportSampleCount > 0 else { return self.missing("no prior workouts of this sport") }
        var rec = sportBaselineRecord(s)
        if let p = s.historicalSportAvgPaceSecPerKm { rec["avg_pace_sec_per_km"] = .double(p) }
        if let h = s.historicalSportAvgHR { rec["avg_hr"] = .double(h) }
        if let a = s.historicalSportAvgAlpha1 { rec["avg_alpha1"] = .double(a) }
        return .record(rec)
    }

    // Explicit data_source + sport fields so
    // the AI can never confuse this with the route-specific
    // tool and miscredit a sport-wide average as
    // route-matched in user-facing language.
    private func sportBaselineRecord(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        [
            "data_source": .string("sport_wide"),
            "sport": .string(s.sport),
            "sample_count": .integer(s.historicalSportSampleCount),
            // `comparison_safe = false` when the
            // sample is too thin to draw a comparison from
            // (single point, no real "average"). The prompt
            // tells the AI to refuse trend / comparison
            // language when this flag is false.
            "comparison_safe": .boolean(s.historicalSportSampleCount >= 2)
        ]
    }

    private static let workoutLiveHistoricalBaselineDescription = """
    Cross-workout baseline — SPORT-WIDE averages across the user's recent (≤30) workouts of the same sport (NOT route-specific; use workout.live.route_history_baseline for route-matched comparisons). Returns a record { data_source: \
    'sport_wide', sport, sample_count, avg_pace_sec_per_km?, avg_hr?, avg_alpha1? }. The data_source field tells you to phrase any comparison as 'compared to your typical run' (sport-wide), NOT 'compared to this route' (which \
    is the route-specific tool). Returns notRecorded when no prior matching workouts exist.
    """

    private var workoutLiveRouteHistoryBaselineEntry: FactEntry {
        .fixed(
            key: "workout.live.route_history_baseline",
            description: Self.routeHistoryBaselineDescription,
            valueType: "Record"
        ) { self.resolveWorkoutLiveRouteHistoryBaseline() }
    }

    private func resolveWorkoutLiveRouteHistoryBaseline() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        guard let routeName = s.recognizedRouteName, !routeName.isEmpty else {
            return self.missing("no recognized route bound to this workout")
        }
        let candidates = routeHistorySessions(named: routeName)
        guard !candidates.isEmpty else {
            return self.missing("first run on this route — no prior history yet")
        }
        return .record(routeBaselineRecord(routeName, candidates: candidates))
    }

    /// The archive index doesn't carry the route name, so sessions are
    /// decoded newest-first and the walk stops at 20 matches or after the
    /// newest `routeHistoryScanLimit` workouts, whichever comes first —
    /// a mid-workout call never decodes the whole archive on the main
    /// actor. Uses the lightweight retrieval path (skips rrSeries; still
    /// loads workoutMetadata with recognizedRouteName + samples).
    private func routeHistorySessions(named routeName: String) -> [HRVSession] {
        let archive = self.archive
        let recent = archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
            .prefix(Self.routeHistoryScanLimit)
        var matches: [HRVSession] = []
        for entry in recent where matches.count < 20 {
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId),
                  Self.isSameRoute(session.workoutMetadata?.recognizedRouteName, routeName)
            else { continue }
            matches.append(session)
        }
        return matches
    }

    /// Most recent workouts searched for prior runs of the current route.
    private static let routeHistoryScanLimit = 120

    /// A past workout ran the current route when its recognized route name
    /// matches ignoring case, the way the saved-route lookups match names.
    /// A workout with no recognized route never matches.
    static func isSameRoute(_ recorded: String?, _ routeName: String) -> Bool {
        guard let recorded else { return false }
        return recorded.caseInsensitiveCompare(routeName) == .orderedSame
    }

    private func routeBaselineRecord(_ routeName: String, candidates: [HRVSession]) -> [String: FactValue] {
        let totals = routeHistoryTotals(candidates)
        var rec: [String: FactValue] = [
            "data_source": .string("route_specific"),
            "route_name": .string(routeName),
            "prior_session_count": .integer(candidates.count),
            "comparison_safe": .boolean(candidates.count >= 2)
        ]
        if totals.dist > 100 {
            rec["avg_pace_sec_per_km"] = .double(totals.dur * 1_000.0 / totals.dist)
        }
        if totals.hrCount > 0 { rec["avg_hr"] = .double(totals.hrSum / Double(totals.hrCount)) }
        if totals.alphaCount > 0 { rec["avg_alpha1"] = .double(totals.alphaSum / Double(totals.alphaCount)) }
        return rec
    }

    /// Rolling sums over a route's prior sessions, gathered in one pass.
    struct RouteHistoryTotals {
        var dist: Double = 0
        var dur: Double = 0
        var hrSum: Double = 0
        var hrCount: Int = 0
        var alphaSum: Double = 0
        var alphaCount: Int = 0
    }

    private func routeHistoryTotals(_ candidates: [HRVSession]) -> RouteHistoryTotals {
        var totals = RouteHistoryTotals()
        for session in candidates {
            if let dist = session.workoutMetadata?.distanceMeters, dist > 100,
               let dur = session.duration, dur > 60 {
                totals.dist += dist
                totals.dur += dur
            }
            let samples = session.workoutMetadata?.samples ?? []
            let hrs = samples.compactMap(\.heartRate).filter { $0 > 0 }
            let alphas = samples.compactMap(\.alpha1).filter { $0 > 0 }
            totals.hrSum += hrs.reduce(0) { $0 + Double($1) }
            totals.hrCount += hrs.count
            totals.alphaSum += alphas.reduce(0, +)
            totals.alphaCount += alphas.count
        }
        return totals
    }

    private static let routeHistoryBaselineDescription = """
    ROUTE-SPECIFIC baseline (NOT sport-wide). When the active workout is bound to a saved-library route, returns aggregate pace + HR + α1 + count from PAST workouts on the SAME named route only. Use this for 'how am I doing \
    on this loop today vs the average for this loop?'. The record's data_source field is 'route_specific' so you know to phrase comparisons as 'on Daily 1 you usually run X' rather than 'you usually run X' (the latter is sport-wide \
    and is a different tool). Returns notRecorded when no route is bound OR when this is the first time the user has run this route. Uses up to the 20 most recent prior runs of the route among the user's last 120 workouts. Record fields: data_source, route_name, \
    prior_session_count, comparison_safe, avg_pace_sec_per_km?, avg_hr?, avg_alpha1?.
    """

    private var workoutLiveTrainingPaceZonesEntry: FactEntry {
        .fixed(
            key: "workout.live.training_pace_zones",
            description: """
            Daniels-style training pace zones derived from the user's 5K race prediction. Returns sec/km per zone: easy (long-run / base), marathon (steady race pace), threshold (tempo), interval (VO2max), repetition (speed). Use to \
            answer 'what pace should I hold for an easy run?' / 'what's my tempo pace?'. Returns notRecorded when no 5K basis exists in the user's history.
            """,
            valueType: "Record"
        ) { self.resolveWorkoutLiveTrainingPaceZones() }
    }

    private func resolveWorkoutLiveTrainingPaceZones() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        guard let totalSec = s.predictedRaceTime5KSec,
              let zones = TrainingPaceZones.from5KPace(secPerKm: totalSec / 5.0)
        else {
            return self.missing("no 5K race basis in history")
        }
        return .record([
            "easy_sec_per_km": .double(zones.easySecPerKm),
            "marathon_sec_per_km": .double(zones.marathonSecPerKm),
            "threshold_sec_per_km": .double(zones.thresholdSecPerKm),
            "interval_sec_per_km": .double(zones.intervalSecPerKm),
            "repetition_sec_per_km": .double(zones.repetitionSecPerKm)
        ])
    }

    private var workoutLiveTodayReadinessEntry: FactEntry {
        .fixed(
            key: "workout.live.today_readiness",
            description: Self.workoutLiveTodayReadinessDescription,
            valueType: "Record"
        ) { self.resolveWorkoutLiveTodayReadiness() }
    }

    private func resolveWorkoutLiveTodayReadiness() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        let live = self.liveTrainingLoad()
        let hasAny = s.todayRecoveryScore != nil
            || s.todayTrainingReadiness != nil
            || live != nil
        guard hasAny else { return self.missing("no morning reading captured yet today") }
        var rec: [String: FactValue] = [:]
        if let r = s.todayRecoveryScore { rec["recovery_score"] = .double(r) }
        if let r = s.todayTrainingReadiness { rec["training_readiness"] = .double(r) }
        if let live {
            rec["atl"] = .double(live.atl)
            rec["ctl"] = .double(live.ctl)
            rec["tsb"] = .double(live.tsb)
        }
        return .record(rec)
    }

    private static let workoutLiveTodayReadinessDescription = """
    Today's readiness record. `recovery_score` and `training_readiness` are frozen at workout start (the numbers the user saw when they tapped Start). `atl` / `ctl` / `tsb` are LIVE — they match the Dashboard's current Load \
    & Trajectory display and update during the workout. Use this as the canonical \"what's my TSB / ATL / CTL\" answer; it returns the same value as `training.load.*` so mixing the two in one conversation no longer produces \
    contradictory replies. Returns notRecorded only when there's no morning HRV reading AND no historical training data.
    """

    // Recent-samples timeline. Lets the AI answer retrospective
    // questions during the workout that single-point snapshots
    // can't ("did my HR spike without elevation gain in the last
    // 5 minutes?"). The recorder captures one sample per second;
    // we decimate to keep the AI's context bounded.
    private var workoutLiveTimelineSecondsEntry: FactEntry {
        .parameterized(
            pattern: "workout.live.timeline($seconds)",
            paramExample: "300",
            description: Self.workoutLiveTimelineSecondsDescription,
            resolve: { param, _ in self.resolveWorkoutLiveTimelineSeconds(param) }
        )
    }

    private func resolveWorkoutLiveTimelineSeconds(_ param: String) -> FactValue {
        let lookback: Int
        do throws(FactArgumentError) {
            lookback = try FactNumericArgument.lookbackSeconds.integer(param)
        } catch {
            return error.factValue
        }
        guard self.snapshot != nil else {
            return .missing(reason: .notRecorded, detail: "no workout active")
        }
        let samples = AppDependencies.current.assistant.liveWorkoutBroker.currentSamples()
        guard !samples.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no samples captured yet")
        }
        let windowed = windowedSamples(samples, lookback: max(30, min(3600, lookback)))
        guard !windowed.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no samples in lookback window")
        }
        return .list(decimated(windowed).map { timelineRecord($0) })
    }

    // Filter to the lookback window — find latest offset, keep samples within window.
    private func windowedSamples(_ samples: [WorkoutSample], lookback lookbackSec: Int) -> [WorkoutSample] {
        let latestOffset = samples.last?.offsetSec ?? 0
        let cutoffOffset = max(0, latestOffset - lookbackSec)
        return samples.filter { $0.offsetSec >= cutoffOffset }
    }

    // Decimate to ≤120 points so a 30-min lookback (1800
    // samples) becomes ~120 (one per ~15s) — keeps the
    // serialised result bounded but the trend visible.
    private func decimated(_ windowed: [WorkoutSample]) -> [WorkoutSample] {
        let stride = max(1, windowed.count / 120)
        return windowed.enumerated()
            .compactMap { idx, sample in idx % stride == 0 ? sample : nil }
    }

    private func timelineRecord(_ sample: WorkoutSample) -> FactValue {
        var rec: [String: FactValue] = [
            "offset_sec": .integer(sample.offsetSec)
        ]
        if let hr = sample.heartRate { rec["hr"] = .integer(hr) }
        if let alt = sample.altitudeMeters { rec["altitude_m"] = .double(alt) }
        if let dist = sample.distanceMeters { rec["distance_m"] = .double(dist) }
        if let p = sample.paceSecPerKm { rec["pace_sec_per_km"] = .double(p) }
        if let c = sample.cadenceStepsPerMin { rec["cadence_spm"] = .double(c) }
        if let a = sample.alpha1 { rec["alpha1"] = .double(a) }
        if let m = sample.mets { rec["mets"] = .double(m) }
        if let w = sample.powerWatts { rec["power_w"] = .integer(w) }
        return .record(rec)
    }

    private static let workoutLiveTimelineSecondsDescription = """
    Recent correlated time-series for the active workout. `$seconds` is the lookback window in seconds (60 for 'last minute', 300 for 'last 5 min', 1800 for 'last 30 min'; a whole number from 1 to 86400, clamped to 30–3600). Returns a list of records, each: { \
    offset_sec, hr, altitude_m?, distance_m?, pace_sec_per_km?, cadence_spm?, alpha1?, mets?, power_w? }. The list is decimated to ≤ 120 points so a 30-min lookback is one sample per ~15 s. Use this to answer questions where \
    you need to correlate variables across time — 'did my HR rise without grade?' / 'when did my pace drop?' / 'did α1 cross AeT during that climb?'. Returns missing when no workout is active.
    """

    // Consolidated location bundle. Replaces a half-dozen
    // individual location fact calls with one record, so the AI's
    // "where am I and what am I doing" question doesn't need three
    // round-trips.
    private var workoutLiveLocationBundleEntry: FactEntry {
        .fixed(
            key: "workout.live.location_bundle",
            description: Self.workoutLiveLocationBundleDescription,
            valueType: "Record"
        ) { self.resolveWorkoutLiveLocationBundle() }
    }

    private func resolveWorkoutLiveLocationBundle() -> FactValue {
        guard let s = self.snapshot else { return self.missing() }
        guard s.currentLatitude != nil || s.currentLongitude != nil else {
            return self.missing("no GPS fix yet")
        }
        var rec = liveFixFields(s)
        let road = liveRoadContext(s)
        addRoadFields(&rec, road: road)
        rec["address_status"] = .string(liveAddressStatus(rec, road: road))
        return .record(rec)
    }

    private func liveFixFields(_ s: AssistantContext.LiveWorkoutSnapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        if let lat = s.currentLatitude { rec["latitude"] = .double(lat) }
        if let lon = s.currentLongitude { rec["longitude"] = .double(lon) }
        if let alt = s.currentAltitudeMeters { rec["altitude_m"] = .double(alt) }
        if let hdg = s.currentHeadingDegrees { rec["heading_degrees"] = .double(hdg) }
        if let spd = s.currentSpeedMS { rec["speed_m_per_s"] = .double(spd) }
        if let g = s.currentGradePercent { rec["grade_percent"] = .double(g) }
        if let acc = s.gpsAccuracyMeters { rec["gps_accuracy_m"] = .double(acc) }
        return rec
    }

    // DISTANCE-VALIDATED cache read (no per-call
    // CLGeocoder roundtrip). A fresh fetch on every
    // tool call violates Apple's 1-req/min/app rate
    // floor — silent kCLErrorNetwork → no street name
    // surfaced. So: serve cached if origin is within
    // `RoadGeocodingService.cachedAddressMaxDistanceMeters`
    // (100 m, the same block) of the user, nil otherwise so
    // address_status says "pending" and the model waits
    // rather than naming a street the user has left. `cachedIfCloseTo` kicks a background refresh
    // so the NEXT tool call gets fresh data without
    // burning rate budget on this one.
    private func liveRoadContext(_ s: AssistantContext.LiveWorkoutSnapshot) -> RoadGeocodingService.RoadContext? {
        MainActor.assumeIsolated {
            let svc = AppDependencies.current.location.roadGeocodingService
            guard let lat = s.currentLatitude, let lon = s.currentLongitude else {
                return svc.current
            }
            let here = CLLocation(latitude: lat, longitude: lon)
            return svc.cachedIfCloseTo(here)
        }
    }

    private func addRoadFields(_ rec: inout [String: FactValue], road: RoadGeocodingService.RoadContext?) {
        guard let road else { return }
        if let street = road.road { rec["street"] = .string(street) }
        if let city = road.locality { rec["city"] = .string(city) }
        if let cross = road.nearestCrossStreet {
            rec["cross_street"] = .string(cross)
        }
        if let isect = road.nearestIntersection {
            rec["nearest_intersection"] = .string(isect)
        }
    }

    // Explicit `address_status` field so the
    // model can give a useful answer when the reverse-geo
    // hasn't filled in yet. If the road / city /
    // cross_street keys are just omitted on incomplete
    // resolution, the model interprets that as "lookup
    // failed" and dumps the internal failure mode on the
    // user ("I don't have a street from the live location
    // fix"). So: ready ⇒ everything resolved; partial ⇒
    // some fields present, others still resolving; pending
    // ⇒ no road context yet at all. The system prompt's
    // no-dev-jargon rule says how to translate these to
    // plain English.
    private func liveAddressStatus(
        _ rec: [String: FactValue],
        road: RoadGeocodingService.RoadContext?
    ) -> String {
        let hasRoad = rec["street"] != nil || rec["city"] != nil
        if road == nil { return "pending" }
        if hasRoad && rec["cross_street"] != nil { return "ready" }
        if hasRoad { return "partial_no_cross_street" }
        return "pending"
    }

    private static let workoutLiveLocationBundleDescription = """
    Consolidated location snapshot for the active workout. Single call returns { latitude, longitude, altitude_m, heading_degrees, speed_m_per_s, grade_percent, gps_accuracy_m, street?, cross_street?, nearest_intersection?, \
    city?, address_status }. Use this when answering any 'where am I' / 'what street' / 'what's my heading' question — replaces calls to individual location.* and workout.live.location.* fields. Returns missing \
    when no workout is active or no GPS fix yet. `address_status` values: 'ready' (street + cross-street both present — quote them), 'partial_no_cross_street' (street present, cross-street not yet resolved — say the street, \
    don't mention cross-street), 'pending' (no street yet — say 'I don't have a street name for where you are right now — try again in a few seconds' and pivot to neighborhood / direction / distance walked. Do NOT mention 'geocoding' \
    / 'live location fix' / 'raw coordinates' to the user).
    """
}
