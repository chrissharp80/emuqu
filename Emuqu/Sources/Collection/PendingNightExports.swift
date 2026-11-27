import Foundation

/// Readings whose export to Apple Health (HRV, heart rate, resting heart rate,
/// sleep) failed, kept so the export is tried again on the next return to the
/// app (`retry`). The reading itself is archived; without this the copy meant
/// for Health was only logged as failed and never written. Workouts have their
/// own path (`HealthKitBackfill`).
///
/// Every export writes under the reading's own identity, so exporting a
/// reading again replaces what an earlier, partly successful attempt wrote
/// rather than adding a second copy.
enum PendingNightExports {
    private static let key = "hkPendingNightExports"
    /// At most this many readings are kept, the newest failures; an export
    /// that keeps failing (Health access turned off) cannot grow the list.
    static let limit = 60

    static func pending(in defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func note(_ id: UUID, in defaults: UserDefaults = .standard) {
        let kept = pending(in: defaults).filter { $0 != id } + [id]
        defaults.set(kept.suffix(limit).map(\.uuidString), forKey: key)
    }

    static func clear(_ id: UUID, in defaults: UserDefaults = .standard) {
        let kept = pending(in: defaults)
        guard kept.contains(id) else { return }
        defaults.set(kept.filter { $0 != id }.map(\.uuidString), forKey: key)
    }

    /// The export's outcome recorded: a failure keeps the reading for
    /// `retry`, a success lets it go.
    static func record(_ id: UUID, exported: Bool, in defaults: UserDefaults = .standard) {
        if exported {
            clear(id, in: defaults)
        } else {
            note(id, in: defaults)
        }
    }

    /// Exports each kept reading again from its archived copy (the id the
    /// archive holds it under). A reading the archive no longer holds is let
    /// go; one that cannot be read or exported now stays for the next call.
    /// Nothing runs while export to Apple Health is off.
    @MainActor
    static func retry(
        archive: SessionArchive, exportEnabled: Bool, in defaults: UserDefaults = .standard,
        export: (HRVSession) async throws -> Void
    ) async {
        guard exportEnabled else { return }
        for id in pending(in: defaults) {
            await retryOne(id, archive: archive, in: defaults, export: export)
        }
    }

    @MainActor
    private static func retryOne(
        _ id: UUID, archive: SessionArchive, in defaults: UserDefaults, export: (HRVSession) async throws -> Void
    ) async {
        let read = await Task.detached(priority: .utility) { Result { try archive.retrieve(archive.archivedId(of: id)) } }.value
        guard case let .success(stored) = read else { return }
        guard let session = stored else { return clear(id, in: defaults) }
        do {
            try await export(session)
            clear(id, in: defaults)
        } catch {
            debugLog("[HealthKit Export] \(id.uuidString.prefix(8)) still not exported, kept for the next return to the app: \(error.localizedDescription)", level: .warning)
        }
    }
}
