import Foundation

/// Persisted SleepData per night.
///
/// The HK sleep observer fires whenever Apple Watch syncs new sleep samples —
/// often *during the night* or within minutes of wake. Without a cache, the
/// observer just bumps a version counter and discards the data; the morning
/// "I'm Up" path then re-queries HK with a 30s retry loop because it has no
/// idea anything arrived.
///
/// This cache holds the processed `SleepData` keyed by the start-of-day of
/// the sleep night. The observer is responsible for keeping it warm; the
/// `fetchSleepData` path reads here first and falls through to a fresh HK
/// query on miss. By morning, the value the wake-up flow needs is already
/// sitting in UserDefaults — no poll, no wait.
///
/// Entries are capped at `maxEntries` nights, oldest dropped first.
enum SleepDataCache {
    private static let key = "SleepDataCache.v1"
    private static let maxEntries = 14

    private struct Store: Codable {
        var entries: [Entry]
    }

    private struct Entry: Codable {
        let dayKey: Date // startOfDay for the sleep night
        let sleepData: SleepData
        let lastUpdated: Date
    }

    static func read(coveringRecordingStart recordingStart: Date) -> SleepData? {
        let calendar = Calendar.current
        // Sleep is keyed by the morning the user woke up. A recording that
        // started the previous evening (e.g. 22:30) belongs to the next day's
        // sleep night — match by the morning AFTER recordingStart if before
        // local 4 AM, otherwise the recording's own morning.
        let target = morningKey(for: recordingStart, calendar: calendar)
        guard let store = loadStore() else { return nil }
        // Allow a ±1 day tolerance to handle late-night vs early-morning
        // recordings — pick the entry whose dayKey is closest to target.
        // When the target night is missing, that can be the adjacent night's
        // sleep; callers check it belongs to the recording
        // (`plausiblyBelongsToRecording`) before using it.
        let best = store.entries
            .filter { abs($0.dayKey.timeIntervalSince(target)) <= 86400 + 3600 }
            .min(by: { abs($0.dayKey.timeIntervalSince(target)) < abs($1.dayKey.timeIntervalSince(target)) })
        return best?.sleepData
    }

    static func write(_ data: SleepData) {
        let calendar = Calendar.current
        let dayKey = calendar.startOfDay(for: data.date)
        var store = loadStore() ?? Store(entries: [])
        store.entries.removeAll { calendar.isDate($0.dayKey, inSameDayAs: dayKey) }
        store.entries.append(Entry(dayKey: dayKey, sleepData: data, lastUpdated: Date()))
        // Prune oldest beyond cap.
        store.entries.sort { $0.dayKey > $1.dayKey }
        if store.entries.count > maxEntries {
            store.entries = Array(store.entries.prefix(maxEntries))
        }
        saveStore(store)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Helpers

    private static func morningKey(for recordingStart: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.hour], from: recordingStart)
        let hour = comps.hour ?? 0
        // Recording starting 16:00–23:59 belongs to the NEXT calendar day's sleep.
        // Recording starting 00:00–15:59 belongs to that day's sleep.
        if hour >= 16 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: recordingStart))
                ?? calendar.startOfDay(for: recordingStart)
        }
        return calendar.startOfDay(for: recordingStart)
    }

    private static func loadStore() -> Store? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return attempt("sleepDataCache.decode") { try JSONDecoder().decode(Store.self, from: data) }
    }

    private static func saveStore(_ store: Store) {
        if let data = attempt("sleepDataCache.encode", { try JSONEncoder().encode(store) }) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
