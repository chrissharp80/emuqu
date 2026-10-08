import Foundation

// MARK: - Time-in-Bed Repair One-Shot Migration
//
// For a few days in October 2026 the sleep resolver and the sleep editor added
// the stretch from the start of the sleep search window to the night's first
// stage to time in bed. That window opens two hours before bedtime (or at the
// strap recording's start), so stored nights read hours longer in bed than
// they were, with efficiency — and the recovery score's efficiency component —
// low to match. Automatic sleep refresh never rewrites a night for a changed
// time in bed alone, so those nights would keep the wrong value.
//
// This one-shot migration sets every stage-built night's time in bed back to
// sleep plus awake, recomputes its efficiency, and rescores the nights it
// changed. Runs once per install — gated by a UserDefaults flag.

extension SessionDataMigrations {
    private static let timeInBedRepairKey = "didRunTimeInBedRepair_v1"

    func runTimeInBedRepairIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.timeInBedRepairKey) else { return }
        var repaired = 0
        for entry in archive.entries where entry.sessionType == .overnight {
            guard await repairTimeInBed(entry) else { continue }
            repaired += 1
        }
        defaults.set(true, forKey: Self.timeInBedRepairKey)
        debugLog("[TimeInBedRepair] Complete. Corrected time in bed on \(repaired) nights.")
    }

    /// Whether the night's stored time in bed was corrected.
    private func repairTimeInBed(_ entry: SessionArchiveEntry) async -> Bool {
        guard var session = archive.retrieveOrLog(entry.sessionId, caller: "TimeInBedRepair"),
              let snapshot = session.sleepSnapshot,
              snapshot.timeInBedIsSleepPlusAwake,
              snapshot.inBedMinutes != snapshot.nightSleepMinutes + snapshot.awakeMinutes
        else { return false }
        session.sleepSnapshot = snapshot.withTimeInBedFromSleepAndAwake()
        do {
            _ = try archive.archive(session)
        } catch {
            debugLog("[TimeInBedRepair] Failed to re-archive \(session.id.uuidString.prefix(8)): \(error)", level: .warning)
            return false
        }
        _ = await reanalysisService.recomputeScoreOnly(sessionId: entry.sessionId)
        return true
    }
}
