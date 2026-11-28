import Foundation

/// How a rescore reaches the archive. A rescore reads the session, works for
/// seconds and writes back, while other paths save to the same session. So
/// the write is optimistic: under the archive's lock (`SessionArchive.update`)
/// the stored copy's inputs (what the result is computed from) are compared
/// with the copy the rescore read. When they still match, only what this kind
/// of rescore computes is set on the stored copy, and every other field stays
/// as stored: tags, notes and the feeling, the HealthKit export stamp (put
/// back to nil it exports the same samples again), the AI context. When they
/// differ, nothing of the rescore is written (the stored copy goes back
/// unchanged) and the caller runs again from the stored copy.
enum RescoreWrite {
    /// Which rescore is writing, and so what it may set.
    enum Kind: Sendable {
        /// `reanalyze`: the window's analysis, its artifact flags, the
        /// cleared manual-window mark, the quality class, the sleep HR in the
        /// vitals snapshot and the score; the training snapshot only when the
        /// pass healed it.
        case reanalysis(healedTraining: Bool)
        /// `recomputeScoreOnly`: the quality class against the current
        /// sleep, the sleep HR in the vitals snapshot, the score, breakdown
        /// and frozen readiness; the training snapshot and the analysis's
        /// training context only when healed.
        case scoreOnly(healedTraining: Bool)
    }

    /// What a write did.
    enum Outcome: Sendable {
        /// Written; the session as stored now.
        case written(HRVSession)
        /// An input changed since the rescore read the session; nothing of
        /// it was written. The stored copy, to run again from.
        case inputsChanged(HRVSession)
        /// The archive does not hold the session (it was never archived, or
        /// was deleted or purged while the rescore ran); nothing was written.
        case notArchived

        /// The session as written; nil when nothing was.
        var written: HRVSession? {
            guard case .written(let session) = self else { return nil }
            return session
        }
    }

    /// How many times a rescore runs before it gives up on inputs that keep
    /// changing. Each edit that changes an input rescores the session
    /// itself, so giving up loses nothing.
    static let runs = 3

    /// Write `rescored`, computed from `read`, onto the archived copy.
    ///
    /// A rescore never creates a session: one the archive does not hold is
    /// not written (`.notArchived`). Archiving it "as it is" put a whole night
    /// back, beats and score included, when "Delete All My Data" emptied the
    /// archive while the rescore ran, and archived a reading still waiting
    /// for the user to accept or discard it.
    static func write(_ rescored: HRVSession, readFrom read: HRVSession, kind: Kind, to archive: SessionArchive) throws -> Outcome {
        guard archive.store.exists(rescored.id) else {
            debugLog("[ReanalysisService] Rescored session \(rescored.id.uuidString.prefix(8)) is not in the archive — not written")
            return .notArchived
        }
        // Every written rescore is uploaded again (`ReanalysisService.queueUpload`):
        // asked for on disk first, so a kill after the write keeps the request.
        archive.noteReuploadIntent([rescored.id])
        var outcome = Outcome.written(rescored)
        try archive.updateIfChanged(rescored.id, requestingReupload: false) { stored in
            guard inputsMatch(stored, read, kind: kind) else {
                outcome = .inputsChanged(stored)
                return false
            }
            applyComputedFields(from: rescored, to: &stored, kind: kind)
            outcome = .written(stored)
            return true
        }
        return outcome
    }

    /// Set on `session` what this kind of rescore computes, from `rescored`.
    ///
    /// The quality class and the vitals snapshot are the ones the pass scored
    /// with: the quality is classified against the sleep the score read, and
    /// the snapshot's sleep HR follows the analysis and quality
    /// (`HRVSession.refreshSleepHeartRate`). Both were derived from the copy
    /// the pass read, which `write` has checked is still the stored one.
    static func applyComputedFields(from rescored: HRVSession, to session: inout HRVSession, kind: Kind) {
        session.recoveryScore = rescored.recoveryScore
        session.scoreBreakdown = rescored.scoreBreakdown
        session.frozenReadiness = rescored.frozenReadiness
        session.hrvDataQuality = rescored.hrvDataQuality
        session.vitalsSnapshot = rescored.vitalsSnapshot
        switch kind {
        case let .reanalysis(healedTraining):
            session.analysisResult = rescored.analysisResult
            session.artifactFlags = rescored.artifactFlags
            session.windowUserAdjusted = rescored.windowUserAdjusted
            if healedTraining { session.trainingSnapshot = rescored.trainingSnapshot }
        case let .scoreOnly(healedTraining):
            guard healedTraining else { return }
            session.trainingSnapshot = rescored.trainingSnapshot
            session.analysisResult?.trainingContext = rescored.analysisResult?.trainingContext
        }
    }

    /// The stored copy a reanalysis whose inputs changed runs again from, or
    /// nil when it stops: a manual window picked meanwhile is the user's and
    /// is never replaced (the pick scores the session itself), a copy with
    /// no beats cannot be analysed, and the last run gives up.
    static func reanalysisRerun(read: HRVSession, stored: HRVSession, run: Int) -> HRVSession? {
        if stored.windowUserAdjusted == true, read.windowUserAdjusted != true {
            debugLog("[ReanalysisService] A window was picked by hand during the reanalysis — leaving it")
            return nil
        }
        guard run < runs else {
            debugLog("[ReanalysisService] Inputs kept changing during the reanalysis — giving up; the edit that changed them rescores the session")
            return nil
        }
        guard let series = stored.rrSeries, !series.points.isEmpty else {
            debugLog("[ReanalysisService] The archived copy has no beats to reanalyse — giving up")
            return nil
        }
        return stored
    }

    /// Whether `training` heals `candidate`: its load differs, the same test
    /// both rescores use before they replace a frozen snapshot.
    static func heals(_ training: TrainingContext, over candidate: TrainingContext?) -> Bool {
        training.atl != candidate?.atl || training.ctl != candidate?.ctl
    }

    /// Whether the two copies' inputs for this kind of rescore are the same.
    /// An input that cannot be encoded counts as changed.
    static func inputsMatch(_ stored: HRVSession, _ read: HRVSession, kind: Kind) -> Bool {
        guard let storedInputs = encodedInputs(of: stored, kind: kind),
              let readInputs = encodedInputs(of: read, kind: kind) else { return false }
        return storedInputs == readInputs
    }

    private static func encodedInputs(of session: HRVSession, kind: Kind) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            return try encoder.encode(Inputs(of: session, kind: kind))
        } catch {
            debugLog("[ReanalysisService] Could not compare a rescore's inputs: \(error)", level: .warning)
            return nil
        }
    }

    /// What a rescore's result is computed from: the recording's span (its
    /// start and end, which the quality check measures), the beats (by count
    /// and first and last timestamp), the sleep boundaries, segments and
    /// snapshot, the vitals, the perceived readiness and the training
    /// snapshot; for a score-only pass also the analysis it scores, and for a
    /// reanalysis the manual-window mark it would clear.
    private struct Inputs: Encodable {
        let startDate: Date
        let endDate: Date?
        let beatCount: Int
        let firstBeatMs: Int64?
        let lastBeatMs: Int64?
        let sleepStartMs: Int64?
        let sleepEndMs: Int64?
        let sleepSegments: [HRVSession.SleepSegmentMs]?
        let sleepSnapshot: SleepData?
        let vitalsSnapshot: RecoveryVitals?
        let perceivedReadiness: Double?
        let trainingSnapshot: TrainingContext?
        let analysisResult: HRVAnalysisResult?
        let windowUserAdjusted: Bool?

        init(of session: HRVSession, kind: Kind) {
            let points = session.rrSeries?.points ?? []
            (startDate, endDate) = (session.startDate, session.endDate)
            beatCount = points.count
            (firstBeatMs, lastBeatMs) = (points.first?.t_ms, points.last?.t_ms)
            sleepStartMs = session.sleepStartMs
            sleepEndMs = session.sleepEndMs
            sleepSegments = session.sleepSegments
            sleepSnapshot = session.sleepSnapshot
            vitalsSnapshot = session.vitalsSnapshot
            perceivedReadiness = session.perceivedReadiness
            trainingSnapshot = session.trainingSnapshot
            switch kind {
            case .reanalysis:
                analysisResult = nil
                windowUserAdjusted = session.windowUserAdjusted
            case .scoreOnly:
                analysisResult = session.analysisResult
                windowUserAdjusted = nil
            }
        }
    }

    /// Every stored field of `HRVSession`, classified. A test checks that the
    /// two sets together name every stored field, so a field added to the
    /// session is classified before a rescore can write it. Computed: set by
    /// some rescore (`applyComputedFields`, each kind its own part).
    static let computedFields: Set<String> = [
        "analysisResult", "artifactFlags", "windowUserAdjusted", "hrvDataQuality",
        "recoveryScore", "scoreBreakdown", "frozenReadiness", "trainingSnapshot", "vitalsSnapshot"
    ]

    /// Never written by a rescore: the recording and its identity, the beats
    /// (the archive's own), the user's entries and adjustments, the sleep
    /// snapshot, and the export, sync and AI bookkeeping.
    static let storedFields: Set<String> = [
        "sourceSchemaVersion", "id", "startDate", "endDate", "state", "sessionType", "rrSeries",
        "tags", "notes", "importedMetrics", "deviceProvenance", "sleepStartMs", "sleepEndMs",
        "sleepSegments", "linkedSessionIds", "pausedDate", "dataSourceSummary", "sleepSnapshot",
        "sleepUserAdjusted", "napRepaired", "autoWindowResult", "autoWindowScore",
        "healthKitExportedAt", "healthKitExportFailureCount", "modifiedAt", "aiContext",
        "perceivedReadiness", "morningFeeling", "morningFeelingTags", "workoutMetadata"
    ]
}
