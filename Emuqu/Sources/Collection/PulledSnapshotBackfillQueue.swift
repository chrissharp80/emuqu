import Foundation

/// Sessions pulled from iCloud still waiting for their sleep and vitals to be
/// read back from Apple Health. Kept in UserDefaults so the backfill, which
/// takes a few per pass, can finish over later launches.
///
/// A session Health had nothing for goes to the back of the queue and is
/// tried again on a later pass, up to `maxAttempts` times: Health answers
/// nothing while the phone is locked or before access is granted, and a
/// night that truly has no Health data must not hold the front forever.
enum PulledSnapshotBackfillQueue {
    private static let key = "cloudkit.pendingSnapshotBackfill"
    private static let attemptsKey = "cloudkit.pendingSnapshotBackfillAttempts"
    static let maxAttempts = 5

    /// True while a pass runs, so a launch pass and a pull pass don't query
    /// Health for the same sessions at once.
    @MainActor static var isDraining = false

    /// The queue after adding `ids`, oldest first.
    @discardableResult
    static func adding(_ ids: [UUID]) -> [UUID] {
        var queue = stored()
        let present = Set(queue)
        queue.append(contentsOf: ids.filter { !present.contains($0) })
        save(queue)
        return queue
    }

    /// Drop ids that are done: filled in, or no longer in need of it.
    static func removing(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        save(stored().filter { !ids.contains($0) })
        var attempts = storedAttempts()
        for id in ids { attempts[id.uuidString] = nil }
        UserDefaults.standard.set(attempts, forKey: attemptsKey)
    }

    /// Move ids Health had nothing for to the back, dropping any that have
    /// now missed `maxAttempts` times.
    static func deferring(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var attempts = storedAttempts()
        var retry: [UUID] = []
        for id in ids {
            let count = (attempts[id.uuidString] ?? 0) + 1
            attempts[id.uuidString] = count < maxAttempts ? count : nil
            if count < maxAttempts { retry.append(id) }
        }
        let deferred = Set(ids)
        save(stored().filter { !deferred.contains($0) } + retry)
        UserDefaults.standard.set(attempts, forKey: attemptsKey)
    }

    private static func stored() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func storedAttempts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: attemptsKey) as? [String: Int]) ?? [:]
    }

    private static func save(_ queue: [UUID]) {
        UserDefaults.standard.set(queue.map(\.uuidString), forKey: key)
    }
}
