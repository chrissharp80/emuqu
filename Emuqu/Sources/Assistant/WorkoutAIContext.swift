import CoreLocation
import Foundation

// MARK: - Workout AI Context
//
// A structured, factual snapshot fed to the voice coach each time it needs to
// decide whether (and what) to say. Every field is directly observed —
// nothing is inferred, averaged against imaginary baselines, or invented.
//
// The trigger engine reads this and decides whether any rule fires. Rules
// produce templated lines that only substitute values *present* in this
// struct; unset optionals mean "we don't know — stay quiet about this."
//
// Design principle: give the coach every observation we have each tick,
// including wall-clock timestamps, GPS position, heading, grade, and
// diagnostic status for flaky inputs. The coach/AI then has full situational
// awareness — "are we still live?" ("nowAt minus sessionStart"), "where are
// we?" ("currentLatitude/Longitude"), "why is α1 missing?"
// ("alpha1Status"). Without these, the AI has to guess.
struct WorkoutAIContext: Equatable {
    // MARK: Identity / time

    let sport: Sport
    /// Wall-clock timestamp of this snapshot. Lets the voice coach know if
    /// we're truly live (recent snapshot) or reading stale state.
    let nowAt: Date
    /// Wall-clock session start. The AI can compute absolute clock time from
    /// this plus `elapsedSeconds` without needing another field.
    let sessionStart: Date
    let elapsedSeconds: Int

    // MARK: Heart-rate state

    let heartRate: Int?
    /// Session-observed peak HR (max the user reached during THIS workout).
    /// Do NOT use as the denominator for zone classification — use
    /// `userMaxHR` instead. Kept here for drift math and "new session peak"
    /// commentary only.
    let peakHR: Int
    /// User's physiological max HR (from Settings → Fitness). This is the
    /// correct denominator for "what zone are you in?" — session peak only
    /// reflects what happened this workout, not the user's actual ceiling.
    /// Always populated (UserSettings.effectiveMaxHR falls back to 220-age,
    /// or 180 if age unknown).
    let userMaxHR: Int
    let hrDriftPercent: Double?

    // MARK: Physiology

    let alpha1: Double?
    let band: LiveDFAAnalyzer.Band
    let alpha1FitQuality: Double?
    /// Diagnostic status for α1. Lets the coach explain *why* α1 isn't
    /// updating (warming up, strap silent, fit failed) rather than pretending
    /// the metric doesn't exist.
    let alpha1Status: LiveDFAAnalyzer.Status

    // MARK: Motion

    let distanceMeters: Double
    /// Current pace in seconds per kilometre, rolling ~30 s window.
    let currentPaceSecPerKm: Double?
    /// Instantaneous speed in m/s, if known (foot-pod or GPS-delta).
    let currentSpeedMS: Double?
    /// Cadence in steps per minute.
    let cadenceStepsPerMin: Double?
    /// Running power in watts (foot pod only).
    let powerWatts: Int?
    /// True when a foot pod (Stryd / FTMS) is currently connected and
    /// streaming. Surfaced explicitly so the AI can distinguish "foot
    /// pod connected, currently 0 / momentarily silent" (legitimate —
    /// user's foot is in the air, BLE packet hasn't arrived this tick)
    /// from "no foot pod paired" (data path doesn't exist). Without
    /// this flag the prompt's `powerW` / `cadenceSpm` lines vanish on
    /// every BLE gap and the AI reports the data missing.
    let footPodActive: Bool
    /// Current METs estimate.
    let currentMETs: Double?
    /// Paces of the most recent 1 km splits (index 0 = most recent).
    let recentSplitPaces: [Double]

    // MARK: Map & terrain

    /// Current GPS latitude (nil if no fix or indoor).
    let currentLatitude: Double?
    /// Current GPS longitude (nil if no fix or indoor).
    let currentLongitude: Double?
    /// Current altitude in metres (nil if no fix).
    let currentAltitudeMeters: Double?
    /// Current heading in degrees true (nil if no fix or stationary).
    let currentHeadingDegrees: Double?
    /// Horizontal GPS accuracy in metres. Higher = noisier fix.
    let gpsAccuracyMeters: Double?
    /// Cumulative elevation gain so far.
    let elevationGainMeters: Double
    /// Current grade in %, sustained over >100 m. Nil when flat or noisy.
    let currentGradePercent: Double?
    /// Upcoming climb within the next ~200 m from route/elevation data.
    /// Nil when there isn't a route loaded (free-run).
    let upcomingClimb: UpcomingClimb?

    /// Full topography snapshot of the bound route — climbs queue,
    /// total ascent remaining, peak altitude, steepest grade ahead.
    /// Nil when no route is bound. Distinct from `upcomingClimb` (which
    /// stays for backwards-compat with the climb-ahead trigger rule);
    /// `routeTopology` carries the richer answer.
    let routeTopology: RouteTopology?

    /// Current weather at the user's GPS coordinate. Refreshed every
    /// ~30 minutes during the workout (workout start + every 1800s tick).
    /// Nil when no fix yet, weather fetch failed, or workout is indoor.
    let weather: WeatherSnapshot?

    struct WeatherSnapshot: Equatable {
        let temperatureC: Double
        let apparentTemperatureC: Double
        let windKMH: Double
        let windDirectionDegrees: Double
        let humidityPercent: Double
        let conditions: String  // "Clear", "Overcast", "Light rain", etc.
        let observedAt: Date
    }

    // MARK: Equipment

    let strapConnected: Bool
    /// Seconds since the last strap-derived HR beat. `nil` when source isn't
    /// strap. Large values (>10) mean we're silently falling back to Watch HR.
    let strapSilentSec: Double?

    // MARK: Resolved location (human-readable, fed into voice context)
    //
    // Voice chat uses `asFactSheet()`; with only raw `gpsLat` / `gpsLon`
    // the voice AI couldn't say "you're on
    // Riverwood Dr" because the resolved street name wasn't in this struct.
    // Mirrored from `RoadGeocodingService.shared.current` at every
    // `buildContext` tick — same source of truth as the chat-path
    // `LiveWorkoutSnapshot.currentRoadName`.
    let currentRoadName: String?
    let currentLocality: String?
    let currentAdministrativeArea: String?
    let currentCountryCode: String?
    /// Compact one-line address ready for the AI to read aloud.
    let currentCompactAddress: String?
    /// Nearest cross street (different from current
    /// road), resolved via MKLocalSearch in a 200 m box. Nil when
    /// the search returned nothing nearby (rural / wilderness).
    /// Combined with `currentRoadName` the AI can answer "what's
    /// the nearest intersection".
    let currentNearestCrossStreet: String?
    /// Pre-formatted "Riverwood Dr & Eastland Ave" intersection
    /// label. Nil when either side is missing.
    let currentNearestIntersection: String?

    // MARK: Session HR aggregates
    //
    // Without this the AI has `currentHR`
    // and `peakHR` but no SESSION AVERAGE, and voice users asking "what's
    // my average heart rate" get nothing back. Computed live from the
    // running `workoutSamples` buffer in WorkoutRecorder.buildContext.
    let sessionAverageHR: Double?

    // MARK: Live trend metrics
    //
    // Surfaced so the AI can compare current effort to
    // earlier in the same workout without recomputing from raw samples.
    // All fields are nil until enough samples accumulate (typically
    // ~5 min into the workout for the first/second-half splits).

    /// Current pace minus the average pace of the FIRST half of the
    /// workout, sec/km. Negative = running faster now (positive split
    /// in reverse), positive = slowing down. Nil before half-time.
    /// Re-computed each tick so the AI can answer "am I still on
    /// pace?" with a real delta.
    let reverseSplitDeltaSecPerKm: Double?

    /// Cardiac drift: current HR vs HR at same-pace samples in the
    /// first quartile. Expressed as a percentage of the baseline HR.
    /// >5 % suggests fatigue/dehydration creeping in. Nil before
    /// 10 min or when pace history is too noisy to match.
    let liveHRDriftPercent: Double?

    /// Bpm change in the last ~90 seconds
    /// (current avg minus 60-90s-ago avg). Positive = HR rising right
    /// now; negative = HR falling right now. Used to suppress the
    /// `hr.driftHigh` alert when long-window drift is positive but the
    /// user is actually descending and HR is recovering — the user was
    /// hearing "your HR has drifted higher" while it was actively
    /// falling on a downhill. This per-tick slope is the live truth;
    /// `liveHRDriftPercent` is the long-window historical comparison.
    let recentHRSlopeBpm: Double?

    /// Aerobic decoupling Pa:Hr — first-half pace/HR ratio compared
    /// to second-half pace/HR ratio, expressed as a percentage drop.
    /// Same metric the post-summary uses, computed live mid-workout.
    /// Nil before half-time or when one half has no usable samples.
    let aerobicDecouplingPercent: Double?

    /// Cadence delta: current cadence minus the average of the first
    /// quartile of the workout. Negative = stride breaking down with
    /// fatigue. Nil before ~5 min or when no cadence source.
    let cadenceDriftSpm: Double?

    /// Pace adjusted for the current grade so the AI can say "your
    /// flat-equivalent pace right now is 5:10/km even though you're
    /// running 4:20/km downhill." Uses Strava-style grade-adjusted
    /// pace (GAP) coefficients. Nil when no current pace or grade.
    let gradeAdjustedPaceSecPerKm: Double?

    /// Last up-to-3 1 km splits, each grade-adjusted by that split's
    /// average grade. Index 0 = most recent split. Empty when no
    /// completed splits yet. Use to answer "was that downhill split
    /// actually fast?" with a flat-equivalent number instead of a
    /// raw watch reading.
    let recentSplitGradeAdjustedPaces: [Double]

    /// Heuristic minutes-until-fade estimate based on the live HR
    /// drift trajectory. Linear extrapolation to 10 % drift (the
    /// commonly-cited threshold past which fatigue compounds). Nil
    /// when drift is flat / negative / not yet computable. Surface
    /// to the user as "rough" — physiology is non-linear, this is a
    /// directional indicator only.
    let projectedMinutesUntilFade: Double?

    // MARK: Historical baselines (cross-workout)
    //
    // Prevents the AI complaint "no workout history on file —
    // session comparisons not available yet." Computed once from the
    // user's archived sessions matching this workout's sport. Lets the
    // coach answer "is today faster or slower than usual?" with a real
    // number instead of declining.

    /// Average pace across the user's last N (≤30) workouts of the
    /// same sport, weighted by distance. Sec/km. Nil when no prior
    /// matching workouts exist.
    let historicalSportAvgPaceSecPerKm: Double?

    /// Average HR across the same window. Bpm. Nil when no prior
    /// matching workouts exist.
    let historicalSportAvgHR: Double?

    /// Average α1 (DFA-α1) across the same window. Nil when no prior
    /// matching workouts captured α1.
    let historicalSportAvgAlpha1: Double?

    /// Number of prior workouts that contributed to the averages
    /// above. Lets the AI say "based on your last 12 runs" rather
    /// than asserting a baseline from a sample of 1.
    let historicalSportSampleCount: Int

    // MARK: Readiness / training load (today's context)
    //
    // Prevents the AI complaint about not knowing whether
    // today is a push day or a back-off day. Captured from this
    // morning's frozen recovery snapshot at workout start so the
    // numbers don't drift mid-workout while the user is moving.

    /// Today's frozen recovery score on a 0–100 scale (the same
    /// number the dashboard ring shows). Nil when no morning HRV
    /// reading exists yet. The voice coach uses this to gauge
    /// whether to nudge intensity up or down.
    let todayRecoveryScore: Double?

    /// Today's frozen training-readiness on a 0–100 scale (combines
    /// recovery score with ATL/CTL/TSB). Nil when training-load
    /// integration is off or data isn't ready.
    let todayTrainingReadiness: Double?

    /// Acute Training Load (7-day exponentially-weighted TRIMP).
    /// Carried verbatim from the morning snapshot. Nil when no
    /// training-load history exists.
    let todayATL: Double?

    /// Chronic Training Load (28-day EWMA). Same source.
    let todayCTL: Double?

    /// Training Stress Balance (CTL − ATL). Negative = fatigued,
    /// positive = freshness. Lets the AI distinguish "you're tired
    /// and pushing through" from "you're rested, this is a good day".
    let todayTSB: Double?

    /// Days from today until TSB returns to ≥ 0 if the user adds
    /// zero further training load (rest forecast). 0 = already fresh.
    /// Nil when current TSB ≥ 0 OR projected recovery would take
    /// >30 days (signal: take a real off-week). Computed at workout
    /// start from today's frozen ATL/CTL via `TrainingLoadProjection`.
    let projectedDaysUntilFresh: Int?

    /// Tomorrow's projected TSB if the user adds the same TRIMP load
    /// as today's session (steady-state forecast). Lets the AI answer
    /// "if I keep doing this, where does my form land in a week?".
    /// Nil when no today TRIMP / no current ATL & CTL.
    let projectedTSBTomorrowSteadyState: Double?

    /// Hours of recovery needed before TSB returns to ≥ 0 (Garmin
    /// "recovery time" equivalent). Nil when already fresh OR no
    /// training-load inputs.
    let recoveryHoursNeeded: Double?

    // MARK: Live time-in-zone breakdown (this workout)

    let zone1Sec: Int
    let zone2Sec: Int
    let zone3Sec: Int
    let zone4Sec: Int
    let zone5Sec: Int
    /// Most-time-in zone (1–5). Nil before any HR samples accumulate.
    let dominantZone: Int?

    // MARK: Race-time predictions (Riegel)
    //
    // `T2 = T1 × (D2/D1)^1.06` projections from the
    // user's fastest sport-matched workout in their archive. Each
    // value is predicted total seconds. Nil when no comparable basis.

    let predictedRaceTime5KSec: Double?
    let predictedRaceTime10KSec: Double?
    let predictedRaceTimeHalfSec: Double?
    let predictedRaceTimeMarathonSec: Double?

    // MARK: User preferences / profile

    /// Units preference for all distance / pace / elevation / temperature
    /// rendering. The AI uses this to speak the user's language — imperial
    /// users don't want "5.2 km at 4:45/km"; they want "3.2 miles at 7:38/mi".
    let userUnits: UnitsPreference

    // MARK: Target

    /// User-selected target zone for this workout (1–5). Nil = no target set,
    /// in which case zone-based trigger rules stay silent. When present, the
    /// voice coach will gently nudge the user back to zone if they drift
    /// above or below it for a sustained period (not single-tick, not
    /// rare spikes).
    let targetZone: Int?

    /// User-defined hard thresholds for ambient coaching. The user pre-sets
    /// "don't let HR exceed 135 bpm for >30s" or "stay above zone 2", goes
    /// silent (audiobook-friendly), and only hears the coach when a threshold
    /// is breached past its debounce. Each threshold carries its own debounce
    /// + cooldown so the coach doesn't nag.
    let activeThresholds: [WorkoutThreshold]

    /// Per-threshold breach state — for each threshold the user set, how many
    /// CONSECUTIVE seconds the metric has been outside the band. Resets to 0
    /// the moment the metric comes back inside. Trigger rules check
    /// `breachDuration >= threshold.debounceSec` to avoid firing on a single
    /// noisy sample. Indexed by threshold ID; missing means "currently inside
    /// the band".
    let thresholdBreachSec: [UUID: Int]

    struct UpcomingClimb: Equatable {
        let distanceMeters: Double
        let gradePercent: Double
        /// Total length of the climb itself (meters) — distinct from
        /// `distanceMeters` which is how far AHEAD it starts.
        var lengthMeters: Double = 0
        /// Total elevation gain across the climb, meters.
        var gainMeters: Double = 0
        /// Reverse-geocoded street name where the climb starts ("Elm
        /// Street", "Old Topside Rd"). Sourced from `Route.Climb.roadName`,
        /// which the SavedRouteStore enrichment pass populates after the
        /// user saves a route. nil for unsaved one-off GPX imports or
        /// when the geocoder couldn't match.
        var roadName: String?
    }

    /// Rich topology snapshot of the bound route, computed once per tick
    /// from the user's current position projected onto the route polyline.
    /// Lets the AI coach answer "what's coming up?" precisely — not just
    /// "a climb soon" but "three climbs left, biggest is 8 % grade in
    /// 1.6 km, peak elevation 410 m at the 70 % mark." Nil when no route
    /// is bound.
    struct RouteTopology: Equatable {
        /// Up to the next 5 climbs ahead, ordered by distance. First entry
        /// duplicates `upcomingClimb` for backwards-compat with code that
        /// only consumes the next one.
        let climbsAhead: [UpcomingClimb]
        /// Sum of all remaining climbs' gain in meters. The "how much
        /// uphill is left" answer.
        let totalAscentRemainingMeters: Double
        /// Peak altitude (meters) anywhere on the route. Static across
        /// the workout — bound at recognition time.
        let peakAltitudeMeters: Double
        /// User's current altitude relative to the route's lowest point.
        /// Lets the AI say "you're 80 m above the lowest point of the
        /// route" without the user having to do mental math on raw GPS.
        let altitudeAboveRouteMinMeters: Double
        /// Steepest sustained grade in the climbs queue ahead. nil when
        /// no climbs remain.
        let steepestGradeAheadPercent: Double?
        /// Distance to the route's peak altitude point, meters. Negative
        /// means the peak is behind us.
        let metersToPeak: Double
        /// Upcoming turns. Cap 5. Computed from the route
        /// trackpoint polyline by walking ahead from the user's current
        /// projected position and flagging points where bearing changes
        /// by ≥30° within a ~30 m window. Lets the AI say "turn right
        /// in 200 m" pre-emptively. Nil-safe; empty when route is
        /// straight or only has gentle bends.
        var turnsAhead: [UpcomingTurn] = []
    }

    /// A meaningful direction change ahead on the bound route. Detected
    /// from the polyline by sliding-window bearing comparison: if the
    /// bearing shifts by ≥30° between two ~15 m segments, it counts.
    /// 90° = right turn, 60° = right-soft, 120° = right-hard. Negative
    /// = left.
    struct UpcomingTurn: Equatable {
        /// Distance from the user's CURRENT projected position to the
        /// turn point, meters. Always positive (turns behind aren't
        /// included).
        let distanceMeters: Double
        /// Signed bearing change, degrees. Positive = right turn,
        /// negative = left turn. Range typically ±150°.
        let bearingChangeDegrees: Double
        /// Compact human-readable label: "right", "left", "soft right",
        /// "soft left", "hard right", "hard left", "U-turn".
        let direction: String
    }

    // Custom Equatable — LiveDFAAnalyzer.Status isn't automatically Equatable
    // (case with TimeInterval payload); we get there by explicit enumeration.
    // Making the whole struct synthesise would require Status to be Equatable,
    // which it is. So the default synthesis works.

    /// Factored for easy serialisation into an LLM system-prompt preamble.
    ///
    /// Note: we expose BOTH `peakHR` (session high-water) and `userMaxHR`
    /// (physiological ceiling) and explicitly tell the model which denominator
    /// to use for zones. Without this, the model would divide current HR by
    /// session peak — producing "Zone 5 at 100 bpm" when the user was standing
    /// still. Also emits a pre-computed `zone=` line so the model doesn't have
    /// to reimplement the math (and potentially disagree with the UI).
    ///
    /// Distance and pace are formatted using the user's unit preference so
    /// the AI doesn't read metric numbers out to an imperial user.
    /// Serializer: one `if let` per optional field on the fact sheet. The branch
    /// count IS the field count — splitting it would not reduce complexity, only
    /// relocate it.
    func asFactSheet() -> String {
        let sections = [
            identityLines(),
            heartRateLines(),
            alpha1Lines(),
            motionLines(),
            terrainLines(),
            equipmentLines(),
            targetLines(),
            liveTrendLines(),
            historicalBaselineLines(),
            readinessLines(),
            timeInZoneLines(),
            racePredictionLines()
        ]
        return sections.flatMap { $0 }.joined(separator: "\n")
    }

    /// Fact-sheet section: Identity / time.
    private func identityLines() -> [String] {
        var out: [String] = []
        out.append("sport=\(sport.rawValue)")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        out.append("nowAt=\(iso.string(from: nowAt))")
        out.append("sessionStart=\(iso.string(from: sessionStart))")
        out.append("elapsedSec=\(elapsedSeconds)")
        out.append("userUnits=\(userUnits.rawValue)")
        return out
    }

    /// Fact-sheet section: HR.
    ///
    /// Includes session-average HR: without it voice users asking
    /// "what's my average HR" got nothing back even though the buffer
    /// existed in WorkoutRecorder. Computed in buildContext() and
    /// surfaced here.
    private func heartRateLines() -> [String] {
        var out: [String] = []
        if let hr = heartRate { out.append("currentHR=\(hr)") }
        out.append("sessionPeakHR=\(peakHR)")
        if let avg = sessionAverageHR { out.append(String(format: "sessionAverageHR=%.0f", avg)) }
        out.append("userMaxHR=\(userMaxHR)")
        if let hr = heartRate, userMaxHR > 0 {
            out.append("percentOfMaxHR=\(Int((Double(hr) / Double(userMaxHR)) * 100.0))")
            out.append("zone=\(HRZone.classify(hr: hr, userMaxHR: userMaxHR)?.label ?? "below_z1")")
        }
        if let drift = hrDriftPercent { out.append(String(format: "hrDriftPercent=%.1f", drift)) }
        return out
    }

    /// Fact-sheet section: α1 (with diagnostic status).
    private func alpha1Lines() -> [String] {
        var out: [String] = []
        if let alpha1 {
            out.append(String(format: "alpha1=%.2f", alpha1))
        }
        out.append("band=\(band.label)")
        out.append("alpha1Status=\(alpha1Status.label)")
        if let q = alpha1FitQuality {
            out.append(String(format: "alpha1FitR2=%.2f", q))
        }
        return out
    }

    /// Fact-sheet section: Motion, formatted per user units.
    private func motionLines() -> [String] {
        var out: [String] = []
        if distanceMeters > 0 {
            out.append("distance=\(userUnits.formatDistance(meters: distanceMeters))")
            out.append(String(format: "distanceM=%.0f", distanceMeters))
        }
        if let pace = currentPaceSecPerKm, pace > 0 {
            out.append(String(format: "paceSecPerKm=%.0f", pace))
            if let formatted = userUnits.formatPace(secondsPerMeter: pace / 1_000) {
                out.append("paceFormatted=\(formatted)")
            }
        }
        if let speed = currentSpeedMS, speed > 0 { out.append(String(format: "speedMS=%.2f", speed)) }
        out += cadenceAndPowerLines()
        if let mets = currentMETs { out.append(String(format: "currentMETs=%.1f", mets)) }
        return out + splitPaceLines()
    }

    /// The three most recent split paces, raw and unit-formatted.
    private func splitPaceLines() -> [String] {
        var out: [String] = []
        for (i, split) in recentSplitPaces.prefix(3).enumerated() {
            out.append(String(format: "splitMinus%dSecPerKm=%.0f", i, split))
            if let formatted = userUnits.formatPace(secondsPerMeter: split / 1_000) {
                out.append("splitMinus\(i)Formatted=\(formatted)")
            }
        }
        return out
    }

    /// Cadence + power: the AI needs to know not just the value but
    /// whether the data path exists. When a foot pod is connected we
    /// ALWAYS emit a line — value when present, "silent" when the
    /// BLE packet hasn't arrived this tick. Without that, every BLE
    /// gap looked indistinguishable to the AI from "no foot pod
    /// paired", which surfaced as the user's "foot pod data not
    /// reaching the AI" complaint (item #5).
    private func cadenceAndPowerLines() -> [String] {
        var out = ["footPodConnected=\(footPodActive)"]
        if let cad = cadenceStepsPerMin, cad > 0 {
            out.append(String(format: "cadenceSpm=%.0f", cad))
        } else if footPodActive {
            out.append("cadenceSpm=silent")
        }
        if let watts = powerWatts, watts > 0 {
            out.append("powerW=\(watts)")
        } else if footPodActive {
            out.append("powerW=silent")
        }
        return out
    }

    /// Fact-sheet section: Map / terrain.
    private func terrainLines() -> [String] {
        addressLines() + terrainGeometryLines()
    }

    /// Emit the RESOLVED address first so the voice
    /// AI reads "you're on Riverwood Dr in Nashville" instead of
    /// raw coords. Falls back to lat/lon (in `terrainGeometryLines`)
    /// when the geocoder hasn't populated yet — the first ~5 s of a
    /// workout, or when offline.
    private func addressLines() -> [String] {
        [
            currentRoadName.map { "currentRoadName=\($0)" },
            currentLocality.map { "currentLocality=\($0)" },
            currentAdministrativeArea.map { "currentAdministrativeArea=\($0)" },
            currentCountryCode.map { "currentCountryCode=\($0)" },
            currentCompactAddress.flatMap { $0.isEmpty ? nil : "currentCompactAddress=\($0)" },
            currentNearestCrossStreet.map { "currentNearestCrossStreet=\($0)" },
            currentNearestIntersection.map { "currentNearestIntersection=\($0)" }
        ].compactMap { $0 }
    }

    /// Position, heading, and the shape of the ground under and ahead of the
    /// user — the half of the terrain section that isn't a place name.
    private func terrainGeometryLines() -> [String] {
        var out: [String] = []
        if let lat = currentLatitude, let lon = currentLongitude {
            out.append(contentsOf: [String(format: "gpsLat=%.6f", lat), String(format: "gpsLon=%.6f", lon)])
        }
        if let alt = currentAltitudeMeters {
            out.append("altitude=\(userUnits.formatElevation(meters: alt))")
        }
        if let heading = currentHeadingDegrees {
            out.append(String(format: "headingDeg=%.0f", heading))
            out.append("headingCardinal=\(Self.compassCardinal(degrees: heading))")
        }
        if let acc = gpsAccuracyMeters { out.append(String(format: "gpsAccuracyM=%.0f", acc)) }
        if elevationGainMeters > 0 {
            out.append("elevationGain=\(userUnits.formatElevation(meters: elevationGainMeters))")
        }
        if let grade = currentGradePercent { out.append(String(format: "currentGradePercent=%.1f", grade)) }
        if let climb = upcomingClimb {
            out.append(String(format: "upcomingClimbM=%.0f@%.1fpct", climb.distanceMeters, climb.gradePercent))
        }
        return out
    }

    /// Fact-sheet section: Equipment.
    private func equipmentLines() -> [String] {
        var out: [String] = []
        out.append("strapConnected=\(strapConnected)")
        if let silent = strapSilentSec {
            out.append(String(format: "strapSilentSec=%.0f", silent))
        }
        return out
    }

    /// Fact-sheet section: Target.
    private func targetLines() -> [String] {
        var out: [String] = []
        if let tz = targetZone { out.append("targetZone=Zone\(tz)") }
        return out
    }

    /// Fact-sheet section: Live trend deltas (mid-workout self-comparison).
    private func liveTrendLines() -> [String] {
        var out = [
            reverseSplitDeltaSecPerKm.map { String(format: "reverseSplitDeltaSecPerKm=%+.0f", $0) },
            liveHRDriftPercent.map { String(format: "liveHRDriftPercent=%+.1f", $0) },
            aerobicDecouplingPercent.map { String(format: "aerobicDecouplingPercent=%+.1f", $0) },
            cadenceDriftSpm.map { String(format: "cadenceDriftSpm=%+.1f", $0) }
        ].compactMap { $0 }
        if let gap = gradeAdjustedPaceSecPerKm {
            out.append(String(format: "gradeAdjustedPaceSecPerKm=%.0f", gap))
            if let formatted = userUnits.formatPace(secondsPerMeter: gap / 1_000) {
                out.append("gradeAdjustedPaceFormatted=\(formatted)")
            }
        }
        for (i, p) in recentSplitGradeAdjustedPaces.prefix(3).enumerated() {
            out.append(String(format: "splitMinus%dGradeAdjustedSecPerKm=%.0f", i, p))
        }
        if let fade = projectedMinutesUntilFade {
            out.append(String(format: "projectedMinutesUntilFade=%.0f", fade))
        }
        return out
    }

    /// Fact-sheet section: Historical sport baselines (cross-workout).
    private func historicalBaselineLines() -> [String] {
        guard historicalSportSampleCount > 0 else { return [] }
        var out = ["historicalSportSampleCount=\(historicalSportSampleCount)"]
        out.append(contentsOf: historicalPaceLines())
        if let h = historicalSportAvgHR { out.append(String(format: "historicalSportAvgHR=%.0f", h)) }
        if let a = historicalSportAvgAlpha1 { out.append(String(format: "historicalSportAvgAlpha1=%.2f", a)) }
        return out
    }

    /// Raw seconds/km plus the user-unit rendering, so the model can quote
    /// either without converting.
    private func historicalPaceLines() -> [String] {
        guard let p = historicalSportAvgPaceSecPerKm else { return [] }
        var out = [String(format: "historicalSportAvgPaceSecPerKm=%.0f", p)]
        if let formatted = userUnits.formatPace(secondsPerMeter: p / 1_000) {
            out.append("historicalSportAvgPaceFormatted=\(formatted)")
        }
        return out
    }

    /// Fact-sheet section: Today's readiness / training-load context.
    private func readinessLines() -> [String] {
        var out: [String] = []
        if let r = todayRecoveryScore {
            out.append(String(format: "todayRecoveryScore=%.0f", r))
        }
        if let r = todayTrainingReadiness {
            out.append(String(format: "todayTrainingReadiness=%.0f", r))
        }
        if let a = todayATL { out.append(String(format: "todayATL=%.1f", a)) }
        if let c = todayCTL { out.append(String(format: "todayCTL=%.1f", c)) }
        if let t = todayTSB { out.append(String(format: "todayTSB=%+.1f", t)) }
        if let d = projectedDaysUntilFresh {
            out.append("projectedDaysUntilFresh=\(d)")
        }
        if let tsb = projectedTSBTomorrowSteadyState {
            out.append(String(format: "projectedTSBTomorrowSteadyState=%+.1f", tsb))
        }
        if let h = recoveryHoursNeeded {
            out.append(String(format: "recoveryHoursNeeded=%.0f", h))
        }
        return out
    }

    /// Fact-sheet section: Time-in-zone (live, Karvonen).
    private func timeInZoneLines() -> [String] {
        var out: [String] = []
        let totalZoneSec = zone1Sec + zone2Sec + zone3Sec + zone4Sec + zone5Sec
        if totalZoneSec > 0 {
            out.append("zone1Sec=\(zone1Sec)")
            out.append("zone2Sec=\(zone2Sec)")
            out.append("zone3Sec=\(zone3Sec)")
            out.append("zone4Sec=\(zone4Sec)")
            out.append("zone5Sec=\(zone5Sec)")
            if let dom = dominantZone {
                out.append("dominantZone=Z\(dom)")
            }
        }
        return out
    }

    /// Fact-sheet section: Race-time predictions (Riegel).
    private func racePredictionLines() -> [String] {
        var out: [String] = []
        if let s = predictedRaceTime5KSec {
            out.append(String(format: "predictedRaceTime5KSec=%.0f", s))
        }
        if let s = predictedRaceTime10KSec {
            out.append(String(format: "predictedRaceTime10KSec=%.0f", s))
        }
        if let s = predictedRaceTimeHalfSec {
            out.append(String(format: "predictedRaceTimeHalfMarathonSec=%.0f", s))
        }
        if let s = predictedRaceTimeMarathonSec {
            out.append(String(format: "predictedRaceTimeMarathonSec=%.0f", s))
        }
        return out
    }

    /// Crude 8-way compass cardinal from a degrees-true heading. Makes the
    /// coach context read like a person ("heading north-east") rather than
    /// a number ("45°").
    private static func compassCardinal(degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let idx = Int(((normalized + 22.5) / 45.0).rounded(.down)) % 8
        return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][idx]
    }
}
