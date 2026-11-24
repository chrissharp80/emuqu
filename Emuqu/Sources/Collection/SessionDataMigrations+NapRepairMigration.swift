import Foundation

// MARK: - Daytime-Nap Repair One-Shot Migration

extension SessionDataMigrations {
    /// One-shot flag: recompute past overnight sessions whose recovery score was
    /// computed before daytime naps counted toward 24-hour sleep duration.
    private static let napRepairMigrationKey = "FlowRecovery.napRepairBackfill.v1.done"

    /// How far back to scan for nap-repairable overnight sessions. Covers the
    /// app's full history with margin.
    private static let napRepairLookbackDays = 400

    /// One-time backfill for overnight sessions scored before daytime naps were
    /// counted toward sleep duration.
    ///
    /// For each recent overnight session it pulls the day-before's *qualifying*
    /// daytime-nap sleep from HealthKit (`fetchDaytimeNapMinutes`) and, when a nap
    /// exists, folds it into the session's sleep snapshot — DURATION only, via
    /// `SleepData.withNapSleepMinutes`, leaving the night's architecture untouched
    /// — then recomputes the recovery score through the normal
    /// `recomputeScoreOnly` path (which also re-uploads to CloudKit). The nap
    /// discharges homeostatic sleep pressure, so a night that came out short
    /// because it was front-loaded by a nap is no longer scored as sleep debt.
    ///
    /// Idempotency is doubly guarded: the global flag skips the whole scan once it
    /// has converged, and `session.napRepaired == true` skips any individual
    /// session already handled — so a session is never processed twice even if the
    /// flag is somehow cleared. Each night is decoded off the main actor:
    /// hundreds of them would hold the screen. Every scanned session is marked `napRepaired`
    /// whether or not a nap was found, so "already checked" is unambiguous. When
    /// HealthKit cannot be read for a night (locked, or the query failed) the
    /// scan stops without marking that night or setting the flag, and the
    /// rest runs on a later launch. A night whose nap could not be written
    /// stays unmarked and leaves the flag unset too, so a later launch folds
    /// it in. Runs once per install once it completes.
    func runNapRepairMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        // Flag check FIRST, before touching the archive (matches the other
        // migrations — avoids loading session files on every launch once done).
        guard !defaults.bool(forKey: Self.napRepairMigrationKey) else { return }
        guard let overnightEntries = napRepairCandidates(defaults: defaults) else { return }
        guard let scan = await repairNaps(in: overnightEntries) else {
            debugLog("[NapRepairMigration] HealthKit nap data unreadable — stopping; the rest is retried next launch", level: .warning)
            return
        }
        guard scan.failed == 0 else {
            debugLog("[NapRepairMigration] \(scan.failed) nights' naps could not be written — retrying next launch", level: .warning)
            return
        }
        defaults.set(true, forKey: Self.napRepairMigrationKey)
        let nightsSuffix = scan.adjustedNights.isEmpty ? "" : " — nights: \(scan.adjustedNights.joined(separator: ", "))"
        debugLog("[NapRepairMigration] Complete — scanned \(scan.scanned) overnight sessions, adjusted \(scan.adjustedNights.count) for daytime naps\(nightsSuffix)")
    }

    /// Runs `repairNap` over each entry not yet checked. Nil as soon as one
    /// night's naps cannot be read; nights handled before it stay marked.
    private func repairNaps(in entries: [SessionArchiveEntry]) async -> (scanned: Int, adjustedNights: [String], failed: Int)? {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var (scanned, failed) = (0, 0)
        var adjustedNights: [String] = []
        for entry in entries {
            guard let session = await retrieveOffMain(entry.sessionId, caller: "NapRepairMigration") else { continue }
            if session.napRepaired == true { continue } // per-session idempotency
            scanned += 1
            switch await repairNap(session, entry: entry) {
            case .folded(let napMinutes):
                adjustedNights.append("\(dayFormatter.string(from: session.startDate)) (+\(napMinutes)m nap)")
            case .unchanged:
                continue
            case .notWritten:
                failed += 1
            case .unreadable:
                return nil
            }
        }
        return (scanned, adjustedNights, failed)
    }

    /// What `repairNap` did to one night.
    private enum NapRepairOutcome {
        /// This many nap minutes were folded in and the score recomputed.
        case folded(Int)
        /// Checked (or nothing to adjust); marked `napRepaired`.
        case unchanged
        /// A nap was found but the night could not be written; left unmarked.
        case notWritten
        /// HealthKit could not say whether there was a nap; left unmarked.
        case unreadable
    }

    /// Overnight entries inside the lookback window, or nil when there's
    /// nothing to scan (in which case the migration is marked complete).
    private func napRepairCandidates(defaults: UserDefaults) -> [SessionArchiveEntry]? {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(
            byAdding: .day, value: -Self.napRepairLookbackDays, to: calendar.startOfDay(for: endDate)
        ) else {
            defaults.set(true, forKey: Self.napRepairMigrationKey)
            return nil
        }
        let overnightEntries = archive.store.entries(from: startDate, to: endDate)
            .filter { $0.sessionType == .overnight }
        // Without HealthKit on this device there is no nap to fold in, ever.
        guard healthKit.isHealthKitAvailable, !overnightEntries.isEmpty else {
            defaults.set(true, forKey: Self.napRepairMigrationKey)
            debugLog("[NapRepairMigration] No HealthKit or no overnight sessions in the last \(Self.napRepairLookbackDays) days — marking complete")
            return nil
        }
        return overnightEntries
    }

    /// Folds a qualifying nap into one night. Every outcome but `.unreadable`
    /// and `.notWritten` marks the session `napRepaired`, so "already
    /// checked" is unambiguous; those nights stay unmarked for a later launch.
    ///
    /// Only overnight sessions with an existing sleep snapshot can have a nap
    /// folded into their duration; nothing to adjust otherwise.
    ///
    /// The night as loaded decides; the change is applied to the archive's
    /// copy as it is at the write (`SessionArchive.update`), so a sleep
    /// refresh or an edit saved since the load is kept.
    private func repairNap(_ session: HRVSession, entry: SessionArchiveEntry) async -> NapRepairOutcome {
        guard let snapshot = session.sleepSnapshot, snapshot.nightSleepMinutes > 0 else {
            markChecked(session.id)
            return .unchanged
        }
        guard let napMinutes = await healthKit.sleepQueries.fetchDaytimeNapMinutesIfReadable(nightAnchoredAt: session.startDate) else {
            return .unreadable
        }
        guard napMinutes > 0 else {
            // Checked — no qualifying nap. Mark and move on (no score change).
            markChecked(session.id)
            return .unchanged
        }
        // Fold the nap into the snapshot (duration only) + flag, persist, then
        // recompute the score from the updated snapshot via the normal path.
        guard persistNap(napMinutes, entry: entry) else { return .notWritten }
        _ = await reanalysisService.recomputeScoreOnly(sessionId: entry.sessionId)
        return .folded(napMinutes)
    }

    private func persistNap(_ napMinutes: Int, entry: SessionArchiveEntry) -> Bool {
        do {
            try archive.update(entry.sessionId, requestingReupload: false) { stored in
                stored.sleepSnapshot = stored.sleepSnapshot?.withNapSleepMinutes(napMinutes)
                stored.napRepaired = true
            }
            return true
        } catch {
            debugLog("[NapRepairMigration] Failed to archive \(entry.sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func markChecked(_ sessionId: UUID) {
        do {
            try archive.update(sessionId, requestingReupload: false) { $0.napRepaired = true }
        } catch {
            // A lost mark only means the night is checked again if the
            // migration runs again; it found no nap to fold in.
            debugLog("[NapRepairMigration] Failed to mark \(sessionId.uuidString.prefix(8)) as checked: \(error.localizedDescription)", level: .warning)
        }
    }
}
