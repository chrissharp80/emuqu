import Foundation

/// Persisted last-known-good wrist temperature baseline.
///
/// Same architecture and motivation as `RespiratoryBaselineCache`: a 7-day
/// rolling average of deviation samples moves slowly, so recomputing it from
/// a fresh HK statistics query at scoring time creates a hard dependency on
/// HK being reachable in the very minutes after wake-up. When morning
/// processing runs on a still-locked phone HK returns
/// `errorDatabaseInaccessible` and the baseline silently becomes nil, which
/// freezes the score breakdown with a "no baseline" label even when the
/// current night's deviation is present.
///
/// Every successful HK baseline fetch for today's reading writes here. The
/// fetcher falls back to this cache when HK is unreachable. Storage, age
/// limit and encoding are `BaselineSnapshot`'s, shared with the respiratory
/// cache; only the key differs.
enum WristTemperatureBaselineCache {
    typealias Snapshot = BaselineSnapshot

    private static let key = "WristTemperatureBaselineCache.v1"

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
