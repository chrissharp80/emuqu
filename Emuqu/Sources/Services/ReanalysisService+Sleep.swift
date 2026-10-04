import Foundation

// Sleep retro-apply and manual-window reanalysis, split out of
// `ReanalysisService.swift`. Both re-score an existing session from
// a user action rather than from new sensor data, which is what the bulk
// re-analysis left behind does.

extension ReanalysisService {
    // MARK: - Sleep Retro-Apply

    /// Reprocess sleep data for every overnight session using current
    /// settings. Workouts, naps, quick readings and breathing sessions have no
    /// night's sleep to attach.
    func retroApplySleepSettings(
        sessions: [HRVSession],
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        let filtered = Self.sessionsInRange(sessions, from: nil, to: nil).filter { $0.sessionType == .overnight }
        let settings = settingsProvider()
        var successCount = 0

        for (index, session) in filtered.enumerated() {
            if Task.isCancelled { break }
            if await retroApply(to: session, settings: settings) { successCount += 1 }
            progress(index + 1, filtered.count)
        }

        await MainActor.run { onArchiveChanged() }
        debugLog("[ReanalysisService] Sleep retro-apply complete: \(successCount)/\(filtered.count) sessions updated\(Task.isCancelled ? " (cancelled)" : "")")
        return successCount
    }

    /// Re-run the sleep pipeline for one session and persist the result.
    /// Returns whether the session was actually rewritten.
    ///
    /// Split by the four things it does:
    /// fetch, decide, re-score, persist.
    private func retroApply(to session: HRVSession, settings: UserSettings) async -> Bool {
        let sessionEnd = session.endDate ?? session.startDate.addingTimeInterval(Self.assumedSessionLength)
        guard let newSleep = await fetchSleep(for: session, sessionEnd: sessionEnd) else { return false }
        guard Self.shouldRetroApply(to: session, newSleep: newSleep, sessionEnd: sessionEnd) else { return false }

        var updated = session
        Self.applySleepBoundaries(newSleep, to: &updated, sessionStart: session.startDate)
        rescore(&updated, newSleep: newSleep, sessionEnd: sessionEnd, settings: settings)
        return persist(updated, originalID: session.id)
    }

    /// A session with no end date is treated as a twelve-hour window — long
    /// enough to contain any overnight recording.
    private static let assumedSessionLength: TimeInterval = 12 * 60 * 60

    /// Re-run the full sleep pipeline with current settings. The augmentation
    /// flag is read inside. Nil on a fetch failure, which is logged and skipped
    /// rather than aborting the whole sweep.
    private func fetchSleep(for session: HRVSession, sessionEnd: Date) async -> SleepData? {
        do {
            return try await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: sessionEnd,
                rrPoints: session.rrSeries?.points
            )
        } catch {
            debugLog("[ReanalysisService] Sleep retro-apply: fetch failed for \(session.id.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Skip sessions with nothing new to write, sessions the user has
    /// hand-corrected — a manual override outranks a settings change — and a
    /// sleep block that doesn't overlap the recording (the same plausibility
    /// gate as `updateSessionSleepBoundaries`).
    private static func shouldRetroApply(to session: HRVSession, newSleep: SleepData, sessionEnd: Date) -> Bool {
        guard newSleep.nightSleepMinutes > 0 || !newSleep.stageIntervals.isEmpty else { return false }
        guard session.sleepUserAdjusted != true else {
            debugLog("[ReanalysisService] Sleep retro-apply: skipping user-adjusted session \(session.id.uuidString.prefix(8))")
            return false
        }
        guard newSleep.plausiblyBelongsToRecording(start: session.startDate, end: sessionEnd) else {
            debugLog("[ReanalysisService] Sleep retro-apply: sleep block does not overlap session \(session.id.uuidString.prefix(8))")
            return false
        }
        return true
    }

    /// Write the new boundaries and segments onto the session.
    private static func applySleepBoundaries(
        _ newSleep: SleepData,
        to updated: inout HRVSession,
        sessionStart: Date
    ) {
        updated.sleepSnapshot = newSleep
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: newSleep.sleepStart.map { Int64($0.timeIntervalSince(sessionStart) * 1000) },
            sleepEndMs: newSleep.sleepEnd.map { Int64($0.timeIntervalSince(sessionStart) * 1000) },
            recordingDurationMs: recordingDurationMs(of: updated)
        )
        if let start = clamped.sleepStartMs { updated.sleepStartMs = start }
        if let end = clamped.sleepEndMs { updated.sleepEndMs = end }
        applySegments(newSleep, to: &updated, sessionStart: sessionStart)
    }

    /// Split nights get a fresh segment array. A single-segment night clears
    /// any stale multi-segment array so it cannot disagree with the snapshot.
    private static func applySegments(
        _ newSleep: SleepData,
        to updated: inout HRVSession,
        sessionStart: Date
    ) {
        guard newSleep.segments.count > 1 else {
            updated.sleepSegments = nil
            return
        }
        updated.sleepSegments = newSleep.segments.map { segment in
            HRVSession.SleepSegmentMs(
                startMs: MillisecondOffset.between(segment.sleepStart, and: sessionStart, fallback: 0),
                endMs: MillisecondOffset.between(segment.sleepEnd, and: sessionStart, fallback: 0)
            )
        }
    }

    /// Both reanalysis write paths clamp START and END offsets through
    /// `SleepBoundaryResolver.clamp`, the same as the three live-recording
    /// write paths. Apple Watch sleep ending after the strap
    /// stopped is the ordinary case if the user takes the strap off before
    /// getting up, so an unclamped end is reachable. `WindowSelection`
    /// re-derives both offsets defensively so no score depends on it, but the
    /// display consumers read the stored value. Offsets count from the series
    /// start, so the recording runs to the last beat's end, as on the morning
    /// path — not the first-to-last span, which is short when the first beat
    /// is not at 0.
    private static func recordingDurationMs(of session: HRVSession) -> Int64 {
        guard let last = session.rrSeries?.points.last else {
            let seconds = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
            return Int64(max(0, seconds) * 1000)
        }
        return last.endMs
    }

    /// Recompute the frozen recovery score against the updated sleep.
    private func rescore(
        _ updated: inout HRVSession,
        newSleep: SleepData,
        sessionEnd: Date,
        settings: UserSettings
    ) {
        guard let result = updated.analysisResult else { return }
        let trainingContext = updated.trainingSnapshot ?? result.trainingContext ?? trainingContextProvider(sessionEnd)
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            scoreInputs(from: result, session: updated, newSleep: newSleep, settings: settings),
            trainingContext: trainingContext,
            config: scoringConfigProvider(),
            // See deriveUseBaselineHRVOnRescore.
            useBaselineHRV: !updated.isReliableForHRVAggregates,
            perceivedReadiness: updated.perceivedReadiness,
            ansBalance: Self.ansBalance(from: result),
            referenceDate: sessionEnd
        )
        updated.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        updated.scoreBreakdown = breakdown
        updated.frozenReadiness = Self.computeFrozenReadiness(
            compositeScore: breakdown.compositeScore,
            trainingContext: trainingContext
        )
    }

    /// The physiological readings one re-score works from — the analysis
    /// result's own metrics, the user's baseline, and the freshly fetched sleep.
    private func scoreInputs(
        from result: HRVAnalysisResult,
        session: HRVSession,
        newSleep: SleepData,
        settings: UserSettings
    ) -> RecoveryScoreCalculator.ScoreInputs {
        RecoveryScoreCalculator.ScoreInputs(
            hrvReadiness: result.ansMetrics?.readinessScore,
            rmssd: result.timeDomain.rmssd,
            meanHR: result.timeDomain.meanHR,
            dfaAlpha1: result.nonlinear.dfaAlpha1,
            baselineStats: scoringBaseline(for: session),
            sleepData: newSleep,
            vitals: Self.scoringVitals(of: session, result: result),
            typicalSleepHours: settings.typicalSleepHours
        )
    }

    /// Preserve the acceptance path's ANS-balance term on a sleep-edit re-score.
    private static func ansBalance(from result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    /// Persist and sync. Nothing here writes to Apple Health; sleep reaches
    /// it only through `HealthKitManager.exportSessionMetrics`, when
    /// `exportSleepData` is on and Emuqu is the night's only sleep source.
    private func persist(_ updated: HRVSession, originalID: UUID) -> Bool {
        do {
            try archive.archive(updated)
            Task { self.onSessionUploaded(updated) }
            return true
        } catch {
            debugLog("[ReanalysisService] Sleep retro-apply: save failed for \(originalID.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    // MARK: - Manual Window Reanalysis

    /// Reanalyze a session at a specific timestamp (for manual window selection).
    func reanalyzeAtPosition(_ inputSession: HRVSession, targetMs: Int64) async -> HRVAnalysisResult? {
        let session = hydrated(inputSession)
        let sessionDate = session.endDate ?? session.startDate
        let trainingContext = session.trainingSnapshot ?? session.analysisResult?.trainingContext ?? trainingContextProvider(sessionDate)
        return await analysisPipeline.reanalyzeAtPosition(
            session: session,
            targetMs: targetMs,
            trainingContext: trainingContext,
            ansConfig: ansConfigProvider(session)
        )
    }

    func applyManualAnalysis(_ inputSession: HRVSession, result: HRVAnalysisResult) async -> HRVSession? {
        // Hydrate before any archive write — otherwise a lightweight
        // input session would be re-encoded with `rrSeries: nil`,
        // erasing the raw beats from disk.
        let session = hydrated(inputSession)
        var appliedResult = result
        appliedResult.isReanalysis = true
        // Preserve the frozen training context from the original session.
        let frozenTraining = session.trainingSnapshot ?? session.analysisResult?.trainingContext
        if let frozen = frozenTraining {
            appliedResult.trainingContext = frozen
        }
        var updatedSession = session
        preserveAutoWindow(of: session, on: &updatedSession)
        updatedSession.analysisResult = appliedResult
        updatedSession.windowUserAdjusted = true
        applyDeterministicScore(to: &updatedSession, result: appliedResult, training: frozenTraining)
        return await persistManualAnalysis(updatedSession, originalId: session.id)
    }

    /// Keep frozen snapshots so manual reanalysis remains deterministic and local.
    private func applyDeterministicScore(
        to session: inout HRVSession, result: HRVAnalysisResult, training: TrainingContext?
    ) {
        guard let scored = deterministicRecoveryScore(for: session, result: result) else { return }
        session.recoveryScore = scored.score
        session.scoreBreakdown = scored.breakdown
        session.frozenReadiness = Self.computeFrozenReadiness(
            compositeScore: scored.breakdown.compositeScore, trainingContext: training
        )
    }

    /// Preserve the AUTO-selected result + score BEFORE the
    /// manual pick overwrites them, so the UI can show a persistent
    /// "you chose X (score N) vs auto picked Y (score M)" comparison.
    /// Guarded on `windowUserAdjusted` so a SECOND manual pick doesn't clobber
    /// the true auto baseline with a prior manual pick.
    private func preserveAutoWindow(of session: HRVSession, on updatedSession: inout HRVSession) {
        guard session.windowUserAdjusted != true else { return }
        updatedSession.autoWindowResult = session.analysisResult
        updatedSession.autoWindowScore = session.recoveryScore
    }

    private func persistManualAnalysis(_ updatedSession: HRVSession, originalId: UUID) async -> HRVSession? {
        do {
            try archive.archive(updatedSession, skipSameNightMerge: false, requestingReupload: true)
            baselineTracker.update(with: updatedSession, sleepSchedule: settingsProvider().sleepSchedule)
            await MainActor.run { onArchiveChanged() }
            let sessionToUpload = updatedSession
            Task { self.onSessionUploaded(sessionToUpload) }
            debugLog("[ReanalysisService] Applied manual analysis to session \(originalId)")
            return updatedSession
        } catch {
            debugLog("[ReanalysisService] Failed to save manual analysis: \(error)")
            return nil
        }
    }

    /// Returns `true` only when the updated session was actually
    /// persisted. Returning `Void` would let a user's manual timeline edit
    /// die in the catch below while the editor UI confirms
    /// success. User-adjustment call sites must check the result and
    /// surface failure; automatic callers may ignore it (discardable).
    @discardableResult
    func updateSessionSleepBoundaries(sessionId: UUID, sleepData: SleepData, isUserAdjustment: Bool = false) -> Bool {
        guard let sleepStart = sleepData.sleepStart, let sleepEnd = sleepData.sleepEnd else {
            debugLog("[UpdateSleepBounds] Bailed: sleepStart or sleepEnd is nil")
            return false
        }
        do {
            guard var session = try archive.retrieve(sessionId) else {
                debugLog("[UpdateSleepBounds] Bailed: session \(sessionId.uuidString.prefix(8)) not in archive")
                return false
            }
            return try applySleepBoundaries(
                to: &session, sleepData: sleepData, sleepStart: sleepStart,
                sleepEnd: sleepEnd, isUserAdjustment: isUserAdjustment
            )
        } catch {
            debugLog("[ReanalysisService] Failed to update sleep boundaries for \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return false
        }
    }

    /// Compute the new offsets, decide whether they apply, write them, rescore
    /// and persist. False means the update was rejected by a gate.
    private func applySleepBoundaries(
        to session: inout HRVSession,
        sleepData: SleepData,
        sleepStart: Date,
        sleepEnd: Date,
        isUserAdjustment: Bool
    ) throws -> Bool {
        let newStartMs = max(0, MillisecondOffset.between(sleepStart, and: session.startDate, fallback: 0))
        let newEndMs = MillisecondOffset.between(sleepEnd, and: session.startDate, fallback: 0)
        logBoundaryUpdate(
            session: session, sleepStart: sleepStart, sleepEnd: sleepEnd, newStartMs: newStartMs,
            newEndMs: newEndMs, sleepData: sleepData, isUserAdjustment: isUserAdjustment
        )
        guard isUserAdjustment || shouldApplyAutomaticUpdate(to: session, sleepData: sleepData, newDuration: newEndMs - newStartMs) else {
            return false
        }
        let oldMinutes = session.sleepSnapshot?.nightSleepMinutes ?? 0
        applyBoundaries(
            to: &session, sleepData: sleepData, newStartMs: newStartMs,
            newEndMs: newEndMs, isUserAdjustment: isUserAdjustment
        )
        rescoreAfterSleepChange(&session, sleepData: sleepData)
        try persistSleepUpdate(session, sleepData: sleepData, oldMinutes: oldMinutes, isUserAdjustment: isUserAdjustment)
        return true
    }

    private func persistSleepUpdate(
        _ session: HRVSession, sleepData: SleepData, oldMinutes: Int, isUserAdjustment: Bool
    ) throws {
        try archive.archive(session, skipSameNightMerge: false, requestingReupload: isUserAdjustment)
        debugLog("[ReanalysisService] Updated sleep data for session \(session.id.uuidString.prefix(8)): \(oldMinutes)min → \(sleepData.nightSleepMinutes)min\(isUserAdjustment ? " (user adjustment)" : "")")
        Task { @MainActor in self.onArchiveChanged() }
        let sessionToUpload = session
        Task { self.onSessionUploaded(sessionToUpload) }
    }

    private func logBoundaryUpdate(
        session: HRVSession,
        sleepStart: Date,
        sleepEnd: Date,
        newStartMs: Int64,
        newEndMs: Int64,
        sleepData: SleepData,
        isUserAdjustment: Bool
    ) {
        debugLog("[UpdateSleepBounds] session.startDate=\(session.startDate) sleepStart=\(sleepStart) sleepEnd=\(sleepEnd)")
        debugLog("[UpdateSleepBounds] newStartMs=\(newStartMs) newEndMs=\(newEndMs) oldStartMs=\(session.sleepStartMs ?? -1) oldEndMs=\(session.sleepEndMs ?? -1)")
        debugLog("[UpdateSleepBounds] newData: totalMin=\(sleepData.totalSleepIncludingNapMinutes) nightMin=\(sleepData.nightSleepMinutes) segments=\(sleepData.segments.count) isUserAdj=\(isUserAdjustment)")
    }

    /// User adjustments (exclude/boundary changes) always apply. Automatic
    /// HealthKit updates only apply if they bring more data.
    ///
    /// Never let an automatic update overwrite a user-adjusted
    /// timeline, regardless of "more data" (FLOWCHART §13.2: user edits are
    /// the source of truth). The callers' own guards can read a stale
    /// `session` captured at view presentation; this is the last gate before
    /// the archived copy is rewritten, so it checks the freshly-retrieved
    /// session. Snapshot-nil sessions are exempt: CloudKit uploads strip
    /// HK-derived snapshots (5.1.3), so a user-adjusted session pulled onto a
    /// second device needs its first local fill.
    ///
    /// An automatic sleep block that doesn't physically overlap
    /// the recording is rejected (see `SleepData.plausiblyBelongsToRecording`).
    private func shouldApplyAutomaticUpdate(
        to session: HRVSession, sleepData: SleepData, newDuration: Int64
    ) -> Bool {
        guard session.sleepUserAdjusted != true || session.sleepSnapshot == nil else {
            debugLog("[UpdateSleepBounds] Bailed: session has user-adjusted sleep; auto update discarded")
            return false
        }
        let recordingEnd = session.endDate ?? session.startDate
        guard sleepData.plausiblyBelongsToRecording(start: session.startDate, end: recordingEnd) else {
            debugLog("[UpdateSleepBounds] Bailed: \(sleepData.nightSleepMinutes)m sleep window does not overlap the \(Int(recordingEnd.timeIntervalSince(session.startDate) / 60))m recording — implausible auto attach")
            return false
        }
        let storedDuration = (session.sleepEndMs ?? 0) - (session.sleepStartMs ?? 0)
        let snapshotMinutes = session.sleepSnapshot?.nightSleepMinutes ?? 0
        return newDuration > storedDuration || sleepData.nightSleepMinutes > snapshotMinutes
    }

    /// Store the boundaries clamped to the strap recording, as the live
    /// write paths do; an offset the clamp rejects is stored as given.
    private static func storeClampedOffsets(startMs: Int64, endMs: Int64, on session: inout HRVSession) {
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: startMs, sleepEndMs: endMs, recordingDurationMs: recordingDurationMs(of: session)
        )
        session.sleepStartMs = clamped.sleepStartMs ?? startMs
        session.sleepEndMs = clamped.sleepEndMs ?? endMs
    }

    /// Write the new boundaries, segments and frozen snapshot onto the session.
    private func applyBoundaries(
        to session: inout HRVSession,
        sleepData: SleepData,
        newStartMs: Int64,
        newEndMs: Int64,
        isUserAdjustment: Bool
    ) {
        Self.storeClampedOffsets(startMs: newStartMs, endMs: newEndMs, on: &session)
        if sleepData.segments.count > 1 {
            let start = session.startDate
            session.sleepSegments = sleepData.segments.map { seg in
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
        session.sleepSnapshot = sleepData
        if isUserAdjustment {
            session.sleepUserAdjusted = true
        }
    }

    /// Recalculate the recovery score when sleep data changes so the score
    /// reflects excluded/adjusted segments. The ANS-balance term is preserved
    /// from the acceptance path so a sleep edit doesn't drift the score for an
    /// unrelated reason.
    private static func ansBalance(of result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    private func rescoreAfterSleepChange(
        _ session: inout HRVSession, sleepData: SleepData
    ) {
        guard let result = session.analysisResult else { return }
        let sessionEnd = session.endDate ?? session.startDate
        let trainingContext = session.trainingSnapshot ?? result.trainingContext
            ?? trainingContextProvider(sessionEnd)
        let breakdown = sleepAdjustedBreakdown(
            session: session, result: result, sleepData: sleepData,
            trainingContext: trainingContext, sessionEnd: sessionEnd
        )
        session.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        session.scoreBreakdown = breakdown
        session.frozenReadiness = Self.computeFrozenReadiness(compositeScore: breakdown.compositeScore, trainingContext: trainingContext)
        debugLog("[ReanalysisService] Recalculated recovery score after sleep adjustment: \(String(format: "%.1f", session.recoveryScore ?? 0))")
    }

    /// The composite recomputed against the edited sleep, everything else frozen.
    private func sleepAdjustedBreakdown(
        session: HRVSession,
        result: HRVAnalysisResult,
        sleepData: SleepData,
        trainingContext: TrainingContext?,
        sessionEnd: Date
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: scoringBaseline(for: session), sleepData: sleepData,
                vitals: Self.scoringVitals(of: session, result: result), typicalSleepHours: settingsProvider().typicalSleepHours
            ),
            trainingContext: trainingContext,
            config: scoringConfigProvider(),
            // See deriveUseBaselineHRVOnRescore.
            useBaselineHRV: !session.isReliableForHRVAggregates,
            perceivedReadiness: session.perceivedReadiness,
            ansBalance: Self.ansBalance(of: result),
            referenceDate: sessionEnd
        )
    }

    /// Diagnostic result from training snapshot repair.
    struct TrainingRepairResult {
        let totalSessions: Int
        let candidates: Int
        var nilContext: Int
        var repaired: Int
        var errors: Int
        var sampleLog: String = ""
    }

    /// Recompute training snapshots for all completed sessions from HealthKit.
    /// Anchors each session to 5 AM on the morning it ended so the EWMA
    /// matches the original morning capture (through yesterday's training).
    func repairTrainingSnapshots(
        sessions: [HRVSession],
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> TrainingRepairResult {
        let candidates = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        Self.logRepairPreamble(sessions: sessions, candidates: candidates)

        var result = TrainingRepairResult(
            totalSessions: sessions.count, candidates: candidates.count,
            nilContext: 0, repaired: 0, errors: 0
        )

        for (index, session) in candidates.enumerated() {
            if Task.isCancelled { break }
            progress(index, candidates.count)
            await repairSnapshot(for: session, into: &result)
        }

        progress(candidates.count, candidates.count)
        Task { @MainActor in self.onArchiveChanged() }
        debugLog("[ReanalysisService] Training repair complete: \(result.repaired)/\(candidates.count) updated, \(result.nilContext) nil context, \(result.errors) errors")
        return result
    }

    /// Session-state breakdown, logged once up front. The "complete but no
    /// analysisResult" count is the diagnostic that explains a small candidate
    /// set.
    private static func logRepairPreamble(sessions: [HRVSession], candidates: [HRVSession]) {
        debugLog("[ReanalysisService] Training repair: \(candidates.count) candidates from \(sessions.count) sessions")
        let stateCounts = Dictionary(grouping: sessions, by: { $0.state }).mapValues(\.count)
        let stateStr = stateCounts.map { "\($0.key.rawValue): \($0.value)" }.sorted().joined(separator: ", ")
        debugLog("[ReanalysisService] Session states: \(stateStr)")
        let noAnalysis = sessions.filter { $0.state == .complete && $0.analysisResult == nil }.count
        debugLog("[ReanalysisService] Complete but no analysisResult: \(noAnalysis)")
    }

    /// Rebuild one session's training snapshot and persist it, folding the
    /// outcome into `result`.
    ///
    /// Kept as its own function so the repair loop's body stays short.
    private func repairSnapshot(for session: HRVSession, into result: inout TrainingRepairResult) async {
        let referenceDate = Self.morningAnchor(for: session)
        let load = await healthKit.calculateTrainingLoad(relativeTo: referenceDate)

        guard var freshContext = TrainingContext(from: load, relativeTo: referenceDate) else {
            debugLog("[ReanalysisService] Training repair: nil context for \(session.id.uuidString.prefix(8)) — metrics=\(load.metrics != nil)")
            result.nilContext += 1
            return
        }
        applyVO2MaxPreference(to: &freshContext)
        Self.appendSampleLine(for: session, fresh: freshContext, referenceDate: referenceDate, into: &result)

        do {
            try persistSnapshot(freshContext, onto: session)
            result.repaired += 1
        } catch {
            debugLog("[ReanalysisService] Failed to repair training snapshot: \(error)")
            result.errors += 1
        }
    }

    /// 5 AM on the morning the session ended, so the EWMA matches the original
    /// morning capture (through yesterday's training).
    ///
    /// `Calendar.date(byAdding:)` can return nil; fall back to
    /// start-of-day so the training-load calculation still runs against a real
    /// anchor.
    private static func morningAnchor(for session: HRVSession) -> Date {
        let calendar = Calendar.current
        let morningOf = calendar.startOfDay(for: session.endDate ?? session.startDate)
        return calendar.date(byAdding: .hour, value: Self.morningAnchorHour, to: morningOf) ?? morningOf
    }

    private static let morningAnchorHour = 5

    /// A user VO2max override wins; otherwise HealthKit's value is used only
    /// when the user has opted into it.
    private func applyVO2MaxPreference(to context: inout TrainingContext) {
        let settings = settingsProvider()
        if let override = settings.vo2MaxOverride {
            context.vo2Max = override
        } else if !settings.useHealthKitVO2Max {
            context.vo2Max = nil
        }
    }

    /// First few sessions only — a before/after line per session so a bad
    /// repair is diagnosable from the log without re-running it.
    private static func appendSampleLine(
        for session: HRVSession,
        fresh: TrainingContext,
        referenceDate: Date,
        into result: inout TrainingRepairResult
    ) {
        guard result.repaired + result.errors < sampleLogLimit else { return }
        let existing = session.trainingSnapshot ?? session.analysisResult?.trainingContext
        let dateStr = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: referenceDate))
        let line = "\(dateStr): ATL \(String(format: "%.0f", existing?.atl ?? -1))→\(String(format: "%.0f", fresh.atl)) CTL \(String(format: "%.0f", existing?.ctl ?? -1))→\(String(format: "%.0f", fresh.ctl))"
        result.sampleLog += (result.sampleLog.isEmpty ? "" : "\n") + line
    }

    private static let sampleLogLimit = 3

    /// Re-read from the archive so a concurrent edit is not clobbered, write
    /// the fresh context, and recompute frozen readiness against it.
    private func persistSnapshot(_ freshContext: TrainingContext, onto session: HRVSession) throws {
        var updated = try archive.retrieve(session.id) ?? session
        updated.trainingSnapshot = freshContext
        updated.analysisResult?.trainingContext = freshContext
        if let breakdown = updated.scoreBreakdown {
            updated.frozenReadiness = Self.computeFrozenReadiness(
                compositeScore: breakdown.compositeScore,
                trainingContext: freshContext
            )
        }
        try archive.archive(updated)
        let synced = updated
        Task { self.onSessionUploaded(synced) }
    }

    func unlinkSegment(segmentId: UUID, fromSession sessionId: UUID) {
        do {
            guard var session = try archive.retrieve(sessionId) else { return }
            guard var links = session.linkedSessionIds, links.contains(segmentId) else { return }
            // Step 1: Remove the link
            links.removeAll { $0 == segmentId }
            session.linkedSessionIds = links.isEmpty ? nil : links
            // Step 2: Strip the unlinked segment's RR data from the merged series.
            stripSegmentPoints(segmentId: segmentId, from: &session)
            try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            debugLog("[ReanalysisService] Unlinked segment \(segmentId.uuidString.prefix(8)) from session \(sessionId.uuidString.prefix(8)) — \(links.count) segments remaining")
            // Step 3: Reanalyze the session with clean data. This recalculates
            // the HRV analysis, recovery score, and frozen readiness without
            // the contaminating segment.
            reanalyzeAfterUnlink(session)
            let sessionToUpload = session
            Task { self.onSessionUploaded(sessionToUpload) }
        } catch {
            debugLog("[ReanalysisService] Failed to unlink segment: \(error)")
        }
    }

    /// Load the unlinked session to find its time range, then remove the
    /// points that fall within that range from the parent's series.
    ///
    /// The strip window is anchored to the SERIES origin, not the session
    /// origin: `series.points[].t_ms` are re-based to `series.startDate`, and
    /// for a merged split-night series that differs from `session.startDate`.
    /// Using `session.startDate` shifted the window and stripped the wrong
    /// beats. Identical for the common non-merged case where the two origins
    /// coincide.
    private func stripSegmentPoints(segmentId: UUID, from session: inout HRVSession) {
        guard let unlinked = archive.retrieveOrLog(segmentId),
              let series = session.rrSeries, !series.points.isEmpty else { return }
        let segStartMs = MillisecondOffset.between(unlinked.startDate, and: series.startDate, fallback: 0)
        let segDurationMs = Self.segmentDurationMs(of: unlinked)
        guard segDurationMs > 0 else { return }
        let segEndMs = segStartMs + segDurationMs
        let originalCount = series.points.count
        let cleanedPoints = series.points.filter { $0.t_ms < segStartMs || $0.t_ms > segEndMs }
        session.rrSeries = RRSeries(
            points: cleanedPoints, sessionId: series.sessionId, startDate: series.startDate
        )
        debugLog("[ReanalysisService] Stripped \(originalCount - cleanedPoints.count) RR points from unlinked segment time range (\(segStartMs)-\(segEndMs) ms)")
    }

    /// The segment's own span, from its stored duration or, failing that, the
    /// last beat of its series.
    private static func segmentDurationMs(of unlinked: HRVSession) -> Int64 {
        if let dur = unlinked.duration { return Int64(dur * 1000) }
        return unlinked.rrSeries?.points.last?.t_ms ?? 0
    }

    private func reanalyzeAfterUnlink(_ session: HRVSession) {
        Task {
            if let reanalyzed = await self.reanalyzeSession(session) {
                debugLog("[ReanalysisService] Reanalyzed after unlink: score \(String(format: "%.1f", reanalyzed.recoveryScore ?? -1))")
            } else {
                debugLog("[ReanalysisService] Reanalysis after unlink returned nil — session archived with stripped data only")
            }
            await MainActor.run { self.onArchiveChanged() }
        }
    }
}
