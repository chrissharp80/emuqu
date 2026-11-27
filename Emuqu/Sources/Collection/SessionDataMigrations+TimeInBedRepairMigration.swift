import Foundation

// MARK: - Time-in-Bed Repair One-Shot Migration
//
// Nights stored by builds whose sleep resolver and sleep editor added the
// stretch from the start of the sleep search window to the night's first
// stage to time in bed read hours longer in bed than they were: that window
// opens two hours before bedtime (or at the strap recording's start), and
// efficiency — and the recovery score's efficiency component — is low to
// match. Automatic sleep refresh never rewrites a night for a changed time
// in bed alone, so those nights would keep the wrong value.
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
        var failed = 0
        for entry in archive.store.entries where entry.sessionType == .overnight {
            switch await repairTimeInBed(entry) {
            case .repaired: repaired += 1
            case .failed: failed += 1
            case .unchanged: continue
            }
        }
        // A night that could not be read or written may still be wrong:
        // leave the flag unset so a later launch tries again. Nights already
        // corrected read as correct and are skipped.
        guard Self.finishTrainingMigration(key: Self.timeInBedRepairKey, complete: failed == 0) else {
            debugLog("[TimeInBedRepair] Corrected time in bed on \(repaired) nights; \(failed) could not be read or written: retrying next launch", level: .warning)
            return
        }
        debugLog("[TimeInBedRepair] Complete. Corrected time in bed on \(repaired) nights.")
    }

    /// What `repairTimeInBed` did to one night.
    private enum TimeInBedRepairOutcome {
        case repaired
        case unchanged
        case failed
    }

    /// Whether the night's stored time in bed was corrected, needed no
    /// correction, or needed one that could not be written. The night is
    /// decoded off the main actor, as the other migrations read; the
    /// correction is applied to the archive's copy as it is at the write, so
    /// a change saved since the load is kept.
    private func repairTimeInBed(_ entry: SessionArchiveEntry) async -> TimeInBedRepairOutcome {
        // Unread is not "nothing to correct".
        guard let session = await retrieveOffMain(entry.sessionId, caller: "TimeInBedRepair") else { return .failed }
        guard let snapshot = session.sleepSnapshot,
              snapshot.timeInBedIsSleepPlusAwake,
              snapshot.inBedMinutes != snapshot.nightSleepMinutes + snapshot.awakeMinutes
        else { return .unchanged }
        do {
            try archive.update(entry.sessionId, requestingReupload: false) { stored in
                stored.sleepSnapshot = stored.sleepSnapshot?.withTimeInBedFromSleepAndAwake()
            }
        } catch {
            debugLog("[TimeInBedRepair] Failed to re-archive \(session.id.uuidString.prefix(8)): \(error)", level: .warning)
            return .failed
        }
        _ = await reanalysisService.recomputeScoreOnly(sessionId: entry.sessionId)
        return .repaired
    }
}
