import Foundation

/// Single display-state read cache — one store, one version-stamped file — so
/// tab surfaces paint their last-known values on frame one and only recompute
/// in the background when a real domain event (session archived, workout
/// finalized, HealthKit sleep/vitals arrival) changes the underlying data.
///
/// This is a READ MODEL in front of the encrypted session archive (the write
/// model): the UI reads O(1) from the in-memory snapshots here; the archive is
/// never decrypted on the critical path just to show a number that hasn't
/// changed. Persistence mirrors the proven `TrainingMetricsCache` pattern
/// (ApplicationSupport JSON, atomic off-main write, schema-versioned restore).
///
/// Every read is
/// additive and self-healing: the live compute path still runs and overwrites,
/// so a missing/stale snapshot only ever costs the uncached behavior, never
/// wrong data.
@MainActor
final class UIStateCache {
    static let shared = UIStateCache()

    // MARK: - Snapshots (raw display values; formatted at render, same as live)

    struct RecentDaySnapshot: Codable, Equatable {
        let date: Date
        /// 0–100 display score, or nil for a no-reading day.
        let score: Int?
    }

    /// Home dashboard summary. Mirrors the fields the index-seed already
    /// derives, but persisted so it survives a cold launch and lives in the one
    /// store (superseding the piecemeal seed plumbing).
    struct DashboardSnapshot: Codable, Equatable {
        var heroScore: Int?          // 0–100
        var hrvRmssdMs: Int?
        var sleepMinutes: Int?
        var recentDays: [RecentDaySnapshot]
        /// Raw vitals of the latest reading with vitals — the view's own
        /// `vitalsVariant` renders the chip from this, so the cached chip is
        /// identical to the live one (no formatting duplicated here).
        var vitals: RecoveryVitals?
    }

    /// Fitness home stats that otherwise require decrypting recent workout
    /// sessions on every tab open.
    struct FitnessSnapshot: Codable, Equatable {
        var todayElevationMeters: Double
        var weekElevationMeters: Double
        var todayAttributedSteps: Int
        var todayAttributedDistanceMeters: Double
        var todayAttributedFlights: Int
    }

    // MARK: - In-memory read model (O(1) property access)

    private(set) var dashboard: DashboardSnapshot?
    private(set) var fitness: FitnessSnapshot?

    // MARK: - Writes (update in memory, persist off-main; no-op if unchanged)

    func setDashboard(_ snapshot: DashboardSnapshot) {
        guard snapshot != dashboard else { return }
        dashboard = snapshot
        persist()
    }

    func setFitness(_ snapshot: FitnessSnapshot) {
        guard snapshot != fitness else { return }
        fitness = snapshot
        persist()
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var schema: Int
        var dashboard: DashboardSnapshot?
        var fitness: FitnessSnapshot?
    }

    private static let schemaVersion = 1

    private static let persistenceURL: URL? = {
        let fm = FileManager.default
        guard let dir = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("UIStateCache.json")
    }()

    private init() {
        loadFromDisk()
    }

    /// One serial queue for every write, so they land in the order they
    /// were made. Detached tasks had no order, and an older snapshot could
    /// land last.
    private static let writeQueue = DispatchQueue(label: "com.emuqu.uistatecache.write", qos: .utility)

    /// Best-effort atomic write off the main actor. A failed write just means
    /// the next launch has no seed and rebuilds live (the pre-cache behavior).
    private func persist() {
        guard let url = Self.persistenceURL else { return }
        let store = Store(schema: Self.schemaVersion, dashboard: dashboard, fitness: fitness)
        Self.writeQueue.async {
            do {
                let data = try JSONEncoder().encode(store)
                try data.write(to: url, options: .atomic)
            } catch {
                debugLog("[UIStateCache] persist failed: \(error)", level: .warning)
            }
        }
    }

    /// Restore the snapshots at launch. A decode failure or schema mismatch →
    /// empty cache → the surfaces render live exactly as before.
    private func loadFromDisk() {
        guard let url = Self.persistenceURL,
              let data = try? Data(contentsOf: url),
              let store = attempt("uiStateCache.decode", { try JSONDecoder().decode(Store.self, from: data) }),
              store.schema == Self.schemaVersion
        else { return }
        dashboard = store.dashboard
        fitness = store.fitness
        debugLog("[UIStateCache] restored display snapshots (dashboard=\(dashboard != nil), fitness=\(fitness != nil))", level: .info)
    }
}
