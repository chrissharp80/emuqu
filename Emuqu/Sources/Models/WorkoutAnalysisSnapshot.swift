import Foundation

// MARK: - Workout Analysis Snapshot
//
// Pre-computed, persistable derivatives of a workout session's raw
// sample stream. Built ONCE at finalize time by
// `WorkoutAnalysisSnapshotBuilder` and stored on
// `WorkoutMetadata.analysisSnapshot`. Every summary render then reads
// cached fields instead of iterating the 3 000+ sample array on every
// SwiftUI body pass (multiple O(n) scans per render is what makes
// post-summary loading feel blocking).
//
// Persisting the snapshot also means the CSV / PDF exporters and the
// AI context read the same cached insights, so a single source of
// truth feeds every surface that reports a "session summary."
//
// Additive-only field layout. New fields decode to nil for older
// snapshots, so the schema evolves without breaking stored sessions.
struct WorkoutAnalysisSnapshot: Codable, Equatable {
    /// Schema marker for safe forward migration. Bump when the *computation
    /// logic* inside `WorkoutAnalysisSnapshotBuilder` changes such that a
    /// stored snapshot is no longer an accurate reflection of the source
    /// samples. Views that open a session with an older `schemaVersion`
    /// re-run the builder and write the result back so history rebuilds
    /// itself one-visit-at-a-time — no blocking launch-time migration.
    ///
    /// Version history:
    /// - v1: initial schema.
    /// - v2: α1 first-cross detector gained a 120 s warmup
    ///   window + 30 s sustain requirement (the user-reported "threshold
    ///   crossing at 4:00 on a Zone-1 walk" bug). Moving-time detection
    ///   switched from "pace > 0" (which failed at casual walk speeds
    ///   because of a 2.5-m GPS-delta gate upstream) to OR-of-three-signals
    ///   + elapsed-seconds accumulation. Stored v1 snapshots carry the
    ///   old, wrong numbers — rebuild on next view.
    static let currentVersion = 2
    let schemaVersion: Int

    // MARK: α1 physiology

    let alpha1Mean: Double?
    let alpha1Max: Double?
    let alpha1Min: Double?
    /// Seconds the user spent in each α1 regime.
    let secondsBelowAT1: Int?      // α1 ≥ 0.75  (easy — below aerobic threshold)
    let secondsBetweenAT1AT2: Int? // 0.50 ≤ α1 < 0.75 (threshold band)
    let secondsAboveAT2: Int?      // α1 < 0.50  (hard — above anaerobic)
    /// First downward α1 = 0.75 crossing — the α1-derived LT1 estimate.
    let firstAT1CrossingOffsetSec: Int?
    let firstAT1CrossingHR: Int?
    /// Dominant α1 band (easy / threshold / hard) — what the user spent
    /// the most time in, for the hero's colored pill.
    let dominantAlpha1BandRaw: String?

    // MARK: HR zone distribution

    /// Time in each of Z1..Z5 in seconds. Zones derived from
    /// user-max-HR at finalize time (not session peak).
    let hrZoneSeconds: [Int]?
    let dominantHRZone: Int?   // 1-5
    let dominantHRZonePercent: Int?  // 0-100

    // MARK: Splits

    /// Index of the fastest split (1-based). Nil for indoor / no-track.
    let fastestSplitIndex: Int?
    let fastestSplitPaceSecPerKm: Double?
    let slowestSplitIndex: Int?
    let slowestSplitPaceSecPerKm: Double?

    // MARK: Derived energy / economy

    let movingTimeSec: Int?
    let movingTimePercent: Int?
    let vamMetersPerHour: Double?           // vertical ascent rate
    let calorieRatePerHour: Double?         // kcal/hr
    let estimatedTotalCalories: Double?
    let strideLengthMeters: Double?
    let powerHRRatio: Double?               // W/bpm (running economy proxy)
    let gradeAdjustedPaceSecPerKm: Double?

    // MARK: Relative effort / context

    /// "Hardest session in the last N days" label if applicable. nil
    /// when no history context was available.
    let relativeEffortLabel: String?

    // MARK: Session narrative

    /// The "how you did" coach-style narrative string, pre-generated so
    /// the in-app card and the PDF's executive-summary page agree
    /// verbatim.
    let howYouDidNarrative: String?
    /// Hero plain-English α1 summary ("Solid aerobic-base effort…").
    let heroNarrative: String?

    // MARK: Init

    // spec:long-function A memberwise initializer is one assignment per stored
    // property and nothing else — no branches, no calls, no logic to extract.
    // Swift additionally forbids calling a helper on `self` before every stored
    // property is initialized, so the body cannot be split even mechanically.
    // Splitting the TYPE would be the real fix; that is tracked separately and
    // is not a formatting change.
    init(
        schemaVersion: Int = WorkoutAnalysisSnapshot.currentVersion,
        alpha1Mean: Double? = nil,
        alpha1Max: Double? = nil,
        alpha1Min: Double? = nil,
        secondsBelowAT1: Int? = nil,
        secondsBetweenAT1AT2: Int? = nil,
        secondsAboveAT2: Int? = nil,
        firstAT1CrossingOffsetSec: Int? = nil,
        firstAT1CrossingHR: Int? = nil,
        dominantAlpha1BandRaw: String? = nil,
        hrZoneSeconds: [Int]? = nil,
        dominantHRZone: Int? = nil,
        dominantHRZonePercent: Int? = nil,
        fastestSplitIndex: Int? = nil,
        fastestSplitPaceSecPerKm: Double? = nil,
        slowestSplitIndex: Int? = nil,
        slowestSplitPaceSecPerKm: Double? = nil,
        movingTimeSec: Int? = nil,
        movingTimePercent: Int? = nil,
        vamMetersPerHour: Double? = nil,
        calorieRatePerHour: Double? = nil,
        estimatedTotalCalories: Double? = nil,
        strideLengthMeters: Double? = nil,
        powerHRRatio: Double? = nil,
        gradeAdjustedPaceSecPerKm: Double? = nil,
        relativeEffortLabel: String? = nil,
        howYouDidNarrative: String? = nil,
        heroNarrative: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.alpha1Mean = alpha1Mean
        self.alpha1Max = alpha1Max
        self.alpha1Min = alpha1Min
        self.secondsBelowAT1 = secondsBelowAT1
        self.secondsBetweenAT1AT2 = secondsBetweenAT1AT2
        self.secondsAboveAT2 = secondsAboveAT2
        self.firstAT1CrossingOffsetSec = firstAT1CrossingOffsetSec
        self.firstAT1CrossingHR = firstAT1CrossingHR
        self.dominantAlpha1BandRaw = dominantAlpha1BandRaw
        self.hrZoneSeconds = hrZoneSeconds
        self.dominantHRZone = dominantHRZone
        self.dominantHRZonePercent = dominantHRZonePercent
        self.fastestSplitIndex = fastestSplitIndex
        self.fastestSplitPaceSecPerKm = fastestSplitPaceSecPerKm
        self.slowestSplitIndex = slowestSplitIndex
        self.slowestSplitPaceSecPerKm = slowestSplitPaceSecPerKm
        self.movingTimeSec = movingTimeSec
        self.movingTimePercent = movingTimePercent
        self.vamMetersPerHour = vamMetersPerHour
        self.calorieRatePerHour = calorieRatePerHour
        self.estimatedTotalCalories = estimatedTotalCalories
        self.strideLengthMeters = strideLengthMeters
        self.powerHRRatio = powerHRRatio
        self.gradeAdjustedPaceSecPerKm = gradeAdjustedPaceSecPerKm
        self.relativeEffortLabel = relativeEffortLabel
        self.howYouDidNarrative = howYouDidNarrative
        self.heroNarrative = heroNarrative
    }
}
