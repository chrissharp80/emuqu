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
///
/// For users who only ever do easy walks, the estimate will
/// under-predict threshold and inflate every workout's TSS — that's the
/// known limitation, and why a manually-set FTP always wins.
enum FTPAutoEstimator {
    private static let cachedFTPKey = "FlowRecovery.ftpAutoEstimate.runningFTP"
    private static let cachedAsOfKey = "FlowRecovery.ftpAutoEstimate.computedAt"
    private static let cachedSourceSessionKey = "FlowRecovery.ftpAutoEstimate.sourceSessionId"
    private static let cachedSourcePowerKey = "FlowRecovery.ftpAutoEstimate.sourceNP"

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

    /// Diagnostic — which session the current estimate came from.
    static var sourceSessionId: UUID? {
        guard let s = UserDefaults.standard.string(forKey: cachedSourceSessionKey) else { return nil }
        return UUID(uuidString: s)
    }

    /// The 20-minute mean power (watts) that anchored the current estimate.
    static var sourceMeanPower: Double {
        UserDefaults.standard.double(forKey: cachedSourcePowerKey)
    }

    /// Scan the archive and recompute, off the main actor. Throttled to
    /// once per 7 days unless `force` is true. Safe to call on every launch.
    static func recomputeIfNeeded(archive: SessionArchive, force: Bool = false, now: Date = Date()) {
        if !force, let last = lastComputedAt, now.timeIntervalSince(last) < 7 * 24 * 3600 {
            return
        }
        Task.detached(priority: .utility) { recompute(archive: archive, now: now) }
    }

    /// Scan synchronously on the caller's thread. Reads are lightweight (no
    /// RR series), and only workouts inside the lookback window are decoded.
    static func recompute(archive: SessionArchive, now: Date = Date()) {
        let effort = bestEffort(in: recentRunningWorkouts(archive: archive, now: now))
        persist(effort, at: now)
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

    /// Running-family workouts that started inside the lookback window.
    private static func recentRunningWorkouts(archive: SessionArchive, now: Date) -> [HRVSession] {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff && $0.date <= now }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "FTPAutoEstimator") }
            .filter { isRunningFamily($0.workoutMetadata?.sport) }
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
        guard let effort else {
            for key in [cachedFTPKey, cachedSourceSessionKey, cachedSourcePowerKey] {
                defaults.removeObject(forKey: key)
            }
            debugLog("[FTPAutoEstimator] No running-family workout in the last \(lookbackDays) days has a 20-min power window — estimate cleared.")
            return
        }
        defaults.set(ftp(for: effort), forKey: cachedFTPKey)
        defaults.set(effort.meanPowerWatts, forKey: cachedSourcePowerKey)
        defaults.set(effort.sessionId.uuidString, forKey: cachedSourceSessionKey)
        debugLog("[FTPAutoEstimator] Auto-estimated running FTP = \(ftp(for: effort)) W (best 20-min mean \(Int(effort.meanPowerWatts.rounded())) W)")
    }
}
