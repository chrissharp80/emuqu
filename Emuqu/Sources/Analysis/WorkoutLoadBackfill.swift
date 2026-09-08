import CoreLocation
import Foundation

/// One-shot retroactive backfill that runs
/// `RouteTRIMPEstimator` against archived workouts that finalized
/// BEFORE the estimator was wired into the live finalize path. The
/// user reported recent walks showing "1 TRIMP" on the Load page
/// because their strap dropped, no Stryd power was captured, and
/// `extrapolatedTRIMP` was nil — so `preferredTrainingLoad` fell all
/// the way through to a junk Banister value. New workouts get the
/// estimate at finalize; this fills in the back catalogue so the Load
/// page, recent-workouts list, ATL/CTL chain, and the AI coach all
/// read coherent numbers without forcing the user to re-record.
///
/// Idempotent: the per-session "did we already try" is the presence
/// of `extrapolatedTRIMP` itself (set when the estimator succeeds) or
/// the global `lastBackfillRunDate` flag below (so we skip the entire
/// scan after it's converged and only re-run if the user later adds a
/// pile of saved routes). Cheap: O(N) over recent workouts, each
/// step is a polyline-shape match + a handful of archive reads.
@MainActor
enum WorkoutLoadBackfill {
    /// UserDefaults key that records when the scan last ran. Used to
    /// skip the scan on subsequent launches once it's stable — only
    /// re-run if a new saved route is added (signal: route count
    /// changed) or 7 days have passed.
    private static let lastRunDefaultsKey = "FlowRecovery.workoutLoadBackfill.lastRun"
    private static let lastRunRouteCountKey = "FlowRecovery.workoutLoadBackfill.routeCountAtLastRun"

    /// Run the backfill if it hasn't run recently. Safe to call on
    /// every launch — the gate keeps it cheap.
    static func runIfNeeded(
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore,
        lookbackDays: Int = 90
    ) async {
        let defaults = UserDefaults.standard
        let routeCount = savedRouteStore.routes.count
        let lastRouteCount = defaults.integer(forKey: lastRunRouteCountKey)
        let lastRun = defaults.object(forKey: lastRunDefaultsKey) as? Date

        // Skip if we ran in the last 7 days AND the saved-route
        // library hasn't grown. New routes change which sessions can
        // match, so we re-scan in that case.
        if let lastRun, Date().timeIntervalSince(lastRun) < 7 * 24 * 3600,
           routeCount == lastRouteCount {
            return
        }

        await run(archive: archive, savedRouteStore: savedRouteStore, lookbackDays: lookbackDays)

        defaults.set(Date(), forKey: lastRunDefaultsKey)
        defaults.set(routeCount, forKey: lastRunRouteCountKey)
    }

    /// Walk recent workout entries, run `RouteTRIMPEstimator` on any
    /// that have no `extrapolatedTRIMP`, persist the result.
    private static func run(
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore,
        lookbackDays: Int
    ) async {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(
            byAdding: .day, value: -lookbackDays, to: calendar.startOfDay(for: endDate)
        ) else { return }
        let entries = archive.entries(from: startDate, to: endDate).filter { $0.sessionType == .workout }
        guard !entries.isEmpty else {
            debugLog("[WorkoutLoadBackfill] No workout entries in the last \(lookbackDays) days — nothing to backfill.")
            return
        }
        var updated = 0
        for entry in entries where backfill(entry, archive: archive, savedRouteStore: savedRouteStore) {
            updated += 1
        }
        debugLog("[WorkoutLoadBackfill] Scan complete — \(entries.count) workouts checked, \(updated) updated with route-heuristic load.")
    }

    /// One entry. Returns true when a new estimate was written.
    ///
    /// Sessions that already carry a route extrapolation, or a non-trivial
    /// powerTSS, are left alone — `preferredTrainingLoad` will already pick the
    /// right number for those.
    private static func backfill(
        _ entry: SessionArchiveEntry,
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore
    ) -> Bool {
        guard var session = try? archive.retrieve(entry.sessionId),
              var meta = session.workoutMetadata,
              meta.extrapolatedTRIMP == nil,
              !(meta.powerTSS.map { $0 > 5 } ?? false),
              let polyline = meta.gpsPolyline
        else { return false }
        let track = GPXExporter.decode(polyline: polyline, startDate: session.startDate)
        guard !track.isEmpty else { return false }
        guard let estimate = RouteTRIMPEstimator.estimate(
            track: track, sport: meta.sport, recordedTRIMP: meta.luciaTRIMP,
            recordedDistance: meta.distanceMeters, archive: archive, savedRouteStore: savedRouteStore
        ) else { return false }
        meta.extrapolatedTRIMP = estimate.estimatedTRIMP
        meta.extrapolationConfidence = estimate.confidence
        meta.extrapolationRouteName = estimate.routeName
        session.workoutMetadata = meta
        return persist(session, entry: entry, meta: meta, archive: archive)
    }

    /// Re-archives the updated session. A write failure is logged and reported
    /// as "not updated" rather than thrown — one bad entry must not abort the
    /// whole backfill sweep.
    private static func persist(
        _ session: HRVSession,
        entry: SessionArchiveEntry,
        meta: WorkoutMetadata,
        archive: SessionArchive
    ) -> Bool {
        do {
            _ = try archive.archive(session)
            debugLog("[WorkoutLoadBackfill] Updated \(entry.sessionId.uuidString.prefix(8)) \(meta.sport.rawValue) → extrapolated TRIMP \(Int(meta.extrapolatedTRIMP ?? 0))")
            return true
        } catch {
            debugLog("[WorkoutLoadBackfill] Failed to re-archive \(entry.sessionId.uuidString.prefix(8)): \(error.localizedDescription)")
            return false
        }
    }
}
