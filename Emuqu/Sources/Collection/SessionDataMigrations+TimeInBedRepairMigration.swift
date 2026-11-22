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
        var failed = 0
        for entry in archive.entries where entry.sessionType == .overnight {
            switch await repairTimeInBed(entry) {
            case .repaired: repaired += 1
            case .failed: failed += 1
            case .unchanged: continue
            }
        }
        // A night whose write failed is still wrong: leave the flag unset so
        // the next launch tries again. Nights already corrected read as
        // correct and are skipped.
        guard failed == 0 else {
            debugLog("[TimeInBedRepair] Corrected time in bed on \(repaired) nights; \(failed) could not be written — retrying next launch", level: .warning)
            return
        }
        defaults.set(true, forKey: Self.timeInBedRepairKey)
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
        guard let session = await retrieveOffMain(entry.sessionId, caller: "TimeInBedRepair"),
              let snapshot = session.sleepSnapshot,
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
