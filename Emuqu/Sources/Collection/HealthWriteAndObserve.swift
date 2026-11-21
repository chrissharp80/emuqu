import Foundation
import HealthKit

/// The half of HealthKit that writes and watches, rather than reads: exporting
/// SDNN and windowed HRV back to Health, writing sleep, deleting what this app
/// wrote, and the observer queries that notice when the Watch adds new data.
///
/// ## Why this is not on `HealthKitManager`
///
/// As two extensions it added 1,010 lines to that type.
///
/// Reads and writes fail differently and are worth separating on that alone: a
/// failed read yields a missing number, a failed write leaves Health holding
/// something wrong, and a leaked observer query keeps firing after the screen
/// is gone. The three read-only query classes (`VitalsHealthQueries`,
/// `TrainingHealthQueries`, `SleepHealthQueries`) came out earlier for the same
/// reason; this is the other side.
///
/// The `[weak self]` captures are query completion and update handlers. They now
/// weakly hold this object rather than the manager — equivalent, since the
/// manager is the only strong reference and each already no-ops on a nil self.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct HealthWriteAndObserve {
    let manager: HealthKitManager

}

// MARK: - Replacing a session's exported samples

/// What one replacement of exported samples covers: the HealthKit type, where
/// earlier exports are searched for, which of the app's samples there it
/// replaces, and which other replacements it must not overlap.
@MainActor
struct HealthSampleReplacement {
    /// The type of the samples saved and replaced.
    let type: HKSampleType
    /// Where the earlier export is searched for; nil searches all time. Wider
    /// than the new samples, so an export made under a different span is
    /// reached too; `matches` keeps the search to this export's own samples.
    let span: DateInterval?
    /// How long the search may take. A search that does not answer in time
    /// fails the replacement: going on with nothing found would leave the
    /// earlier export beside the new one.
    let timeout: TimeInterval
    /// Names the search in its timeout error.
    let label: String
    /// Replacements with the same key run one at a time: the session's UUID,
    /// or a wider key when `matches` reaches other sessions' samples.
    let serialKey: String
    /// Whether a sample's ExternalUUID is one of those this export replaces.
    let matches: (String) -> Bool
}

/// The three Health store calls a replacement makes. `HealthKitSampleStore`
/// is the one the app uses; tests supply an in-memory store.
@MainActor
protocol HealthSampleStore: AnyObject, Sendable {
    /// This app's own samples of `type` within `span` (all time when nil).
    /// Throws on a query error and when the read does not answer in `timeout`.
    func ownSamples(of type: HKSampleType, in span: DateInterval?, timeout: TimeInterval, label: String) async throws -> [HKSample]
    func save(_ samples: [HKSample]) async throws
    func delete(_ samples: [HKSample]) async throws
}

/// The app's Health store, read through the bounded, fail-closed query
/// (`runBoundedThrowingQuery`). Holds the manager weakly: the manager owns it.
@MainActor
final class HealthKitSampleStore: HealthSampleStore {
    private weak var manager: HealthKitManager?

    init(manager: HealthKitManager) {
        self.manager = manager
    }

    func ownSamples(of type: HKSampleType, in span: DateInterval?, timeout: TimeInterval, label: String) async throws -> [HKSample] {
        let predicate = Self.ownSamplesPredicate(in: span)
        return try await requireManager().runBoundedThrowingQuery(
            timeout: timeout,
            makeQuery: { resolve in
                HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                    resolve(HealthKitManager.sampleResult(results, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut(label)) }
        )
    }

    func save(_ samples: [HKSample]) async throws {
        try await requireManager().healthStore.save(samples)
    }

    func delete(_ samples: [HKSample]) async throws {
        try await requireManager().healthStore.delete(samples)
    }

    private func requireManager() throws -> HealthKitManager {
        guard let manager else { throw HealthKitManager.HealthKitError.notAvailable }
        return manager
    }

    /// Samples from this app's own source, inside `span` when one is given.
    /// An instant span is widened by a second so an instant sample is found.
    nonisolated static func ownSamplesPredicate(in span: DateInterval?) -> NSPredicate {
        let ownSource = HKQuery.predicateForObjects(from: Set([HKSource.default()]))
        guard let span else { return ownSource }
        let end = span.duration > 0 ? span.end : span.start.addingTimeInterval(1)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            ownSource, HKQuery.predicateForSamples(withStart: span.start, end: end, options: [])
        ])
    }
}

/// The one way an export replaces what it wrote before, for every metric.
///
/// Reads the earlier samples first, saves the new ones, then deletes exactly
/// the earlier ones it read. A failed save leaves the earlier export in Health;
/// a failed delete throws, and the next export of the session removes both
/// sets, since both carry the session's identity. Replacements with the same
/// `serialKey` run one at a time, in the order they were asked for, so two
/// exports of a session never both read the same earlier set; different keys
/// run concurrently. The save and the delete each get the replacement's
/// `timeout`, as the read does, so a Health call that never answers fails
/// this replacement instead of holding its key for every later one.
@MainActor
final class HealthSampleReplacer {
    let store: any HealthSampleStore
    /// The last replacement queued under each key; it ends once its work has.
    private var tails: [String: Task<Void, Never>] = [:]

    init(store: any HealthSampleStore) {
        self.store = store
    }

    func replace(_ samples: [HKSample], _ replacement: HealthSampleReplacement) async throws {
        let key = replacement.serialKey
        let previous = tails[key]
        let work = Task {
            await previous?.value
            try await self.replaceNow(samples, replacement)
        }
        let tail = Task { _ = await work.result }
        tails[key] = tail
        defer { if tails[key] == tail { tails[key] = nil } }
        try await work.value
    }

    private func replaceNow(_ samples: [HKSample], _ replacement: HealthSampleReplacement) async throws {
        let prior = try await store.ownSamples(
            of: replacement.type, in: replacement.span, timeout: replacement.timeout, label: replacement.label
        ).filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return replacement.matches(uuid)
        }
        if !samples.isEmpty {
            try await Self.bounded("\(replacement.label) save", timeout: replacement.timeout) { try await self.store.save(samples) }
        }
        if !prior.isEmpty {
            try await Self.bounded("\(replacement.label) delete", timeout: replacement.timeout) { try await self.store.delete(prior) }
        }
        debugLog("[HealthKit Export] \(replacement.label) (\(replacement.serialKey.prefix(8))): wrote \(samples.count), removed \(prior.count) earlier")
    }

    /// `operation`, or `HealthKitError.queryTimedOut(label)` once `timeout`
    /// passes first. Health may still finish the call afterwards: a late save
    /// leaves both sets and a late delete removes what was meant to go, and
    /// the next export of the session leaves one set either way.
    private static func bounded(
        _ label: String, timeout: TimeInterval, _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finish = resumingOnce(continuation)
            Task { @MainActor in finish(await outcome(of: operation)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HealthKitManager.HealthKitError.queryTimedOut(label)))
            }
        }
    }

    /// What `operation` did: success, or the error it threw.
    private static func outcome(of operation: @MainActor () async throws -> Void) async -> Result<Void, Error> {
        do {
            try await operation()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
