import Foundation

/// Auto-estimate the user's running-power FTP from
/// archived Stryd workouts when they haven't (and won't) set one
/// manually.
///
/// User reality: most people have never done a 20-min FTP test and
/// don't want to. They DO have a Stryd that's recorded normalized
/// power on every walk and run. The TrainingPeaks convention —
/// best 20-min mean power × 0.95 — converts a real sustained
/// effort into a credible 60-min threshold estimate without
/// asking the user to do anything.
///
/// What we look for:
///   • Sport must be in the running family (Stryd's domain — run,
///     trail run, walk, hike, treadmill). Cycling FTP would use
///     its own estimator from a power meter on the bike.
///   • Duration ≥ 20 min — short intervals don't represent
///     threshold; their NP overshoots.
///   • Highest `normalizedPowerWatts` wins. We don't blend or
///     average — a single hard session is a better anchor than
///     the average of easy sessions.
///
/// Calibration: NP × 0.95. Validated cycling convention; works
/// fine for running power because Stryd reports in the same units
/// and the lactate-threshold concept transfers across the modes.
///
/// User cue that confirmed this is workable: they pointed at an
/// April 21 workout as "about as hard as I go" — i.e. the archive
/// DOES contain a near-threshold anchor, so the best-NP scan has
/// something meaningful to find. For users who only ever do easy
/// walks, the estimate will under-predict threshold and inflate
/// every workout's TSS — that's the known limitation and why we
/// don't push this on users whose archive lacks a hard session.
@MainActor
enum FTPAutoEstimator {
    private static let cachedFTPKey = "FlowRecovery.ftpAutoEstimate.runningFTP"
    private static let cachedAsOfKey = "FlowRecovery.ftpAutoEstimate.computedAt"
    private static let cachedSourceSessionKey = "FlowRecovery.ftpAutoEstimate.sourceSessionId"
    private static let cachedSourceNPKey = "FlowRecovery.ftpAutoEstimate.sourceNP"

    /// Latest cached estimate. nil when the scan hasn't run yet
    /// or found no qualifying sessions.
    static var cachedRunningFTP: Int? {
        let value = UserDefaults.standard.integer(forKey: cachedFTPKey)
        return value > 0 ? value : nil
    }

    /// Last successful recompute time. Used to throttle re-scans
    /// — FTP changes slowly so weekly is plenty.
    static var lastComputedAt: Date? {
        UserDefaults.standard.object(forKey: cachedAsOfKey) as? Date
    }

    /// Diagnostic — which session the current estimate came from.
    static var sourceSessionId: UUID? {
        guard let s = UserDefaults.standard.string(forKey: cachedSourceSessionKey) else { return nil }
        return UUID(uuidString: s)
    }

    /// NP that anchored the current estimate (in watts).
    static var sourceNP: Double {
        UserDefaults.standard.double(forKey: cachedSourceNPKey)
    }

    /// Scan the archive and recompute. Throttled to once per
    /// 7 days unless `force` is true. Safe to call on every
    /// launch.
    static func recomputeIfNeeded(archive: SessionArchive, force: Bool = false) {
        if !force, let last = lastComputedAt,
           Date().timeIntervalSince(last) < 7 * 24 * 3600 {
            return
        }
        recompute(archive: archive)
    }

    /// Force a rescan. Use after a workout finishes — the new
    /// session may push the best-NP envelope and the estimate
    /// should reflect it immediately.
    static func recompute(archive: SessionArchive) {
        guard let best = bestSustainedEffort(archive: archive) else {
            debugLog("[FTPAutoEstimator] No qualifying workouts found (need ≥ 20 min with NP > 0 in running family).")
            return
        }
        // TrainingPeaks convention: 20-min best × 0.95 = FTP.
        let ftp = Int((best.np * 0.95).rounded())
        persist(ftp: ftp, best: best)
        debugLog("[FTPAutoEstimator] Auto-estimated running FTP = \(ftp) W (best NP=\(String(format: "%.0f", best.np)) W over \(Int(best.durationSec / 60)) min)")
    }

    /// The highest normalized power over a sustained effort in the
    /// running family. Nil when nothing qualifies.
    private static func bestSustainedEffort(
        archive: SessionArchive
    ) -> (np: Double, sessionId: UUID?, durationSec: Double)? {
        var bestNP: Double = 0
        var bestSessionId: UUID?
        var bestDurationSec: Double = 0
        for entry in archive.entries where entry.sessionType == .workout {
            guard let session = try? archive.retrieve(entry.sessionId),
                  let candidate = qualifyingEffort(session) else { continue }
            if candidate.np > bestNP {
                bestNP = candidate.np
                bestSessionId = entry.sessionId
                bestDurationSec = candidate.durationSec
            }
        }
        guard bestNP > 0 else { return nil }
        return (bestNP, bestSessionId, bestDurationSec)
    }

    /// Sport filter is Stryd's running-family domain; the 20-minute duration
    /// floor keeps NP representing a sustained effort rather than a short burst
    /// whose NP overshoots threshold.
    private static func qualifyingEffort(_ session: HRVSession) -> (np: Double, durationSec: Double)? {
        guard let meta = session.workoutMetadata,
              let np = meta.normalizedPowerWatts, np > 0 else { return nil }
        switch meta.sport {
        case .run, .trailRun, .walk, .hike, .treadmill: break
        default: return nil
        }
        let durationSec = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        guard durationSec >= 20 * 60 else { return nil }
        return (np, durationSec)
    }

    private static func persist(ftp: Int, best: (np: Double, sessionId: UUID?, durationSec: Double)) {
        let defaults = UserDefaults.standard
        defaults.set(ftp, forKey: cachedFTPKey)
        defaults.set(Date(), forKey: cachedAsOfKey)
        defaults.set(best.np, forKey: cachedSourceNPKey)
        if let id = best.sessionId {
            defaults.set(id.uuidString, forKey: cachedSourceSessionKey)
        }
    }
}
