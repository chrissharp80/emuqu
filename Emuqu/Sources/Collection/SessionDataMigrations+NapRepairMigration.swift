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
    /// flag is somehow cleared. Every scanned session is marked `napRepaired`
    /// whether or not a nap was found, so "already checked" is unambiguous. Runs
    /// exactly once per install.
    func runNapRepairMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        // Flag check FIRST, before touching the archive (matches the other
        // migrations — avoids loading session files on every launch once done).
        guard !defaults.bool(forKey: Self.napRepairMigrationKey) else { return }
        guard let overnightEntries = napRepairCandidates(defaults: defaults) else { return }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var scanned = 0
        var adjustedNights: [String] = []
        for entry in overnightEntries {
            guard var session = try? archive.retrieve(entry.sessionId) else { continue }
            if session.napRepaired == true { continue } // per-session idempotency
            scanned += 1
            if let napMinutes = await repairNap(&session, entry: entry) {
                adjustedNights.append("\(dayFormatter.string(from: session.startDate)) (+\(napMinutes)m nap)")
            }
        }
        defaults.set(true, forKey: Self.napRepairMigrationKey)
        let nightsSuffix = adjustedNights.isEmpty ? "" : " — nights: \(adjustedNights.joined(separator: ", "))"
        debugLog("[NapRepairMigration] Complete — scanned \(scanned) overnight sessions, adjusted \(adjustedNights.count) for daytime naps\(nightsSuffix)")
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
        guard !overnightEntries.isEmpty else {
            defaults.set(true, forKey: Self.napRepairMigrationKey)
            debugLog("[NapRepairMigration] No overnight sessions in the last \(Self.napRepairLookbackDays) days — marking complete")
            return nil
        }
        return overnightEntries
    }

    /// Returns the nap minutes folded in, or nil when nothing changed. Every
    /// path marks the session `napRepaired` so "already checked" is
    /// unambiguous.
    ///
    /// Only overnight sessions with an existing sleep snapshot can have a nap
    /// folded into their duration; nothing to adjust otherwise.
    private func repairNap(_ session: inout HRVSession, entry: SessionArchiveEntry) async -> Int? {
        guard let snapshot = session.sleepSnapshot, snapshot.nightSleepMinutes > 0 else {
            markChecked(&session)
            return nil
        }
        let napMinutes = await healthKit.fetchDaytimeNapMinutes(nightAnchoredAt: session.startDate)
        guard napMinutes > 0 else {
            // Checked — no qualifying nap. Mark and move on (no score change).
            markChecked(&session)
            return nil
        }
        // Fold the nap into the snapshot (duration only) + flag, persist, then
        // recompute the score from the updated snapshot via the normal path.
        session.sleepSnapshot = snapshot.withNapSleepMinutes(napMinutes)
        session.napRepaired = true
        guard persist(session, entry: entry) else { return nil }
        _ = await reanalysisService.recomputeScoreOnly(sessionId: entry.sessionId)
        return napMinutes
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
            // A lost mark means this session is re-examined on every launch.
            // `persist` above already logs its failures; this one did not.
            debugLog("[NapRepairMigration] Failed to mark \(session.id.uuidString.prefix(8)) as checked: \(error.localizedDescription)", level: .warning)
        }
    }
}
