import Foundation

/// Which of a workout's five possible training-load figures it is actually
/// scored by, lifted out of `HealthKitManager.WorkoutSummary`.
///
/// The order below IS the function, and the number it picks becomes the
/// workout's contribution to CTL, ATL and TSB — so every recommendation the app
/// makes rests on it. Drop the METs tier and treadmill walks fall through to
/// an HR fallback that reads low for easy walking: a user doing MORE volume
/// watches TSB sit at ~−2 instead of ~−13.
///
/// Its own type because a precedence rule about training load is a domain fact,
/// not a HealthKit detail, and because a rule this consequential should be
/// somewhere a test can reach without an actor hop.
enum TrainingLoadPrecedence {
    /// Hand the resolver's preferred load (powerTSS > route estimate when
    /// it replaces a strap-dropout HR load > hrTSS > METs > luciaTRIMP >
    /// extrapolatedTRIMP) through to the daily-TRIMP builder
    /// so ATL/CTL/TSB anchor on the most accurate available source — for
    /// power-equipped users, that's powerTSS on every workout instead of an
    /// HR-derived approximation.
    ///
    /// Uses only STORED fields so this can run off
    /// the main actor (the canonical `meta.preferredTrainingLoad` is
    /// `@MainActor` because it reads `SettingsManager` for FTP
    /// auto-estimate). Effect: live FTP-derived powerTSS for sessions that
    /// finalized without an FTP anchor is computed by the in-session code
    /// path and persisted to `meta.powerTSS` on archive write, so the
    /// stored value here is sufficient for historical training-load math.
    ///
    /// The `.mets` tier must stay. A "stored
    /// fields only" reading would drop `computedMETLoad` because it isn't a
    /// stored scalar — but it reads ONLY `meta.samples` (no
    /// SettingsManager), and samples ARE populated by the
    /// `archive.retrieveLightweight` read in `WorkoutSummary.summary(from:archive:)`
    /// (HealthDataTypes.swift), so it's safe off-main. Dropping it under-counted load for any
    /// workout with no power and no stored hrTSS — e.g. treadmill walks,
    /// which then fell all the way through to the HR-Banister fallback (low
    /// for easy-HR walks) or nil. Real-world hit: a user doing MORE
    /// treadmill volume saw TSB sit at ~−2 instead of the expected ~−13
    /// because each walk's MET-based load never reached ATL.
    /// `computedPowerTSS` (FTP-derived) is deliberately NOT a tier here —
    /// it reads SettingsManager (@MainActor) and its value is already
    /// persisted to `meta.powerTSS` at archive write, covered by tier 1.
    ///
    /// `internal` rather than `private` so the PRECEDENCE can
    /// be tested. The order is the whole content of this function, and the
    /// effect of a lost tier or a wrong
    /// order is a training load that is silently too low or too high for
    /// every historical workout — which then feeds CTL, ATL, TSB and every
    /// recommendation built on them.
    nonisolated static func stored(_ meta: WorkoutMetadata) -> (value: Double, source: WorkoutMetadata.TrainingLoadSource)? {
        if let p = meta.storedPowerTSS { return (p, .power) }
        if meta.routeEstimateReplacesHRLoad, let e = meta.extrapolatedTRIMP { return (e, .routeHistory) }
        if let h = meta.hrTSS, h > 0 { return (h, .hr) }
        if let m = meta.computedMETLoad, m > 0 { return (m, .mets) }
        if let l = meta.luciaTRIMP, l > 0 { return (l, .banister) }
        if let e = meta.extrapolatedTRIMP, e > 0 { return (e, .routeHistory) }
        return nil
    }
}
