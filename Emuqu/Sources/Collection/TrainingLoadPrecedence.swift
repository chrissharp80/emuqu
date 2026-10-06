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
    /// The FTPs a read-time power TSS is anchored to: what
    /// `UserSettings.effectiveRunningFTP` / `effectiveCyclingFTP` resolve
    /// (a user-entered FTP, else the running auto-estimate). Plain values,
    /// so the ladder below runs off the main actor.
    struct FTPAnchors: Equatable, Codable, Sendable {
        let running: Int?
        let cycling: Int?

        static let none = FTPAnchors(running: nil, cycling: nil)

        /// The anchors in `settings`, read without the main actor: the user's
        /// entered FTPs, and for running the auto-estimate when none is set
        /// (`FTPAutoEstimator.cachedRunningFTP`, the fallback
        /// `effectiveRunningFTP` uses).
        nonisolated static func current(_ settings: UserSettings) -> FTPAnchors {
            let running = settings.runningFTPWatts.flatMap { $0 > 0 ? $0 : nil } ?? FTPAutoEstimator.cachedRunningFTP
            let cycling = settings.cyclingFTPWatts.flatMap { $0 > 0 ? $0 : nil }
            return FTPAnchors(running: running, cycling: cycling)
        }

        /// The FTP for `sport`; nil for sports with no power FTP (rowing,
        /// air bike, CrossFit).
        nonisolated func ftp(for sport: Sport) -> Int? {
            switch sport {
            case .run, .trailRun, .walk, .hike, .treadmill: running
            case .bike, .indoorBike: cycling
            default: nil
            }
        }
    }

    /// Hand the resolver's preferred load (powerTSS > route estimate when
    /// it replaces a strap-dropout HR load > hrTSS > METs > luciaTRIMP >
    /// extrapolatedTRIMP) through to the daily-TRIMP builder
    /// so ATL/CTL/TSB anchor on the most accurate available source — for
    /// power-equipped users, that's powerTSS on every workout instead of an
    /// HR-derived approximation.
    ///
    /// The power tier is the TSS stored at finalize (`storedPowerTSS`), or,
    /// for a session that finalized before any FTP was known, the TSS
    /// derived now from its stored NP and today's FTP (`readTimePowerTSS`).
    /// That is the figure the workout's own row shows
    /// (`WorkoutMetadata.preferredTrainingLoad`), so once an FTP is set or
    /// auto-estimated, historical power sessions count as power TSS in
    /// ATL/CTL too, not as their heart-rate estimate.
    ///
    /// Reads only stored fields and the `ftp` values passed in, so it runs
    /// off the main actor. The default reads the FTPs from the settings
    /// snapshot.
    ///
    /// The `.mets` tier must stay. `computedMETLoad` isn't a stored scalar,
    /// but it reads ONLY `meta.samples` (no SettingsManager), and samples
    /// ARE populated by the `archive.retrieveLightweight` read in
    /// `WorkoutSummary.summary(from:archive:)` (HealthDataTypes.swift), so
    /// it's safe off-main. Dropping it under-counted load for any workout
    /// with no power and no stored hrTSS — e.g. treadmill walks, which then
    /// fell all the way through to the HR-Banister fallback (low for
    /// easy-HR walks) or nil. Real-world hit: a user doing MORE treadmill
    /// volume saw TSB sit at ~−2 instead of the expected ~−13 because each
    /// walk's MET-based load never reached ATL.
    ///
    /// `internal` rather than `private` so the PRECEDENCE can
    /// be tested. The order is the whole content of this function, and the
    /// effect of a lost tier or a wrong
    /// order is a training load that is silently too low or too high for
    /// every historical workout — which then feeds CTL, ATL, TSB and every
    /// recommendation built on them.
    nonisolated static func stored(
        _ meta: WorkoutMetadata,
        ftp: FTPAnchors = .current(AppDependencies.current.app.settingsManager.settingsSnapshot)
    ) -> (value: Double, source: WorkoutMetadata.TrainingLoadSource)? {
        if let p = meta.storedPowerTSS ?? readTimePowerTSS(meta, ftp: ftp) { return (p, .power) }
        if meta.routeEstimateReplacesHRLoad, let e = meta.extrapolatedTRIMP { return (e, .routeHistory) }
        if let h = meta.hrTSS, h > 0 { return (h, .hr) }
        if let m = meta.computedMETLoad, m > 0 { return (m, .mets) }
        if let l = meta.luciaTRIMP, l > 0 { return (l, .banister) }
        if let e = meta.extrapolatedTRIMP, e > 0 { return (e, .routeHistory) }
        return nil
    }

    /// Coggan power TSS derived now, for a session stored with NP but no
    /// power TSS (it finalized before an FTP was known): IF² × moving hours
    /// × 100, IF = NP / today's FTP for the sport. Moving hours are the last
    /// sample's offset, as for the finalize value. Nil without NP, without an
    /// FTP for the sport, or under a minute of samples.
    nonisolated static func readTimePowerTSS(_ meta: WorkoutMetadata, ftp: FTPAnchors) -> Double? {
        guard let np = meta.normalizedPowerWatts, np > 0,
              let anchor = ftp.ftp(for: meta.sport), anchor > 0,
              let movingSec = meta.samples?.map(\.offsetSec).max(), movingSec > 60
        else { return nil }
        let intensityFactor = np / Double(anchor)
        let tss = intensityFactor * intensityFactor * (Double(movingSec) / 3600.0) * 100.0
        return tss > 0 ? tss : nil
    }
}
