import Foundation

/// The main-actor state a re-score reads besides the session
/// (`ReanalysisService.rescoredBreakdown`): the baseline of the nights before
/// the session, the user's typical sleep and the scoring configuration.
/// Captured on the main actor, so the arithmetic itself can run off it.
struct RescoreContext: Sendable {
    let baselineStats: BaselineTracker.RecoveryBaselineStats?
    let typicalSleepHours: Double
    let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
}

/// How a sleep-boundary edit (`ReanalysisService.updateSessionSleepBoundaries`)
/// reaches the archive, off the main actor. The service reads the session and
/// captures what the re-score needs from the main actor (`Inputs`); `write`
/// then runs on a detached task. It decides on the copy it read whether the
/// edit applies, and under the archive's lock (`SessionArchive.update`)
/// compares that copy's inputs with the stored copy's, as `RescoreWrite`
/// does. When they still match, the boundaries, segments and snapshot are set
/// on the stored copy, which is then classified and scored again; every other
/// field stays as stored. When they differ, nothing is written and the caller
/// runs again from the stored copy.
enum SleepBoundaryWrite {
    /// One edit: the new sleep, with the start and end it must have.
    struct Edit: Sendable {
        let sleepData: SleepData
        let sleepStart: Date
        let sleepEnd: Date
        /// A user's own edit: always applies, marks the sleep as adjusted and
        /// asks iCloud to upload the session again.
        let isUserAdjustment: Bool

        /// Nil when the sleep has no start or no end.
        init?(sleepData: SleepData, isUserAdjustment: Bool) {
            guard let start = sleepData.sleepStart, let end = sleepData.sleepEnd else { return nil }
            self.sleepData = sleepData
            sleepStart = start
            sleepEnd = end
            self.isUserAdjustment = isUserAdjustment
        }
    }

    /// What the edit's re-score reads that the session does not hold.
    struct Inputs: Sendable {
        let context: RescoreContext
        /// The training context built for the session's date. Used only when
        /// the session has an analysis but no training context of its own;
        /// nil otherwise.
        let fallbackTraining: TrainingContext?
    }

    /// What a write did.
    enum Outcome: Sendable {
        /// Written; the session as stored now.
        case written(HRVSession)
        /// An automatic update that does not apply to the copy it read
        /// (`shouldApplyAutomaticUpdate`); nothing was written.
        case declined
        /// An input changed since the copy was read; nothing of the edit was
        /// written. The stored copy, to run again from.
        case inputsChanged(HRVSession)
        /// The archive no longer holds the session; nothing was written.
        case notArchived

        /// The session as written; nil when nothing was.
        var written: HRVSession? {
            guard case .written(let session) = self else { return nil }
            return session
        }
    }

    /// Apply `edit`, decided on `read`, to the archived copy of `read`.
    static func write(_ edit: Edit, readFrom read: HRVSession, inputs: Inputs, to archive: SessionArchive) throws -> Outcome {
        logBoundaryUpdate(edit, on: read)
        guard edit.isUserAdjustment || shouldApplyAutomaticUpdate(edit, to: read) else { return .declined }
        guard archive.store.exists(read.id) else {
            debugLog("[UpdateSleepBounds] Bailed: session \(read.id.uuidString.prefix(8)) not in archive")
            return .notArchived
        }
        // Uploaded again once written (`ReanalysisService.queueUpload`): asked for first.
        archive.noteReuploadIntent([read.id])
        var outcome = Outcome.written(read)
        try archive.updateIfChanged(read.id, requestingReupload: edit.isUserAdjustment) { stored in
            guard readIsCurrent(read, stored: stored) else {
                outcome = .inputsChanged(stored)
                return false
            }
            apply(edit, to: &stored, inputs: inputs)
            outcome = .written(stored)
            return true
        }
        return outcome
    }

    /// Whether what the edit was decided and scored from is still the
    /// stored copy's: the inputs a score-only re-score compares
    /// (`RescoreWrite.inputsMatch`: beats, sleep, vitals, perceived
    /// readiness, training, the analysis), the user-adjusted mark the
    /// automatic gate reads, and the end date the offsets are clamped to.
    static func readIsCurrent(_ read: HRVSession, stored: HRVSession) -> Bool {
        RescoreWrite.inputsMatch(stored, read, kind: .scoreOnly(healedTraining: false))
            && stored.sleepUserAdjusted == read.sleepUserAdjusted
            && stored.endDate == read.endDate
    }

    /// Set the clamped boundaries, segments and snapshot on `session`, then
    /// classify and score it again.
    ///
    /// An automatic update of a night whose sleep the user adjusted (reached
    /// only while it has no snapshot, `shouldApplyAutomaticUpdate`) fills the
    /// snapshot and keeps the boundaries and segments the user set, as the
    /// automatic refresh does (`SleepRefreshPolicy.applyAutoRefresh`); its
    /// scoring window did not move, so it is not scored again.
    static func apply(_ edit: Edit, to session: inout HRVSession, inputs: Inputs) {
        guard edit.isUserAdjustment || session.sleepUserAdjusted != true else {
            SleepRefreshPolicy.applyPulledSleep(edit.sleepData, to: &session)
            return
        }
        applyBoundaries(edit, offsets: clampedOffsets(of: edit, on: session), to: &session)
        rescore(&session, sessionEnd: session.endDate ?? session.startDate, inputs: inputs)
    }

    /// The edit's start and end as offsets from the session's start, clamped
    /// to the strap recording as the live write paths clamp them (the bounds
    /// `SleepBoundaryResolver.clamp` applies, 0 ... recording length). The
    /// "more data" test and the stored offsets both use these, so an end past
    /// the recording does not count as new data on every refresh.
    static func clampedOffsets(of edit: Edit, on session: HRVSession) -> (startMs: Int64, endMs: Int64) {
        let startMs = max(0, MillisecondOffset.between(edit.sleepStart, and: session.startDate, fallback: 0))
        let endMs = MillisecondOffset.between(edit.sleepEnd, and: session.startDate, fallback: 0)
        let limit = ReanalysisService.recordingDurationMs(of: session)
        return (max(0, min(startMs, limit)), max(0, min(endMs, limit)))
    }

    /// User adjustments (exclude/boundary changes) always apply. Automatic
    /// HealthKit updates only apply if they bring more data.
    ///
    /// Never let an automatic update overwrite a user-adjusted timeline,
    /// regardless of "more data" (ADR 009: user edits are the source
    /// of truth). The callers' own guards can read a stale `session` captured
    /// at view presentation; this gate reads the copy just retrieved from the
    /// archive, and `write` refuses the edit if that copy is no longer the
    /// stored one. Snapshot-nil sessions are exempt: CloudKit uploads strip
    /// HK-derived snapshots (5.1.3), so a user-adjusted session pulled onto a
    /// second device needs its first local fill.
    ///
    /// An automatic sleep block that doesn't physically overlap the recording
    /// is rejected (see `SleepData.plausiblyBelongsToRecording`).
    static func shouldApplyAutomaticUpdate(_ edit: Edit, to session: HRVSession) -> Bool {
        let sleepData = edit.sleepData
        guard session.sleepUserAdjusted != true || session.sleepSnapshot == nil else {
            debugLog("[UpdateSleepBounds] Bailed: session has user-adjusted sleep; auto update discarded")
            return false
        }
        let recordingEnd = session.endDate ?? session.startDate
        guard sleepData.plausiblyBelongsToRecording(start: session.startDate, end: recordingEnd) else {
            debugLog("[UpdateSleepBounds] Bailed: \(sleepData.nightSleepMinutes)m sleep window does not overlap the \(Int(recordingEnd.timeIntervalSince(session.startDate) / 60))m recording — implausible auto attach")
            return false
        }
        let offsets = clampedOffsets(of: edit, on: session)
        let storedDuration = (session.sleepEndMs ?? 0) - (session.sleepStartMs ?? 0)
        let snapshotMinutes = session.sleepSnapshot?.nightSleepMinutes ?? 0
        return offsets.endMs - offsets.startMs > storedDuration || sleepData.nightSleepMinutes > snapshotMinutes
    }

    /// Write the clamped boundaries, segments and frozen snapshot onto the session.
    private static func applyBoundaries(_ edit: Edit, offsets: (startMs: Int64, endMs: Int64), to session: inout HRVSession) {
        session.sleepStartMs = offsets.startMs
        session.sleepEndMs = offsets.endMs
        if edit.sleepData.segments.count > 1 {
            let start = session.startDate
            session.sleepSegments = edit.sleepData.segments.map { seg in
                HRVSession.SleepSegmentMs(
                    startMs: MillisecondOffset.between(seg.sleepStart, and: start, fallback: 0),
                    endMs: MillisecondOffset.between(seg.sleepEnd, and: start, fallback: 0)
                )
            }
        } else {
            // Single-segment night: drop any stale multi-segment array so
            // it can't disagree with the freshly-written snapshot.
            session.sleepSegments = nil
        }
        // Also update the frozen snapshot so history shows the complete data
        session.sleepSnapshot = edit.sleepData.keepingNapCredit(of: session.sleepSnapshot)
        if edit.isUserAdjustment {
            session.sleepUserAdjusted = true
        }
    }

    /// Recalculate the recovery score when the session's sleep snapshot
    /// changed (a sleep edit, an automatic update or a retro-apply), so the
    /// score reflects excluded/adjusted segments. The session is classified
    /// again first: whether the recording overlaps sleep is decided from the
    /// sleep, so an edit can set or clear `.preSleep`, and the snapshot's
    /// sleep HR follows the new quality. The score is
    /// `ReanalysisService.rescoredBreakdown` against the frozen training
    /// context (the session's, else its analysis's, else
    /// `inputs.fallbackTraining`), anchored to `sessionEnd`. A session with
    /// no analysis is left as it is, and so is the score of one no baseline
    /// can be built for (`ReanalysisService.keepsStoredScore`).
    static func rescore(_ session: inout HRVSession, sessionEnd: Date, inputs: Inputs) {
        guard let result = session.analysisResult else { return }
        let beforeClassifying = session
        ReanalysisService.reclassifyHRVQuality(of: &session, result: result, baselineStats: inputs.context.baselineStats)
        session.refreshSleepHeartRate(replacing: beforeClassifying)
        guard !ReanalysisService.keepsStoredScore(session, baseline: inputs.context.baselineStats) else { return }
        let trainingContext = session.trainingSnapshot ?? result.trainingContext ?? inputs.fallbackTraining
        let breakdown = ReanalysisService.rescoredBreakdown(
            of: session, result: result, training: trainingContext, referenceDate: sessionEnd, context: inputs.context
        )
        session.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        session.scoreBreakdown = breakdown
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(compositeScore: breakdown.compositeScore, trainingContext: trainingContext)
        debugLog("[ReanalysisService] Recalculated recovery score after sleep adjustment: \(String(format: "%.1f", session.recoveryScore ?? 0))")
    }

    private static func logBoundaryUpdate(_ edit: Edit, on session: HRVSession) {
        let newStartMs = max(0, MillisecondOffset.between(edit.sleepStart, and: session.startDate, fallback: 0))
        let newEndMs = MillisecondOffset.between(edit.sleepEnd, and: session.startDate, fallback: 0)
        let sleepData = edit.sleepData
        debugLog("[UpdateSleepBounds] session.startDate=\(session.startDate) sleepStart=\(edit.sleepStart) sleepEnd=\(edit.sleepEnd)")
        debugLog("[UpdateSleepBounds] newStartMs=\(newStartMs) newEndMs=\(newEndMs) oldStartMs=\(session.sleepStartMs ?? -1) oldEndMs=\(session.sleepEndMs ?? -1)")
        debugLog("[UpdateSleepBounds] newData: totalMin=\(sleepData.totalSleepIncludingNapMinutes) nightMin=\(sleepData.nightSleepMinutes) segments=\(sleepData.segments.count) isUserAdj=\(edit.isUserAdjustment)")
    }
}
