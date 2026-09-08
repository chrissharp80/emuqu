import Foundation

// Named replacements for 4- and 5-field tuples that were written out longhand
// at their declaration and every call site. Field names and meanings are
// unchanged throughout, so `.mean` / `.deep` / `.low` reads exactly as before —
// what changes is that the shape has a name, is documented once, and can gain a
// field without editing every signature that mentions it.

/// Heart-rate statistics over a rolling-window analysis.
///
/// Distinct from ``HeartRateStats``, which summarises a HealthKit query and
/// carries the timestamp of the nadir. This one is the RR-derived form: it
/// carries the standard deviation the analysis needs and no timestamp.
struct HRWindowStatistics: Equatable, Sendable {
    let mean: Double
    let sd: Double
    let min: Double
    let max: Double
}

/// Artifact composition of an RR series, as reported by verification.
struct ArtifactBreakdown: Equatable, Sendable {
    /// Share of beats flagged as artifact, 0–100.
    let artifactPercent: Double
    /// Ectopic, extra, and missed beats combined.
    let ectopyCount: Int
    /// Beats below the physiological floor.
    let oobLowCount: Int
    /// Beats above the physiological ceiling.
    let oobHighCount: Int
}

/// Age- and sex-adjusted RMSSD band edges, in milliseconds.
///
/// Percentiles relative to the age-adjusted median: `low` is the 25th, `fair`
/// the 50th, `good` the 75th, `excellent` above it.
struct RMSSDThresholds: Equatable, Sendable {
    let low: Double
    let fair: Double
    let good: Double
    let excellent: Double
}

/// Minutes spent in each sleep stage.
///
/// `unspecified` intervals are folded into ``core`` — the same convention the
/// accumulator has always used, now stated where the type is defined rather
/// than only inside the loop that applies it.
struct SleepStageMinutes: Equatable, Sendable {
    let deep: Int
    let rem: Int
    let core: Int
    let awake: Int
}

/// Training-load state at a point in time.
///
/// `acwr` is optional because the acute:chronic ratio is undefined until there
/// is enough chronic history to divide by.
struct TrainingLoadState: Equatable, Sendable {
    /// Acute training load.
    let atl: Double
    /// Chronic training load.
    let ctl: Double
    /// Training stress balance (`ctl - atl`).
    let tsb: Double
    /// Acute:chronic workload ratio, or `nil` before the baseline matures.
    let acwr: Double?
}
