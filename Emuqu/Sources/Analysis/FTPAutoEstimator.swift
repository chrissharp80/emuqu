import Foundation

/// Auto-estimate the user's running-power FTP from
/// archived Stryd workouts when they haven't (and won't) set one
/// manually.
///
/// User reality: most people have never done a 20-min FTP test and
/// don't want to. They DO have a Stryd that's recorded power on every
/// walk and run, so the archive already holds the 20-minute efforts a
/// test would ask for.
///
/// The estimate is the TrainingPeaks / Coggan convention applied to the
/// archive: FTP = 0.95 × the best 20-minute mean power found in any
/// running-family workout of the last `lookbackDays` days.
///
/// What we look for:
///   • Sport must be in the running family (Stryd's domain — run,
///     trail run, walk, hike, treadmill). Cycling FTP would use
///     its own estimator from a power meter on the bike.
///   • A rolling 20-minute window of moving time in which at least
///     90 % of the seconds carry a power reading. Its mean power is the
///     candidate; the highest candidate wins. A whole-session average
///     dilutes a hard 20 minutes with the warm-up and cool-down, so it
///     under-reads threshold.
///   • Only the last 90 days, so the estimate follows the user down
///     after a lay-off as well as up after a block of training.
///
/// When nothing qualifies (no recent power, or the anchoring workout
/// was deleted) the cached estimate is cleared rather than kept: an
/// old number would keep scaling every power-TSS. The scan time is
/// stamped either way, so a fruitless scan isn't repeated every launch.
/// A scan that could not read every workout in the window is not a
/// verdict: it never clears or lowers the estimate (the best effort may be
/// in the workout it could not read), raises it only when it found a
/// better effort, and is not stamped, so the next launch scans again.
/// The weekly throttle is skipped when a workout was added since the last
/// scan or the anchoring workout is no longer in the archive, so the next
/// launch scan picks up a new best effort or drops a deleted anchor.
///
/// For users who only ever do easy walks, the estimate will
/// under-predict threshold and inflate every workout's TSS — that's the
/// known limitation, and why a manually-set FTP always wins.
enum FTPAutoEstimator {
    private static let cachedFTPKey = "FlowRecovery.ftpAutoEstimate.runningFTP"
    private static let cachedAsOfKey = "FlowRecovery.ftpAutoEstimate.computedAt"
    private static let cachedSourceSessionKey = "FlowRecovery.ftpAutoEstimate.sourceSessionId"
    /// Written by earlier versions (it held the 20-minute mean power, not
    /// normalized power, and nothing read it); removed on every scan.
    private static let legacySourcePowerKey = "FlowRecovery.ftpAutoEstimate.sourceNP"
    /// Re-scan at most this often unless the archive changed (see `needsRecompute`).
    private static let rescanInterval: TimeInterval = 7 * 24 * 3600

    /// How far back the scan looks. Long enough to find a hard effort in a
    /// normal training cycle, short enough to follow detraining.
    static let lookbackDays = 90
    /// The Coggan test window: 20 minutes of moving time.
    static let effortWindowSeconds = 20 * 60
    /// Share of the window's seconds that must carry a power reading.
    static let minimumPowerCoverage = 0.9
    /// FTP ≈ 95 % of the best 20-minute mean power (Allen & Coggan).
    static let twentyMinuteToFTPFactor = 0.95

    /// The best qualifying effort: its 20-minute mean power and its session.
    struct Effort: Equatable {
        let meanPowerWatts: Double
        let sessionId: UUID
    }

    /// Latest cached estimate. nil when the scan hasn't run yet
    /// or found no qualifying sessions.
    static var cachedRunningFTP: Int? {
        let value = UserDefaults.standard.integer(forKey: cachedFTPKey)
        return value > 0 ? value : nil
    }

    /// Last scan time, stamped whether or not it found a qualifying
    /// session. Used to throttle re-scans — FTP changes slowly so weekly
    /// is plenty.
    static var lastComputedAt: Date? {
        UserDefaults.standard.object(forKey: cachedAsOfKey) as? Date
    }

    /// The session the current estimate came from; `needsRecompute` checks
    /// it is still in the archive.
    static var sourceSessionId: UUID? {
        guard let s = UserDefaults.standard.string(forKey: cachedSourceSessionKey) else { return nil }
        return UUID(uuidString: s)
    }

    /// Scan the archive and recompute, off the main actor, without waiting.
    /// Skipped unless `force` or `needsRecompute`. Safe to call on every
    /// launch. A caller that reads the FTP next should await
    /// `recomputeIfNeededAndWait` instead.
    static func recomputeIfNeeded(archive: SessionArchive, force: Bool = false, now: Date = Date()) {
        guard force || needsRecompute(archive: archive, now: now) else { return }
        Task.detached(priority: .utility) { recompute(archive: archive, now: now) }
    }

    /// `recomputeIfNeeded`, returning only once the scan has stored its
    /// result, so a training-load refresh that follows reads the new FTP.
    static func recomputeIfNeededAndWait(archive: SessionArchive, force: Bool = false, now: Date = Date()) async {
        guard force || needsRecompute(archive: archive, now: now) else { return }
        await Task.detached(priority: .utility) { recompute(archive: archive, now: now) }.value
    }

    /// True when there was no scan yet, the last one is older than
    /// `rescanInterval`, a workout was added since it, or the anchoring
    /// workout is no longer in the archive.
    static func needsRecompute(archive: SessionArchive, now: Date) -> Bool {
        guard let last = lastComputedAt, now.timeIntervalSince(last) < rescanInterval else { return true }
        if archive.entries.contains(where: { $0.sessionType == .workout && $0.date > last }) { return true }
        guard let anchor = sourceSessionId else { return false }
        return !archive.entries.contains { $0.sessionId == anchor }
    }

    /// Scan synchronously on the caller's thread. Reads are lightweight (no
    /// RR series), and only workouts inside the lookback window are decoded.
    static func recompute(archive: SessionArchive, now: Date = Date()) {
        let scan = recentRunningWorkouts(archive: archive, now: now)
        let effort = bestEffort(in: scan.sessions)
        guard scan.complete else { return keepUnlessBetter(effort) }
        persist(effort, at: now)
    }

    /// What an incomplete scan stores: a found effort only when its FTP is
    /// above the cached one; never a clear, and no stamp.
    static func incompleteScanStores(_ effort: Effort?, cachedFTP: Int?) -> Bool {
        guard let effort else { return false }
        return ftp(for: effort) > (cachedFTP ?? 0)
    }

    /// An incomplete scan (`incompleteScanStores`): stores a better effort
    /// without stamping the scan, else keeps the cached estimate as it is.
    private static func keepUnlessBetter(_ effort: Effort?) {
        guard incompleteScanStores(effort, cachedFTP: cachedRunningFTP), let effort else {
            debugLog("[FTPAutoEstimator] Some workouts could not be read — estimate kept, scan not stamped, retried next launch.", level: .warning)
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(ftp(for: effort), forKey: cachedFTPKey)
        defaults.set(effort.sessionId.uuidString, forKey: cachedSourceSessionKey)
        debugLog("[FTPAutoEstimator] Some workouts could not be read — a better effort was found, FTP raised to \(ftp(for: effort)) W; scan not stamped, retried next launch.", level: .warning)
    }

    /// Estimated FTP for an effort: 95 % of its 20-minute mean power.
    static func ftp(for effort: Effort) -> Int {
        Int((effort.meanPowerWatts * twentyMinuteToFTPFactor).rounded())
    }

    /// The highest qualifying 20-minute mean power across `sessions`.
    static func bestEffort(in sessions: [HRVSession]) -> Effort? {
        sessions.compactMap { session -> Effort? in
            guard let samples = session.workoutMetadata?.samples,
                  let power = bestTwentyMinuteMeanPower(samples) else { return nil }
            return Effort(meanPowerWatts: power, sessionId: session.id)
        }
        .max { $0.meanPowerWatts < $1.meanPowerWatts }
    }

    /// Best rolling 20-minute mean power over moving time, or nil when no
    /// window has enough power readings.
    static func bestTwentyMinuteMeanPower(_ samples: [WorkoutSample]) -> Double? {
        let perSecond = perSecondPower(samples)
        let window = effortWindowSeconds
        guard perSecond.count >= window else { return nil }
        let minimumReadings = Int((Double(window) * minimumPowerCoverage).rounded(.up))
        var rolling = RollingPower()
        var best: Double?
        for second in perSecond.indices {
            rolling.add(perSecond[second])
            if second >= window { rolling.remove(perSecond[second - window]) }
            guard second >= window - 1, rolling.readings >= minimumReadings else { continue }
            best = max(best ?? 0, rolling.mean)
        }
        return best
    }

    /// Power at each second of moving time (the samples' offsets), nil
    /// where no reading was taken.
    private static func perSecondPower(_ samples: [WorkoutSample]) -> [Int?] {
        let valid = samples.filter { $0.offsetSec >= 0 && $0.offsetSec < 24 * 3600 }
        guard let last = valid.map(\.offsetSec).max() else { return [] }
        var perSecond = [Int?](repeating: nil, count: last + 1)
        for sample in valid {
            if let watts = sample.powerWatts, watts > 0 { perSecond[sample.offsetSec] = watts }
        }
        return perSecond
    }

    /// Running sum and count of the power readings inside the window.
    private struct RollingPower {
        private(set) var readings = 0
        private var sum = 0.0

        var mean: Double { readings > 0 ? sum / Double(readings) : 0 }

        mutating func add(_ watts: Int?) {
            guard let watts else { return }
            sum += Double(watts)
            readings += 1
        }

        mutating func remove(_ watts: Int?) {
            guard let watts else { return }
            sum -= Double(watts)
            readings -= 1
        }
    }

    /// Running-family workouts that started inside the lookback window, and
    /// whether every workout there could be read (a read that throws is
    /// logged and makes the scan incomplete).
    private static func recentRunningWorkouts(archive: SessionArchive, now: Date) -> (sessions: [HRVSession], complete: Bool) {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let entries = archive.entries.filter { $0.sessionType == .workout && $0.date >= cutoff && $0.date <= now }
        var sessions: [HRVSession] = []
        var complete = true
        for entry in entries {
            let outcome = readSession(entry, archive: archive)
            complete = complete && outcome.read
            if let session = outcome.session, isRunningFamily(session.workoutMetadata?.sport) { sessions.append(session) }
        }
        return (sessions, complete)
    }

    /// One entry's session, lightweight, and whether it could be read: a
    /// read that throws is logged and returns (nil, false).
    private static func readSession(_ entry: SessionArchiveEntry, archive: SessionArchive) -> (session: HRVSession?, read: Bool) {
        do {
            return (try archive.retrieveLightweight(entry.sessionId), true)
        } catch {
            debugLog("[FTPAutoEstimator] \(entry.sessionId.uuidString.prefix(8)) could not be read: \(error)", level: .warning)
            return (nil, false)
        }
    }

    private static func isRunningFamily(_ sport: Sport?) -> Bool {
        guard let sport else { return false }
        switch sport {
        case .run, .trailRun, .walk, .hike, .treadmill: return true
        default: return false
        }
    }

    /// Stores the estimate, or clears it when nothing qualified; stamps the
    /// scan time either way.
    private static func persist(_ effort: Effort?, at now: Date) {
        let defaults = UserDefaults.standard
        defaults.set(now, forKey: cachedAsOfKey)
        defaults.removeObject(forKey: legacySourcePowerKey)
        guard let effort else {
            for key in [cachedFTPKey, cachedSourceSessionKey] {
                defaults.removeObject(forKey: key)
            }
            debugLog("[FTPAutoEstimator] No running-family workout in the last \(lookbackDays) days has a 20-min power window — estimate cleared.")
            return
        }
        defaults.set(ftp(for: effort), forKey: cachedFTPKey)
        defaults.set(effort.sessionId.uuidString, forKey: cachedSourceSessionKey)
        debugLog("[FTPAutoEstimator] Auto-estimated running FTP = \(ftp(for: effort)) W (best 20-min mean \(Int(effort.meanPowerWatts.rounded())) W)")
    }
}
