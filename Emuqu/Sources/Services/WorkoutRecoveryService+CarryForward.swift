import Foundation

extension WorkoutRecoveryService {
    /// What a rebuild cannot recompute, taken from the archived copy it
    /// replaces.
    ///
    /// Trim, "Recover from strap" and "Recover route from Watch" are offered
    /// on any finished workout, and each rebuilds the session from its backups
    /// under the same id. The rebuild used to start empty, so it dropped the
    /// user's tags, notes and feeling, the heart-rate recovery, weather and
    /// power figures, and the Apple Health export stamp, which sent the
    /// workout to Apple Health a second time on the next back-fill.
    static func carryForward(from archived: HRVSession, into session: inout HRVSession) {
        carrySessionFields(from: archived, into: &session)
        guard let old = archived.workoutMetadata, var new = session.workoutMetadata else { return }
        carryUserFields(from: old, into: &new)
        if coversSameTime(archived, session) {
            carryMeasuredFields(from: old, into: &new)
            carryPowerFields(from: old, into: &new)
        }
        carrySamples(from: archived, into: session, metadata: &new)
        // A finished workout that is trimmed is not a crash recovery.
        new.partialDataReason = old.partialDataReason
        new.recoveredAt = old.recoveredAt
        session.workoutMetadata = new
    }

    private static func carrySessionFields(from archived: HRVSession, into session: inout HRVSession) {
        session.tags = archived.tags
        session.notes = archived.notes
        session.deviceProvenance = archived.deviceProvenance
        session.linkedSessionIds = archived.linkedSessionIds
        session.aiContext = archived.aiContext
        session.perceivedReadiness = archived.perceivedReadiness
        session.morningFeeling = archived.morningFeeling
        session.morningFeelingTags = archived.morningFeelingTags
        session.trainingSnapshot = archived.trainingSnapshot
        session.healthKitExportedAt = archived.healthKitExportedAt
        session.healthKitExportFailureCount = archived.healthKitExportFailureCount
    }

    /// True when the rebuild starts and ends where the archived copy did, so
    /// figures measured over that span still describe it. After a trim they
    /// would describe time the workout no longer has.
    private static func coversSameTime(_ archived: HRVSession, _ session: HRVSession) -> Bool {
        guard abs(session.startDate.timeIntervalSince(archived.startDate)) < 1 else { return false }
        guard let oldEnd = archived.endDate, let newEnd = session.endDate else { return archived.endDate == session.endDate }
        return abs(newEnd.timeIntervalSince(oldEnd)) < 1
    }

    /// What the user entered or the conditions on the day, true of any
    /// span of the workout. Kept only where the rebuild had nothing.
    private static func carryUserFields(from old: WorkoutMetadata, into new: inout WorkoutMetadata) {
        new.weatherSnapshot = new.weatherSnapshot ?? old.weatherSnapshot
        new.workoutFeeling = new.workoutFeeling ?? old.workoutFeeling
        new.workoutFeelingNote = new.workoutFeelingNote ?? old.workoutFeelingNote
        new.recognizedRouteName = new.recognizedRouteName ?? old.recognizedRouteName
        new.dragFactor = new.dragFactor ?? old.dragFactor
    }

    /// Kept only where the rebuild had nothing and covers the same time: its
    /// own figures, from the recovered data, win.
    private static func carryMeasuredFields(from old: WorkoutMetadata, into new: inout WorkoutMetadata) {
        new.hrrSamples = new.hrrSamples ?? old.hrrSamples
        new.liveMarkers = new.liveMarkers ?? old.liveMarkers
        new.laps = new.laps ?? old.laps
        new.strokeCount = new.strokeCount ?? old.strokeCount
    }

    /// The per-second samples, which only the live recording produced: the
    /// track backup they could be rebuilt from is gone once a workout is
    /// saved. Kept when the rebuild starts where the archived copy did (each
    /// sample is timed and its distance counted from the start), cut to the
    /// rebuild's end. A trim that moved the start leaves them out rather than
    /// misplace every one. The rows marked as heart rate from Apple Health
    /// keep their markers, so the iCloud upload still leaves them out.
    private static func carrySamples(from archived: HRVSession, into session: HRVSession, metadata new: inout WorkoutMetadata) {
        guard new.samples == nil, let old = archived.workoutMetadata?.samples, !old.isEmpty,
              abs(session.startDate.timeIntervalSince(archived.startDate)) < 1
        else { return }
        let end = (session.endDate ?? archived.endDate).map { $0.timeIntervalSince(session.startDate) }
        let kept = end.map { limit in old.filter { Double($0.offsetSec) <= limit } } ?? old
        new.samples = kept
        new.healthKitHROffsets = healthKitHROffsets(archived.workoutMetadata?.healthKitHROffsets ?? [], in: kept)
        if kept.count == old.count {
            new.averageSplitSecPer500m = new.averageSplitSecPer500m ?? archived.workoutMetadata?.averageSplitSecPer500m
        }
    }

    private static func carryPowerFields(from old: WorkoutMetadata, into new: inout WorkoutMetadata) {
        new.averagePowerWatts = new.averagePowerWatts ?? old.averagePowerWatts
        new.normalizedPowerWatts = new.normalizedPowerWatts ?? old.normalizedPowerWatts
        new.peakPowerWatts = new.peakPowerWatts ?? old.peakPowerWatts
        new.powerTSS = new.powerTSS ?? old.powerTSS
        new.intensityFactor = new.intensityFactor ?? old.intensityFactor
        new.variabilityIndex = new.variabilityIndex ?? old.variabilityIndex
        new.ftpAtTimeOfSession = new.ftpAtTimeOfSession ?? old.ftpAtTimeOfSession
    }
}
