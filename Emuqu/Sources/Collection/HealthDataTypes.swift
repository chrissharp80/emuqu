import Foundation
import HealthKit

// The data types HealthKit reads and writes flow through.
//
// They were nested inside `HealthKitManager` — 435 lines of `struct` and `enum`
// declarations on a 2,925-line type that the aggregate type-size gate counts in
// full. They are data, not behaviour: nothing here touches the store, the
// authorization state or a query.
//
// Top-level types, with typealiases left behind so the existing
// `HealthKitManager.WorkoutSummary`-style references keep working
// unchanged.

struct HealthWorkoutSummary: Codable {
    let date: Date
    let workoutType: String // Store as string for Codable
    let durationMinutes: Double
    let caloriesBurned: Double?
    let averageHR: Double?
    let maxHR: Double?
    /// Pre-computed training load (TSS or TRIMP scale)
    /// carried straight from `WorkoutMetadata.preferredTrainingLoad`
    /// when this summary was built from the app's own archive. When
    /// non-nil, `effectiveLoad(...)` returns this directly instead
    /// of computing HR-based Banister TRIMP from `averageHR`. This
    /// is what lets the daily TRIMP buildup — and therefore ATL,
    /// CTL, and TSB — anchor on powerTSS for power-equipped users
    /// rather than on HR alone. HealthKit-sourced summaries leave
    /// this `nil`, falling back to HR TRIMP as before.
    let precomputedLoad: Double?
    /// Source tag for the precomputed load (display + debugging).
    let precomputedLoadSource: String?
    /// True when this summary came from a crash-recovered / partial session
    /// (`WorkoutMetadata.partialDataReason != nil`). `effectiveLoad` distrusts
    /// an implausibly long recovered session (a recording that never stopped)
    /// until the user trims it. HealthKit-sourced summaries are `false`.
    let wasRecovered: Bool

    init(
        date: Date,
        type: HKWorkoutActivityType,
        durationMinutes: Double,
        caloriesBurned: Double?,
        averageHR: Double?,
        maxHR: Double?,
        precomputedLoad: Double? = nil,
        precomputedLoadSource: String? = nil,
        wasRecovered: Bool = false
    ) {
        self.date = date
        workoutType = HealthWorkoutSummary.typeToString(type)
        self.durationMinutes = durationMinutes
        self.caloriesBurned = caloriesBurned
        self.averageHR = averageHR
        self.maxHR = maxHR
        self.precomputedLoad = precomputedLoad
        self.precomputedLoadSource = precomputedLoadSource
        self.wasRecovered = wasRecovered
    }

    // Explicit Codable so `wasRecovered` (a newer field) defaults to
    // false when decoding any older-encoded HealthWorkoutSummary rather than
    // failing the whole decode.
    private enum CodingKeys: String, CodingKey {
        case date, workoutType, durationMinutes, caloriesBurned
        case averageHR, maxHR, precomputedLoad, precomputedLoadSource, wasRecovered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        workoutType = try c.decode(String.self, forKey: .workoutType)
        durationMinutes = try c.decode(Double.self, forKey: .durationMinutes)
        caloriesBurned = try c.decodeIfPresent(Double.self, forKey: .caloriesBurned)
        averageHR = try c.decodeIfPresent(Double.self, forKey: .averageHR)
        maxHR = try c.decodeIfPresent(Double.self, forKey: .maxHR)
        precomputedLoad = try c.decodeIfPresent(Double.self, forKey: .precomputedLoad)
        precomputedLoadSource = try c.decodeIfPresent(String.self, forKey: .precomputedLoadSource)
        wasRecovered = try c.decodeIfPresent(Bool.self, forKey: .wasRecovered) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(workoutType, forKey: .workoutType)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encodeIfPresent(caloriesBurned, forKey: .caloriesBurned)
        try c.encodeIfPresent(averageHR, forKey: .averageHR)
        try c.encodeIfPresent(maxHR, forKey: .maxHR)
        try c.encodeIfPresent(precomputedLoad, forKey: .precomputedLoad)
        try c.encodeIfPresent(precomputedLoadSource, forKey: .precomputedLoadSource)
        try c.encode(wasRecovered, forKey: .wasRecovered)
    }

    /// A `switch` with explicit cases
    /// + `default:` triggered "Default will never be executed" on
    /// some Xcode versions, while `@unknown default:` triggered
    /// "switch must be exhaustive" because HKWorkoutActivityType has
    /// 70+ visible cases this app doesn't enumerate. Dictionary
    /// lookup with `?? "Workout"` sidesteps both warnings and is
    /// also slightly faster (single hash lookup vs. linear case scan).
    private static let typeToStringMap: [HKWorkoutActivityType: String] = [
        .running: "Running",
        .cycling: "Cycling",
        .swimming: "Swimming",
        .functionalStrengthTraining: "Strength",
        .traditionalStrengthTraining: "Strength",
        .highIntensityIntervalTraining: "HIIT",
        .yoga: "Yoga",
        .walking: "Walking",
        .hiking: "Hiking",
        .rowing: "Rowing",
        .crossTraining: "Cross Training",
        .elliptical: "Elliptical",
        .stairClimbing: "Stairs"
    ]

    private static func typeToString(_ type: HKWorkoutActivityType) -> String {
        typeToStringMap[type] ?? "Workout"
    }

    var typeDescription: String {
        workoutType
    }

    /// Extract HealthWorkoutSummary entries from the app's
    /// own SessionArchive. Used by `TrainingMetricsCache.refresh`
    /// to merge with HealthKit-fetched workouts so the training-
    /// load math sees BOTH the user's Apple Health workouts AND
    /// the workouts they recorded in Emuqu — even when
    /// the fire-and-forget HealthKit-export step at WorkoutRecorder
    /// silently failed.
    ///
    /// Sport mapping is best-effort; the TRIMP calculation only
    /// reads `durationMinutes` + `averageHR`, so the activityType
    /// only matters for display in `recentWorkouts` lists. Average
    /// HR comes from the per-tick sample series (the same fallback
    /// `ContextBuilder.buildWorkoutHistory` uses when
    /// `analysisResult.timeDomain.meanHR` is nil — workout sessions
    /// skip the HRV-analysis pipeline that populates that field).
    /// Not `@MainActor`, and the inner read is `archive.retrieveLightweight`
    /// rather than `archive.retrieve`.
    ///
    /// Two beta-user reports converged here:
    ///   • "App hangs ~20 s when I tap Start Workout."
    ///   • The dashboard's training-load card sometimes lags at
    ///     foreground for a similar duration.
    ///
    /// Root cause was this function. It iterates 100+ workout
    /// sessions on the **main actor**, calling the full-decode
    /// `archive.retrieve` for each. Full decode runs an AES-GCM
    /// pass + a JSONDecoder over `rrSeries` (typically thousands of
    /// RR points per session). 50–200 ms per session × 100 = a
    /// 5–20 s MainActor stall. A user tapping "Start Workout" mid-
    /// stall is queued behind it.
    ///
    /// Two fixes, layered:
    ///   1. `retrieveLightweight` skips the `rrSeries` decode (the
    ///      heavy 99 %). All fields this function reads
    ///      (`workoutMetadata.samples`, `meanHR`, `endDate`) are
    ///      preserved.
    ///   2. `SessionArchive` synchronizes via its own NSLock and is
    ///      safe to call from any thread, so the `@MainActor`
    ///      annotation was forcing main-thread work that didn't
    ///      need it. Calculation paths (cache refresh,
    ///      `buildDailySeries`) now await this from a detached task
    ///      and the main thread is free to handle taps.
    static func fromAppArchive(
        archive: SessionArchive,
        days: Int,
        relativeTo referenceDate: Date = Date()
    ) -> [HealthWorkoutSummary] {
        let calendar = Calendar.current
        let endDate = referenceDate
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: endDate)) else {
            return []
        }
        let entries = archive.entries(from: startDate, to: endDate)
            .filter { $0.sessionType == .workout }
        return entries.compactMap { summary(from: $0, archive: archive) }
    }

    /// Minimum duration for a recording to count as a workout. Anything
    /// shorter is a mis-tap or an aborted start.
    private static let minimumWorkoutDurationSec: TimeInterval = 60

    /// Builds one `HealthWorkoutSummary` from an archive entry, or nil when the
    /// entry cannot be decoded, carries no workout metadata, or is too
    /// short to count.
    ///
    /// Kept out of `fromAppArchive` for cyclomatic complexity; almost all
    /// of that function is this per-entry transform. The comments on the
    /// helpers below each record a
    /// specific field incident (the 827-minute duration, the missing
    /// `.mets` tier).
    ///
    /// Lightweight decode — skips `rrSeries`, which is the expensive part.
    /// Workout metadata + sample buffer + meanHR are top-level fields and
    /// remain populated.
    private static func summary(
        from entry: SessionArchiveEntry,
        archive: SessionArchive
    ) -> HealthWorkoutSummary? {
        guard let session = try? archive.retrieveLightweight(entry.sessionId),
              let meta = session.workoutMetadata
        else { return nil }
        let samples = meta.samples ?? []
        let durationSec = clampedDuration(samples: samples, entry: entry)
        guard durationSec >= minimumWorkoutDurationSec else { return nil }
        let sampleHRs = samples.compactMap { $0.heartRate }
        let preferred = TrainingLoadPrecedence.stored(meta)
        return HealthWorkoutSummary(
            date: entry.date,
            type: Self.activityTypeFromSport(meta.sport),
            durationMinutes: durationSec / 60.0,
            caloriesBurned: nil,
            averageHR: session.meanHR ?? Self.mean(sampleHRs),
            maxHR: sampleHRs.max().map(Double.init),
            precomputedLoad: preferred?.value,
            precomputedLoadSource: preferred?.source.rawValue,
            wasRecovered: meta.partialDataReason != nil
        )
    }

    /// Clamp duration to the recording's actual time span.
    /// `samples.last.offsetSec` alone cannot be trusted: a
    /// polluted sample buffer (samples appended past workout end, a
    /// pause/resume merge that scrambled offsets, a stale tick after
    /// finalize) produced absurd durations (827 min for a real 38-min
    /// workout). The recording's endDate-startDate IS bounded by the user
    /// actually stopping the recording, so it's the trustworthy ceiling.
    /// Use the smaller of (last-sample-offset, recording-span).
    private static func clampedDuration(samples: [WorkoutSample], entry: SessionArchiveEntry) -> TimeInterval {
        let lastSampleSec = samples.last.map { TimeInterval($0.offsetSec) }
        let recordingSpanSec = entry.endDate.map { $0.timeIntervalSince(entry.date) }
        switch (lastSampleSec, recordingSpanSec) {
        case let (sample?, span?): return min(sample, span)
        case let (sample?, nil): return sample
        case let (nil, span?): return span
        case (nil, nil): return 0
        }
    }

    private static func mean(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func activityTypeFromSport(_ sport: Sport) -> HKWorkoutActivityType {
        switch sport {
        case .run, .trailRun: .running
        case .walk: .walking
        case .hike: .hiking
        case .bike: .cycling
        case .indoorBike: .cycling
        case .treadmill: .running
        case .row: .rowing
        case .airBike: .cycling
        case .crossFit: .crossTraining
        }
    }

    /// Calculate TRIMP (Training Impulse) using Banister's method.
    /// TRIMP = duration_min × HRR × 0.64 × e^(k × HRR)     (k = 1.92 male, 1.67 female)
    ///
    /// The 0.64 scaling is part of the published formula and is what keeps
    /// TRIMP values in the range third-party trackers (iSmoothRun, Athlytic,
    /// TrainingPeaks) report. Without it a moderate 1-hour walk comes back at
    /// ~100 instead of ~40–50. Matches this file's own
    /// [WorkoutAnalyzer.banisterTRIMP], the beat-level implementation.
    ///
    /// `maxHR` must be the user's physiological max (NOT the workout's peak HR).
    /// Using the workout's own peak as the denominator inverts HR-reserve scoring:
    /// low-effort activities score higher than hard ones because avg HR is always
    /// a large fraction of the workout's own range. When the caller doesn't pass
    /// one we fall back to `AppDependencies.current.app.settingsManager.settings.effectiveMaxHR` so
    /// display-layer callers stay consistent with the training-metrics pipeline.
    ///
    /// Single entry point the daily-load builder uses to ask
    /// "what's the stress score for this workout?" Returns `precomputedLoad`
    /// straight through when present (i.e. the archive's powerTSS / hrTSS
    /// via `preferredTrainingLoad`), otherwise falls back to the HR-only
    /// Banister TRIMP formula. Keeps the call site in `buildDailyTrimp`
    /// simple while letting power-equipped sessions skip the HR estimate.
    ///
    /// Load = Coggan TSS (power) when available, else Banister TRIMP (HR).
    /// Both scale CONTINUOUSLY with intensity AND duration — a resting-HR
    /// session already computes ≈0 (Banister HRR≈0, a smooth taper), and a
    /// long easy session yields its true moderate load.
    ///
    /// There are deliberately NO zeroing guards (duration>10h,
    /// recovered>4h, HR-reserve<0.10, long+low-HR → 0). Per the
    /// training-load literature (Banister; Morton/Fitz-Clarke/Banister 1990;
    /// Coggan TSS; TrainingPeaks PMC) and the reference implementations
    /// (intervals.icu, GoldenCheetah, TrainingPeaks), NO method DISCARDS a
    /// session for being "too long" or "too easy" — that deletes legitimate
    /// ultra-endurance (a 15–24 h event is real, high load) and Zone-1 /
    /// recovery training (which TRIMP/TSS exist to capture). Those guards
    /// were silently cratering load ("way too low"). Corrupt data (a
    /// never-stopped recording) is handled the correct way: by validating
    /// the recorded span — app-recorded workouts already clamp duration to
    /// min(sample-span, recording-span) in `fromAppArchive` — and by capping
    /// ONLY at a non-physiological extreme.
    func effectiveLoad(restingHR: Double = 60, maxHR: Double? = nil) -> Double {
        let base = (precomputedLoad ?? 0) > 0 ? (precomputedLoad ?? 0)
            : calculateTrimp(restingHR: restingHR, maxHR: maxHR)
        return cappedLoad(base)
    }

    /// The ONLY guard the evidence supports: cap a single workout at a
    /// non-physiological extreme. A legitimate 15–24 h ultra is only
    /// ~600–700 TSS, well under this, so real training is untouched; a
    /// corrupt record that slipped past span-validation is bounded here
    /// (one damped ATL bump) instead of cratering the whole PMC. Logged so
    /// genuine corruption stays visible.
    private func cappedLoad(_ base: Double) -> Double {
        guard base > TrainingConstants.TRIMP.maxSingleWorkoutLoad else { return base }
        debugLog("[TrainingLoad] capped \(workoutType) \(date) load \(Int(base)) → \(Int(TrainingConstants.TRIMP.maxSingleWorkoutLoad)) (non-physiological extreme; dur=\(Int(durationMinutes))m src=\(precomputedLoadSource ?? "hr"))", level: .warning)
        return TrainingConstants.TRIMP.maxSingleWorkoutLoad
    }

    /// No average HR → no intensity data → 0 load, NOT a
    /// fabricated 120 bpm. An `averageHR ?? 120` fallback invents a
    /// moderate-intensity TRIMP for HR-less workouts (Strava/manual
    /// imports with no HR), silently inflating ATL/CTL/TSB from nothing.
    /// `effectiveLoad` already prefers `precomputedLoad` (power-TSS /
    /// hr-TSS) when present, so this only zeroes workouts we genuinely have
    /// no intensity signal for.
    ///
    /// Banister TRIMP: dur_min × HRR × A·e^(b·HRR) — Morton, Fitz-Clarke &
    /// Banister, J Appl Physiol 1990;69(3):1171-1177. HRR is Karvonen:
    /// (HR − HRrest)/(HRmax − HRrest) — Karvonen, Kentala & Mustala,
    /// Ann Med Exp Biol Fenn 1957;35(3):307-315.
    ///
    /// No per-workout TRIMP log here. A 120-day training-metrics
    /// fetch hits this function 40+ times, which would flood the log on every
    /// dashboard load and every SwiftUI body rebuild that touched training
    /// readiness. Aggregate-level logs live in the callers
    /// (buildDailyTrimp / TrainingMetricsCache).
    func calculateTrimp(restingHR: Double = 60, maxHR: Double? = nil) -> Double {
        guard let effectiveAvgHR = averageHR else { return 0 }
        let effectiveMaxHR = maxHR ?? Double(AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveMaxHR)
        let hrRange = effectiveMaxHR - restingHR
        let hrReserve = hrRange > 0 ? max(0, min(1, (effectiveAvgHR - restingHR) / hrRange)) : 0
        return durationMinutes * hrReserve * Self.banisterIntensityFactor(hrReserve: hrReserve)
    }

    /// Banister TRIMP weighting differs by biological sex because the
    /// blood-lactate response to exercise intensity differs:
    ///   Male:   0.64 × e^(1.92 × HRR)
    ///   Female: 0.86 × e^(1.67 × HRR)
    /// Source: Banister 1991 / Morton, Fitz-Clarke, Banister 1990.
    ///
    /// Female users were silently scored 13–24 % low (depending on HRR)
    /// before this — the male formula was hard-coded for every user. Falls
    /// back to male values when the user hasn't set a sex preference
    /// (matches the prior default rather than guessing).
    private static func banisterIntensityFactor(hrReserve: Double) -> Double {
        let isFemale = AppDependencies.current.app.settingsManager.settingsSnapshot.biologicalSex == .female
        let k = isFemale ? TrainingConstants.TRIMP.femaleWeighting
                         : TrainingConstants.TRIMP.maleWeighting
        let coefficient = isFemale ? TrainingConstants.TRIMP.femaleScale
                                   : TrainingConstants.TRIMP.maleScale
        return coefficient * exp(k * hrReserve)
    }

    /// Intensity score 0-100 based on duration and HR
    var intensityScore: Double {
        var score = min(durationMinutes / 60.0 * 30, 50) // Up to 50 points for duration (2hr max)

        if let avgHR = averageHR, let maxHR, maxHR > 0 {
            let hrIntensity = avgHR / maxHR
            score += hrIntensity * 50 // Up to 50 points for HR intensity
        } else if let calories = caloriesBurned {
            score += min(calories / 500 * 25, 50) // Fallback: calories
        }

        return min(score, 100)
    }

    /// Whether this counts as a "hard" workout
    var isHardWorkout: Bool {
        intensityScore > 60 || durationMinutes > 60
    }
}

/// An HRV reading from Apple Health (typically from Apple Watch Breathe app)
struct HealthBreatheHRVReading {
    let date: Date
    let sdnn: Double // SDNN in milliseconds
    let sourceName: String // e.g. "Apple Watch" or "Breathe"
}

/// Diagnostic status shown in the UI so the user can see if Watch data is reaching HealthKit.
struct HealthBreatheDiagnostics {
    let lastSDNNDate: Date?
    let lastSDNNValue: Double?
    let lastSDNNSource: String?
    let lastMindfulDate: Date?
    let mindfulSessionCount24h: Int
    let sdnnCount24h: Int
}

// MARK: - Biometric profile fetch
//
// Pulls the three "static" biometric values from Apple Health for
// pre-filling the user's profile: latest body mass, biological sex,
// and date of birth. Each is permission-scoped — the user can deny
// any subset without affecting the rest of the app, and a denied
// read returns nil rather than throwing. Used by the "Fill from
// Apple Health" button on the Biometrics settings page.
struct HealthBiometricProfile {
    let bodyWeightKg: Double?
    let biologicalSex: HKBiologicalSex?
    let dateOfBirth: Date?

    /// The app's `BiologicalSex` for the HealthKit value, or nil when
    /// unset/not-set. Lets non-HealthKit callers (e.g. the AI fact
    /// resolver) map sex without importing HealthKit.
    var appBiologicalSex: UserSettings.BiologicalSex? {
        switch biologicalSex {
        case .female: return .female
        case .male: return .male
        case .other: return .other
        default: return nil
        }
    }
}

enum HealthStoreError: Error, LocalizedError {
    case notAvailable
    case notAuthorized
    case noSleepData
    /// Raised when an HKQuantityType / HKCategoryType
    /// identifier doesn't resolve. Should never occur for the
    /// well-known Apple identifiers we use, but the typed error
    /// replaces force-unwraps that would have crashed the app on
    /// that vanishingly-rare condition (feature-gated identifier,
    /// SDK / runtime mismatch, deprecated identifier).
    case typeUnavailable(String)
    /// A bounded HK query hit its timeout on a path where an
    /// empty result would be UNSAFE (e.g. the pre-save dedup read: an empty
    /// result would skip stale-row deletion and re-create the duplicate
    /// Apple Health rows the idempotent write exists to prevent). Such
    /// callers fail closed with this rather than proceed on no data.
    case queryTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Apple Health is not available on this device"
        case .notAuthorized:
            "Apple Health access not authorized"
        case .noSleepData:
            "No sleep data found for the requested period"
        case let .typeUnavailable(name):
            "Apple Health type '\(name)' is not available on this device"
        case let .queryTimedOut(name):
            "Apple Health query '\(name)' timed out"
        }
    }
}
