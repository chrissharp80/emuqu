import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

/// Exports archived workouts that never reached Apple Health, and stamps
/// each one exported so a later pass leaves it alone.
@MainActor
final class HealthKitBackfill {
    /// The Health store whose write permissions gate the export.
    let access: HealthKitAccess
    /// The store earlier copies of a workout are replaced through.
    let sampleReplacer: HealthSampleReplacer

    /// The Workouts-write warning has been logged this launch.
    private var hasReportedWorkoutWriteDenied = false

    init(access: HealthKitAccess, sampleReplacer: HealthSampleReplacer) {
        self.access = access
        self.sampleReplacer = sampleReplacer
    }

    /// Back-publish past workouts to Apple Health.
    ///
    /// Users who had not granted workout write access (or who initially
    /// denied it) can have a history of archived workouts that never reached
    /// HealthKit. Once they grant
    /// the supplementary permission (`ensureWriteAuthorizationFresh`
    /// re-prompts at launch), this method walks the archive, exports anything still flagged
    /// `healthKitExportedAt == nil`, and stamps each one on success
    /// so a follow-up call doesn't duplicate. Idempotent.
    ///
    /// Runs serially with a small delay between writes so HealthKit's
    /// rate limiter doesn't bounce the batch — observed limit on iOS
    /// 17 is ~1 workout/sec sustained. A one-year archive of 4
    /// workouts/week takes ~3 minutes; we yield to the runloop on
    /// each iteration so the UI stays responsive.
    ///
    /// This runs on EVERY foreground and, without the watermark
    /// gate, would do a full `archive.retrieve` (disk + AES-GCM decrypt + JSON
    /// decode) for every workout just to read the `healthKitExportedAt` flag —
    /// dozens of decrypts per foreground even when everything is already
    /// exported. The whole scan is skipped when the workout set is unchanged
    /// since the last clean (failed==0) backfill, judged by the count AND the
    /// newest workout's date: deleting one workout and recording another
    /// leaves the count alone, but not the newest date.
    ///
    /// First, before the watermark: a workout saved while the phone was
    /// locked has its earlier copies deleted (`PendingWorkoutReplacements`).
    @discardableResult
    func backfillWorkoutsToHealthKit(
        archive: SessionArchive,
        bodyWeightKg: Double
    ) async -> (exported: Int, skipped: Int, failed: Int) {
        guard access.isAvailable, workoutWriteAuthorized else { return (0, 0, 0) }
        await PendingWorkoutReplacements.finish(in: sampleReplacer.store)
        let candidates = archive.store.entries.filter { $0.sessionType == .workout }
        let watermark = Self.backfillWatermark(candidates)
        if UserDefaults.standard.string(forKey: Self.backfillWatermarkKey) == watermark {
            return (0, candidates.count, 0)
        }
        reportDeniedWorkoutSampleTypes()
        var tally = (exported: 0, skipped: 0, failed: 0)
        for entry in candidates {
            await Task.yield()
            await backfillOne(entry: entry, archive: archive, bodyWeightKg: bodyWeightKg, tally: &tally)
        }
        // Advance the watermark only when nothing failed, so failed sessions
        // are retried next foreground (until the retry ceiling skips them).
        if tally.failed == 0 {
            UserDefaults.standard.set(watermark, forKey: Self.backfillWatermarkKey)
        }
        debugLog("[HealthKitManager] backfill complete — exported=\(tally.exported) skipped=\(tally.skipped) failed=\(tally.failed) of \(candidates.count) candidates")
        return tally
    }

    /// Only proceed if the user has granted workout-write — otherwise every
    /// export throws and we'd burn battery.
    ///
    /// Workouts is the one permission an export cannot do without. The sample
    /// types it attaches (heart rate, distance, energy, route) are each
    /// optional: `HealthKitWorkoutExport` leaves off any the user has switched
    /// off, so they are named for the user but never block the export.
    ///
    /// `.warning`, not `debugLogExternal`: this has to reach the user-facing
    /// problems list. Logged as an external event it would stay invisible while
    /// every workout fails to reach Apple Health — and the training load, which
    /// is built only from HealthKit workouts, would be computed without them.
    /// Once per launch, because backfill checks on every foreground.
    private var workoutWriteAuthorized: Bool {
        guard access.store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            if !hasReportedWorkoutWriteDenied {
                hasReportedWorkoutWriteDenied = true
                debugLog(
                    "[HealthKitManager] Workouts can't be written to Apple Health — writing is off for Workouts. Turn it on in Settings → Health → Data Access & Devices → Emuqu. Until then workouts stay in Emuqu only and the training load will not include them.",
                    level: .warning
                )
            }
            return false
        }
        return true
    }

    /// Say which optional workout data will be left off, once per backfill
    /// that has something to export.
    private func reportDeniedWorkoutSampleTypes() {
        let denied = Self.workoutExportSampleTypes.compactMap { type, name in
            access.store.authorizationStatus(for: type) == .sharingAuthorized ? nil : name
        }
        guard !denied.isEmpty else { return }
        debugLog(
            "[HealthKitManager] Workouts reach Apple Health without: \(denied.joined(separator: ", ")) — writing is off for them in Settings → Health → Data Access & Devices → Emuqu.",
            level: .warning
        )
    }

    /// The optional sample types `HealthKitWorkoutExport` attaches to a
    /// workout, paired with the label each one carries in the iOS Health
    /// permission list.
    nonisolated static let workoutExportSampleTypes: [(HKSampleType, String)] = [
        (HKQuantityType(.heartRate), "Heart Rate"),
        (HKQuantityType(.activeEnergyBurned), "Active Energy"),
        (HKQuantityType(.distanceWalkingRunning), "Walking + Running Distance"),
        (HKQuantityType(.distanceCycling), "Cycling Distance"),
        (HKSeriesType.workoutRoute(), "Workout Routes")
    ]

    nonisolated private static let backfillWatermarkKey = "hkBackfillExportedWatermark"

    /// Make the next backfill scan every workout. For a change the
    /// watermark cannot see: a rebuilt workout keeps its id, start and
    /// count, but its export stamp was cleared so the new copy replaces the
    /// one in Apple Health.
    nonisolated static func requestBackfillRescan() {
        UserDefaults.standard.removeObject(forKey: backfillWatermarkKey)
    }

    /// "count-newestDate" for the workout entries; see `backfillWorkoutsToHealthKit`.
    nonisolated private static func backfillWatermark(_ entries: [SessionArchiveEntry]) -> String {
        let newest = entries.map(\.date).max()?.timeIntervalSince1970 ?? 0
        return "\(entries.count)-\(Int(newest))"
    }

    /// Gives up after N failed attempts. Without this gate, the
    /// same 2 sessions failing every backfill cycle log `failed=2 of 27` every
    /// minute forever and burn battery retrying writes HealthKit has already
    /// rejected (typically because a sub-permission like active-energy was
    /// never granted). After `healthKitExportRetryCeiling` they're marked
    /// giving-up and skipped; nothing resets the failure counter, so granting
    /// the missing permission later does not retry these sessions.
    private func backfillOne(
        entry: SessionArchiveEntry,
        archive: SessionArchive,
        bodyWeightKg: Double,
        tally: inout (exported: Int, skipped: Int, failed: Int)
    ) async {
        // Another export of this session is in flight. Counted as not done,
        // so the watermark holds and the next pass checks it again in case
        // that export failed. The session is read only once the claim is
        // held: read before it, a workout the recorder exports and stamps in
        // between would look unexported and go to Health twice.
        guard HealthExportClaims.claim(entry.sessionId) else { return tally.failed += 1 }
        defer { HealthExportClaims.release(entry.sessionId) }
        guard var session = readableSession(entry, archive: archive, tally: &tally) else { return }
        guard Self.needsBackfill(session) else { return tally.skipped += 1 }
        guard !Self.exportedUnstamped().contains(entry.sessionId.uuidString) else {
            return stampAlreadyExported(entry.sessionId, archive: archive, tally: &tally)
        }
        await exportClaimed(&session, entry: entry, archive: archive, bodyWeightKg: bodyWeightKg, tally: &tally)
    }

    /// The session, or nil when it cannot be read. A failure retrying will
    /// not clear (the file missing, undecryptable or undecodable) counts as
    /// skipped: counted as failed it held the watermark for good, and every
    /// foreground decrypted every workout again. One that clears by itself
    /// (`ArchiveAccessFailure.mayClear`: the device locked, the disk full)
    /// counts as failed, so the watermark holds and the workout is exported
    /// once it can be read, not left out of Apple Health as done.
    private func readableSession(
        _ entry: SessionArchiveEntry, archive: SessionArchive, tally: inout (exported: Int, skipped: Int, failed: Int)
    ) -> HRVSession? {
        let id = entry.sessionId.uuidString.prefix(8)
        do {
            if let session = try archive.retrieve(entry.sessionId) { return session }
            debugLog("[HealthKitManager] backfill: workout \(id) is listed but missing from the archive — skipped", level: .warning)
            tally.skipped += 1
        } catch {
            let forNow = ArchiveAccessFailure.mayClear(error)
            debugLog("[HealthKitManager] backfill: workout \(id) could not be read (\(forNow ? "retried" : "skipped")): \(error.localizedDescription)", level: .warning)
            if forNow { tally.failed += 1 } else { tally.skipped += 1 }
        }
        return nil
    }

    /// A session already in Apple Health whose stamp did not persist: only
    /// the stamp is written. Exporting it again put a second copy of the
    /// workout in Health.
    private func stampAlreadyExported(_ id: UUID, archive: SessionArchive, tally: inout (exported: Int, skipped: Int, failed: Int)) {
        do {
            try Self.writeExportStamp(id, at: Date(), archive: archive)
            Self.noteExportedUnstamped(id, pending: false)
            tally.skipped += 1
        } catch {
            debugLog("[HealthKit] Export stamp still not persisted for \(id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            tally.failed += 1
        }
    }

    private func exportClaimed(
        _ session: inout HRVSession,
        entry: SessionArchiveEntry,
        archive: SessionArchive,
        bodyWeightKg: Double,
        tally: inout (exported: Int, skipped: Int, failed: Int)
    ) async {
        do {
            try await exportAndStamp(&session, archive: archive, bodyWeightKg: bodyWeightKg)
            tally.exported += 1
        } catch {
            tally.failed += 1
            recordBackfillFailure(error, session: &session, archive: archive, sessionId: entry.sessionId)
        }
    }

    /// Polite pacing after each write — HealthKit's writer accepts ~1/sec
    /// sustained without throwing, so a 1 s pause after each export keeps
    /// the batch at or below that.
    private func exportAndStamp(_ session: inout HRVSession, archive: SessionArchive, bodyWeightKg: Double) async throws {
        try await HealthKitWorkoutExport.export(
            session: session, healthStore: access.store, sampleStore: sampleReplacer.store, bodyWeightKg: bodyWeightKg,
            writesHeartRate: HealthKitWorkoutExport.writesHeartRate(with: access.settingsProvider())
        )
        let exportedAt = Date()
        session.healthKitExportedAt = exportedAt
        session.healthKitExportFailureCount = nil
        do {
            try Self.writeExportStamp(session.id, at: exportedAt, archive: archive)
        } catch {
            // The export itself succeeded; only the "already exported" stamp
            // failed to persist. Noted outside the archive, so the next pass
            // stamps it instead of exporting a second copy to Health.
            Self.noteExportedUnstamped(session.id, pending: true)
            debugLog("[HealthKit] Export stamp not persisted for \(session.id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
        }
        await sleepQuietly(1_000_000_000, context: "exportAndStamp")
    }

    /// Only the stamp, onto the copy as stored now: the export takes a
    /// moment, and writing back the copy read before it undid an edit or a
    /// heart-rate-recovery save made meanwhile. A routine stamp: it asks for
    /// no re-upload and leaves `modifiedAt` alone, so this device's copy,
    /// which may predate an edit made on another device, cannot overwrite
    /// that edit in iCloud. The stamp rides the session's next real upload,
    /// and a pull keeps it (`CloudKitSessionFreshness.replacing`); the sync
    /// identifiers already stop a second device's export from duplicating
    /// the workout in Health.
    static func writeExportStamp(_ id: UUID, at exportedAt: Date, archive: SessionArchive) throws {
        try archive.update(id, requestingReupload: false) {
            $0.healthKitExportedAt = exportedAt
            $0.healthKitExportFailureCount = nil
        }
    }

    /// Sessions exported to Apple Health whose stamp could not be written
    /// to the archive (`UserDefaults`, swept by Delete All My Data).
    nonisolated private static let exportedUnstampedKey = "hkExportedUnstampedSessions"

    private static func exportedUnstamped() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: exportedUnstampedKey) ?? [])
    }

    private static func noteExportedUnstamped(_ id: UUID, pending: Bool) {
        var ids = exportedUnstamped()
        if pending { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        UserDefaults.standard.set(Array(ids), forKey: exportedUnstampedKey)
    }

    /// A workout with no forward duration can never be exported.
    ///
    /// HealthKit rejects a builder whose collection ends where it began —
    /// "endDate must be after startDate" — and it will reject it identically
    /// every time. Without this guard such a session stays eligible, so every
    /// foreground retries the same doomed write until the retry ceiling burns
    /// through, and each failure re-archives the session to record the count.
    /// The usual case is the one-second stub a crashed recording leaves behind.
    nonisolated static func needsBackfill(_ session: HRVSession) -> Bool {
        guard session.healthKitExportedAt == nil,
              (session.healthKitExportFailureCount ?? 0) < HRVSession.healthKitExportRetryCeiling,
              session.workoutMetadata != nil,
              let endDate = session.endDate,
              endDate > session.startDate
        else { return false }
        return true
    }

    private func recordBackfillFailure(_ error: Error, session: inout HRVSession, archive: SessionArchive, sessionId: UUID) {
        let newFails = (session.healthKitExportFailureCount ?? 0) + 1
        session.healthKitExportFailureCount = newFails
        do {
            try archive.update(sessionId, requestingReupload: false) { $0.healthKitExportFailureCount = newFails }
        } catch let archiveError {
            // Bound explicitly: a bare `catch` would shadow this function's own
            // `error` parameter, and the two are different failures — that one
            // is the HealthKit export, this one is the archive write recording
            // that it failed. If this write is lost the retry counter never
            // advances and the session retries export forever against the
            // retry ceiling.
            debugLog("[HealthKit] Backfill failure count not persisted for \(sessionId.uuidString.prefix(8)): \(archiveError.localizedDescription)", level: .warning)
        }
        Self.logBackfillFailure(error, sessionId: sessionId, attempt: newFails)
    }

    /// Quiet "Authorization is not determined" by default. Most
    /// "failed" counts come from this and it's an auth-completeness issue, not
    /// a code bug. But: log a ONE-TIME warning on the very first failure per
    /// session so the user / log reader can see why backfill is short, AND log
    /// on the final failure (hitting the retry ceiling) so it's clear we're
    /// giving up.
    nonisolated private static func logBackfillFailure(_ error: Error, sessionId: UUID, attempt newFails: Int) {
        let ceilingHit = newFails >= HRVSession.healthKitExportRetryCeiling
        guard newFails == 1 || ceilingHit else { return }
        let desc = error.localizedDescription
        // By code, not by the message: `localizedDescription` follows the
        // device language.
        let isAuthNotDetermined = (error as? HKError)?.code == .errorAuthorizationNotDetermined
        guard !isAuthNotDetermined || ceilingHit else { return }
        let suffix = ceilingHit ? " — giving up after \(newFails) attempts" : ""
        debugLog("[HealthKitManager] backfill export failed for \(sessionId.uuidString.prefix(8)): \(desc)\(suffix)", level: .warning)
    }
}
