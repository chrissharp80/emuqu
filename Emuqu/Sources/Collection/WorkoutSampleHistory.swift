import Foundation

/// A workout's per-second rows put back together from the two places that
/// hold them. The recorder keeps at most 12 h of rows in memory
/// (`WorkoutTicker.capWorkoutSampleMemory`) and drops the oldest past that;
/// the crash backup (`WorkoutTrackBackup`) wrote every row as it came. The
/// archive is written from the merge, so it holds the whole workout and not
/// only its last 12 h.
enum WorkoutSampleHistory {
    /// The per-second samples and the offsets of the rows whose heart rate
    /// was the Watch's wrist HR.
    struct Rows: Equatable {
        var samples: [WorkoutSample]
        var wristHROffsets: [Int]
    }

    /// The backed-up rows from before the first row still `held`, then the
    /// held rows. A backed-up row past `lastOffset` is after the workout's end
    /// (a stop dated earlier than it arrived) and is left out, as the held
    /// rows past it were. Each offset appears once.
    static func merged(held: Rows, backedUp: Rows, through lastOffset: Int) -> Rows {
        let firstHeld = held.samples.first?.offsetSec ?? Int.max
        let bound = min(firstHeld - 1, lastOffset)
        let head = risingByOffset(backedUp.samples.filter { $0.offsetSec <= bound })
        let headWrist = backedUp.wristHROffsets.filter { $0 <= bound }
        return Rows(
            samples: head + held.samples,
            wristHROffsets: Array(Set(headWrist + held.wristHROffsets)).sorted()
        )
    }

    /// `rows` in order with any repeat of an offset already taken left out.
    private static func risingByOffset(_ rows: [WorkoutSample]) -> [WorkoutSample] {
        var kept: [WorkoutSample] = []
        for row in rows.sorted(by: { $0.offsetSec < $1.offsetSec }) where row.offsetSec > (kept.last?.offsetSec ?? Int.min) {
            kept.append(row)
        }
        return kept
    }
}

/// Whether an archived workout holds everything its crash backup holds, so
/// the backup can go without losing a row. A backup is retired only when
/// this finds nothing missing; otherwise it stays on disk.
enum WorkoutBackupCoverage {
    /// The backup's streams with a row the archived copy lacks, by name;
    /// empty when the archive covers it.
    ///
    /// - samples: every backed-up row up to the archived copy's last one
    ///   (rows after it are past the end the workout was cut to).
    /// - wrist HR: every backed-up wrist-HR row the archive holds is marked,
    ///   so its Apple Health heart rate stays out of the iCloud upload.
    /// - track: as many fixes as the backup took up to the workout's end,
    ///   unless the track was replaced on purpose (`trackReplaced`, an Apple
    ///   Watch route recovered in its place).
    static func missingStreams(of backup: WorkoutTrackBackup.Recovered, in archived: HRVSession, trackReplaced: Bool) -> [String] {
        let metadata = archived.workoutMetadata
        let archivedOffsets = Set((metadata?.samples ?? []).map(\.offsetSec))
        let lastArchived = metadata?.samples?.last?.offsetSec ?? Int.min
        var missing: [String] = []
        if backup.samples.contains(where: { $0.offsetSec <= lastArchived && !archivedOffsets.contains($0.offsetSec) }) {
            missing.append("samples")
        }
        let marked = Set(metadata?.healthKitHROffsets ?? [])
        if backup.healthKitHROffsets.contains(where: { archivedOffsets.contains($0) && !marked.contains($0) }) {
            missing.append("wrist HR")
        }
        if !trackReplaced, fixCount(of: backup, through: archived.endDate) > archivedFixCount(archived) {
            missing.append("track")
        }
        return missing
    }

    /// The backed-up fixes taken at or before `end` (all of them without one).
    private static func fixCount(of backup: WorkoutTrackBackup.Recovered, through end: Date?) -> Int {
        guard let end else { return backup.track.count }
        return backup.track.filter { $0.timestamp <= end }.count
    }

    /// The fixes of the archived copy's stored route.
    private static func archivedFixCount(_ session: HRVSession) -> Int {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return 0 }
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate).count
    }
}
