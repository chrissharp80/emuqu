import Foundation
// `@preconcurrency`: HealthKit query and anchor types predate Sendable.
@preconcurrency import HealthKit
import os

/// The half of HealthKit that writes and watches, rather than reads: exporting
/// SDNN and windowed HRV back to Health, writing sleep, deleting what this app
/// wrote, and the observer queries that notice when the Watch adds new data.
///
/// Reads and writes fail differently and are worth separating on that alone: a
/// failed read yields a missing number, a failed write leaves Health holding
/// something wrong, and a leaked observer query keeps firing after the screen
/// is gone. The three read-only query classes (`VitalsHealthQueries`,
/// `TrainingHealthQueries`, `SleepHealthQueries`) are the other side.
///
/// The `[weak self]` captures are query completion and update handlers. They
/// weakly hold this object; the manager is its only strong reference, and each
/// no-ops on a nil self.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct HealthWriteAndObserve {
    let manager: HealthKitManager

    /// Delete everything this app exported to Apple Health for a session
    /// deleted forever: its HRV (`removeExportedHRV`), heart rate
    /// (`HeartRateHealthQueries.removeExportedHeartRate`), resting heart rate
    /// (`removeExportedRestingHeartRate`, dated at the end as the export
    /// dates it), sleep (`removeExportedSleep`), and any workout with the
    /// samples and route saved with it (`HealthKitWorkoutExport.removeExports`).
    /// `start...end` is the recording's span. Every removal is tried whatever
    /// the others did, and the first error is thrown afterwards, so the
    /// caller can say samples are still in Health.
    func removeExports(sessionId: UUID, from start: Date, to end: Date) async throws {
        let removals: [(String, @MainActor () async throws -> Void)] = [
            ("HRV", { try await removeExportedHRV(sessionId: sessionId, from: start, to: end) }),
            ("heart rate", { try await manager.heartRate.removeExportedHeartRate(sessionId: sessionId, from: start, to: end) }),
            ("resting heart rate", { try await manager.removeExportedRestingHeartRate(at: end, sessionId: sessionId) }),
            ("sleep", { try await removeExportedSleep(sessionId: sessionId) }),
            ("workout", { try await HealthKitWorkoutExport.removeExports(sessionId: sessionId, startDate: start, healthKit: manager) })
        ]
        var firstError: Error?
        for (label, removal) in removals {
            do {
                try await removal()
            } catch {
                debugLog("[HealthKit] \(label) of \(sessionId.uuidString.prefix(8)) could not be deleted from Apple Health: \(error)", level: .warning)
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
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
    /// How long the save and the delete may each take; nil gives them the
    /// read's `timeout`. A series of hundreds of samples saved at wake, while
    /// Health is busy with the Watch's night, needs longer than a read: one
    /// that timed out and finished late left the earlier set beside it.
    var writeTimeout: TimeInterval?
}

/// The three Health store calls a replacement makes. `HealthKitSampleStore`
/// is the one the app uses; tests supply an in-memory store.
@MainActor
protocol HealthSampleStore: AnyObject, Sendable {
    /// This app's own samples of `type` within `span` (all time when nil).
    /// Throws on a query error and when the read does not answer in `timeout`.
    func ownSamples(of type: HKSampleType, in span: DateInterval?, timeout: TimeInterval, label: String) async throws -> [HKSample]
    /// This app's own samples of `type` saved with `workout`. Throws on a
    /// query error and when the read does not answer in `timeout`.
    func ownSamples(of type: HKSampleType, savedWith workout: HKWorkout, timeout: TimeInterval, label: String) async throws -> [HKSample]
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
        try await ownSamples(of: type, matching: Self.ownSamplesPredicate(in: span), timeout: timeout, label: label)
    }

    func ownSamples(of type: HKSampleType, savedWith workout: HKWorkout, timeout: TimeInterval, label: String) async throws -> [HKSample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: Set([HKSource.default()])), HKQuery.predicateForObjects(from: workout)
        ])
        return try await ownSamples(of: type, matching: predicate, timeout: timeout, label: label)
    }

    /// The bounded, fail-closed read both lookups run.
    private func ownSamples(of type: HKSampleType, matching predicate: NSPredicate, timeout: TimeInterval, label: String) async throws -> [HKSample] {
        try await requireManager().runBoundedThrowingQuery(
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
/// the earlier ones it read that the save did not already replace through
/// their sync identifier (`notReplacedBySync`). A failed save leaves the
/// earlier export in Health;
/// a failed delete throws, and the next export of the session removes both
/// sets, since both carry the session's identity. Replacements with the same
/// `serialKey` run one at a time, in the order they were asked for, so two
/// exports of a session never both read the same earlier set; different keys
/// run concurrently. The save and the delete each get the replacement's
/// `writeTimeout` (else its `timeout`), so a Health call that never answers
/// fails this replacement instead of holding its key for every later one.
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
        let writeTimeout = replacement.writeTimeout ?? replacement.timeout
        if !samples.isEmpty {
            try await Self.bounded("\(replacement.label) save", timeout: writeTimeout) { try await self.store.save(samples) }
        }
        let leftOver = Self.notReplacedBySync(prior, by: samples)
        if !leftOver.isEmpty {
            try await Self.bounded("\(replacement.label) delete", timeout: writeTimeout) { try await self.store.delete(leftOver) }
        }
        debugLog("[HealthKit Export] \(replacement.label) (\(replacement.serialKey.prefix(8))): wrote \(samples.count), removed \(leftOver.count) earlier, \(prior.count - leftOver.count) replaced by HealthKit")
    }

    /// The earlier samples the save did not replace itself. A new sample with
    /// an earlier one's sync identifier replaces it in the save
    /// (`HealthExportIdentity.metadata`), or is dropped when the earlier one
    /// is at a newer version, so the earlier one is not deleted again: one
    /// copy with that identifier stays either way. The rest (an earlier
    /// export with more members, or one written before sync identifiers)
    /// are deleted.
    static func notReplacedBySync(_ prior: [HKSample], by saved: [HKSample]) -> [HKSample] {
        let savedIds = Set(saved.compactMap(HealthExportIdentity.syncIdentifier(of:)))
        guard !savedIds.isEmpty else { return prior }
        return prior.filter { sample in
            HealthExportIdentity.syncIdentifier(of: sample).map { !savedIds.contains($0) } ?? true
        }
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

// MARK: - Watching for samples other sources add

/// Watches one sample type for samples another source (the Watch, the
/// iPhone) adds: in the foreground, and when HealthKit wakes the app in the
/// background for a type with background delivery on.
///
/// An `HKObserverQuery` hears each change, and fires once when it starts.
/// Each time, an `HKAnchoredObjectQuery` reads what was added since the
/// anchor kept for `anchorKey`. One read per anchor runs at a time: a fire
/// during it (another change, or a restarted observer's first fire) has the
/// read run once more when it ends, from the anchor it kept. Overlapping
/// reads would deliver the same samples twice, and one answering last could put
/// back the older anchor. The anchor is stored across launches, so samples
/// that arrived while the app was not running are delivered on the next
/// launch, a background one included. Without a stored anchor the read
/// covers the last two days. The app's own samples are left out: they are
/// not new data.
///
/// The observer's completion handler, which background delivery requires
/// (HealthKit stops waking an app that never calls it), is called once the
/// read is under way. HealthKit does not declare it `Sendable`, so it cannot
/// be carried into the read's result handler. Nothing is lost if the app is
/// suspended before the read answers: the anchor only moves once a read has
/// answered, so the next fire, or the next launch, reads the same samples.
enum HealthSampleWatch {
    /// The observer query to execute for `type`. `deliver` gets each
    /// non-empty batch of other sources' samples, on HealthKit's queue.
    static func observerQuery(
        for type: HKSampleType,
        anchorKey: String,
        store: HKHealthStore,
        deliver: @escaping @Sendable ([HKSample]) -> Void
    ) -> HKObserverQuery {
        HKObserverQuery(sampleType: type, predicate: nil) { [weak store] _, completion, error in
            if let error {
                debugLog("[HealthSampleWatch] \(type.identifier) observer failed: \(error.localizedDescription)", level: .warning)
            } else if let store {
                requestRead(of: type, anchorKey: anchorKey, store: store, deliver: deliver)
            }
            completion()
        }
    }

    /// One read per anchor key at a time.
    struct ReadGate: Sendable {
        /// The reads under way, by key: true when a request came during one.
        private let reads = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

        /// True when the caller starts the read for `key`. False when one is
        /// under way: that one then runs once more when it ends.
        func claimRead(_ key: String) -> Bool {
            reads.withLock { reads in
                guard reads[key] == nil else {
                    reads[key] = true
                    return false
                }
                reads[key] = false
                return true
            }
        }

        /// The read for `key` ended. True when a request came during it and
        /// `canRerun`: the caller runs it again, as the one under way. Else the
        /// key is free.
        func finishRead(_ key: String, canRerun: Bool = true) -> Bool {
            reads.withLock { reads in
                guard reads[key] == true, canRerun else {
                    reads[key] = nil
                    return false
                }
                reads[key] = false
                return true
            }
        }
    }

    private static let readGate = ReadGate()

    /// Starts the read for `anchorKey` unless one is under way (`ReadGate`).
    private static func requestRead(
        of type: HKSampleType, anchorKey: String, store: HKHealthStore, deliver: @escaping @Sendable ([HKSample]) -> Void
    ) {
        guard readGate.claimRead(anchorKey) else { return }
        readAdded(of: type, anchorKey: anchorKey, store: store, deliver: deliver)
    }

    /// The read for `anchorKey` ended: it runs again when a fire came during
    /// it and the store is still there.
    private static func readEnded(
        of type: HKSampleType, anchorKey: String, store: HKHealthStore?, deliver: @escaping @Sendable ([HKSample]) -> Void
    ) {
        guard readGate.finishRead(anchorKey, canRerun: store != nil), let store else { return }
        readAdded(of: type, anchorKey: anchorKey, store: store, deliver: deliver)
    }

    /// Reads the samples of `type` added since the stored anchor, keeps the
    /// new anchor, and hands other sources' samples to `deliver` when there
    /// are any, then ends the read (`readEnded`). A failed read keeps the old
    /// anchor, so the next one reads the same samples again.
    private static func readAdded(
        of type: HKSampleType, anchorKey: String, store: HKHealthStore, deliver: @escaping @Sendable ([HKSample]) -> Void
    ) {
        let anchor = storedAnchor(anchorKey)
        let recent = anchor == nil
            ? HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-48 * 60 * 60), end: nil, options: [])
            : nil
        let query = HKAnchoredObjectQuery(type: type, predicate: recent, anchor: anchor, limit: HKObjectQueryNoLimit) { [weak store] _, added, _, newAnchor, error in
            defer { readEnded(of: type, anchorKey: anchorKey, store: store, deliver: deliver) }
            if let error {
                debugLog("[HealthSampleWatch] \(type.identifier) read failed: \(error.localizedDescription)", level: .info)
                return
            }
            if let newAnchor { keepAnchor(newAnchor, key: anchorKey) }
            let samples = othersSamples(added ?? [])
            if !samples.isEmpty { deliver(samples) }
        }
        store.execute(query)
    }

    /// The samples another source wrote.
    static func othersSamples(_ samples: [HKSample]) -> [HKSample] {
        let ownSource = HKSource.default()
        return samples.filter { $0.sourceRevision.source != ownSource }
    }

    private static func storedAnchor(_ key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            debugLog("[HealthSampleWatch] stored anchor \(key) unreadable, reading the last two days: \(error.localizedDescription)", level: .info)
            return nil
        }
    }

    private static func keepAnchor(_ anchor: HKQueryAnchor, key: String) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            debugLog("[HealthSampleWatch] anchor \(key) not kept: \(error.localizedDescription)", level: .info)
        }
    }
}
