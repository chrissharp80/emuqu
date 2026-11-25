import Foundation
// `@preconcurrency`: HealthKit query types predate Sendable.
@preconcurrency import HealthKit

/// What every HealthKit query works through: the app's one Health store, the
/// user's settings, and the bounded executors that run each query with a
/// timeout. The query types (`HeartRateHealthQueries`, `SleepHealthQueries`,
/// `VitalsHealthQueries`, `TrainingHealthQueries`, `HealthWriteAndObserve`)
/// each take this and the other parts they use, and nothing else.
struct HealthKitAccess: Sendable {
    /// The app's one `HKHealthStore`. Every consumer goes through it, so they
    /// share its anchors and observer notifications.
    let store: HKHealthStore
    let settingsProvider: @Sendable () -> UserSettings

    /// Whether this device has Apple Health at all.
    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// The user's sleep schedule, which sets the overnight, morning and
    /// daytime query windows.
    var sleepSchedule: SleepSchedule {
        settingsProvider().sleepSchedule
    }
}

// MARK: - Bounded HealthKit query execution (single source of truth)
//
// `HKSampleQuery` / `HKStatisticsQuery` have NO built-in timeout.
// At wake the HealthKit store is busy ingesting the Watch's overnight data, and
// any unbounded query can hang for many seconds (a daytime-resting-HR query
// can take 19 SECONDS to return), and one awaited inline in morning HRV
// analysis stalls the whole morning and freezes the record screen. This extension is the ONE place a
// HealthKit query continuation lives: every raw query is executed through
// `runBoundedQuery` / `runBoundedThrowingQuery`, which enforce a timeout +
// `store.stop(query)` + resume-once on EVERY query. No raw
// `withCheckedContinuation { … execute }` should exist outside here.
extension HealthKitAccess {
    // MARK: Per-query-type timeouts (ENGINEERING BOUNDS — not science)
    //
    // Two tiers:
    //  • UI-critical reads awaited inline in morning processing → short (a few
    //    seconds). Every one is an OPTIONAL refinement that already falls back to
    //    nil / a cached value, so timing out and proceeding is correct, not
    //    lossy — showing the score now beats blocking on a slow store.
    //  • Large background aggregations (e.g. 400-day workout history) → a
    //    generous DEADLOCK BACKSTOP: long enough that a legitimately large query
    //    finishes, short enough that a genuinely wedged store still recovers.
    //    This is NOT a latency bound (those queries are off the UI critical path).

    /// UI-critical morning vitals reads (respiratory rate, SpO2, wrist temp, resting HR).
    nonisolated static let vitalsQueryTimeoutSec: TimeInterval = 6.0
    /// UI-critical sleep reads on the morning path.
    nonisolated static let sleepQueryTimeoutSec: TimeInterval = 8.0
    /// UI-critical HRV (SDNN) reads on the morning path.
    nonisolated static let hrvQueryTimeoutSec: TimeInterval = 6.0
    /// Large background aggregations (workout history, training load, heat) —
    /// a deadlock backstop, not a UI-latency bound.
    nonisolated static let backgroundAggregateQueryTimeoutSec: TimeInterval = 30.0

    // MARK: Bounded executors

    /// Run an HKQuery bounded by `timeout`, resolving to `nil` if it doesn't
    /// answer in time. `makeQuery` builds the query and MUST call the supplied
    /// `resolve` closure exactly once from its result handler. On timeout the
    /// query is `stop()`-ed and the call resolves to `nil`. Resume-once guarded
    /// (the result handler and the timeout can race). Non-throwing: use for the
    /// many reads that already treat any failure as "no data → nil".
    ///
    /// `resolve` is `@Sendable` and `T` is constrained to `Sendable`. Every
    /// caller passes `resolve` straight into an `HKQuery` result handler, which
    /// HealthKit declares `@Sendable`; without those annotations every call
    /// site fails strict concurrency checking ("capture of 'resolve' with
    /// non-Sendable type in a '@Sendable' closure").
    @MainActor
    func runBoundedQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (T?) -> Void) -> HKQuery
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let finish = resumingOnce(continuation)
            let query = makeQuery { finish($0) }
            store.execute(query)
            // Stopping an already-finished query is a harmless no-op; `finish`
            // is idempotent, so the timeout losing the race changes nothing.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak healthStore = store] in
                healthStore?.stop(query)
                finish(nil)
            }
        }
    }

    /// Throwing variant: for queries whose callers distinguish a real failure
    /// from "no data". `makeQuery` MUST call `resolve` once with a `Result`. On
    /// timeout the query is stopped and `onTimeout()` supplies the result — e.g.
    /// `.success([])` to proceed with none, or `.failure(…)` to surface a stall.
    ///
    /// Same `Sendable` annotation reasoning as `runBoundedQuery` above.
    @MainActor
    func runBoundedThrowingQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (Result<T, Error>) -> Void) -> HKQuery,
        onTimeout: @escaping @Sendable () -> Result<T, Error>
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let finish = resumingOnce(continuation)
            let query = makeQuery(finish)
            store.execute(query)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak healthStore = store] in
                healthStore?.stop(query)
                finish(onTimeout())
            }
        }
    }
}
