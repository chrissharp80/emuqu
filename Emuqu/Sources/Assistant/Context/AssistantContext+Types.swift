import Foundation

// The nested value types that make up an `AssistantContext`, split out of
// `AssistantContext.swift`. Nested type declarations are legal in an
// extension, so the shape is unchanged — `AssistantContext.Recovery` is still
// `AssistantContext.Recovery`. What stays behind is the context's own stored
// fields and the renderers that read them.

extension AssistantContext {
    // MARK: - Sub-structs

    struct UserProfileSnapshot: Codable {
        let age: Int?
        let biologicalSex: String? // "Male", "Female", "Other", or nil
        let fitnessLevel: String? // FitnessLevel.rawValue, or nil
        let vo2Max: Double?
        let typicalSleepHours: Double?
        let customTagNames: [String]
        /// User's max HR in bpm. From Settings override, else 208 − 0.7 × age (Tanaka), else 180.
        /// Populated always — the AI needs this to discuss zones correctly.
        let maxHR: Int?
        /// Whether `maxHR` came from the user's explicit override (true) or
        /// a fallback calculation (false). Lets the AI phrase accordingly.
        let maxHRIsUserOverride: Bool
        /// "metric" or "imperial". The AI adapts distance / pace phrasing.
        let unitsPreference: String?
        /// Training-break flag. "I'm on a break" should change the AI's
        /// interpretation of low activity + elevated HRV.
        let onTrainingBreak: Bool
        /// Optional user-provided reason ("surgery", "vacation", "sick").
        let trainingBreakReason: String?
        /// Does the user have HealthKit sleep integration enabled?
        let sleepIntegrationEnabled: Bool
        /// Does the user have training-load integration enabled?
        let trainingLoadIntegrationEnabled: Bool
        /// Comeback-mode active flag. When true, the
        /// recovery score is using HRV 80% / Sleep 20% / Vitals 0%
        /// instead of the standard 60/25/15. The AI should know this so
        /// it can explain "why is my Vitals factor at 0%" or "why does
        /// my score weight HRV more heavily?" in the user's terms.
        let comebackModeActive: Bool
        /// Day of the 21-day Comeback window (0 on the first day,
        /// nil when not active). Lets the AI say "you're 5 days into a
        /// 21-day comeback window" instead of just "comeback mode is on".
        let comebackModeDayInWindow: Int?
        /// Recovery-score algorithm version. "v1" =
        /// pre-May-2026 (HRV/Sleep/Training, ACWR-aware). "v2" =
        /// May-2026 onwards (HRV/Sleep/Vitals, no training). Lets the AI
        /// answer "why does my score look different than last week?"
        /// honestly — we changed the math, your inputs are the same.
        let scoreAlgorithmVersion: String
        /// Whether the user has run the one-shot history recompute since
        /// the v1 → v2 change. False means archived sessions still show
        /// scores under the older algorithm.
        let scoreHistoryRecomputed: Bool
        /// The Training goal from Settings → Training, with what it asks of
        /// the coach. The setting existed and nothing read it.
        var trainingGoal: String?
    }

    /// Compact entry per workout session — ~10–20 lines total for 30 days
    /// when rendered. Fields chosen so the AI can answer "what workouts did
    /// I do this week?" / "how did my 5K go on Sunday?" / "have I gotten
    /// faster?" without having to load the full HRVSession.
    ///
    /// Power / cadence / alpha1 / HRR / feeling are carried so the
    /// AI can answer "how does my power today compare to last week" / "is
    /// my cadence trending up" / "how was my recovery on yesterday's run"
    /// without falling through to per-session tool calls. Apple sees these
    /// directly in the compactRender block; cloud providers see them via
    /// the renderer's line per workout. All new fields nullable.
    struct WorkoutHistoryEntry: Codable {
        let date: Date
        let sport: String           // Sport.rawValue, e.g. "run", "walk"
        let durationSec: Int?
        let distanceMeters: Double?
        let elevationGainMeters: Double?
        let averageHR: Double?
        let maxHRInSession: Int?
        let averagePaceSecPerKm: Double?
        let trimp: Double?
        let hrTSS: Double?
        let decouplingPercent: Double?
        /// Avg METs + calorie estimate if the per-tick sample series was
        /// captured (newer sessions). Old sessions without samples → nil.
        let avgMETs: Double?
        let estimatedCalories: Double?
        // Power. Nil when no power-capable sensor was paired
        // (most walks / runs). When present, these answer the user's
        // "compare my power today vs other days" questions directly.
        let avgPowerWatts: Double?
        let normalizedPowerWatts: Double?
        let peakPowerWatts: Int?
        let powerTSS: Double?
        let intensityFactor: Double?
        // Cadence. Foot pod cadence for runs / walks, pedal
        // cadence for bike. Average across the session.
        let avgCadenceSpm: Int?
        // DFA α1 mean across the session. Anchored to AeT/AeT
        // boundary inferences ("was I in the aerobic band?") that the AI
        // currently can only answer per-session via tool calls.
        let alpha1Mean: Double?
        // Heart rate recovery drops (best at 1 min / 2 min).
        // Lets the AI answer "is my recovery improving" across the strip.
        let hrr1MinDrop: Int?
        let hrr2MinDrop: Int?
        // Subjective workout feeling 1–5 + optional note.
        // Lets the AI cross-reference "felt easy / felt hard" with the
        // objective numbers across sessions.
        let workoutFeeling: Int?
        let workoutFeelingNote: String?
    }

    struct SessionSnapshot: Codable {
        let id: UUID
        let startDate: Date
        let endDate: Date?
        let sessionType: String // SessionType.rawValue
        let recoveryScore: Double? // 0-10 composite
        let scoreTier: Int? // 1, 2, or 3
        let scoreFactors: [ScoreFactorSnapshot]
        let scorePenalties: [String]
        let scoreMessage: String?
        let timeDomain: TimeDomainSnapshot?
        let frequencyDomain: FrequencyDomainSnapshot?
        let nonlinear: NonlinearSnapshot?
        let ansMetrics: ANSMetricsSnapshot?
        /// Whole-night HR summary: nadir + min/max/mean across the FULL session
        /// (not the 5-min analysis window). Lets the AI answer "what was my
        /// true nadir last night?" / "when did my HR bottom out?" without the
        /// app having to ship the raw RR series in every prompt.
        let overnightHR: OvernightHRSnapshot?
        let sleep: SleepSnapshot?
        let vitals: VitalsSnapshot?
        let training: TrainingSnapshot?
        let tags: [String]
        let notes: String?
        let morningFeeling: Int? // 1-5
        let morningFeelingTags: [String]
        let hrvDataQuality: String? // "good", "preSleep", "insufficient"
        let perceivedReadiness: Double? // 0.0-1.0
        let artifactPercentage: Double?
    }

    /// Whole-recording HR summary, derived from the artifact-cleaned RRSeries
    /// at analysis time and persisted on `HRVAnalysisResult`. The AI surfaces
    /// these directly when asked about "nadir" / "lowest HR" / "when did my
    /// HR drop the most?".
    struct OvernightHRSnapshot: Codable {
        let nadirBPM: Double
        /// Wall-clock time of the nadir if known, else session start + offset.
        let nadirAt: Date?
        let minBPM: Double
        let maxBPM: Double
        let meanBPM: Double
    }

    struct SessionSnapshotLite: Codable {
        let date: Date
        let sessionType: String
        let recoveryScore: Double?
        let rmssd: Double?
        let meanHR: Double?
        let stressIndex: Double?
        let sleepMinutes: Int?
        let morningFeeling: Int?
        let tags: [String]
        // Training-load fields so the AI can answer "how did yesterday's
        // workout drop my readiness?" without having to recompute anything.
        let atl: Double?
        let ctl: Double?
        let tsb: Double?
        /// ATL/CTL — load-range indicator (<0.8 below the user's usual range,
        /// 0.8-1.3 within it, >1.5 a sharp recent increase). Per Impellizzeri
        /// 2020/2021 the ratio's signal value is weaker than the original
        /// Gabbett framing claimed; treat it as descriptive context, not an
        /// injury predictor.
        let acwr: Double?
        let yesterdayTrimp: Double?
        // One-line summary from the cached AnalysisSummary if present.
        let analysisTitle: String?
        let scoreMessage: String?
        // Sleep-stage minutes — exposed across the whole 14-day window so the
        // AI can answer "when did I have my best deep sleep this month?"
        // without needing to load each session file.
        let deepSleepMinutes: Int?
        let remSleepMinutes: Int?
        let coreSleepMinutes: Int?
        let awakeMinutes: Int?
        // Nocturnal HR dip (% drop from waking → sleeping HR). Healthy 10–20%.
        let nocturnalDipPercent: Double?
    }

    struct ScoreFactorSnapshot: Codable {
        let label: String
        let detail: String
        let score: Double // 0-100
        let weight: Double // 0-1
        let impact: String // "positive", "neutral", "negative"
        let contribution: Double // score * weight
    }

    struct TimeDomainSnapshot: Codable {
        let rmssd: Double
        let sdnn: Double
        let pnn50: Double
        let meanRR: Double
        let meanHR: Double
    }

    struct FrequencyDomainSnapshot: Codable {
        let lf: Double
        let hf: Double
        let lfHfRatio: Double?
        let totalPower: Double
    }

    struct NonlinearSnapshot: Codable {
        let sd1: Double
        let sd2: Double
        let sd1Sd2Ratio: Double
        let dfaAlpha1: Double?
        let dfaAlpha2: Double?
        let sampleEntropy: Double?
    }

    struct ANSMetricsSnapshot: Codable {
        let stressIndex: Double?
        let pnsIndex: Double?
        let snsIndex: Double?
        let readinessScore: Double? // 1-10 HRV-only
        let respirationRate: Double?
        let nocturnalHRDip: Double?
    }

    struct SleepSnapshot: Codable {
        let totalSleepMinutes: Int
        let inBedMinutes: Int
        let deepSleepMinutes: Int?
        let remSleepMinutes: Int?
        let awakeMinutes: Int
        let sleepEfficiency: Double // 0-1
        let isShortSleep: Bool
        let isFragmented: Bool
    }

    struct VitalsSnapshot: Codable {
        let respiratoryRate: Double?
        let respiratoryRateBaseline: Double?
        let oxygenSaturation: Double?
        let oxygenSaturationMin: Double?
        let wristTemperatureDeviation: Double? // °C from baseline
        let restingHeartRate: Double?
    }

    struct TrainingSnapshot: Codable {
        let atl: Double // Acute Training Load (fatigue)
        let ctl: Double // Chronic Training Load (fitness)
        let tsb: Double // CTL - ATL (form/freshness)
        let acwr: Double? // ATL/CTL — load-spike indicator (<0.8 below your usual range, 0.8-1.3 within your usual range, >1.5 sharp recent increase)
        let yesterdayTrimp: Double
        let daysSinceHardWorkout: Int?
        let vo2Max: Double?
    }

    struct BaselineSnapshot: Codable {
        let lnRmssdMean: Double? // mean ln(RMSSD) over rolling window
        let lnRmssdSD: Double?
        let lnRmssdCV7Day: Double? // reduced CV signals overreaching
        let meanHRBaseline: Double?
        let meanHRSD: Double?
        let daysInWindow: Int
        let lastDataPointDate: Date?

        // Friendly raw values for narrative use
        let rmssdBaseline: Double? // 7-day mean RMSSD
        let sdnnBaseline: Double?
        let dfaAlpha1Baseline: Double?
        let stressIndexBaseline: Double?
    }

    struct TrendSnapshot: Codable {
        struct MetricTrend: Codable {
            let metric: String // "rmssd", "meanHR", "stressIndex", etc.
            let count: Int
            let mean: Double
            let standardDeviation: Double
            let min: Double
            let max: Double
            let trend: String // "Improving", "Stable", "Declining", "Insufficient Data"
            let trendSlope: Double
            let coefficientOfVariation: Double
            let baseline: Double?
            let deviationFromBaseline: Double?
        }

        let period: String // "7 Days", "30 Days", etc.
        let dataPointCount: Int
        let overallTrend: String
        let metrics: [MetricTrend]
        let insights: [String]
    }

    struct AnalysisSummarySnapshot: Codable {
        struct ProbableCause: Codable {
            let cause: String
            let confidence: String // "High", "Medium", "Low"
            let explanation: String
        }

        let analysisTitle: String
        let diagnosticScore: Double
        let analysisExplanation: String
        let probableCauses: [ProbableCause]
        let keyFindings: [String]
        let actionableSteps: [String]
        let trendInsight: String
    }

    /// Live-workout snapshot. Populated only while a workout is recording so
    /// the AI can answer "what's my HR?" / "what pace am I on?" / "where am
    /// I?" / "why isn't α1 showing?" with the actual number or reason —
    /// never a guess. Built from WorkoutRecorder's observable state.
    ///
    /// Contains both raw metric values AND the user's unit preference +
    /// wall-clock timestamps, so rendering can be localised and the AI
    /// knows "this was captured seven seconds ago" not "some time in the
    /// last session." Wall-clock fields also let the AI distinguish "we're
    /// truly live right now" from "we have stale snapshot state."
    struct LiveWorkoutSnapshot: Codable {
        let sport: String
        /// Wall-clock timestamp of THIS snapshot (not the session start).
        let snapshotAt: Date
        /// Wall-clock timestamp of when the workout started. AI can compute
        /// absolute "we started at 2:47 pm" without any app-local math.
        let sessionStartAt: Date
        let elapsedSeconds: Int
        let heartRate: Int?
        /// Session-observed peak HR. DO NOT use as the denominator for zone
        /// math — that's what produced "Zone 5 at 100 bpm" when peak was only
        /// 105. Use `userMaxHR` instead.
        let peakHR: Int
        /// User's physiological max HR (Settings override, else 208 − 0.7 × age, else
        /// 180). This is the correct denominator for "what zone are you in?"
        /// Prefer this over session peak for zone math.
        let userMaxHR: Int
        let beatCount: Int
        let distanceMeters: Double
        let stepCount: Int
        let cadenceStepsPerMin: Double?
        let elevationGainMeters: Double
        let alpha1: Double?
        let alpha1Band: String
        /// Human-readable α1 diagnostic status ("ok", "warming up (45 %)",
        /// "strap silent for 32 s", "fit failed"). Lets the AI explain why
        /// α1 isn't visible instead of pretending the metric doesn't exist.
        let alpha1Status: String
        let alpha1FitQualityR2: Double?
        let strapConnected: Bool
        /// Seconds since the last strap-derived HR beat (nil when source
        /// isn't strap). Values > ~10 s mean we've silently fallen back to
        /// Watch HR and the AI should say so if asked.
        let strapSilentSec: Double?
        let gpsFixCount: Int
        let gpsAccuracyMeters: Double?

        // --- New: pace, power, energy ---
        let currentPaceSecPerKm: Double?
        let currentSpeedMS: Double?
        let powerWatts: Int?
        let currentMETs: Double?
        /// Last up-to-3 split paces in sec / km (index 0 = most recent).
        let recentSplitPaces: [Double]

        // --- New: map & terrain ---
        let currentLatitude: Double?
        let currentLongitude: Double?
        let currentAltitudeMeters: Double?
        /// Degrees true, 0 = north. nil when stationary or no fix.
        let currentHeadingDegrees: Double?
        /// Cardinal label derived from `currentHeadingDegrees`
        /// (N, NE, E, SE, S, SW, W, NW). Easier for the AI to turn into
        /// natural-language directions ("you're heading east on Maple")
        /// than reading degrees out loud. nil when heading is nil.
        let currentHeadingCardinal: String?
        /// Grade in %, computed from the last ~100 m of track.
        let currentGradePercent: Double?

        // --- New: preferences + target ---
        /// User's unit preference string ("auto" / "metric" / "imperial").
        /// Lets the AI render distances and paces in the user's language
        /// instead of always emitting metric — the cause of the "voice
        /// chat was all metric until I told it imperial" complaint.
        let unitsPreference: String
        let targetZone: Int?

        // --- New: recognised route ---
        /// Name of the route the recorder bound for this workout. Either
        /// the user's library name ("Daily 1", "Long loop") when the
        /// recogniser matched a saved route, or the GPX file name when
        /// the user manually loaded a course. Nil when no route is bound.
        var recognizedRouteName: String?
        /// True when the binding came from auto-recognition against the
        /// user's saved route library. Lets the AI distinguish "you
        /// loaded this manually" from "the app recognised this".
        var recognizedRouteWasAutoDetected: Bool = false
        /// "forward" or "reverse" — set when the recogniser matched a
        /// saved route in the opposite direction the user originally saved
        /// it. Lets the AI say "running Daily 1 in reverse today" so the
        /// user knows the climb predictions reflect today's actual
        /// heading, not the saved-day's heading.
        var recognizedRouteDirection: String?
        /// Total length of the bound route, meters. Surfaces "you're 60 %
        /// through" math without the model having to estimate.
        var routeTotalDistanceMeters: Double?
        /// Number of climbs the bound route has overall. Lets the assistant
        /// answer "how many climbs left?" without re-loading the polyline.
        var routeClimbCount: Int?

        // --- Road context (reverse-geocoded street + locality so the
        // AI can say "you're on Elm Street" instead of "lat 39.78 lon
        // -89.65"). Refreshed every ~30 s during the workout via
        // `RoadGeocodingService` (Apple CLGeocoder). Nil when the
        // geocoder hasn't responded yet, or when the user is somewhere
        // CLGeocoder doesn't recognise (water, wilderness). ---
        var currentRoadName: String?
        var currentLocality: String?
        var currentAdministrativeArea: String?
        var currentCountry: String?
        var currentCountryCode: String?
        var currentCompactAddress: String?
        /// Nearest cross street (different from
        /// `currentRoadName`) resolved via MKLocalSearch in a 200 m
        /// box. Lets the AI answer "what's the nearest intersection".
        /// Nil when MKLocalSearch returned nothing nearby (rural,
        /// wilderness) or before the search has completed for this
        /// location.
        var currentNearestCrossStreet: String?

        // --- New: route topography + weather (rich AI context) ---
        /// Full topology snapshot of the bound route (climbs queue,
        /// remaining ascent, peak altitude, etc.). Same data the
        /// trigger engine sees in WorkoutAIContext, mirrored here so the
        /// assistant's tool calls can answer "how steep is the next one?"
        /// and "how much uphill is left?" precisely.
        var routeTopology: RouteTopologySnapshot?
        /// Current weather at the user's GPS location. Refreshed every
        /// ~30 minutes by `WeatherService`.
        var weather: WeatherSnapshot?

        // --- Live trend metrics (mid-workout
        // self-comparison). These mirror the same fields on
        // `WorkoutAIContext` so the chat tool path (which reads from
        // this snapshot) sees the same data the voice path does.
        // Defaulted nil for back-compat with sessions persisted before
        // these existed. ---

        /// Current pace minus first-half average pace, sec/km.
        /// Negative = faster second half. Nil before half-time.
        var reverseSplitDeltaSecPerKm: Double?
        /// Cardiac drift: last-quartile HR vs first-quartile HR, % of baseline.
        /// >5% suggests fatigue. Nil before ~7 min.
        var liveHRDriftPercent: Double?
        /// Live HR slope, last 30s avg minus 60-90s-ago
        /// avg. Positive = HR currently rising; negative = HR currently
        /// falling. Used to suppress drift alerts when long-window drift
        /// is positive but instantaneous direction has reversed.
        var recentHRSlopeBpm: Double?
        /// Aerobic decoupling Pa:Hr — first-half pace/HR vs second-half
        /// pace/HR, percentage drop. Nil before half-time.
        var aerobicDecouplingPercent: Double?
        /// Cadence delta: last-quartile cadence minus first-quartile, spm.
        /// Negative = stride breaking down. Nil before ~7 min.
        var cadenceDriftSpm: Double?
        /// Pace adjusted for current grade (Minetti 2002 energy cost).
        /// Sec/km. Nil when no current pace or grade.
        var gradeAdjustedPaceSecPerKm: Double?
        /// Last up-to-3 1 km splits, each grade-adjusted by that
        /// split's average grade. Index 0 = most recent. Empty when
        /// no completed splits yet.
        var recentSplitGradeAdjustedPaces: [Double] = []
        /// Heuristic minutes-until-fade based on the live HR drift
        /// trajectory (linear extrapolation to 10 % drift).
        /// Surface as "rough" — physiology is non-linear. Nil when
        /// drift is flat / negative / not yet computable.
        var projectedMinutesUntilFade: Double?

        // --- Historical sport baselines (cross-workout)
        // captured at workout start so the AI can compare today vs
        // typical without an archive scan per turn. ---

        /// Distance-weighted avg pace across the user's recent
        /// workouts of the same sport, sec/km. Nil when no prior matches.
        var historicalSportAvgPaceSecPerKm: Double?
        /// Sample-weighted avg HR across the same window. Nil when none.
        var historicalSportAvgHR: Double?
        /// Sample-weighted avg α1 across the same window. Nil when none.
        var historicalSportAvgAlpha1: Double?
        /// How many prior workouts contributed to the averages above.
        /// 0 means "no historical context yet."
        var historicalSportSampleCount: Int = 0

        // --- Today's frozen readiness snapshot, captured
        // at workout start. Lets the AI frame "is this a push day or
        // back-off day?" with real numbers. ---

        /// Today's frozen recovery score on a 0–100 scale.
        var todayRecoveryScore: Double?
        /// Today's HRV ANS readiness on a 0–100 scale.
        var todayTrainingReadiness: Double?
        /// Acute Training Load (7-day EWMA TRIMP).
        var todayATL: Double?
        /// Chronic Training Load (42-day EWMA).
        var todayCTL: Double?
        /// Training Stress Balance (CTL − ATL). Negative = fatigued.
        var todayTSB: Double?
        /// Forward-looking: days until TSB ≥ 0 with zero added load
        /// (rest forecast). 0 = already fresh. Nil when fresh OR
        /// recovery would take >30 days.
        var projectedDaysUntilFresh: Int?
        /// Forward-looking: tomorrow's TSB if today's TRIMP repeats
        /// (steady-state forecast). Nil when no projection inputs.
        var projectedTSBTomorrowSteadyState: Double?
        /// Garmin-style "recovery time" — hours until TSB ≥ 0 with
        /// zero added load. Nil when already fresh OR no inputs.
        var recoveryHoursNeeded: Double?

        /// Live time-in-zone breakdown (5 zones by percent of max HR,
        /// seconds in each). Defaulted to 0 so back-compat sessions look like
        /// "no zone data yet" naturally.
        var zone1Sec: Int = 0
        var zone2Sec: Int = 0
        var zone3Sec: Int = 0
        var zone4Sec: Int = 0
        var zone5Sec: Int = 0
        /// Most-time-in zone (1–5). Nil before any HR samples.
        var dominantZone: Int?

        /// Riegel race-time predictions (total seconds) at canonical
        /// distances. All nil when no comparable history.
        var predictedRaceTime5KSec: Double?
        var predictedRaceTime10KSec: Double?
        var predictedRaceTimeHalfSec: Double?
        var predictedRaceTimeMarathonSec: Double?

        struct RouteTopologySnapshot: Codable, Equatable {
            let climbsAhead: [ClimbSnapshot]
            let totalAscentRemainingMeters: Double
            let peakAltitudeMeters: Double
            let altitudeAboveRouteMinMeters: Double
            let steepestGradeAheadPercent: Double?
            let metersToPeak: Double
            /// Upcoming direction changes derived from the
            /// route polyline. See `WorkoutAIContext.UpcomingTurn`.
            /// Defaulted for back-compat with sessions persisted before
            /// the field existed.
            var turnsAhead: [TurnSnapshot] = []

        }

        struct WeatherSnapshot: Codable, Equatable {
            let temperatureC: Double
            let apparentTemperatureC: Double
            let windKMH: Double
            let windDirectionDegrees: Double
            let humidityPercent: Double
            let conditions: String
            let observedAt: Date
        }

        // --- Threshold-coach state (closes the loop on the user's
        // pre-declared "don't let HR exceed 135 for 30s" thresholds —
        // the AI can now answer "what thresholds did I set?" and "am I
        // breaching anything right now?") ---

        /// User's active thresholds for this workout. Empty when the user
        /// chose silent / no-threshold mode. Each entry mirrors the
        /// `WorkoutThreshold` model's salient fields in a Codable shape.
        var activeThresholds: [ThresholdSnapshot] = []

        /// Per-threshold breach state. Indexed by threshold id (UUID
        /// string). `0` means inside the band; positive values are
        /// the consecutive seconds the breach has held. Resets to 0 the
        /// moment the metric returns to safe range. Trigger-rule fires
        /// when a counter crosses the threshold's debounceSec.
        var thresholdBreachSec: [String: Int] = [:]

        struct ThresholdSnapshot: Codable, Equatable {
            let id: String              // UUID string for indexing into thresholdBreachSec
            let metric: String          // "hr_bpm", "hr_zone", "power_watts", …
            let condition: String       // "gt" or "lt"
            let value: Double
            let debounceSec: Int
            let cooldownSec: Int
            let userCue: String?
        }

        // --- Interval plan progress (the voice coach already announces
        // step changes; this lets the AI introspect the plan when asked
        // "what step am I on?" / "how long until the next interval?") ---

        /// Active interval plan progress. Nil when the user didn't bind
        /// a plan, or when the plan has finished. Populated each tick
        /// from the recorder's `IntervalController`.
        var intervalProgress: IntervalProgressSnapshot?

        struct IntervalProgressSnapshot: Codable, Equatable {
            /// 1-based step number for human display ("step 3 of 8").
            let currentStepNumber: Int
            let totalSteps: Int
            /// Free-text label for the current step ("3 min @ Z4",
            /// "easy spin 5 min", "all out 30s"). Sourced from the step's
            /// own description so the AI can read it back verbatim.
            let currentStepLabel: String
            let stepElapsedSec: Int
            /// Seconds remaining in the current step. nil for distance-
            /// based steps where time-remaining isn't computable.
            let stepRemainingSec: Int?
            /// Free-text label for the NEXT step, nil on the final step.
            let nextStepLabel: String?
            let isFinished: Bool
        }
    }

    /// Live HRV-recording snapshot. Populated whenever RRCollector is in
    /// a non-idle phase (quick streaming, overnight, paused, analyzing).
    /// Distinct from `LiveWorkoutSnapshot` — a user can be mid-workout
    /// (workout snapshot) AND recording HRV (this snapshot), or either
    /// one independently. Both appear in the live block so "what's my
    /// current beat count?" or "how long has tonight's recording been
    /// going?" have honest answers instead of the AI confabulating.
    struct LiveHRVSnapshot: Codable {
        /// Machine-readable phase label ("idle", "streaming", "overnight",
        /// "paused", "analyzing", "awaitingAcceptance"). Humans read
        /// `phaseDescription` instead.
        let phase: String
        /// Human-readable phase ("Quick streaming", "Overnight recording",
        /// "Paused", "Analyzing last night"). What the AI should use in
        /// a reply to the user.
        let phaseDescription: String
        /// True only while beats are actively landing. Paused/analyzing
        /// phases have a session but aren't collecting.
        let isCollecting: Bool
        /// Total RR beats captured in the active session so far.
        let beatCount: Int
        /// Seconds since the active session started, or nil if it hasn't
        /// started yet (e.g. pre-warm / permission check).
        let elapsedSeconds: Int?
        /// Wall-clock timestamp of when the current session began, nil
        /// when no session is in flight yet.
        let sessionStartAt: Date?
        /// Wall-clock timestamp of THIS snapshot. Lets the AI distinguish
        /// "truly live right now" vs stale state.
        let snapshotAt: Date
        /// Last-error surface — populated when a recording stumbled. The
        /// AI can explain *why* a session is paused rather than guessing.
        let lastErrorDescription: String?
    }
}

// Climb and turn rows for `RouteTopologySnapshot`, declared in an extension so
// the nesting stays two deep. Same types, same Codable shape as when nested.
extension AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot {
    struct ClimbSnapshot: Codable, Equatable {
        let distanceToStartMeters: Double
        let lengthMeters: Double
        let gainMeters: Double
        let gradePercent: Double
        /// Reverse-geocoded street name where the climb starts
        /// ("Elm Street", "Ridge Rd"). Resolved at SavedRoute
        /// save time and cached on the route, so the AI can say
        /// "the climb on Elm Street is in 0.4 miles." Nil when
        /// the route was bound from a one-off GPX (no save-time
        /// geocoding pass) or when the geocoder failed for that
        /// coordinate.
        var roadName: String?
    }

    struct TurnSnapshot: Codable, Equatable {
        let distanceMeters: Double
        let bearingChangeDegrees: Double
        let direction: String
    }
}
