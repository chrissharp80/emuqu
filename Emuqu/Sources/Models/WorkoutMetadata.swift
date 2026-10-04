import Foundation
import HealthKit

// MARK: - Sport

/// Curated list of supported workout activities. We intentionally start small
/// and add more as demand surfaces rather than shipping a custom-activity
/// builder on day one.
enum Sport: String, Codable, CaseIterable, Identifiable {
    case run
    case trailRun = "trail_run"
    case walk
    case hike
    case bike
    case indoorBike = "indoor_bike"
    case treadmill
    /// Indoor rowing on a Concept2 PM5 (or any FTMS rower). Distance,
    /// stroke rate, watts, and drag factor come from the rower itself
    /// over BLE — GPS, motion, and pedometer sources are inappropriate
    /// (you're stationary). The rower's watts are recorded, but there is no
    /// rowing FTP, so no power-TSS: training load comes from heart rate.
    case row
    /// Air / assault bike. Indoor, interval-based conditioning. No BLE power
    /// meter here and not a steady-state endurance effort, so it's treated as
    /// a non-power sport (no FTP, no power-TSS). Strap HR only.
    case airBike = "air_bike"
    /// CrossFit / functional-fitness WOD. Indoor, interval-based, no pace or
    /// power meter — strap HR only, non-power sport.
    case crossFit = "crossfit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run: "Run"
        case .trailRun: "Trail Run"
        case .walk: "Walk"
        case .hike: "Hike"
        case .bike: "Ride"
        case .indoorBike: "Indoor Ride"
        case .treadmill: "Treadmill"
        case .row: "Row"
        case .airBike: "Air Bike"
        case .crossFit: "CrossFit"
        }
    }

    /// The sport's name in the app's language, for the screen and the spoken
    /// start cue. `displayName` stays English for the assistant, exports and
    /// logs; shown as-is it was English in every language.
    var localizedName: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .run: String(localized: "Run", bundle: b)
        case .trailRun: String(localized: "Trail Run", bundle: b)
        case .walk: String(localized: "Walk", bundle: b)
        case .hike: String(localized: "Hike", bundle: b)
        case .bike: String(localized: "Ride", bundle: b)
        case .indoorBike: String(localized: "Indoor Ride", bundle: b)
        case .treadmill: String(localized: "Treadmill", bundle: b)
        case .row: String(localized: "Row", bundle: b)
        case .airBike: String(localized: "Air Bike", bundle: b)
        case .crossFit: String(localized: "CrossFit", bundle: b)
        }
    }

    var icon: String {
        switch self {
        case .run: "figure.run"
        case .trailRun: "figure.hiking"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .bike: "bicycle"
        case .indoorBike: "figure.indoor.cycle"
        case .treadmill: "figure.run"
        case .row: "figure.rower"
        case .airBike: "figure.mixed.cardio"
        case .crossFit: "figure.strengthtraining.functional"
        }
    }

    /// Whether this sport benefits from GPS tracking.
    var usesGPS: Bool {
        switch self {
        case .run, .trailRun, .walk, .hike, .bike: true
        case .indoorBike, .treadmill, .row, .airBike, .crossFit: false
        }
    }
}

// MARK: - Split

/// A split is a fixed-distance segment (typically 1 km or 1 mi) auto-emitted
/// during a GPS workout. Indoor sessions have no splits.
struct Split: Codable, Equatable {
    let index: Int                      // 1-based
    let distanceMeters: Double
    let durationSeconds: Double
    let averageHR: Double?
    let averagePaceSecPerKm: Double?
    let elevationGainMeters: Double?
    /// Avg α1 over the split window. `nil` for splits
    /// computed before this field was added (older sessions decode to
    /// `nil` via `decodeIfPresent` semantics) or for splits where no
    /// usable α1 samples landed in the window. The summary view shows
    /// the column only when the value is present.
    var averageAlpha1: Double?
}

// MARK: - Lap

/// A lap is a user- or interval-triggered segment (not distance-based).
struct Lap: Codable, Equatable {
    let index: Int
    let startOffsetSec: Double          // from session start
    let endOffsetSec: Double
    let distanceMeters: Double?
    let averageHR: Double?
    let maxHR: Double?
    let averagePaceSecPerKm: Double?
}

// MARK: - Live Marker

/// A timestamped marker placed during recording. Captures interval transitions,
/// hill crests, user taps, sensor disconnects — anything worth surfacing on the
/// post-session timeline.
struct LiveMarker: Codable, Equatable {
    enum Kind: String, Codable {
        case userFlag
        case intervalStart
        case intervalEnd
        case hillTop
        case strapDisconnect
        case strapReconnect
        case autoPause
        case autoResume
    }

    let kind: Kind
    let offsetSec: Double
    let note: String?
}

// MARK: - Per-tick Sample
//
// Captured once per UI tick (~1 Hz) during recording so the post-summary can
// draw actual charts (HR over time, pace over time, cadence over time) instead
// of relying on aggregates. We keep it simple: sparse optional fields, one
// row per second. A 60-minute workout is 3600 rows — a few hundred KB at
// most after zlib compression, well worth the explainability.
struct WorkoutSample: Codable, Equatable {
    /// Seconds since session start.
    let offsetSec: Int
    /// Smoothed HR (bpm). Nil when the strap was silent at this tick.
    let heartRate: Int?
    /// Cumulative distance in meters at this tick. Reflects max(GPS,
    /// pedometer, foot-pod) so indoor sports without GPS still get a curve.
    let distanceMeters: Double?
    /// Instantaneous pace in seconds per kilometer. Nil when speed too low
    /// to be meaningful (we'd get 40-minute-mile artifacts otherwise).
    let paceSecPerKm: Double?
    /// Live cadence. Foot-pod reading if connected, else pedometer. Nil for
    /// bike sports.
    let cadenceStepsPerMin: Double?
    /// Altitude in meters (if GPS was contributing).
    let altitudeMeters: Double?
    /// DFA α1 at this tick — informative for post-session physiology charts.
    let alpha1: Double?
    /// METs at this tick — derived from speed + grade + sport as a rough
    /// energy-expenditure proxy. "Rough" because we don't have a treadmill
    /// integration or power meter input; METs from heart rate alone would
    /// require a user VO2max and is less reliable.
    let mets: Double?
    /// Instantaneous power in watts from a connected foot-pod / running
    /// power meter (Stryd). Nil when no power-capable pod is active.
    let powerWatts: Int?

    /// A copy with α1 replaced. Used by the post-session re-analyzer, which
    /// recomputes α1 from the raw RR series and leaves every other field alone.
    func withAlpha1(_ alpha1: Double?) -> WorkoutSample {
        WorkoutSample(
            offsetSec: offsetSec,
            heartRate: heartRate,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            cadenceStepsPerMin: cadenceStepsPerMin,
            altitudeMeters: altitudeMeters,
            alpha1: alpha1,
            mets: mets,
            powerWatts: powerWatts
        )
    }

    /// A copy with `heartRate` replaced. Used by the finalize-time wrist-HR
    /// backfill, which splices Apple Watch HR into ticks where the strap was
    /// silent and leaves every other field alone.
    func withHeartRate(_ heartRate: Int?) -> WorkoutSample {
        WorkoutSample(
            offsetSec: offsetSec,
            heartRate: heartRate,
            distanceMeters: distanceMeters,
            paceSecPerKm: paceSecPerKm,
            cadenceStepsPerMin: cadenceStepsPerMin,
            altitudeMeters: altitudeMeters,
            alpha1: alpha1,
            mets: mets,
            powerWatts: powerWatts
        )
    }

    // Custom decode so older sessions (before powerWatts existed) don't fail
    // to deserialize. Every other field is required from day one.
    enum CodingKeys: String, CodingKey {
        case offsetSec, heartRate, distanceMeters, paceSecPerKm
        case cadenceStepsPerMin, altitudeMeters, alpha1, mets, powerWatts
    }

    init(
        offsetSec: Int,
        heartRate: Int? = nil,
        distanceMeters: Double? = nil,
        paceSecPerKm: Double? = nil,
        cadenceStepsPerMin: Double? = nil,
        altitudeMeters: Double? = nil,
        alpha1: Double? = nil,
        mets: Double? = nil,
        powerWatts: Int? = nil
    ) {
        self.offsetSec = offsetSec
        self.heartRate = heartRate
        self.distanceMeters = distanceMeters
        self.paceSecPerKm = paceSecPerKm
        self.cadenceStepsPerMin = cadenceStepsPerMin
        self.altitudeMeters = altitudeMeters
        self.alpha1 = alpha1
        self.mets = mets
        self.powerWatts = powerWatts
    }

    // spec:long-function A Codable decoder cannot be decomposed in Swift:
    // every stored property must be initialized before any method on `self`
    // may be called, so a `private mutating func decodeX(...)` helper is
    // rejected outright, and `let` properties can only be assigned by `init`.
    // The alternatives are defaulting every property in its declaration (which
    // turns a missing assignment from a compile error into a silent nil) or
    // restructuring the on-disk JSON (a data migration, for a formatting rule).
    // Body is one assignment per field, in the same order as the encoder.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offsetSec = try c.decode(Int.self, forKey: .offsetSec)
        heartRate = try c.decodeIfPresent(Int.self, forKey: .heartRate)
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        paceSecPerKm = try c.decodeIfPresent(Double.self, forKey: .paceSecPerKm)
        cadenceStepsPerMin = try c.decodeIfPresent(Double.self, forKey: .cadenceStepsPerMin)
        altitudeMeters = try c.decodeIfPresent(Double.self, forKey: .altitudeMeters)
        alpha1 = try c.decodeIfPresent(Double.self, forKey: .alpha1)
        mets = try c.decodeIfPresent(Double.self, forKey: .mets)
        powerWatts = try c.decodeIfPresent(Int.self, forKey: .powerWatts)
    }
}

// MARK: - HRR Sample

/// Heart-rate recovery sample captured in the minutes after a session ends.
/// Tagged with provenance so UI and analysis can trust strap-derived values
/// above Watch-derived or Apple-computed values when merging.
struct HRRSample: Codable, Equatable {
    enum Provenance: String, Codable {
        case strap              // Computed from Polar RR stream
        case watchSamples       // Computed from HealthKit HR samples (typically Apple Watch)
        case healthKitComputed  // Read directly from HKQuantityTypeIdentifier.heartRateRecoveryOneMinute
    }

    /// Seconds after the user tapped Stop.
    let offsetSec: Int
    /// Heart rate at the sample point (bpm).
    let hr: Int
    /// Drop from peak HR to this sample (bpm). Negative if HR hasn't fallen.
    let drop: Int
    /// Peak HR used as the reference for `drop`.
    let peakHR: Int
    let provenance: Provenance
}

// MARK: - Workout Metadata

/// All workout-specific data attached to an HRVSession whose sessionType is
/// `.workout`. Non-workout sessions leave this nil.
///
/// Design note: workouts reuse the HRVSession container (RRSeries, archive,
/// CloudKit sync, baseline tracking). This struct holds only the
/// workout-flavoured extras — motion, geography, splits, HRR, and the few
/// workout-specific computed metrics that aren't already part of
/// HRVAnalysisResult.
struct WorkoutMetadata: Codable, Equatable {
    static let currentSchemaVersion = 1

    let sport: Sport

    // MARK: Motion / geography
    /// zlib-compressed encoded polyline of the GPS track (nil for indoor sessions
    /// or sessions where the user denied location permission).
    var gpsPolyline: Data?
    /// Total distance covered in meters (GPS-derived, treadmill pedometer, or
    /// indoor-bike trainer).
    var distanceMeters: Double?
    /// Total elevation gain in meters.
    var elevationGainMeters: Double?
    var elevationLossMeters: Double?

    // MARK: Segmented timeline
    var splits: [Split]?
    var laps: [Lap]?
    var liveMarkers: [LiveMarker]?

    // MARK: Per-tick time series
    /// Per-second samples of HR, pace, cadence, altitude, α1, METs. Drives
    /// the post-workout charts and the per-row CSV/TCX export columns.
    /// Optional: older sessions (before this field existed) simply don't have
    /// a time series and charts degrade to showing only aggregates.
    var samples: [WorkoutSample]?

    // MARK: Post-session physiology
    /// Heart-rate recovery samples captured opportunistically in the post-stop
    /// window. Tier fallback: strap > Watch > HealthKit-computed. Absence is OK.
    var hrrSamples: [HRRSample]?

    /// Aerobic decoupling (Pa:Hr) as a percentage. Difference between
    /// first-half and second-half efficiency (pace / HR). Values above ~5%
    /// suggest cardiac drift or efficiency loss mid-session.
    var decouplingPercent: Double?

    /// Efficiency Factor (normalized pace ÷ average HR) for this session.
    var efficiencyFactor: Double?

    /// Lucia TRIMP keyed to the user's HRVT-derived thresholds when available,
    /// otherwise falls back to %HRmax zones.
    var luciaTRIMP: Double?

    /// Heart-rate Training Stress Score (TrainingPeaks convention).
    var hrTSS: Double?

    // MARK: Pre-computed analysis snapshot
    //
    // Persistable, once-computed derivations of the session's raw
    // sample stream. Stored here so every summary render reads cached
    // fields instead of re-iterating thousands of samples per SwiftUI
    // body pass. Populated at `WorkoutRecorder.finalizeSession()`; for
    // pre-fix sessions it computes on first summary open and writes
    // back. `nil` means "not yet computed."
    var analysisSnapshot: WorkoutAnalysisSnapshot?

    // MARK: Partial / recovered session

    /// Why the session ended without a clean Stop tap. Set only when
    /// the workout was reconstructed by the launch-time recovery path
    /// from on-disk backups. `nil` for normal, completed workouts.
    /// The summary UI renders an "Estimated — partial data" badge
    /// when this is non-nil, and the dashboard distinguishes recovered
    /// sessions from clean ones in totals.
    var partialDataReason: PartialDataReason?

    /// When the recovery ran. Surfaces in the summary as
    /// "Restored from backup at …" so the user can correlate with
    /// what they remember from the interrupted workout.
    var recoveredAt: Date?

    /// TRIMP extrapolated from prior sessions on the same saved route
    /// when the recorded HR doesn't cover the full distance. Always
    /// rendered alongside `luciaTRIMP` so the user sees the recorded value
    /// AND the route-extrapolated estimate. It becomes the workout's load
    /// only when `routeEstimateReplacesHRLoad` says the recorded HR load is
    /// a strap dropout (see `preferredTrainingLoad`).
    var extrapolatedTRIMP: Double?

    /// Confidence in the route-based extrapolation, 0..1. Function of
    /// (a) how many prior sessions matched the route and (b) how
    /// consistent their TRIMP/distance ratio was. Surfaced in the UI
    /// as a quality hint ("based on 3 prior runs of this route") so
    /// the user can judge whether to trust the estimate.
    var extrapolationConfidence: Double?

    /// Display name of the saved route used for extrapolation, copied
    /// here so the summary doesn't need to re-resolve the route ID
    /// against `SavedRouteStore` on every render.
    var extrapolationRouteName: String?

    /// Name of the saved-library route this workout was
    /// bound to at start (auto-recognized OR user-loaded). Distinct
    /// from `extrapolationRouteName` (which is set only when TRIMP is
    /// extrapolated from prior data); this is set on EVERY clean
    /// workout that ran on a recognized route, so per-route history
    /// queries can reliably filter past sessions for "the same loop."
    /// Nil for unbound / one-off GPX runs.
    var recognizedRouteName: String?

    // MARK: Environment (heat acclimatization)

    /// Weather at the session, captured at finalize from the live
    /// `WeatherService` snapshot. Persisted so the heat-acclimatization model
    /// can replay each workout's heat exposure over time; a workout with no
    /// snapshot is left out of heat load. Nil for indoor sessions, older
    /// sessions, or when no weather fix was available.
    var weatherSnapshot: WorkoutWeatherSnapshot?

    // MARK: Subjective — "how did that feel?"

    /// 1-5 subjective workout-feeling rating the user submitted from the
    /// post-workout summary. Parallel to `HRVSession.morningFeeling` —
    /// captured separately so the subjective signal never contaminates
    /// the objective metrics (TRIMP, HRR, α1, etc.). Empty until the
    /// user picks one; `nil` means "not asked yet". Editable.
    ///
    /// Scale:
    ///   1 = Terrible (couldn't finish / injury flare / felt awful)
    ///   2 = Hard (struggled more than effort warranted)
    ///   3 = OK (expected level of effort, no red flags)
    ///   4 = Good (felt strong, executed well)
    ///   5 = Great (PR-worthy / best-in-recent-memory feel)
    var workoutFeeling: Int?

    /// Optional free-text note the user can attach ("heavy legs from
    /// yesterday," "fuelled well," etc.). Separate from the 1-5 to
    /// keep the rating clean for trend aggregation.
    var workoutFeelingNote: String?

    // MARK: Running power (from foot pod / Stryd)

    /// Average power in watts across the session when a power-capable foot pod
    /// was connected. Nil if no power data was captured.
    var averagePowerWatts: Double?
    /// Normalized power — 4th-root-mean-4th-power smoothing over 30 s windows.
    /// Standard TrainingPeaks convention; better reflects physiological stress
    /// than simple average when power varies (intervals, hills).
    var normalizedPowerWatts: Double?
    /// Maximum instantaneous power observed during the session.
    var peakPowerWatts: Int?

    /// Power-based Training Stress Score, computed only when an FTP anchor
    /// exists for this sport (running FTP for run/walk/hike, cycling FTP for
    /// bike sports). Formula: TSS = (NP/FTP)² × duration_hours × 100.
    /// Reference: Coggan, TrainingPeaks "Performance Manager" model.
    var powerTSS: Double?

    /// Intensity Factor — NP / FTP. 1.00 = right at threshold for the
    /// session's duration; > 1.05 sustained is unsustainable; < 0.75 is
    /// recovery / endurance.
    var intensityFactor: Double?

    /// Variability Index — NP / Avg Power. 1.00 = perfectly steady (TT,
    /// flat course); > 1.10 means the effort had real surges (intervals,
    /// rolling terrain). Together with NP this distinguishes "I held 240 W
    /// flat" from "I averaged 240 W with peaks at 600 W".
    var variabilityIndex: Double?

    /// FTP value in watts that was used to compute powerTSS / IF. Persisted
    /// alongside the metric so future analysis is auditable — if the user
    /// later updates their FTP, historical sessions still show the IF that
    /// reflected their fitness AT that time.
    var ftpAtTimeOfSession: Int?

    // MARK: - Preferred training load (cross-source resolver)
    //
    // Published research (TrainingPeaks, Stryd RSS, Coggan)
    // is consistent: power-based TSS is significantly more accurate than
    // HR-based TSS for variable-intensity work because HR lags and
    // undercounts surges. When a power meter contributed to the session,
    // powerTSS is the canonical load number — not a fallback. This
    // resolver makes that the rule across the app: display tiles, the
    // recent-workouts list, the AI coach, and load-trajectory rows all
    // pick the best available source through the same property.
    //
    // Scale note: powerTSS and hrTSS are both calibrated so 100 = one
    // hour at threshold, so they're directly substitutable. luciaTRIMP
    // is on Banister's HRR-coefficient scale and ranks numerically
    // lower — only used as a last-resort fallback for legacy sessions
    // recorded before LTHR was set. extrapolatedTRIMP comes from
    // `RouteTRIMPEstimator` and is on TRIMP scale too; it's the
    // partial-data backup for HR-dropout sessions.
    enum TrainingLoadSource: String {
        /// Coggan power-based TSS. Best available; HR-independent.
        case power
        /// HR-based TSS (HRSS formulation). Solid for steady efforts.
        case hr
        /// Metabolic-equivalent-of-task load derived from
        /// the workout's per-sample `mets` curve (which itself comes
        /// from sport × pace × grade). Works on any workout that has
        /// GPS or foot-pod pace — no HR, no power, no saved route
        /// required. Computed at read time from already-stored sample
        /// data, so historical workouts fix themselves without a
        /// migration.
        case mets
        /// Banister Lucia TRIMP. Older scale, last-resort.
        case banister
        /// Route-history extrapolation when HR was lost mid-workout.
        case routeHistory

        /// Canonical short label for the value this source produces.
        /// Power/HR/METs load is on the TSS scale → "LOAD"; only the
        /// Banister/route-history fallbacks are on the TRIMP scale → "TRIMP".
        /// Single source of truth for the label so
        /// no display can print an effective-load value under the wrong name
        /// (the "TRIMP 94 here / 111 TRIMP there" split for the same workout).
        var displayLabel: String {
            switch self {
            case .power, .hr, .mets: String(localized: "LOAD", bundle: LanguageManager.appBundle)
            case .banister, .routeHistory: String(localized: "TRIMP", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// METs-based load on the same TSS scale (100 = 1 h
    /// at threshold). Sum METs × dt across the sample stream to get
    /// MET-hours, then normalize against a 12-MET threshold anchor
    /// (Friel / ACSM convention for lactate-threshold metabolic rate
    /// in a fit endurance athlete). The math is honest on its scale:
    ///   • 1 hr steady walk at 4 METs → 33 (matches "easy aerobic")
    ///   • 30 min hard run at 14 METs → 58 (matches "tempo")
    ///   • 1 hr threshold ride at 12 METs → 100 (anchor)
    ///
    /// Why this is a sensible fallback above luciaTRIMP for HR-missing
    /// sessions: it uses real captured physical motion (pace + grade)
    /// rather than a synthesized HR. For the user's daily walk where
    /// the strap dropped, this returns ~30–40 instead of 1.
    ///
    /// Uses the richest path the data supports: the per-sample stream, else
    /// one bucket from distance and duration. The bucket's duration comes
    /// from the per-second samples, so a session with a distance but no
    /// samples returns nil, as does one with no usable motion data at all.
    var computedMETLoad: Double? {
        perSampleMETLoad() ?? bucketMETLoad()
    }

    /// Path A — per-sample integration. Most accurate; uses every pace+grade
    /// tick. Skipped when the stream is too sparse or all-nil, and abandoned
    /// unless at least a quarter of the samples carried a usable METs reading —
    /// below that the foot pod / GPS usually stopped reporting pace partway
    /// through, and integrating would dramatically underestimate the real effort.
    private func perSampleMETLoad() -> Double? {
        guard let samples, samples.count >= 30 else { return nil }
        let sorted = samples.sorted { $0.offsetSec < $1.offsetSec }
        var metHours = 0.0
        var validRows = 0
        for i in 0 ..< sorted.count {
            guard let mets = sorted[i].mets, mets > 0 else { continue }
            metHours += mets * Self.sampleSeconds(sorted, at: i) / 3600.0
            validRows += 1
        }
        guard validRows * 4 >= sorted.count, metHours > 0.01 else { return nil }
        return loadFromMETHours(metHours)
    }

    /// How long the sample at `i` represents. Capped at 30 s — anything longer
    /// is a real recording gap (pause, GPS dropout) and we shouldn't claim the
    /// user was working at the prior MET level through it.
    private static func sampleSeconds(_ sorted: [WorkoutSample], at i: Int) -> Double {
        guard i + 1 < sorted.count else { return 1.0 }
        let gap = sorted[i + 1].offsetSec - sorted[i].offsetSec
        return min(30.0, max(1.0, Double(gap)))
    }

    /// Path B — single-bucket fallback. Uses just total distance, total
    /// duration, and sport. EVERY workout has these even when per-sample pace
    /// samples are absent — so a walk where GPS dropped or the Stryd didn't
    /// carry per-second pace STILL gets a sensible load number here.
    ///
    /// This is the path that keeps strap-dropped daily
    /// walks from landing at "1 TRIMP" when every other tier returns nil.
    /// Coarse but honest: the formula is the same one each per-sample MET uses,
    /// just bucketed once over the whole session.
    private func bucketMETLoad() -> Double? {
        guard let distance = distanceMeters, distance > 50,
              let avgKmh = averageKmh(),
              let bucketMETs = WorkoutRecorder.estimateMETs(
                  sport: sport,
                  paceSecPerKm: 3600.0 / avgKmh,
                  heartRate: nil,
                  userMaxHR: AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveMaxHR
              ), bucketMETs > 0,
              let durationSec = totalDurationSec(), durationSec >= 60
        else { return nil }
        return loadFromMETHours(bucketMETs * (durationSec / 3600.0))
    }

    /// Mean km/h from the session totals — distance / elapsed.
    /// Used by the single-bucket METs fallback when per-sample pace
    /// isn't usable.
    private func averageKmh() -> Double? {
        guard let distance = distanceMeters, distance > 0,
              let durationSec = totalDurationSec(), durationSec > 0
        else { return nil }
        let km = distance / 1000.0
        let hours = durationSec / 3600.0
        let kmh = km / hours
        // Sanity ceiling at 60 km/h — anything above means GPS
        // accumulated noise (e.g. car-leg in the track). Don't
        // claim a 30 MET sprint in that case.
        guard kmh > 0.5, kmh < 60 else { return nil }
        return kmh
    }

    /// Moving seconds: the last sample's offset. The ticker stamps each
    /// sample with the moving-time counter and records none while paused,
    /// so this excludes paused stretches. Nil without samples — the caller
    /// is welcome to use `endDate - startDate` from the parent session.
    private func totalDurationSec() -> Double? {
        if let last = samples?.max(by: { $0.offsetSec < $1.offsetSec })?.offsetSec {
            return Double(last)
        }
        return nil
    }

    private func loadFromMETHours(_ metHours: Double) -> Double? {
        guard metHours > 0.01 else { return nil }
        // Threshold-equivalent MET-hour for normalisation. 12 METs
        // is a reasonable anchor for a fit endurance athlete's
        // lactate threshold (ACSM / Friel). Could later be
        // personalised from the user's VO2max, but a fixed anchor
        // keeps the ratio self-consistent across sessions and
        // across users until we do that work properly.
        let thresholdMETs = 12.0
        let load = metHours / thresholdMETs * 100.0
        return load > 0.5 ? load : nil
    }

    /// Derive powerTSS at read time from stored NP +
    /// the current effective FTP (which includes the auto-
    /// estimate via `FTPAutoEstimator`). This fills in powerTSS
    /// for HISTORICAL workouts that finalized before an FTP was
    /// known — no re-archive needed, the number appears as soon
    /// as the auto-estimate runs at launch.
    ///
    /// Coggan formula: `IF² × duration_hours × 100`, where
    /// `IF = NP / FTP`. Returns nil when NP or FTP is missing,
    /// or when the session has a stored powerTSS already (caller
    /// uses that path instead).
    @MainActor
    var computedPowerTSS: Double? {
        if let stored = storedPowerTSS { return stored }
        guard let np = normalizedPowerWatts, np > 0 else { return nil }
        let settings = AppDependencies.current.app.settingsManager.settings
        let ftp: Int? = {
            switch sport {
            case .run, .trailRun, .walk, .hike, .treadmill: return settings.effectiveRunningFTP
            case .bike, .indoorBike: return settings.effectiveCyclingFTP
            default: return nil
            }
        }()
        guard let ftp, ftp > 0 else { return nil }
        guard let durationSec = totalDurationSec(), durationSec > 60 else { return nil }
        let durationHours = durationSec / 3600.0
        let intensityFactor = np / Double(ftp)
        let tss = intensityFactor * intensityFactor * durationHours * 100.0
        return tss > 0 ? tss : nil
    }

    /// The power TSS frozen at finalize, re-derived over MOVING time.
    ///
    /// TSS is IF² × hours of effort × 100, and NP is computed over the moving
    /// samples only, so the hours must be moving hours too. Finalize used
    /// start-to-stop wall-clock time, so a 60-minute ride with a 30-minute
    /// café stop at IF 0.8 was stored as 96 TSS instead of 64. When the frozen
    /// IF (which carries the FTP of that day) and the per-second samples are
    /// both present, the moving-time figure is returned; otherwise the stored
    /// value. Stored fields only, so it is safe off the main actor.
    var storedPowerTSS: Double? {
        if let intensity = intensityFactor, intensity > 0,
           let movingSec = totalDurationSec(), movingSec > 60 {
            return intensity * intensity * (movingSec / 3600.0) * 100.0
        }
        guard let stored = powerTSS, stored > 0 else { return nil }
        return stored
    }

    /// Confidence `RouteTRIMPEstimator` gives an estimate built with no
    /// prior run of the route (today's own ratio, scaled). Anything above
    /// it was built from at least one prior run.
    static let routeEstimateNoPriorConfidence = 0.4

    /// The recorded HR load must be below this share of the route estimate
    /// for the estimate to replace it. The estimate blends 60 % prior and
    /// 40 % recorded, so recorded < 0.5 × estimate means the recorded load
    /// is under ~37 % of the user's usual load on that route — a strap
    /// dropout (TRIMP ≈ 2), not an easy day (which the 60/40 blend would
    /// otherwise inflate).
    static let routeDropoutRecordedShare = 0.5

    /// True when the route-history estimate, not the recorded HR load, is
    /// this workout's load: the estimate rests on prior runs of the same
    /// route, and the recorded TRIMP is a dropout fraction of it. Stored
    /// fields only, so `TrainingLoadPrecedence` applies the same rule.
    var routeEstimateReplacesHRLoad: Bool {
        guard let estimate = extrapolatedTRIMP, estimate > 0,
              let confidence = extrapolationConfidence,
              confidence > Self.routeEstimateNoPriorConfidence
        else { return false }
        return (luciaTRIMP ?? 0) < Self.routeDropoutRecordedShare * estimate
    }

    /// Preferred numeric load + the source it came from. Order is by
    /// published accuracy:
    ///   1. powerTSS (Coggan, with Stryd / cycling power; either
    ///      the stored value over moving time OR derived at read time
    ///      from NP and the current effective FTP — incl. auto-estimate)
    ///   2. extrapolatedTRIMP, only when `routeEstimateReplacesHRLoad`:
    ///      the strap dropped, so every HR-derived figure below is a
    ///      fraction of the real effort
    ///   3. hrTSS (HRSS, with HR + LTHR)
    ///   4. METs-based load (per-sample sport+pace+grade)
    ///   5. luciaTRIMP (Banister, HR-only)
    ///   6. extrapolatedTRIMP (route-history, when nothing else exists)
    ///
    /// Callers use the source tag to label the displayed number
    /// honestly ("Coggan · power", "METs · partial", etc.).
    @MainActor
    var preferredTrainingLoad: (value: Double, source: TrainingLoadSource)? {
        // `computedPowerTSS` resolves stored powerTSS
        // first, then derives it from NP + current FTP for
        // sessions that finalized without an FTP anchor. Together
        // this means: once auto-estimate fires, EVERY historical
        // workout with Stryd NP shows power-based load.
        if let pTSS = computedPowerTSS, pTSS > 0 { return (pTSS, .power) }
        if routeEstimateReplacesHRLoad, let extrap = extrapolatedTRIMP { return (extrap, .routeHistory) }
        if let tss = hrTSS, tss > 0 { return (tss, .hr) }
        if let metsLoad = computedMETLoad, metsLoad > 0 { return (metsLoad, .mets) }
        if let trimp = luciaTRIMP, trimp > 0 { return (trimp, .banister) }
        if let extrap = extrapolatedTRIMP, extrap > 0 { return (extrap, .routeHistory) }
        return nil
    }

    // MARK: Rowing-specific (from Concept2 PM5)
    //
    // The PM5 reports several signals no other sport captures: stroke count,
    // average split pace (sec / 500 m), and drag factor (a calibration of
    // how much resistance the fan damper provides). Without persisting
    // these, post-summary for a rowing session would lose the row-specific
    // story — split pace is to a rower what min/mile is to a runner.
    /// Total stroke count for the session. PM5 odometer.
    var strokeCount: Int?
    /// Average split pace across the session, in seconds per 500 m. The
    /// PM5's native pace unit; rowers think in "splits", not in m/s.
    var averageSplitSecPer500m: Double?
    /// Drag factor — proxy for fan damper resistance. Typical 100–135.
    /// Sticky across the session; we capture the value at finish.
    var dragFactor: Int?

    // MARK: Lightweight init
    init(
        sport: Sport,
        gpsPolyline: Data? = nil,
        distanceMeters: Double? = nil,
        elevationGainMeters: Double? = nil,
        elevationLossMeters: Double? = nil,
        splits: [Split]? = nil,
        laps: [Lap]? = nil,
        liveMarkers: [LiveMarker]? = nil,
        samples: [WorkoutSample]? = nil,
        hrrSamples: [HRRSample]? = nil,
        decouplingPercent: Double? = nil,
        efficiencyFactor: Double? = nil,
        luciaTRIMP: Double? = nil,
        hrTSS: Double? = nil
    ) {
        self.sport = sport
        self.gpsPolyline = gpsPolyline
        self.distanceMeters = distanceMeters
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.splits = splits
        self.laps = laps
        self.liveMarkers = liveMarkers
        self.samples = samples
        self.hrrSamples = hrrSamples
        self.decouplingPercent = decouplingPercent
        self.efficiencyFactor = efficiencyFactor
        self.luciaTRIMP = luciaTRIMP
        self.hrTSS = hrTSS
    }

    // MARK: Codable (explicit to allow additive schema evolution)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sport
        case gpsPolyline, distanceMeters, elevationGainMeters, elevationLossMeters
        case splits, laps, liveMarkers
        case samples
        case hrrSamples, decouplingPercent, efficiencyFactor, luciaTRIMP, hrTSS
        case averagePowerWatts, normalizedPowerWatts, peakPowerWatts
        case powerTSS, intensityFactor, variabilityIndex, ftpAtTimeOfSession
        case strokeCount, averageSplitSecPer500m, dragFactor
        case workoutFeeling, workoutFeelingNote
        case analysisSnapshot
        case partialDataReason, recoveredAt
        case extrapolatedTRIMP, extrapolationConfidence, extrapolationRouteName
        case recognizedRouteName
        case weatherSnapshot
    }

    // spec:long-function A Codable decoder cannot be decomposed in Swift:
    // every stored property must be initialized before any method on `self`
    // may be called, so a `private mutating func decodeX(...)` helper is
    // rejected outright, and `let` properties can only be assigned by `init`.
    // The alternatives are defaulting every property in its declaration (which
    // turns a missing assignment from a compile error into a silent nil) or
    // restructuring the on-disk JSON (a data migration, for a formatting rule).
    // Body is one assignment per field, in the same order as the encoder.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        sport = try c.decode(Sport.self, forKey: .sport)
        gpsPolyline = try c.decodeIfPresent(Data.self, forKey: .gpsPolyline)
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        elevationGainMeters = try c.decodeIfPresent(Double.self, forKey: .elevationGainMeters)
        elevationLossMeters = try c.decodeIfPresent(Double.self, forKey: .elevationLossMeters)
        splits = try c.decodeIfPresent([Split].self, forKey: .splits)
        laps = try c.decodeIfPresent([Lap].self, forKey: .laps)
        liveMarkers = try c.decodeIfPresent([LiveMarker].self, forKey: .liveMarkers)
        samples = try c.decodeIfPresent([WorkoutSample].self, forKey: .samples)
        hrrSamples = try c.decodeIfPresent([HRRSample].self, forKey: .hrrSamples)
        decouplingPercent = try c.decodeIfPresent(Double.self, forKey: .decouplingPercent)
        efficiencyFactor = try c.decodeIfPresent(Double.self, forKey: .efficiencyFactor)
        luciaTRIMP = try c.decodeIfPresent(Double.self, forKey: .luciaTRIMP)
        hrTSS = try c.decodeIfPresent(Double.self, forKey: .hrTSS)
        averagePowerWatts = try c.decodeIfPresent(Double.self, forKey: .averagePowerWatts)
        normalizedPowerWatts = try c.decodeIfPresent(Double.self, forKey: .normalizedPowerWatts)
        peakPowerWatts = try c.decodeIfPresent(Int.self, forKey: .peakPowerWatts)
        powerTSS = try c.decodeIfPresent(Double.self, forKey: .powerTSS)
        intensityFactor = try c.decodeIfPresent(Double.self, forKey: .intensityFactor)
        variabilityIndex = try c.decodeIfPresent(Double.self, forKey: .variabilityIndex)
        ftpAtTimeOfSession = try c.decodeIfPresent(Int.self, forKey: .ftpAtTimeOfSession)
        strokeCount = try c.decodeIfPresent(Int.self, forKey: .strokeCount)
        averageSplitSecPer500m = try c.decodeIfPresent(Double.self, forKey: .averageSplitSecPer500m)
        dragFactor = try c.decodeIfPresent(Int.self, forKey: .dragFactor)
        workoutFeeling = try c.decodeIfPresent(Int.self, forKey: .workoutFeeling)
        workoutFeelingNote = try c.decodeIfPresent(String.self, forKey: .workoutFeelingNote)
        analysisSnapshot = try c.decodeIfPresent(WorkoutAnalysisSnapshot.self, forKey: .analysisSnapshot)
        partialDataReason = try c.decodeIfPresent(PartialDataReason.self, forKey: .partialDataReason)
        recoveredAt = try c.decodeIfPresent(Date.self, forKey: .recoveredAt)
        extrapolatedTRIMP = try c.decodeIfPresent(Double.self, forKey: .extrapolatedTRIMP)
        extrapolationConfidence = try c.decodeIfPresent(Double.self, forKey: .extrapolationConfidence)
        extrapolationRouteName = try c.decodeIfPresent(String.self, forKey: .extrapolationRouteName)
        recognizedRouteName = try c.decodeIfPresent(String.self, forKey: .recognizedRouteName)
        weatherSnapshot = try c.decodeIfPresent(WorkoutWeatherSnapshot.self, forKey: .weatherSnapshot)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeRouteAndSamples(into: &c)
        try encodeLoadMetrics(into: &c)
        try encodePowerMetrics(into: &c)
        try encodeContext(into: &c)
    }

    /// Sport, route geometry, and the per-tick sample series.
    private func encodeRouteAndSamples(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(sport, forKey: .sport)
        try c.encodeIfPresent(gpsPolyline, forKey: .gpsPolyline)
        try c.encodeIfPresent(distanceMeters, forKey: .distanceMeters)
        try c.encodeIfPresent(elevationGainMeters, forKey: .elevationGainMeters)
        try c.encodeIfPresent(elevationLossMeters, forKey: .elevationLossMeters)
        try c.encodeIfPresent(splits, forKey: .splits)
        try c.encodeIfPresent(laps, forKey: .laps)
        try c.encodeIfPresent(liveMarkers, forKey: .liveMarkers)
        try c.encodeIfPresent(samples, forKey: .samples)
    }

    /// Cardiac drift, efficiency and the HR-based load scores.
    private func encodeLoadMetrics(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encodeIfPresent(hrrSamples, forKey: .hrrSamples)
        try c.encodeIfPresent(decouplingPercent, forKey: .decouplingPercent)
        try c.encodeIfPresent(efficiencyFactor, forKey: .efficiencyFactor)
        try c.encodeIfPresent(luciaTRIMP, forKey: .luciaTRIMP)
    }

    /// Power-meter derived metrics, plus the rowing-specific set.
    private func encodePowerMetrics(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encodeIfPresent(hrTSS, forKey: .hrTSS)
        try c.encodeIfPresent(averagePowerWatts, forKey: .averagePowerWatts)
        try c.encodeIfPresent(normalizedPowerWatts, forKey: .normalizedPowerWatts)
        try c.encodeIfPresent(peakPowerWatts, forKey: .peakPowerWatts)
        try c.encodeIfPresent(powerTSS, forKey: .powerTSS)
        try c.encodeIfPresent(intensityFactor, forKey: .intensityFactor)
        try c.encodeIfPresent(variabilityIndex, forKey: .variabilityIndex)
        try c.encodeIfPresent(ftpAtTimeOfSession, forKey: .ftpAtTimeOfSession)
        try c.encodeIfPresent(strokeCount, forKey: .strokeCount)
        try c.encodeIfPresent(averageSplitSecPer500m, forKey: .averageSplitSecPer500m)
    }

    /// Subjective feeling, recovery/partial-data provenance, route
    /// recognition, and the weather at the time of the workout.
    private func encodeContext(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encodeIfPresent(dragFactor, forKey: .dragFactor)
        try c.encodeIfPresent(workoutFeeling, forKey: .workoutFeeling)
        try c.encodeIfPresent(workoutFeelingNote, forKey: .workoutFeelingNote)
        try c.encodeIfPresent(analysisSnapshot, forKey: .analysisSnapshot)
        try c.encodeIfPresent(partialDataReason, forKey: .partialDataReason)
        try c.encodeIfPresent(recoveredAt, forKey: .recoveredAt)
        try c.encodeIfPresent(extrapolatedTRIMP, forKey: .extrapolatedTRIMP)
        try c.encodeIfPresent(extrapolationConfidence, forKey: .extrapolationConfidence)
        try c.encodeIfPresent(extrapolationRouteName, forKey: .extrapolationRouteName)
        try c.encodeIfPresent(recognizedRouteName, forKey: .recognizedRouteName)
        // Written so the weather captured at finalize survives archiving:
        // heat tracking reads only this.
        try c.encodeIfPresent(weatherSnapshot, forKey: .weatherSnapshot)
    }
}

/// Persisted weather at a workout, for the heat-acclimatization model.
/// A slim Codable mirror of the live `WorkoutAIContext.WeatherSnapshot`
/// (which is transient/Equatable-only). All temperatures in °C.
struct WorkoutWeatherSnapshot: Codable, Equatable, Sendable {
    let temperatureC: Double
    let apparentTemperatureC: Double?
    let relativeHumidityPercent: Double
    let windKMH: Double?
    let conditions: String?
    /// When the weather was observed: the fetch time for a live capture, the
    /// workout start for weather read from Apple Health.
    let observedAt: Date
    /// True on snapshots older builds filled in later from a weather archive;
    /// decoded so those records load. New snapshots are always `false`.
    let backfilled: Bool
}

extension WorkoutWeatherSnapshot {
    /// The weather Apple Watch saves with an outdoor workout (HealthKit's
    /// temperature and humidity metadata). Nil unless both are present.
    init?(healthKitMetadata metadata: [String: Any]?, observedAt: Date) {
        guard let temperature = metadata?[HKMetadataKeyWeatherTemperature] as? HKQuantity,
              let humidity = metadata?[HKMetadataKeyWeatherHumidity] as? HKQuantity,
              temperature.is(compatibleWith: .degreeCelsius()),
              humidity.is(compatibleWith: .percent()) else { return nil }
        self.init(
            temperatureC: temperature.doubleValue(for: .degreeCelsius()),
            apparentTemperatureC: nil,
            relativeHumidityPercent: humidity.doubleValue(for: .percent()) * 100,
            windKMH: nil,
            conditions: nil,
            observedAt: observedAt,
            backfilled: false
        )
    }
}

// MARK: - PartialDataReason

/// Why a workout's data is incomplete. Set by the recovery path when
/// reconstructing a session whose normal `Stop` finalize never ran.
enum PartialDataReason: String, Codable, Equatable {
    /// App crashed or was force-quit mid-recording. Detected at launch
    /// via `PersistedRecordingState` + on-disk RR/track backups.
    case appCrashed
    /// Strap battery died or fell out of range; the recording phase
    /// continued without HR data, so HR-based metrics cover only the
    /// first portion of the session.
    case strapDisconnected
    /// User-driven: tapped Save-as-Complete on the launch interruption
    /// alert without resuming, accepting the partial record as final.
    case userInterrupted

    /// Short user-facing label rendered in the summary "Estimated"
    /// chip, alongside the metric values.
    var displayLabel: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .appCrashed: String(localized: "Estimated — partial HR data", bundle: b)
        case .strapDisconnected: String(localized: "Estimated — strap dropout", bundle: b)
        case .userInterrupted: String(localized: "Saved as partial — interrupted", bundle: b)
        }
    }
}

// MARK: - Convenience accessors on HRRSample collections

extension [HRRSample] {
    /// The canonical HRR@60s reading, preferring strap-derived over Watch over
    /// HealthKit-computed when more than one provenance is present.
    var bestAtOneMinute: HRRSample? {
        let within = filter { abs($0.offsetSec - 60) <= 10 }
        let order: [HRRSample.Provenance] = [.strap, .watchSamples, .healthKitComputed]
        for prov in order {
            if let s = within.first(where: { $0.provenance == prov }) { return s }
        }
        return nil
    }

    /// Same idea for 2-minute mark.
    var bestAtTwoMinutes: HRRSample? {
        let within = filter { abs($0.offsetSec - 120) <= 15 }
        let order: [HRRSample.Provenance] = [.strap, .watchSamples, .healthKitComputed]
        for prov in order {
            if let s = within.first(where: { $0.provenance == prov }) { return s }
        }
        return nil
    }
}
