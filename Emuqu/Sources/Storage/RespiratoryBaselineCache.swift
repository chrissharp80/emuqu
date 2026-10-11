import Foundation

/// Persisted last-known-good respiratory baseline.
///
/// The baseline is a 7-day rolling average — it moves slowly and is essentially
/// the same value across consecutive days. Recomputing it from a fresh HealthKit
/// statistics query at scoring time creates a hard dependency on HK being
/// reachable at that exact moment. Morning processing runs while the phone is
/// still locked (post-reboot, Face ID not yet used), so HK returns
/// `errorDatabaseInaccessible` and the baseline silently becomes nil — which
/// the score breakdown then freezes as "RR — no data" even when the rate
/// itself is present.
///
/// Architecture: every successful HK baseline fetch for TODAY's reading (from
/// any caller — dashboard render, Vitals detail open, observer wake-up)
/// writes here; a reanalysis of a past night neither writes nor reads it
/// (`VitalsHealthQueries.refreshesBaselineCache` / `cachedBaselineIfToday`).
/// The scoring path falls back to this cache when HK is unreachable. As long
/// as the user has opened the app at least once recently with HK unlocked,
/// the cache stays warm and the locked-phone-at-6AM window no longer drops the
/// baseline.
enum RespiratoryBaselineCache {
    typealias Snapshot = BaselineSnapshot

    private static let key = "RespiratoryBaselineCache.v1"

    static func read() -> Snapshot? {
        BaselineSnapshot.read(key: key, maxAgeSeconds: BaselineSnapshot.maxAgeSeconds)
    }

    static func write(value: Double) {
        BaselineSnapshot.write(value, key: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// One cached HealthKit baseline value and when it was stored. Shared by the
/// respiratory and wrist-temperature caches, which persist the same shape
/// under different `UserDefaults` keys through the helpers below. Snapshots
/// stored by earlier builds also carry a `sampleCount` key, which decoding
/// ignores.
struct BaselineSnapshot: Codable {
    let value: Double
    let lastUpdated: Date

    /// How long a cached baseline stands in for a live one.
    static let maxAgeSeconds: TimeInterval = 30 * 86400 // 30 days

    /// The snapshot stored under `key`, or nil when there is none, it fails to
    /// decode, or it is older than `maxAgeSeconds`.
    static func read(key: String, maxAgeSeconds: TimeInterval) -> BaselineSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snap = try? JSONDecoder().decode(BaselineSnapshot.self, from: data)
        else { return nil }
        if Date().timeIntervalSince(snap.lastUpdated) > maxAgeSeconds { return nil }
        return snap
    }

    /// Stores `value` under `key`, stamped now; an encode failure is logged
    /// under `<key>.encode`.
    static func write(_ value: Double, key: String) {
        let snap = BaselineSnapshot(value: value, lastUpdated: Date())
        if let data = attempt("\(key).encode", { try JSONEncoder().encode(snap) }) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
