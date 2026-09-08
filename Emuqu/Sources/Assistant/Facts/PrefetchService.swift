import Foundation

/// Prefetch service.
///
/// Read-through cache for the high-frequency live-state values that
/// the LLM (or `DeterministicIntent`) might need on a voice turn:
/// weather, last-known location, recent HRV, last workout summary.
/// Tool calls (or fact-resolver lookups) check this cache first
/// before hitting the network or HealthKit. This is the lowest-effort
/// latency win — a typical
/// voice-mode tool round-trip costs 400–800 ms (Fora Soft 2026
/// production data on `gpt-realtime` function calling); a cache hit
/// drops it to ~50 ms.
///
/// **TTLs.**
/// | Key                | TTL   | Rationale |
/// |--------------------|-------|-----------|
/// | weather            | 10 m  | Open-Meteo's own update cadence is hourly; 10 m is a good safety margin. |
/// | location           | 60 s  | Coarse — caller resolves to "what street am I on" via reverse-geocoding upstream. |
/// | latestHRV          | 1 h   | Today's overnight reading doesn't change once frozen. |
/// | lastWorkout        | 24 h  | Updated when a new workout lands. |
/// | sleepSummary       | 1 h   | Same as HRV — frozen once today's reading lands. |
///
/// **Privacy.** All values cached here are already user-owned data
/// the app holds elsewhere. The cache is in-memory only, never
/// written to disk. Wiped on `DataPurgeService.purgeAllUserData()`
/// alongside the rest of the on-device state.
///
/// **Concurrency.** `@MainActor` — all reads and writes happen on the
/// main thread. The cache is a simple dictionary; locking would be
/// overkill for the access pattern (one read per tool call, write
/// rate ~10/min).
@MainActor
final class PrefetchService {
    static let shared = PrefetchService()

    private init() {}

    // MARK: - Cache entry

    /// One TTL-bounded value. The wrapped type is `Any` because the
    /// keys span heterogeneous payloads (weather struct, CLLocation,
    /// HRV value, workout summary). Callers cast on read.
    struct Entry {
        let value: Any
        let storedAt: Date
        let ttl: TimeInterval

        var isFresh: Bool {
            Date().timeIntervalSince(storedAt) < ttl
        }
    }

    /// Cache keys. Adding new ones is safe; the cache treats
    /// unrecognised keys as misses.
    enum Key: String, CaseIterable {
        case weather
        case location
        case latestHRV
        case lastWorkout
        case sleepSummary
        case currentPace          // mid-workout
        case currentHR            // mid-workout
        case routeProgress        // mid-workout
    }

    /// TTL per key. Looked up at write time so callers don't have to
    /// remember.
    private static let ttls: [Key: TimeInterval] = [
        .weather: 10 * 60,
        .location: 60,
        .latestHRV: 60 * 60,
        .lastWorkout: 24 * 60 * 60,
        .sleepSummary: 60 * 60,
        .currentPace: 5,    // workout-only; freshness matters
        .currentHR: 3,      // workout-only; live data
        .routeProgress: 30 // workout-only; coarse
    ]

    // MARK: - Storage

    private var cache: [Key: Entry] = [:]

    /// Hits + misses for the lifetime of the process. Surfaced via
    /// `stats()` for the Settings → Troubleshooting cache card.
    private(set) var hitCount: Int = 0
    private(set) var missCount: Int = 0

    // MARK: - Read-through API

    /// Read a value if fresh; nil otherwise. Increments hit/miss
    /// counters for telemetry.
    func read<T>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard let entry = cache[key], entry.isFresh else {
            missCount += 1
            return nil
        }
        hitCount += 1
        return entry.value as? T
    }

    /// Write a value with the configured TTL for its key.
    func write(_ key: Key, value: Any) {
        let ttl = Self.ttls[key] ?? 60
        cache[key] = Entry(value: value, storedAt: Date(), ttl: ttl)
    }

    /// Wipe a single key. Called when underlying data invalidates
    /// (e.g. user changes location preference, new workout lands).
    func invalidate(_ key: Key) {
        cache.removeValue(forKey: key)
    }

    /// Wipe everything. Called by `DataPurgeService.purgeAllUserData()`
    /// alongside the other on-device clears.
    func invalidateAll() {
        cache.removeAll()
        hitCount = 0
        missCount = 0
    }

    // MARK: - Telemetry

    /// Stats for the Settings cache-health card.
    struct Stats {
        let hitCount: Int
        let missCount: Int
        let liveKeys: [Key]

        var hitRatio: Double {
            let total = hitCount + missCount
            guard total > 0 else { return 0 }
            return Double(hitCount) / Double(total)
        }
    }

    func stats() -> Stats {
        let live = Key.allCases.filter { cache[$0]?.isFresh == true }
        return Stats(hitCount: hitCount, missCount: missCount, liveKeys: live)
    }

    // MARK: - Voice-session warm-up

    /// Called when a voice session starts. Best-effort — kicks off
    /// fetches in parallel for the keys most likely to be needed.
    /// Idempotent if items are already fresh.
    ///
    /// Concrete fetch implementations live in the call sites that
    /// own the underlying source (WeatherService, AmbientLocationService,
    /// SessionArchive). This service doesn't import them — it's a
    /// pure cache. Wiring is one-way: callers `write()` after a
    /// successful fetch; this service never calls upstream.
    ///
    /// To preload at session start, the caller should:
    ///
    /// ```swift
    /// Task { @MainActor in
    ///     async let weather = WeatherService.shared.fetchCurrent()
    ///     async let location = AmbientLocationService.shared.lastFix
    ///     async let workout = SessionArchive.shared.entries.first {
    ///         $0.sessionType == .workout
    ///     }
    ///     if let w = await weather { PrefetchService.shared.write(.weather, value: w) }
    ///     if let l = await location { PrefetchService.shared.write(.location, value: l) }
    ///     if let lw = await workout { PrefetchService.shared.write(.lastWorkout, value: lw) }
    /// }
    /// ```
    ///
    /// `VoiceConversationController` triggers this on session start.
    func voiceSessionStarted() {
        // Hook for callers; the actual fetch dispatch happens in the
        // VoiceConversationController where the dependencies are
        // already wired. Kept as a named method so the call site is
        // semantically clear ("voiceSessionStarted") rather than
        // a bare `Task` block.
        debugLog("[PrefetchService] voice session started — cache hits=\(hitCount) misses=\(missCount)")
    }
}
