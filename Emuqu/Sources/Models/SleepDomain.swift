import Foundation

// Sleep domain model.
//
// These seven types live here rather than nested inside `HealthKitManager`,
// a very large class whose job is HealthKit I/O. They are
// not I/O; they are the vocabulary the analysis layer speaks. Nearly every
// reference to `HealthKitManager` from `Analysis/` is to one of these
// types, not to `.shared`. So the analysis layer is not
// CALLING HealthKit at all; nesting would put the name of the I/O
// class in every pure function's signature, which is the dependency direction
// the refactor spec forbids: "pure logic never imports the world."
//
// Housing them here inverts that without touching a single call site.
// `HealthKitManager` keeps a typealias for each, exactly as it already did for
// `SleepData` — that precedent is why this is a safe move rather than a
// rename sweep. JSON is unaffected: `Codable` synthesises from property names,
// not from the enclosing type, and no code derives a persisted discriminator
// from the type name.

enum SleepBoundarySource: String, Codable {
    case healthKit = "HealthKit" // From Apple Watch/HealthKit
    case hrValidated = "HR Validated" // HealthKit boundaries validated/adjusted by HR analysis
    case hrEstimated = "HR Estimated" // Estimated from HR drop patterns (no HealthKit data)
    case healthKitHREstimated = "HK HR Estimated" // Estimated from HealthKit background HR samples (Apple Watch passive monitoring)
    case recordingBounds = "Recording" // Using recording start/end as fallback
}

/// Metadata showing how sleep boundaries were resolved when HR data is available.
/// Carries both HealthKit and HR-detected times so the UI can show transparency.
struct SleepBoundaryValidation: Codable {
    let healthKitStart: Date?
    let healthKitEnd: Date?
    let hrDetectedStart: Date?
    let hrDetectedEnd: Date?
    /// Positive = HR detected sleep earlier than HealthKit (boundary extended)
    let startAdjustmentMinutes: Int?
    /// Positive = HR detected wake later than HealthKit (boundary extended)
    let endAdjustmentMinutes: Int?
}

/// RMSSD-derived sleep quality metrics from continuous RR data.
/// Provides physiological sleep quality measures that Apple Watch doesn't offer.
struct HRSleepQuality: Codable {
    /// Average RMSSD during sleep (parasympathetic tone)
    let avgSleepRMSSD: Double
    /// Minutes spent in high-RMSSD (restorative/parasympathetic dominant) state
    let restorativeSleepMinutes: Int
    /// Ratio of restorative time to total sleep (0.0–1.0)
    let restorativeSleepRatio: Double
    /// Average heart rate during sleep
    let avgSleepHR: Double
    /// Lowest heart rate window during sleep (likely deepest sleep)
    let minSleepHR: Double
}

/// A single contiguous sleep segment (part of a potentially split night)
struct SleepSegment: Codable {
    let sleepStart: Date
    let sleepEnd: Date
    let totalSleepMinutes: Int
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let coreSleepMinutes: Int?
    let awakeMinutes: Int
}

/// Individual sleep stage period for timeline visualization
enum SleepStage: String, Codable {
    case deep, core, rem, awake, unspecified
}

/// Source of a single stage interval. Preserved through edits so the
/// timeline editor can color-code provenance (Watch vs. HRV-derived vs. user)
/// and the scoring pipeline can decide how much to trust each slice.
enum SleepStageProvenance: String, Codable {
    case watch // Apple Watch stage sample
    case iphone // InBed sample from phone accelerometer
    case hrvDerived // inferred by SleepMergingPipeline from HR
    case userAdded // user-declared sleep (new segment)
    case userCarved // user-declared awake inside a sleep segment
    case userAdjusted // boundary pulled by the user
}

struct SleepStageInterval: Identifiable, Codable, Equatable {
    let id: UUID
    let stage: SleepStage
    let start: Date
    let end: Date
    /// Where this interval came from. Defaults to `.watch` on decode for
    /// archives written before provenance was tracked.
    var provenance: SleepStageProvenance

    init(stage: SleepStage, start: Date, end: Date, provenance: SleepStageProvenance = .watch) {
        id = UUID()
        self.stage = stage
        self.start = start
        self.end = end
        self.provenance = provenance
    }

    /// Whole minutes, rounded from seconds. Every per-stage total — the
    /// resolver's night, the sleep editor's, segments, stage scores — sums
    /// this one value, so the same stages always give the same total.
    /// Truncating instead loses up to a minute per stage, which on a night of
    /// a few dozen Watch stages is several minutes.
    var durationMinutes: Int {
        Int((end.timeIntervalSince(start) / 60).rounded())
    }

    /// Explicit Codable init so archives missing the `provenance` field
    /// decode with `.watch` rather than failing. Preserves the existing
    /// contract for pre-provenance archives and CloudKit records.
    private enum CodingKeys: String, CodingKey { case id, stage, start, end, provenance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        stage = try c.decode(SleepStage.self, forKey: .stage)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        provenance = try c.decodeIfPresent(SleepStageProvenance.self, forKey: .provenance) ?? .watch
    }
}
