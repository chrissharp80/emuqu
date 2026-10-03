import CloudKit
import Foundation
import os

/// Last-writer-wins for a session that more than one device holds.
///
/// An edit uploaded from one device (a feeling, tags or notes, a trim, a sleep
/// edit, a reanalysis) has to reach a device that already holds that session.
/// Each edit stamps `HRVSession.modifiedAt`; the stamp travels inside the
/// encrypted payload and, so a pull can compare without downloading every
/// backup file, as one plain date field on the record. A date is not health
/// information — `check_no_health_data_in_cloudkit.sh` keeps it that way.
///
/// The rule is the same in both directions. A pull replaces the local copy
/// only when the iCloud copy is strictly newer; an upload that meets a newer
/// iCloud copy does not overwrite it, and the pull imports it instead. An
/// unsynced local edit carries its own stamp, so it is kept exactly when it is
/// newer than what iCloud holds. A copy with no stamp was never edited since
/// stamping began and counts as older than any stamped one: a routine
/// re-upload (the sanitising drip, a migration) must not undo a real edit.
enum CloudKitSessionFreshness {
    /// The plain CKRecord field carrying `HRVSession.modifiedAt`.
    static let modifiedAtField = "modifiedAt"

    enum Decision: Equatable {
        case importRemote
        case keepLocal
    }

    /// Whether the iCloud copy should replace this device's copy.
    ///
    /// Compared in whole seconds — the precision every copy of the stamp keeps
    /// (the payload's ISO-8601 dates drop the fraction) — so a device never
    /// sees its own upload as newer than itself.
    static func decide(localModifiedAt: Date?, remoteModifiedAt: Date?) -> Decision {
        guard let remote = remoteModifiedAt.map(wholeSeconds) else { return .keepLocal }
        guard let local = localModifiedAt.map(wholeSeconds) else { return .importRemote }
        return remote > local ? .importRemote : .keepLocal
    }

    /// The stamp for an edit made now, already at the precision it is compared in.
    static func stamp(at now: Date = Date()) -> Date {
        Date(timeIntervalSince1970: wholeSeconds(now))
    }

    private static func wholeSeconds(_ date: Date) -> TimeInterval {
        date.timeIntervalSince1970.rounded(.down)
    }

    static func modifiedAt(of record: CKRecord) -> Date? {
        record[modifiedAtField] as? Date
    }

    // MARK: - Upload

    /// Set once per launch when the production schema rejects the field (it is
    /// added in Development and must be deployed). Uploads then go without it:
    /// edits stop propagating, but backups keep working instead of every
    /// stamped session failing on every sync.
    private static let fieldRejected = OSAllocatedUnfairLock(initialState: false)

    /// Write the session's edit time onto its record.
    static func stampRecord(_ record: CKRecord, from session: HRVSession) {
        guard let modifiedAt = session.modifiedAt, !fieldRejected.withLock({ $0 }) else { return }
        record[modifiedAtField] = modifiedAt as CKRecordValue
    }

    /// Stamp an edit that reaches the archive without `requestingReupload`
    /// (a reanalysis, a repair, a restore) but is then force-uploaded, so a
    /// device holding the older copy takes it. Off the main actor: the write
    /// re-encodes the whole session.
    static func stampEdit(of sessionId: UUID, in archive: SessionArchive) async {
        await Task.detached(priority: .utility) {
            Self.stampEditNow(of: sessionId, in: archive)
        }.value
    }

    private static func stampEditNow(of sessionId: UUID, in archive: SessionArchive) {
        do {
            try archive.update(sessionId, requestingReupload: false) { $0.modifiedAt = Self.stamp() }
        } catch {
            debugLog("[CloudKit] Could not stamp the edit time on \(sessionId.uuidString.prefix(8)): \(error.localizedDescription) — other devices keep their copy", level: .warning)
        }
    }

    /// Notice a save the production schema refused because of this field, so
    /// the next attempt leaves it out. With `sessionId`, the failed upload is
    /// logged too.
    static func noteSaveFailure(_ error: Error, uploading sessionId: UUID? = nil) {
        let text = (error as NSError).localizedDescription
        if let sessionId {
            debugLog("[CloudKit] Upload failed for \(sessionId.uuidString.prefix(8)): \(text)")
        }
        guard text.contains(modifiedAtField), text.contains("production schema") else { return }
        fieldRejected.withLock { $0 = true }
        debugLog("[CloudKit] Session record field \(modifiedAtField) is not in the production schema — uploading without it; edits will not propagate until it is deployed", level: .error)
    }

    /// Copy this device's record onto the server's, keeping the server's change
    /// tag — unless the server's copy was edited more recently. Returns false
    /// then: the record is left alone, the session counts as uploaded (there
    /// is nothing newer to send), and the pull imports the server's copy.
    static func overwrite(_ server: CKRecord, with local: CKRecord, yieldingIn state: inout CloudKitSyncState) -> Bool {
        let decision = decide(localModifiedAt: modifiedAt(of: local), remoteModifiedAt: modifiedAt(of: server))
        guard decision == .keepLocal else {
            if let sessionId = UUID(uuidString: server.recordID.recordName) { state.markUploaded(sessionId) }
            debugLog("[CloudKit] \(server.recordID.recordName.prefix(8)) was edited more recently on another device — not overwritten; the pull imports it")
            return false
        }
        for key in local.allKeys() {
            server[key] = local[key]
        }
        return true
    }

    // MARK: - Pull

    /// The newer iCloud copy, keeping what never travels with it.
    ///
    /// The upload strips the HealthKit sleep and vitals snapshots and the
    /// auto-window comparison. The vitals and the comparison are kept from the
    /// local copy. The sleep snapshot is kept only while the sleep window is
    /// the one it was derived for; after a sleep edit it is dropped and the
    /// pulled-session backfill re-derives it, as for a newly pulled session.
    /// A HealthKit export recorded here is kept, so the workout is not
    /// written to Health twice.
    static func replacing(_ local: HRVSession, with remote: HRVSession) -> HRVSession {
        var merged = remote
        merged.vitalsSnapshot = remote.vitalsSnapshot ?? local.vitalsSnapshot
        if sameSleepWindow(local, remote) {
            merged.sleepSnapshot = remote.sleepSnapshot ?? local.sleepSnapshot
        }
        if remote.windowUserAdjusted == true, remote.autoWindowResult == nil {
            merged.autoWindowResult = local.autoWindowResult
            merged.autoWindowScore = local.autoWindowScore
        }
        if remote.healthKitExportedAt == nil {
            merged.healthKitExportedAt = local.healthKitExportedAt
            merged.healthKitExportFailureCount = local.healthKitExportFailureCount
        }
        return merged
    }

    private static func sameSleepWindow(_ lhs: HRVSession, _ rhs: HRVSession) -> Bool {
        lhs.sleepStartMs == rhs.sleepStartMs
            && lhs.sleepEndMs == rhs.sleepEndMs
            && lhs.sleepSegments == rhs.sleepSegments
            && lhs.sleepUserAdjusted == rhs.sleepUserAdjusted
    }
}

extension CloudPullCoordinator {
    /// A session this device already holds: replaced by the iCloud copy only
    /// when that copy was edited more recently. The decision reads the
    /// record's date field and the index, so an unchanged session costs no
    /// download.
    func refreshIfRemoteIsNewer(_ record: CKRecord, sessionId: UUID) async -> RecordOutcome {
        let remoteModifiedAt = CloudKitSessionFreshness.modifiedAt(of: record)
        let localModifiedAt = manager.archive.entryById(sessionId)?.modifiedAt
        let decision = CloudKitSessionFreshness.decide(localModifiedAt: localModifiedAt, remoteModifiedAt: remoteModifiedAt)
        guard decision == .importRemote, manager.archive.exists(sessionId),
              let assetURL = await assetURL(for: record) else { return RecordOutcome() }
        return await replaceLocalCopy(from: assetURL, sessionId: sessionId, remoteModifiedAt: remoteModifiedAt)
    }

    /// Written without a re-upload request and marked uploaded: the copy came
    /// from iCloud, and sending it back would start a loop. A pending local
    /// upload is dropped with it — it was older.
    private func replaceLocalCopy(from assetURL: URL, sessionId: UUID, remoteModifiedAt: Date?) async -> RecordOutcome {
        do {
            var remote = try await Task.detached(priority: .utility) {
                try Self.decodeSessionAsset(at: assetURL)
            }.value
            // The record's date is the one the next pull compares against.
            remote.modifiedAt = remoteModifiedAt
            guard let local = try manager.archive.retrieveLightweight(sessionId) else { return RecordOutcome() }
            let replacement = CloudKitSessionFreshness.replacing(local, with: remote)
            try manager.archive.archive(replacement, skipSameNightMerge: true)
            manager.state.markUploaded(sessionId)
            debugLog("[CloudKit] Pull: replaced \(sessionId.uuidString.prefix(8)) with the newer copy from iCloud")
            return RecordOutcome(backfillId: replacement.sleepSnapshot == nil ? sessionId : nil, refreshed: 1)
        } catch {
            return importFailure(error, sessionIdString: sessionId.uuidString)
        }
    }
}
