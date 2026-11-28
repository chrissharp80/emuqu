import Foundation

// The sleep record's timing and heart-rate fields: bedtime, when the user
// fell asleep, wake time, how the night split, and the RR-derived read of
// the sleep.

extension SleepNamespace {
    /// When the user went to bed, fell asleep and woke, and how the night
    /// split up.
    static func sleepTimingFields(_ sleep: SleepData) -> [String: FactValue] {
        var out: [String: FactValue] = ["segment_count": .integer(sleep.effectiveSegments.count)]
        out["sleep_start_iso"] = sleep.sleepStart.map { .date($0) }
        out["sleep_end_iso"] = sleep.sleepEnd.map { .date($0) }
        out["in_bed_start_iso"] = sleep.inBedStart.map { .date($0) }
        out["core_minutes"] = coreMinutes(in: sleep).map { .integer($0) }
        out["nap_minutes"] = sleep.napSleepMinutes.flatMap { $0 > 0 ? FactValue.integer($0) : nil }
        return out
    }

    /// Core sleep by the archive index's rule (`SessionArchiveEntry.SleepMirror`),
    /// so it matches the history list: the segments' core minutes, else the
    /// night's `.core` stage intervals (nil when it has stages but none is
    /// core), else, with no stages at all, total minus deep and REM. The
    /// index's helper takes a session, and building one here would write a
    /// stored field the scoring hash then traces.
    static func coreMinutes(in sleep: SleepData) -> Int? {
        let fromSegments = sleep.effectiveSegments.compactMap(\.coreSleepMinutes).reduce(0, +)
        if fromSegments > 0 { return fromSegments }
        if !sleep.stageIntervals.isEmpty {
            let core = sleep.stageIntervals.filter { $0.stage == .core }
            return core.isEmpty ? nil : core.map(\.durationMinutes).reduce(0, +)
        }
        guard let deep = sleep.deepSleepMinutes, let rem = sleep.remSleepMinutes else { return nil }
        return max(0, sleep.nightSleepMinutes - deep - rem)
    }

    /// The heart-rate read of the sleep from the night's RR data: absent
    /// when the night had no RR data under it.
    static func heartRateQualityFields(_ sleep: SleepData) -> [String: FactValue] {
        guard let quality = sleep.hrSleepQuality else { return [:] }
        return [
            "avg_sleep_rmssd_ms": .double(quality.avgSleepRMSSD),
            "min_sleep_hr_bpm": .double(quality.minSleepHR),
            "avg_sleep_hr_bpm": .double(quality.avgSleepHR),
            "restorative_minutes": .integer(quality.restorativeSleepMinutes),
            "restorative_ratio": .double(quality.restorativeSleepRatio)
        ]
    }
}
