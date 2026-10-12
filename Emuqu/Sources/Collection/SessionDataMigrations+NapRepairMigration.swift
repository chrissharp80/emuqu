import Foundation

// MARK: - Daytime-Nap Repair One-Shot Migration

extension SessionDataMigrations {
    /// One-shot flag: recompute past overnight sessions whose recovery score was
    /// computed before daytime naps counted toward 24-hour sleep duration.
    private static let napRepairMigrationKey = "FlowRecovery.napRepairBackfill.v1.done"

    /// How far back to scan for nap-repairable overnight sessions. Covers the
    /// full TestFlight history with margin.
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
    /// flag is somehow cleared. Each night is decoded off the main actor, as
    /// hundreds of them held the screen. Every scanned session is marked `napRepaired`
    /// whether or not a nap was found, so "already checked" is unambiguous. When
    /// HealthKit cannot be read for a night (locked, or the query failed) the
    /// scan stops without marking that night or setting the flag, and the
    /// rest runs on a later launch. Runs once per install once it completes.
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
        defaults.set(true, forKey: Self.napRepairMigrationKey)
        let nightsSuffix = scan.adjustedNights.isEmpty ? "" : " — nights: \(scan.adjustedNights.joined(separator: ", "))"
        debugLog("[NapRepairMigration] Complete — scanned \(scan.scanned) overnight sessions, adjusted \(scan.adjustedNights.count) for daytime naps\(nightsSuffix)")
    }

    /// Runs `repairNap` over each entry not yet checked. Nil as soon as one
    /// night's naps cannot be read; nights handled before it stay marked.
    private func repairNaps(in entries: [SessionArchiveEntry]) async -> (scanned: Int, adjustedNights: [String])? {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var scanned = 0
        var adjustedNights: [String] = []
        for entry in entries {
            guard var session = await retrieveOffMain(entry.sessionId, caller: "NapRepairMigration") else { continue }
            if session.napRepaired == true { continue } // per-session idempotency
            scanned += 1
            switch await repairNap(&session, entry: entry) {
            case .folded(let napMinutes):
                adjustedNights.append("\(dayFormatter.string(from: session.startDate)) (+\(napMinutes)m nap)")
            case .unchanged:
                continue
            case .unreadable:
                return nil
            }
        }
        return (scanned, adjustedNights)
    }

    /// What `repairNap` did to one night.
    private enum NapRepairOutcome {
        /// This many nap minutes were folded in and the score recomputed.
        case folded(Int)
        /// Checked (or nothing to adjust); marked `napRepaired`.
        case unchanged
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
        let overnightEntries = archive.entries(from: startDate, to: endDate)
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
    /// marks the session `napRepaired`, so "already checked" is unambiguous;
    /// an unreadable night stays unmarked for a later launch.
    ///
    /// Only overnight sessions with an existing sleep snapshot can have a nap
    /// folded into their duration; nothing to adjust otherwise.
    private func repairNap(_ session: inout HRVSession, entry: SessionArchiveEntry) async -> NapRepairOutcome {
        guard let snapshot = session.sleepSnapshot, snapshot.nightSleepMinutes > 0 else {
            markChecked(&session)
            return .unchanged
        }
        guard let napMinutes = await healthKit.fetchDaytimeNapMinutesIfReadable(nightAnchoredAt: session.startDate) else {
            return .unreadable
        }
        guard napMinutes > 0 else {
            // Checked — no qualifying nap. Mark and move on (no score change).
            markChecked(&session)
            return .unchanged
        }
        // Fold the nap into the snapshot (duration only) + flag, persist, then
        // recompute the score from the updated snapshot via the normal path.
        session.sleepSnapshot = snapshot.withNapSleepMinutes(napMinutes)
        session.napRepaired = true
        guard persist(session, entry: entry) else { return .unchanged }
        _ = await reanalysisService.recomputeScoreOnly(sessionId: entry.sessionId)
        return .folded(napMinutes)
    }

    private func persist(_ session: HRVSession, entry: SessionArchiveEntry) -> Bool {
        do {
            _ = try archive.archive(session)
            return true
        } catch {
            debugLog("[NapRepairMigration] Failed to archive \(entry.sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func markChecked(_ session: inout HRVSession) {
        session.napRepaired = true
        do {
            _ = try archive.archive(session)
        } catch {
            // A lost mark only matters if the migration runs again: its
            // global flag is set whatever happens to individual sessions.
            debugLog("[NapRepairMigration] Failed to mark \(session.id.uuidString.prefix(8)) as checked: \(error.localizedDescription)", level: .warning)
        }
    }
}
