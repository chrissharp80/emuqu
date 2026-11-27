import Foundation

/// Owns the heavy work of session acceptance (score recomputation, sleep fetch,
/// archive, baseline update, CloudKit upload, HealthKit export) without directly
/// mutating any observable UI state. The caller (RRCollector) performs the final
/// UI state updates after the service returns.
@MainActor
final class SessionAcceptanceService {
    // MARK: - Dependencies

    private let archive: SessionArchive
    private let healthKit: any HealthKitServiceProtocol
    private let baselineTracker: BaselineTracker
    private let rawBackup: RawRRBackup
    /// Called to sync an accepted session to iCloud.
    private let onCloudSync: (HRVSession) async -> Void

    /// Called to delete a live backup from iCloud after acceptance or rejection.
    private let onCloudDelete: (UUID) async -> Void

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        onCloudSync: @escaping (HRVSession) async -> Void,
        onCloudDelete: @escaping (UUID) async -> Void
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.baselineTracker = baselineTracker
        self.rawBackup = rawBackup
        self.onCloudSync = onCloudSync
        self.onCloudDelete = onCloudDelete
    }

    // MARK: - Accept Session

    /// How far to trust this recording's HRV, and whether to fall back to the
    /// user's baseline instead.
    ///
    /// Decision tree, checked in this order:
    ///   1. RMSSD < baseline and either the analysis window is too short (the
    ///      strap died mid-window) or a short session never reached organised
    ///      recovery → baseline fallback (`.insufficient`)
    ///   2. No sleep overlap → baseline fallback (`.preSleep`)
    ///   3. RMSSD < baseline + short session → baseline fallback (`.insufficient`)
    ///   4. Otherwise → trust it (`.good`), including a long session below
    ///      baseline, which is a legitimately bad night
    ///
    /// The thresholds are `HRVConstants.MinimumDuration.forReliableWindowMs`
    /// and `forOvernightSessionSeconds`.
    struct HRVQualityDecision {
        let dataQuality: HRVDataQuality

        /// Whether the score substitutes the baseline for this recording's
        /// HRV: exactly when the quality keeps the reading out of HRV
        /// aggregates (`.insufficient`, `.preSleep`). The re-score paths
        /// derive the same flag from the stored quality through
        /// `HRVSession.isReliableForHRVAggregates`, so both read one rule.
        var useBaselineHRV: Bool {
            !HRVDataQuality.allowsHRVAggregates(dataQuality)
        }
    }

    nonisolated static func classifyHRVQuality(
        result: HRVAnalysisResult,
        sleepData: SleepData?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        recordingStart: Date,
        recordingEnd: Date
    ) -> HRVQualityDecision {
        let sessionDuration = recordingEnd.timeIntervalSince(recordingStart)
        let rmssd = result.timeDomain.rmssd
        let baselineRmssd = baselineStats.map { exp($0.lnRmssdMean) } ?? 0
        if let insufficient = insufficientDataDecision(result: result, rmssd: rmssd, baselineRmssd: baselineRmssd, sessionDuration: sessionDuration) {
            return insufficient
        }
        guard overlapsSleep(sleepData, recordingStart: recordingStart, recordingEnd: recordingEnd) else {
            debugLog("[SessionAcceptanceService] HRV recording doesn't overlap sleep — using baseline HRV")
            return HRVQualityDecision(dataQuality: .preSleep)
        }
        let longEnough = sessionDuration >= HRVConstants.MinimumDuration.forOvernightSessionSeconds
        guard rmssd >= baselineRmssd || longEnough else {
            // RMSSD and baseline are PHI and debugLog is user-exportable.
            debugLog("[SessionAcceptanceService] Short session (\(Int(sessionDuration))s) with RMSSD below baseline — using baseline HRV")
            return HRVQualityDecision(dataQuality: .insufficient)
        }
        if !longEnough {
            debugLog("[SessionAcceptanceService] Short session (\(Int(sessionDuration))s) but RMSSD at or above baseline — trusting it")
        }
        return HRVQualityDecision(dataQuality: .good)
    }

    /// No sleep data means we cannot determine overlap — trust the HRV as-is.
    nonisolated private static func overlapsSleep(
        _ sleepData: SleepData?, recordingStart: Date, recordingEnd: Date
    ) -> Bool {
        guard let sleepStart = sleepData?.sleepStart, let sleepEnd = sleepData?.sleepEnd else {
            return true
        }
        return recordingEnd > sleepStart && recordingStart < sleepEnd
    }

    /// Rule 1, the insufficient-data rule, and the one implementation of it:
    /// the morning pre-score gate and the insufficient-data migration reach
    /// it through `ReanalysisService.hasInsufficientData`. A window too short
    /// to trust, or a session that never reached its recovery zone, both
    /// count as insufficient when the RMSSD also came in under baseline. With
    /// no window (full-session analysis) the analysed span is the session.
    nonisolated static func isInsufficientData(
        result: HRVAnalysisResult, baselineRmssd: Double, sessionDuration: TimeInterval
    ) -> Bool {
        guard result.timeDomain.rmssd < baselineRmssd else { return false }
        let windowTooShort = analysedSpanMs(of: result, sessionDuration: sessionDuration)
            < HRVConstants.MinimumDuration.forReliableWindowMs
        let noRecoveryZoneData = result.isOrganizedRecovery != true
            && sessionDuration < HRVConstants.MinimumDuration.forOvernightSessionSeconds
        return windowTooShort || noRecoveryZoneData
    }

    /// The analysis window's length, or the session's when there is none.
    /// The one reading of the span both this rule and the baseline's
    /// structural gate (`BaselineTracker.isStructurallySound`) compare with
    /// `forReliableWindowMs`. A window's bounds are half-open in time (the
    /// selector ends it where its last beat ends), so this is the time the
    /// window covers, the quantity the 5-minute threshold is written in.
    nonisolated static func analysedSpanMs(of result: HRVAnalysisResult, sessionDuration: TimeInterval) -> Int64 {
        guard let wsMs = result.windowStartMs, let weMs = result.windowEndMs else { return Int64(sessionDuration * 1000) }
        return weMs - wsMs
    }

    /// Rule 1 as a decision, with the reason logged. Nil means the data is
    /// good enough to judge normally. `rmssd` is the result's own RMSSD.
    nonisolated private static func insufficientDataDecision(
        result: HRVAnalysisResult, rmssd: Double, baselineRmssd: Double, sessionDuration: TimeInterval
    ) -> HRVQualityDecision? {
        guard rmssd < baselineRmssd,
              isInsufficientData(result: result, baselineRmssd: baselineRmssd, sessionDuration: sessionDuration) else {
            return nil
        }
        let analysisWindowDurationMs = analysedSpanMs(of: result, sessionDuration: sessionDuration)
        if analysisWindowDurationMs < HRVConstants.MinimumDuration.forReliableWindowMs {
            debugLog("[SessionAcceptanceService] Analysis window only \(analysisWindowDurationMs / 1000)s with RMSSD below baseline — too short to trust, using baseline HRV")
        } else {
            debugLog("[SessionAcceptanceService] No organized recovery in \(Int(sessionDuration / 60))min session with RMSSD below baseline — didn't reach recovery zone, using baseline HRV")
        }
        return HRVQualityDecision(dataQuality: .insufficient)
    }

    /// The training context to freeze alongside the score.
    ///
    /// The recovery composite does not read training load
    /// (`calculateWithBreakdown` ignores it); the context feeds the frozen
    /// training readiness and is stamped onto the session so every read path
    /// sees the ATL/CTL/TSB/ACWR of that morning. If the caller hands us no
    /// context and the user has training-load integration enabled, one is
    /// fetched inline: one bounded HealthKit call on the rare cold path,
    /// rather than a session frozen with no training context at all.
    private func resolveTrainingContext(
        given trainingContext: TrainingContext?,
        scoringConfig: RecoveryScoreCalculator.ScoringConfiguration,
        sessionEnd: Date
    ) async -> TrainingContext? {
        if let ctx = trainingContext { return ctx }
        guard scoringConfig.enableTrainingLoadIntegration,
              !scoringConfig.isOnTrainingBreak
        else { return nil }
        let load = await healthKit.calculateTrainingLoad(relativeTo: sessionEnd)
        return TrainingContext(from: load, relativeTo: sessionEnd)
    }

    /// Sleep and vitals, frozen from this point forward — raced against a
    /// 10-second timeout.
    ///
    /// The HealthKit queries go through `withCheckedContinuation`, which hangs
    /// forever if the callback never fires. `runWithTimeout` returns at ten
    /// seconds without awaiting the wedged fetch, so it costs ten seconds and
    /// a score without sleep/vitals, rather than an acceptance that never
    /// completes.
    /// A failed sleep fetch is not fatal to acceptance — the score is computed
    /// without it — but it must leave a trace.
    ///
    /// The search runs over the whole night, but the beats count from when the
    /// strap started (`rrStart`); without it, a night with no Watch had its
    /// beat-estimated sleep laid out from the bedtime window's start instead,
    /// shifting the night by however long before the strap that window opens.
    nonisolated private static func sleepOrNil(
        _ hk: any HealthKitServiceProtocol, from fetchStart: Date, to fetchEnd: Date,
        rrPoints: [RRPoint]?, rrStart: Date
    ) async -> SleepData? {
        do {
            return try await hk.fetchNightSleep(
                for: fetchStart, recordingEnd: fetchEnd, rrPoints: rrPoints, rrStart: rrStart, nightAnchor: rrStart
            )
        } catch {
            debugLog("[SessionAcceptanceService] Sleep fetch failed: \(error)")
            return nil
        }
    }

    private func fetchSleepAndVitals(
        rrPoints: [RRPoint]?,
        fetchStart: Date,
        fetchEnd: Date,
        sessionStart: Date,
        sessionEnd: Date
    ) async -> (SleepData?, RecoveryVitals?) {
        let hk = healthKit
        let raced = await runWithTimeout(seconds: 10) {
            let fetched = await Self.sleepOrNil(
                hk, from: fetchStart, to: fetchEnd, rrPoints: rrPoints, rrStart: sessionStart
            )
            return SleepAndVitals(sleep: fetched, vitals: await hk.fetchRecoveryVitals(relativeTo: sessionEnd))
        }
        guard let raced else {
            debugLog("[SessionAcceptanceService] ⚠️ HealthKit fetch timed out after 10s — scoring without sleep/vitals")
            return (nil, nil)
        }
        return (raced.sleep, raced.vitals)
    }

    private struct SleepAndVitals: Sendable {
        let sleep: SleepData?
        let vitals: RecoveryVitals?
    }

    /// The frozen inputs one acceptance scores against.
    struct AcceptanceInputs {
        let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
        let trainingContext: TrainingContext?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let typicalSleepHours: Double
        let sleepSchedule: SleepSchedule
    }

    /// Performs the heavy work of accepting a session:
    /// recomputes the recovery score with fresh HealthKit data, archives the session,
    /// updates baseline, marks raw backup, exports to HealthKit if enabled, and syncs
    /// to CloudKit.
    ///
    /// When the archive folds the recording into a night it already holds (a
    /// second recording of the same night), the baseline, the Apple Health
    /// export and the upload take that merged night, which keeps the score of
    /// the analysis it kept; the recording's own live backup is still cleared.
    ///
    /// - Returns: The accepted session, or the night it was folded into.
    /// - Throws: If archiving fails.
    func processAcceptance(
        session: HRVSession,
        inputs: AcceptanceInputs,
        enableHealthKitExport: Bool,
        clearPersistedRecordingState: () -> Void
    ) async throws -> HRVSession {
        let recordingId = session.id
        debugLog("[SessionAcceptanceService] Accepting and archiving session ID: \(recordingId.uuidString)")
        let accepted: HRVSession
        if let archived = try await acceptArchived(session, inputs: inputs) {
            accepted = archived
        } else {
            accepted = try await acceptUnarchived(session, inputs: inputs)
        }
        baselineTracker.update(with: accepted, sleepSchedule: inputs.sleepSchedule)
        Self.requestRewindowIfSleepMoved(from: session, to: accepted)
        let session = accepted
        // Clear persisted recording state - session is now safely archived.
        // NOTE: We intentionally do NOT clear the H10 memory here — data stays
        // on the H10 as a backup until a new recording starts.
        clearPersistedRecordingState()
        exportToHealthIfEnabled(session, enabled: enableHealthKitExport)
        syncToCloud(session, liveBackupOf: recordingId)
        return session
    }

    /// A night the archive does not hold yet: frozen, then archived whole.
    private func acceptUnarchived(_ session: HRVSession, inputs: AcceptanceInputs) async throws -> HRVSession {
        var session = session
        if let result = session.analysisResult {
            await freezeScore(on: &session, result: result, inputs: inputs)
        }
        let (archive, rawBackup, toArchive) = (archive, rawBackup, session)
        return try await Task.detached(priority: .userInitiated) {
            try Self.archiveReturningNight(toArchive, archive: archive, rawBackup: rawBackup)
        }.value
    }

    /// A night already in the archive, saved there before the user reviewed
    /// it (`MorningSessionPipeline.archiveForReview`). While the review card
    /// was open the user's rating, window pick and sleep edit, and any
    /// rescore, went to the archived copy, not to the card's. Writing the
    /// card's copy back whole undid them. The score is frozen from the
    /// stored copy and only what acceptance computes is written onto it,
    /// under the archive's lock, when its inputs are still the ones read
    /// (`RescoreWrite.inputsMatch`); otherwise it runs again from the newer
    /// copy. nil when the archive does not hold the night, or holds other
    /// beats than the card's: a strap download merged into an archived night
    /// is meant to replace it on Accept (`assembleDownloadedSession`), and is
    /// written whole as before.
    ///
    /// A recording the archive folded into a night it already held
    /// (`SessionArchive.archivedId(of:)`) is accepted as that night, whose
    /// beats include the card's: archiving the card's copy again would merge
    /// the recording a second time and freeze a score nothing keeps.
    private func acceptArchived(_ session: HRVSession, inputs: AcceptanceInputs) async throws -> HRVSession? {
        let (archive, rawBackup) = (archive, rawBackup)
        let id = archive.archivedId(of: session.id)
        guard archive.store.exists(id), let stored = try archive.retrieve(id),
              id != session.id || Self.sameBeats(stored, session) else { return nil }
        for _ in 0 ..< RescoreWrite.runs {
            guard var frozen = try archive.retrieve(id) else { return nil }
            let read = frozen
            if let result = frozen.analysisResult { await freezeScore(on: &frozen, result: result, inputs: inputs) }
            let toWrite = frozen
            if let written = try await Task.detached(priority: .userInitiated, operation: { try Self.writeAccepted(toWrite, readFrom: read, to: archive) }).value {
                rawBackup.markAsArchived(session.id)
                return written
            }
        }
        debugLog("[SessionAcceptanceService] The night kept changing while it was accepted; it keeps its stored score", level: .warning)
        rawBackup.markAsArchived(session.id)
        return try archive.retrieve(id)
    }

    /// Puts what acceptance computed on the archived copy, if its inputs are
    /// those of `read`; nil, with nothing written, when they are not. Throws
    /// when the night is no longer in the archive (deleted meanwhile): a
    /// deleted night is not written back.
    nonisolated static func writeAccepted(_ frozen: HRVSession, readFrom read: HRVSession, to archive: SessionArchive) throws -> HRVSession? {
        var written: HRVSession?
        try archive.updateIfChanged(frozen.id, requestingReupload: false) { stored in
            guard RescoreWrite.inputsMatch(stored, read, kind: .scoreOnly(healedTraining: false)) else { return false }
            applyAccepted(from: frozen, to: &stored)
            written = stored
            return true
        }
        return written
    }

    /// Whether two copies of a night hold the same beats: their count and
    /// first and last timestamps.
    nonisolated static func sameBeats(_ lhs: HRVSession, _ rhs: HRVSession) -> Bool {
        let (left, right) = (lhs.rrSeries?.points ?? [], rhs.rrSeries?.points ?? [])
        return left.count == right.count && left.first?.t_ms == right.first?.t_ms && left.last?.t_ms == right.last?.t_ms
    }

    /// The fields acceptance computes: the frozen sleep with its window, the
    /// vitals and the score.
    nonisolated static func applyAccepted(from frozen: HRVSession, to stored: inout HRVSession) {
        applyFrozenSleep(from: frozen, to: &stored)
        stored.vitalsSnapshot = frozen.vitalsSnapshot
        stored.hrvDataQuality = frozen.hrvDataQuality
        stored.recoveryScore = frozen.recoveryScore
        stored.scoreBreakdown = frozen.scoreBreakdown
        stored.frozenReadiness = frozen.frozenReadiness
        stored.analysisResult?.trainingContext = frozen.analysisResult?.trainingContext
        if stored.trainingSnapshot == nil { stored.trainingSnapshot = frozen.trainingSnapshot }
    }

    /// Archive the accepted recording and return the night that now holds it:
    /// the recording itself, or the night already archived that it was folded
    /// into (a second recording of the same night). Encoding, encryption,
    /// hashing and the file and index writes run on the caller's detached
    /// task, never the main actor; the archive and the backup index guard
    /// their own state with locks.
    nonisolated private static func archiveReturningNight(
        _ session: HRVSession, archive: SessionArchive, rawBackup: RawRRBackup
    ) throws -> HRVSession {
        let night = try archive.archiveReturningNight(session)
        rawBackup.markAsArchived(session.id)
        return night
    }

    /// Recompute the composite recovery score at acceptance time and snapshot
    /// HealthKit data, so the dashboard stays stable for the rest of the day.
    private func freezeScore(
        on session: inout HRVSession, result: HRVAnalysisResult, inputs: AcceptanceInputs
    ) async {
        let sessionEnd = session.endDate ?? session.startDate
        let resolvedTrainingContext = await resolveTrainingContext(
            given: inputs.trainingContext,
            scoringConfig: inputs.scoringConfig,
            sessionEnd: sessionEnd
        )
        await snapshotHealthData(on: &session, sessionEnd: sessionEnd, sleepSchedule: inputs.sleepSchedule)
        let useBaselineHRV = Self.applyHRVQuality(to: &session, result: result, baselineStats: inputs.baselineStats)
        session.applySleepHeartRateToVitals()
        let breakdown = scoreBreakdown(
            result: result, session: session, inputs: inputs,
            training: resolvedTrainingContext, useBaselineHRV: useBaselineHRV
        )
        applyFrozenScore(breakdown, to: &session, training: resolvedTrainingContext)
    }

    /// Classify the session's HRV against its sleep and the baseline, store
    /// the quality on it, and return whether the score should use baseline
    /// HRV. The acceptance path runs it, and the archived-score refresh runs
    /// it for a session that was never classified.
    private static func applyHRVQuality(
        to session: inout HRVSession,
        result: HRVAnalysisResult,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> Bool {
        let quality = classifyHRVQuality(
            result: result,
            sleepData: session.sleepSnapshot,
            baselineStats: baselineStats,
            recordingStart: session.startDate,
            recordingEnd: session.endDate ?? session.startDate
        )
        session.hrvDataQuality = quality.dataQuality
        return quality.useBaselineHRV
    }

    /// Fetch and snapshot sleep + vitals — frozen from this point forward.
    /// HealthKit queries use withCheckedContinuation which can hang if
    /// callbacks never fire, so we race against a 10-second timeout.
    ///
    /// The vitals are stored as HealthKit gives them; the strap's nocturnal
    /// HR replaces Apple's daytime-rest RHR once the recording's quality is
    /// known (`HRVSession.applySleepHeartRateToVitals`, in `freezeScore`), so
    /// an unusable recording's awake heart rate never stands as sleep HR.
    private func snapshotHealthData(
        on session: inout HRVSession, sessionEnd: Date, sleepSchedule: SleepSchedule
    ) async {
        let (fetchStart, fetchEnd) = sleepFetchRange(for: session, sessionEnd: sessionEnd, sleepSchedule: sleepSchedule)
        let (sleepData, vitals) = await fetchSleepAndVitals(
            rrPoints: session.rrSeries?.points,
            fetchStart: fetchStart,
            fetchEnd: fetchEnd,
            sessionStart: session.startDate,
            sessionEnd: sessionEnd
        )
        Self.freezeFetchedSleep(sleepData, on: &session)
        if let vitals { session.vitalsSnapshot = vitals }
    }

    /// Freezes the fetched sleep on the session (`sleepToFreeze`), with the
    /// boundaries and segments the analysis window is chosen in moved to it
    /// (`ReanalysisService.applySleepBoundaries`), as the automatic sleep
    /// refresh moves them: a snapshot replaced under unchanged boundaries
    /// shows one sleep while the score is computed in another, and the
    /// later refresh, comparing against the replaced snapshot, never sees
    /// the end move. A night whose sleep the user set by hand keeps it:
    /// Health's reading is what they corrected.
    nonisolated static func freezeFetchedSleep(_ fetched: SleepData?, on session: inout HRVSession) {
        guard session.sleepUserAdjusted != true, let fetched, freezes(fetched, over: session.sleepSnapshot) else { return }
        // A sleep with no start or end has no window to move to.
        guard fetched.sleepStart != nil, fetched.sleepEnd != nil else {
            session.sleepSnapshot = fetched
            return
        }
        ReanalysisService.applySleepBoundaries(fetched, to: &session, sessionStart: session.startDate)
    }

    /// The sleep snapshot and the window derived from it, moved together.
    nonisolated static func applyFrozenSleep(from frozen: HRVSession, to stored: inout HRVSession) {
        stored.sleepSnapshot = frozen.sleepSnapshot
        stored.sleepStartMs = frozen.sleepStartMs
        stored.sleepEndMs = frozen.sleepEndMs
        stored.sleepSegments = frozen.sleepSegments
    }

    /// Acceptance scored the night in the analysis window chosen inside the
    /// morning's sleep window. When it froze a sleep that moved that window,
    /// the night is analysed again inside the new one, as the automatic
    /// sleep refresh does (`.flowRecoveryRescoreNeeded`, which keeps a window
    /// the user picked and scores it instead).
    static func requestRewindowIfSleepMoved(from before: HRVSession, to after: HRVSession) {
        guard before.id == after.id, ReanalysisService.sleepWindowMoved(from: before, to: after) else { return }
        NotificationCenter.default.post(
            name: .flowRecoveryRescoreNeeded, object: after.id,
            userInfo: ["reason": "sleep", "detail": "the sleep frozen with the score moved the sleep window"]
        )
    }

    /// The night acceptance freezes. A fetch that timed out, failed or found
    /// no sleep (Health holding only "in bed" samples resolves to an empty
    /// night) keeps the morning pass's snapshot, which was resolved from the
    /// same recording. Replacing it with nothing made the dashboard fall back
    /// to an older night's sleep and vitals.
    nonisolated static func sleepToFreeze(fetched: SleepData?, morning: SleepData?) -> SleepData? {
        guard let fetched, freezes(fetched, over: morning) else { return morning }
        return fetched
    }

    /// Whether `fetched` replaces the morning pass's snapshot.
    nonisolated static func freezes(_ fetched: SleepData, over morning: SleepData?) -> Bool {
        fetched.nightSleepMinutes > 0 || morning == nil
    }

    /// The composite breakdown for this session. `training` is passed along
    /// for the signature's sake; the composite itself does not use it.
    private func scoreBreakdown(
        result: HRVAnalysisResult,
        session: HRVSession,
        inputs: AcceptanceInputs,
        training: TrainingContext?,
        useBaselineHRV: Bool
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: inputs.baselineStats, sleepData: session.sleepSnapshot,
                vitals: session.vitalsSnapshot, typicalSleepHours: inputs.typicalSleepHours
            ),
            trainingContext: training,
            config: inputs.scoringConfig,
            useBaselineHRV: useBaselineHRV,
            perceivedReadiness: session.perceivedReadiness,
            ansBalance: ReanalysisService.ansBalance(of: result),
            // Anchored to the night, as `ReanalysisService` does, so the
            // staleness term reads the same whenever the score is computed.
            referenceDate: session.endDate ?? session.startDate
        )
    }

    /// Stamp the resolved training context onto the session so every read path
    /// (dashboard, history, AI context) sees the exact ATL/CTL/TSB/ACWR that
    /// was current when the score froze. Without this, later code reading
    /// `analysisResult.trainingContext` would still see nil.
    ///
    /// Training readiness freezes alongside the score — same EWMA step logic
    /// as `ReanalysisService.computeFrozenReadiness`.
    private func applyFrozenScore(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown,
        to session: inout HRVSession,
        training: TrainingContext?
    ) {
        let score = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        // Scores are PHI and debugLog is user-exportable: log the update, not the values.
        debugLog("[SessionAcceptanceService] Updating recovery score (\(session.recoveryScore == nil ? "first score" : "replacing a score"), tier=\(breakdown.tier), trainingContext=\(training == nil ? "nil" : "present"))")
        session.recoveryScore = score
        session.scoreBreakdown = breakdown
        session.analysisResult?.trainingContext = training
        if session.trainingSnapshot == nil {
            session.trainingSnapshot = training
        }
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: breakdown.compositeScore,
            trainingContext: training
        )
        debugLog("[SessionAcceptanceService] Frozen readiness \(session.frozenReadiness == nil ? "not set" : "set")")
    }

    /// Export to Apple Health if enabled (fire-and-forget, non-blocking).
    /// Deliberately untracked — the session is already
    /// persisted to the local archive at this point; these post-save
    /// mirrorings should finish even if the user dismisses the post-summary
    /// view. Cancellation here would lose the HealthKit row, which is the
    /// OPPOSITE of what the user wants. A failed export is kept and tried
    /// again on the next return to the app (`PendingNightExports`).
    private func exportToHealthIfEnabled(_ session: HRVSession, enabled: Bool) {
        guard enabled else { return }
        let exportSession = session
        let hk = healthKit
        Task {
            do {
                try await hk.exportSessionMetrics(from: exportSession)
                PendingNightExports.record(exportSession.id, exported: true)
            } catch {
                debugLog("[SessionAcceptanceService] HealthKit export failed, kept for a retry: \(error.localizedDescription)")
                PendingNightExports.record(exportSession.id, exported: false)
            }
        }
    }

    /// Sync to iCloud (fire-and-forget) and clean up the live backup. Same
    /// intentional-untracked rationale as the HealthKit export above.
    /// Upload the archived night, then clear the iCloud live backup of the
    /// recording, which is keyed by the recording's own id.
    private func syncToCloud(_ session: HRVSession, liveBackupOf recordingId: UUID) {
        let cloudSync = onCloudSync
        let cloudDelete = onCloudDelete
        Task {
            await cloudSync(session)
            await cloudDelete(recordingId)
        }
    }

    // MARK: - Update Composite Recovery Score

    /// Recompute and re-archive the composite recovery score for an already-archived session.
    /// Also snapshots sleep and vitals data so the dashboard stays stable.
    ///
    /// Called when dismissing results for already-archived sessions (e.g., streaming/quick).
    ///
    /// - Parameter exportMetrics: When `true`, exports the final metrics to Apple Health
    ///   (if the user has HealthKit export enabled).
    /// - Returns: `true` if the archive was successfully updated.
    @discardableResult
    func updateCompositeRecoveryScore(
        for session: HRVSession,
        scoringConfig: RecoveryScoreCalculator.ScoringConfiguration,
        trainingContext: TrainingContext?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        typicalSleepHours: Double,
        sleepSchedule: SleepSchedule,
        exportMetrics: Bool = false,
        enableHealthKitExport: Bool = false
    ) async -> Bool {
        guard let result = session.analysisResult else { return false }
        let inputs = AcceptanceInputs(
            scoringConfig: scoringConfig, trainingContext: trainingContext,
            baselineStats: baselineStats, typicalSleepHours: typicalSleepHours,
            sleepSchedule: sleepSchedule
        )
        let updated = await rescoredWithRefreshedHealth(session, result: result, inputs: inputs)
        guard let stored = reArchive(updated, scoredFrom: session) else { return false }
        Self.requestRewindowIfSleepMoved(from: session, to: stored)
        exportToHealthIfEnabled(stored, enabled: exportMetrics && enableHealthKitExport)
        return true
    }

    /// `session` with its sleep and vitals fetched again, classified against
    /// the refreshed sleep when it moved, and scored from them.
    private func rescoredWithRefreshedHealth(
        _ session: HRVSession, result: HRVAnalysisResult, inputs: AcceptanceInputs
    ) async -> HRVSession {
        var updated = session
        await refreshHealthSnapshots(on: &updated, result: result, sleepSchedule: inputs.sleepSchedule)
        let useBaselineHRV = Self.refreshedUseBaselineHRV(
            on: &updated, result: result, baselineStats: inputs.baselineStats, sleepBefore: session.sleepSnapshot
        )
        updated.applySleepHeartRateToVitals()
        let breakdown = scoreBreakdown(
            result: result, session: updated, inputs: inputs,
            training: inputs.trainingContext, useBaselineHRV: useBaselineHRV
        )
        debugLog("[SessionAcceptanceService] Updating archived recovery score for \(session.id.uuidString.prefix(8))")
        applyFrozenScore(breakdown, to: &updated, training: inputs.trainingContext)
        return updated
    }

    /// An untrustworthy reading (`.insufficient` / `.preSleep`) scores from
    /// the baseline, on every path. A session never classified (nil reads as
    /// reliable), or one whose sleep the refresh moved, is classified now
    /// against the refreshed sleep, as at acceptance: whether the recording
    /// overlaps sleep is decided from the sleep's start and end, so a quality
    /// decided on the earlier sleep no longer describes this one. A quality
    /// decided on the same sleep stands.
    static func refreshedUseBaselineHRV(
        on session: inout HRVSession,
        result: HRVAnalysisResult,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        sleepBefore: SleepData?
    ) -> Bool {
        let sleepMoved = !sameSleepSpan(session.sleepSnapshot, sleepBefore)
        guard session.hrvDataQuality == nil || sleepMoved else { return !session.isReliableForHRVAggregates }
        return applyHRVQuality(to: &session, result: result, baselineStats: baselineStats)
    }

    /// Whether two sleeps start and end at the same times: the part of a
    /// sleep the quality classifier reads.
    nonisolated static func sameSleepSpan(_ lhs: SleepData?, _ rhs: SleepData?) -> Bool {
        lhs?.sleepStart == rhs?.sleepStart && lhs?.sleepEnd == rhs?.sleepEnd
    }

    /// Write the update onto the archived copy, in place (`SessionArchive.update`),
    /// with a re-upload request (stamps `modifiedAt`), so a session iCloud
    /// already holds is pushed again and other devices get the new score,
    /// quality and snapshots. Returns the session as stored, or nil when
    /// nothing was written: the archive does not hold it (deleted or purged
    /// while the score was computed; it is never created here) or the write
    /// failed.
    ///
    /// The score was computed over the HealthKit fetch, which can take up to
    /// ten seconds, from `read`. Writing the whole of `updated` back would
    /// put every other field back as `read` held it, undoing a sleep edit, a
    /// window pick or a rescore saved meanwhile, and the re-upload would push
    /// that older copy to iCloud as the newest. So only what this update sets
    /// is written (`applyUpdate`).
    private func reArchive(_ updated: HRVSession, scoredFrom read: HRVSession) -> HRVSession? {
        var stored: HRVSession?
        do {
            try archive.update(updated.id, requestingReupload: true) { archived in
                Self.applyUpdate(updated, scoredFrom: read, to: &archived)
                stored = archived
            }
        } catch {
            debugLog("[SessionAcceptanceService] Failed to re-archive with updated score: \(error)")
            return nil
        }
        return stored
    }

    /// What `updateCompositeRecoveryScore` sets on the archived copy.
    ///
    /// The tags and notes the caller carried (the auto-accept's pre-night
    /// choice) are always kept: tags it added join the stored ones, and its
    /// notes join the stored notes (`SessionMerger.mergedNotes`), so notes
    /// already on the night (one it was folded into) are not replaced. The score, its breakdown, the
    /// frozen readiness, the training context, the quality class and the
    /// sleep and vitals snapshots are set only while the inputs they were
    /// computed from are still the archive's (`RescoreWrite.inputsMatch`). An
    /// edit that changed them meanwhile scored the night itself, and that
    /// newer score stays.
    nonisolated static func applyUpdate(_ updated: HRVSession, scoredFrom read: HRVSession, to archived: inout HRVSession) {
        let added = updated.tags.filter { !archived.tags.contains($0) }
        archived.tags += added
        archived.notes = SessionMerger.mergedNotes(archived.notes, updated.notes)
        guard RescoreWrite.inputsMatch(archived, read, kind: .scoreOnly(healedTraining: false)) else {
            debugLog("[SessionAcceptanceService] The night changed while its score was computed — keeping the stored score")
            return
        }
        archived.recoveryScore = updated.recoveryScore
        archived.scoreBreakdown = updated.scoreBreakdown
        archived.frozenReadiness = updated.frozenReadiness
        archived.analysisResult?.trainingContext = updated.analysisResult?.trainingContext
        if archived.trainingSnapshot == nil { archived.trainingSnapshot = updated.trainingSnapshot }
        archived.hrvDataQuality = updated.hrvDataQuality
        applyFrozenSleep(from: updated, to: &archived)
        archived.vitalsSnapshot = updated.vitalsSnapshot
    }

    /// Fetch and snapshot sleep + vitals for an already-archived session,
    /// raced against the same 10-second timeout as acceptance
    /// (`fetchSleepAndVitals`). A fetch that fails or times out keeps the
    /// snapshot frozen before — HealthKit refuses reads while the phone is
    /// locked — instead of re-scoring the night without its sleep.
    ///
    /// Sleep HR: see `snapshotHealthData`; `updateCompositeRecoveryScore`
    /// applies it once the quality is known.
    private func refreshHealthSnapshots(
        on session: inout HRVSession, result: HRVAnalysisResult, sleepSchedule: SleepSchedule
    ) async {
        let sessionEnd = session.endDate ?? session.startDate
        let (fetchStart, fetchEnd) = sleepFetchRange(for: session, sessionEnd: sessionEnd, sleepSchedule: sleepSchedule)
        let (sleepData, vitals) = await fetchSleepAndVitals(
            rrPoints: session.rrSeries?.points, fetchStart: fetchStart, fetchEnd: fetchEnd,
            sessionStart: session.startDate, sessionEnd: sessionEnd
        )
        Self.freezeFetchedSleep(sleepData, on: &session)
        if let vitals { session.vitalsSnapshot = vitals }
    }

    // MARK: - Reject Session

    /// Rejects the current session: clears the persisted recording state and
    /// deletes the iCloud live backup; the strap keeps its own copy until the
    /// next recording clears it. The
    /// archived copy of a night saved before review is removed by the
    /// collector (`discardReviewArchivedSession`), which moves it to Trash,
    /// syncs the deletion and rebuilds the baseline without it.
    ///
    /// - Parameters:
    ///   - sessionId: The ID of the session to reject (for CloudKit cleanup).
    ///   - clearPersistedRecordingState: Callback to clear RRCollector's persisted state.
    func processRejection(
        sessionId: UUID?,
        clearPersistedRecordingState: () -> Void
    ) async {
        // Clear persisted recording state - user explicitly rejected
        clearPersistedRecordingState()

        // Clean up live backup from iCloud
        if let sessionId {
            let cloudDelete = onCloudDelete
            Task { await cloudDelete(sessionId) }
        }
    }

    // MARK: - Sleep Fetch Range Helper

    /// The sleep fetch range: the whole night the session started in, from
    /// the schedule's overnight-window start to that night's morning cutoff,
    /// whatever the session type or length. A split night (linked segments,
    /// or sleep the watch alone tracked after the strap stopped) and a
    /// single-segment night all fall inside it, so the frozen sleepSnapshot
    /// captures the FULL night's sleep, not just the recording window. The
    /// session end is not read: the range is the night, not the recording.
    func sleepFetchRange(
        for session: HRVSession,
        sessionEnd _: Date,
        sleepSchedule: SleepSchedule
    ) -> (start: Date, end: Date) {
        // Sleep is about the recovery window, not the recording session.
        // Always use the full overnight window so any session type
        // (overnight, quick reading, streaming) captures last night's sleep.
        let referenceDate = session.startDate
        let start = sleepSchedule.overnightWindowStart(relativeTo: referenceDate)
        // The cutoff for the night that `start` opens, not one taken from the
        // session's own day: for a session started after midnight that was the
        // next night's, and two nights of sleep went into one snapshot.
        let end = sleepSchedule.morningCutoff(forNightStartingAt: start)

        return (start, end)
    }
}
