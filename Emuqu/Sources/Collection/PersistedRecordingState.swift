import Foundation

/// Atomic persisted recording state — replaces three separate UserDefaults keys
/// with a single Codable struct to eliminate partial-write corruption.
///
/// If the app crashes between writing individual keys, the state can be inconsistent
/// (e.g., sessionId present but startTime missing). A single atomic write/read
/// eliminates this class of bugs entirely.
struct PersistedRecordingState: Codable, Equatable {
    let sessionId: UUID
    let startTime: Date
    let sessionType: SessionType
    let phase: String // RecordingPhase description for diagnostics
    /// Whether device internal backup is enabled for overnight streaming.
    /// Persisted so pause/resume across app restarts preserves the user's capture mode choice.
    let useDeviceInternalBackup: Bool?

    private static let storageKey = UserDefaultsKeys.persistedRecordingState
    /// The "Dismiss" action on the
    /// `Session Interrupted` alert deliberately preserved the
    /// persisted state ("leave backup available for Lost Sessions"),
    /// but `checkForInterruptedSession` re-detects it every launch
    /// → alert pops up every launch → dismissing does nothing useful.
    /// Track which session IDs the user has explicitly dismissed.
    /// `checkForInterruptedSession` reads this set and skips the
    /// alert when the current persisted state's sessionId is in it.
    /// The state stays on disk (Lost Sessions can still recover);
    /// only the re-prompt is suppressed.
    private static let dismissedKey = "RRCollector.dismissedInterruptedSessionIds"

    // MARK: - Persistence

    /// Save state atomically. Returns true on success.
    @discardableResult
    static func save(_ state: PersistedRecordingState) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: storageKey)
            return true
        } catch {
            debugLog("[PersistedRecordingState] Failed to save: \(error)")
            return false
        }
    }

    /// Load persisted state, or nil if none exists.
    static func load() -> PersistedRecordingState? {
        // Try new atomic format first
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do {
                return try JSONDecoder().decode(PersistedRecordingState.self, from: data)
            } catch {
                debugLog("[PersistedRecordingState] Failed to decode: \(error)")
            }
        }

        // Fall back to legacy 3-key format for migration
        return loadLegacy()
    }

    /// Clear persisted state.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        // Also clear legacy keys
        clearLegacy()
        // Also wipe the dismissed-IDs set when state is
        // genuinely cleared. Keeping stale UUIDs in the set isn't
        // harmful but the set should not grow unbounded across the
        // user's lifetime of recordings.
        UserDefaults.standard.removeObject(forKey: dismissedKey)
        debugLog("[PersistedRecordingState] Cleared")
    }

    // MARK: - Dismissal tracking

    /// Record that the user has explicitly dismissed the
    /// "Session Interrupted" alert for this session. Stops the
    /// alert from re-prompting on every subsequent launch.
    static func markDismissed(_ sessionId: UUID) {
        var ids = dismissedSessionIds()
        ids.insert(sessionId)
        let strings = ids.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: dismissedKey)
        debugLog("[PersistedRecordingState] Marked \(sessionId.uuidString.prefix(8)) as dismissed (\(ids.count) total)")
    }

    /// True if the user has previously dismissed the alert for
    /// this session ID.
    static func isDismissed(_ sessionId: UUID) -> Bool {
        dismissedSessionIds().contains(sessionId)
    }

    private static func dismissedSessionIds() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    // MARK: - Legacy Migration

    private static let legacyStartTimeKey = UserDefaultsKeys.activeRecordingStartTime
    private static let legacySessionIdKey = UserDefaultsKeys.activeRecordingSessionId
    private static let legacyTypeKey = UserDefaultsKeys.activeRecordingSessionType

    private static func loadLegacy() -> PersistedRecordingState? {
        guard let startTime = UserDefaults.standard.object(forKey: legacyStartTimeKey) as? Date,
              let sessionIdString = UserDefaults.standard.string(forKey: legacySessionIdKey),
              let sessionId = UUID(uuidString: sessionIdString)
        else {
            return nil
        }
        let sessionTypeRaw = UserDefaults.standard.string(forKey: legacyTypeKey) ?? "overnight"
        let migrated = PersistedRecordingState(
            sessionId: sessionId,
            startTime: startTime,
            sessionType: SessionType(rawValue: sessionTypeRaw) ?? .overnight,
            phase: "migrated-from-legacy",
            useDeviceInternalBackup: nil
        )
        // Auto-migrate to new format
        save(migrated)
        clearLegacy()
        debugLog("[PersistedRecordingState] Migrated from legacy 3-key format")
        return migrated
    }

    private static func clearLegacy() {
        UserDefaults.standard.removeObject(forKey: legacyStartTimeKey)
        UserDefaults.standard.removeObject(forKey: legacySessionIdKey)
        UserDefaults.standard.removeObject(forKey: legacyTypeKey)
    }
}
