import CoreLocation
import Foundation

/// One-shot retroactive backfill that runs
/// `RouteTRIMPEstimator` against archived workouts that finalized
/// without an estimate. When the strap dropped, no Stryd power was
/// captured, and `extrapolatedTRIMP` is nil, `preferredTrainingLoad`
/// falls all the way through to a junk Banister value (a walk shows
/// "1 TRIMP" on the Load page). New workouts get the
/// estimate at finalize; this fills in the back catalogue so the Load
/// page, recent-workouts list, ATL/CTL chain, and the AI coach all
/// read coherent numbers without forcing the user to re-record.
///
/// Idempotent: the per-session "did we already try" is the presence
/// of `extrapolatedTRIMP` itself (set when the estimator succeeds), and
/// the whole scan is gated by two UserDefaults keys below — when it last
/// ran (`lastRunDefaultsKey`) and which saved routes existed then
/// (`lastRunRouteIdsKey`) — so it is skipped once converged and re-runs
/// when the saved-route library changes. O(N) over recent workouts; each step is an
/// archive read and polyline decode off the main actor plus a
/// polyline-shape match on it. The year of earlier workouts the estimates
/// draw their priors from is read once per scan, off the main actor
/// (`RouteTRIMPEstimator.priorRuns`), not once per workout.
@MainActor
enum WorkoutLoadBackfill {
    /// UserDefaults key that records when the scan last ran. Used to
    /// skip the scan on subsequent launches once it's stable — only
    /// re-run if the saved routes changed (`lastRunRouteIdsKey`) or 7
    /// days have passed.
    private static let lastRunDefaultsKey = "FlowRecovery.workoutLoadBackfill.lastRun"
    /// The saved routes' IDs at the last run, sorted and joined. IDs rather
    /// than a count: deleting one route and adding another leaves the count
    /// equal while changing which sessions can match.
    private static let lastRunRouteIdsKey = "FlowRecovery.workoutLoadBackfill.routeIdsAtLastRun"

    /// Run the backfill if it hasn't run recently. Safe to call on
    /// every launch — the gate keeps it cheap.
    ///
    /// The scan is stamped as run only when it completed: a workout or a
    /// prior that could not be read for now, or an estimate that could not
    /// be written for now (the device locked, the disk full:
    /// `ArchiveAccessFailure.mayClear`), leaves the stamp as it was, so the
    /// next launch scans again instead of skipping that workout for a week.
    /// A workout that can never be read as it is (corrupt, undecodable) is
    /// skipped and does not hold the stamp back; the weekly rescan tries it
    /// again.
    static func runIfNeeded(
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore,
        lookbackDays: Int = 90
    ) async {
        let defaults = UserDefaults.standard
        let routeIds = routeFingerprint(savedRouteStore.routes)
        guard !ranRecently(defaults: defaults, routeIds: routeIds) else { return }

        let complete = await run(archive: archive, savedRouteStore: savedRouteStore, lookbackDays: lookbackDays)
        guard complete else {
            debugLog("[WorkoutLoadBackfill] Scan incomplete — not stamped, so the next launch scans again.", level: .warning)
            return
        }
        defaults.set(Date(), forKey: lastRunDefaultsKey)
        defaults.set(routeIds, forKey: lastRunRouteIdsKey)
    }

    /// Whether the scan ran in the last 7 days against the same saved
    /// routes. Different routes change which sessions can match, so the scan
    /// runs again then.
    private static func ranRecently(defaults: UserDefaults, routeIds: String) -> Bool {
        guard let lastRun = defaults.object(forKey: lastRunDefaultsKey) as? Date else { return false }
        return Date().timeIntervalSince(lastRun) < 7 * 24 * 3600
            && defaults.string(forKey: lastRunRouteIdsKey) == routeIds
    }

    /// The routes' IDs, sorted and joined, so the same library always gives
    /// the same string whatever its order.
    private static func routeFingerprint(_ routes: [SavedRoute]) -> String {
        routes.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    /// Walk recent workout entries, run `RouteTRIMPEstimator` on any
    /// that have no `extrapolatedTRIMP`, persist the result.
    ///
    /// Reading, decrypting and decoding each session, and writing it back,
    /// run off the main actor; only the route match (which reads the
    /// main-actor saved-route library) runs on it, one entry at a time with a
    /// yield in between, so a long history doesn't hitch the UI after launch.
    /// The prior runs are read once, off the main actor, before the walk; a
    /// session given an estimate here replaces its run, so a later workout
    /// does not take it as a clean prior. True unless a workout or prior
    /// could not be read, or an estimate written, for now.
    private static func run(
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore,
        lookbackDays: Int
    ) async -> Bool {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(
            byAdding: .day, value: -lookbackDays, to: calendar.startOfDay(for: endDate)
        ) else { return true }
        let entries = archive.entries(from: startDate, to: endDate).filter { $0.sessionType == .workout }
        guard !entries.isEmpty else {
            debugLog("[WorkoutLoadBackfill] No workout entries in the last \(lookbackDays) days — nothing to backfill.")
            return true
        }
        let priors = await Task.detached(priority: .utility) {
            RouteTRIMPEstimator.priorRuns(archive: archive, from: startDate, to: endDate)
        }.value
        var scan = Scan(priorRuns: priors.runs, complete: priors.complete)
        for entry in entries {
            await backfill(entry, archive: archive, savedRouteStore: savedRouteStore, scan: &scan)
            await Task.yield()
        }
        debugLog("[WorkoutLoadBackfill] Scan complete — \(entries.count) workouts checked, \(scan.updated) updated with route-heuristic load.")
        return scan.complete
    }

    /// What a scan carries from one workout to the next.
    private struct Scan {
        /// The workouts the estimates draw their priors from, most recent
        /// first.
        var priorRuns: [RouteTRIMPEstimator.PriorRun]
        /// False once a workout or prior could not be read, or an estimate
        /// written, for a reason that may clear.
        var complete: Bool
        var updated = 0

        /// What one write did: a written session counts as updated and takes
        /// its new run's place; a write that failed for now leaves the scan
        /// incomplete; one that can never succeed is skipped.
        mutating func record(_ outcome: Persisted) {
            switch outcome {
            case let .written(session):
                updated += 1
                replaceRun(of: session)
            case .alreadyEstimated, .failedForGood: break
            case .failedForNow: complete = false
            }
        }

        /// A session just given an estimate takes its new run's place.
        mutating func replaceRun(of session: HRVSession) {
            guard let index = priorRuns.firstIndex(where: { $0.sessionId == session.id }),
                  let run = RouteTRIMPEstimator.PriorRun(session: session) else { return }
            priorRuns[index] = run
        }
    }

    /// A session that may need a route-heuristic estimate, with its decoded track.
    private struct Candidate: Sendable {
        let session: HRVSession
        let meta: WorkoutMetadata
        let track: [CLLocation]
    }

    /// One entry: an estimate from the scan's prior runs, written back. A
    /// session that could not be read or written for now marks the scan
    /// incomplete; one that can never be read is skipped; one given an
    /// estimate replaces its run among the priors.
    private static func backfill(
        _ entry: SessionArchiveEntry,
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore,
        scan: inout Scan
    ) async {
        let candidate: Candidate
        switch await loadCandidate(entry.sessionId, archive: archive) {
        case let .candidate(loaded): candidate = loaded
        case .noBackfillNeeded, .unreadableForGood: return
        case .unreadableForNow:
            scan.complete = false
            return
        }
        let meta = candidate.meta
        guard let estimate = RouteTRIMPEstimator.estimate(
            track: candidate.track, sport: meta.sport, recordedTRIMP: meta.luciaTRIMP,
            recordedDistance: meta.distanceMeters,
            distanceMayBeTruncated: RouteTRIMPEstimator.recordingMayBeTruncated(meta),
            priorRuns: scan.priorRuns, savedRouteStore: savedRouteStore
        ) else { return }
        let extrapolation = Extrapolation(
            trimp: estimate.estimatedTRIMP, confidence: estimate.confidence, routeName: estimate.routeName
        )
        scan.record(await persist(extrapolation, entry: entry, archive: archive))
    }

    /// What reading one entry found.
    private enum Loaded: Sendable {
        case candidate(Candidate)
        /// Already estimated, carrying power TSS, or without GPS, or gone.
        case noBackfillNeeded
        /// The session could not be read, for a reason that may clear.
        case unreadableForNow
        /// The session can never be read as it is (corrupt, undecodable).
        case unreadableForGood
    }

    /// What writing one estimate did.
    private enum Persisted: Sendable {
        case written(HRVSession)
        /// The session was gone or had been estimated meanwhile.
        case alreadyEstimated
        /// It could not be read again or written, for a reason that may clear.
        case failedForNow
        /// It can never be read again or written as it is.
        case failedForGood
    }

    /// The three fields the backfill writes.
    private struct Extrapolation: Sendable {
        let trimp: Double
        let confidence: Double
        let routeName: String
    }

    /// Reads and decodes one session off the main actor. No backfill is
    /// needed for sessions that already carry a route extrapolation, or a
    /// non-trivial powerTSS — `preferredTrainingLoad` will already pick the
    /// right number for those — for sessions without GPS, or for one deleted
    /// meanwhile. A read that throws is logged and is `.unreadableForNow`
    /// when the failure may clear (`ArchiveAccessFailure.mayClear`), else
    /// `.unreadableForGood`.
    private static func loadCandidate(_ id: UUID, archive: SessionArchive) async -> Loaded {
        await Task.detached(priority: .utility) { () -> Loaded in
            let read: HRVSession?
            do {
                read = try archive.retrieve(id)
            } catch {
                debugLog("[WorkoutLoadBackfill] \(id.uuidString.prefix(8)) could not be read: \(error)", level: .warning)
                return ArchiveAccessFailure.mayClear(error) ? .unreadableForNow : .unreadableForGood
            }
            guard let session = read, let meta = session.workoutMetadata,
                  meta.extrapolatedTRIMP == nil,
                  !(meta.powerTSS.map { $0 > 5 } ?? false),
                  let polyline = meta.gpsPolyline
            else { return .noBackfillNeeded }
            let track = GPXExporter.decode(polyline: polyline, startDate: session.startDate)
            return track.isEmpty ? .noBackfillNeeded : .candidate(Candidate(session: session, meta: meta, track: track))
        }.value
    }

    /// Writes the estimate off the main actor. The session is read again
    /// right before the write and only the three extrapolation fields are
    /// changed, so an edit or a CloudKit pull that landed on it while the
    /// route match ran is kept rather than overwritten with the copy read at
    /// the start. A read or write failure is logged and reported rather than
    /// thrown — one bad entry must not abort the whole sweep. One that may
    /// clear (`.failedForNow`) keeps the scan from being stamped done; one
    /// that cannot (`.failedForGood`) does not.
    private static func persist(
        _ extrapolation: Extrapolation,
        entry: SessionArchiveEntry,
        archive: SessionArchive
    ) async -> Persisted {
        let sessionId = entry.sessionId
        return await Task.detached(priority: .utility) { () -> Persisted in
            let read: HRVSession?
            do {
                read = try archive.retrieve(sessionId)
            } catch {
                return failure(error, "could not be read again", id: sessionId)
            }
            guard var session = read else { return .alreadyEstimated }
            guard var meta = session.workoutMetadata, meta.extrapolatedTRIMP == nil else { return .alreadyEstimated }
            meta.extrapolatedTRIMP = extrapolation.trimp
            meta.extrapolationConfidence = extrapolation.confidence
            meta.extrapolationRouteName = extrapolation.routeName
            session.workoutMetadata = meta
            return write(session, sport: meta.sport, archive: archive)
        }.value
    }

    nonisolated private static func write(_ session: HRVSession, sport: Sport, archive: SessionArchive) -> Persisted {
        do {
            _ = try archive.archive(session)
            debugLog("[WorkoutLoadBackfill] Updated \(session.id.uuidString.prefix(8)) \(sport.rawValue) → extrapolated TRIMP \(Int(session.workoutMetadata?.extrapolatedTRIMP ?? 0))")
            return .written(session)
        } catch {
            return failure(error, "could not be re-archived", id: session.id)
        }
    }

    /// A failed read or write, logged: `.failedForNow` when it may clear
    /// (`ArchiveAccessFailure.mayClear`), else `.failedForGood`.
    nonisolated private static func failure(_ error: any Error, _ what: String, id: UUID) -> Persisted {
        debugLog("[WorkoutLoadBackfill] \(id.uuidString.prefix(8)) \(what): \(error.localizedDescription)", level: .warning)
        return ArchiveAccessFailure.mayClear(error) ? .failedForNow : .failedForGood
    }
}
