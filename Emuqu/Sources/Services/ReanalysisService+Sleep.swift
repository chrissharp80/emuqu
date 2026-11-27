import Foundation

// Sleep retro-apply and manual-window reanalysis. Both re-score an existing
// session from a user action; the bulk re-analysis in
// `ReanalysisService.swift` re-scores from new sensor data.

extension ReanalysisService {
    // MARK: - Sleep Retro-Apply

    /// Reprocess sleep data for every overnight session using current
    /// settings. Workouts, naps, quick readings and breathing sessions have no
    /// night's sleep to attach.
    func retroApplySleepSettings(
        sessions: ArchivedSessions,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        let filtered = sessions.filter { $0.sessionType == .overnight }
        var successCount = 0

        for index in 0 ..< filtered.count {
            if Task.isCancelled { break }
            if let session = await filtered.session(at: index), Self.hasBeats(session), await retroApply(to: session) {
                successCount += 1
            }
            progress(index + 1, filtered.count)
        }

        await MainActor.run { onArchiveChanged() }
        debugLog("[ReanalysisService] Sleep retro-apply complete: \(successCount)/\(filtered.count) sessions updated\(Task.isCancelled ? " (cancelled)" : "")")
        return successCount
    }

    /// Re-run the sleep pipeline for one session and persist the result.
    /// Returns whether the session was actually rewritten.
    ///
    /// Split by the things it does: fetch, decide, then apply, re-score and
    /// persist on the archived copy.
    private func retroApply(to session: HRVSession) async -> Bool {
        let sessionEnd = session.endDate ?? session.startDate.addingTimeInterval(Self.assumedSessionLength)
        guard let newSleep = await fetchSleep(for: session, sessionEnd: sessionEnd) else { return false }
        guard Self.shouldRetroApply(to: session, newSleep: newSleep, sessionEnd: sessionEnd) else { return false }
        await prepareScoringBaseline(for: session)
        // Read before the write: the baseline can read the archive's index,
        // which the update holds locked while its closure runs.
        let inputs = sleepRescoreInputs(for: session, sessionEnd: sessionEnd)
        guard let written = persistRetroApply(newSleep, sessionId: session.id, sessionEnd: sessionEnd, inputs: inputs) else { return false }
        await finishSleepWrite(from: session, to: written)
        return true
    }

    /// Whether a write moved the sleep window: its start, end or segments.
    /// The analysis window is chosen inside it (`analysisBounds`), so a moved
    /// sleep window leaves the stored analysis describing the old one.
    nonisolated static func sleepWindowMoved(from before: HRVSession, to after: HRVSession) -> Bool {
        before.sleepStartMs != after.sleepStartMs || before.sleepEndMs != after.sleepEndMs
            || before.sleepSegments != after.sleepSegments
    }

    /// After a sleep write from `before` to `after`: the analysis window is
    /// chosen again inside the sleep window `after` holds when the write moved
    /// it, as the automatic sleep refresh does for a moved onset (a window
    /// the user picked stays: the write already scored it against the new
    /// sleep), then the session as it now stands is written to Apple Health
    /// when its readings changed. One after the other, so an export of the
    /// copy before the analysis never lands after the newer one.
    func finishSleepWrite(from before: HRVSession, to after: HRVSession) async {
        var final = after
        if Self.sleepWindowMoved(from: before, to: after), after.windowUserAdjusted != true,
           let reanalysed = await reanalyzeSession(after, preserveManualWindows: true) {
            final = reanalysed
        }
        reexportIfReadingsChanged(from: before, to: final)
    }

    /// Writes the session to Apple Health again when a rewrite changed what
    /// its export is written from (`HealthExportReadings`): Health otherwise
    /// keeps the heart rate, HRV, resting heart rate and sleep of the session
    /// as it was. The export replaces the earlier samples by the session's
    /// identity and reads the export switches itself; a night still on the
    /// review card is left to acceptance.
    func reexportIfReadingsChanged(from before: HRVSession, to after: HRVSession) {
        guard HealthExportReadings(of: before) != HealthExportReadings(of: after), !isAwaitingReview(after.id) else { return }
        let (healthKit, previous) = (healthKit, pendingHealthExport)
        pendingHealthExport = Task {
            await previous?.value
            do {
                try await healthKit.exportSessionMetrics(from: after)
            } catch {
                debugLog("[ReanalysisService] Apple Health export of a rewritten session failed: \(error.localizedDescription)")
            }
        }
    }

    /// A session with no end date is treated as a twelve-hour window — long
    /// enough to contain any overnight recording.
    private static let assumedSessionLength: TimeInterval = 12 * 60 * 60

    /// Re-run the full sleep pipeline with current settings. The augmentation
    /// flag is read inside. The day-before's qualifying nap is credited
    /// toward 24 h sleep, as every morning-path fetch does, so a retro-apply
    /// does not drop it. Nil on a fetch failure, which is logged and skipped
    /// rather than aborting the whole sweep.
    private func fetchSleep(for session: HRVSession, sessionEnd: Date) async -> SleepData? {
        do {
            let fetchedSleep = try await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: sessionEnd,
                rrPoints: session.rrSeries?.points
            )
            let napMinutes = await healthKit.fetchDaytimeNapMinutes(nightAnchoredAt: session.startDate)
            return napMinutes > 0 ? fetchedSleep.withNapSleepMinutes(napMinutes) : fetchedSleep
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

    /// Write the new sleep onto the session: the snapshot, and the
    /// boundaries and segments the analysis window is chosen in, clamped to
    /// the recording, so the scoring window never describes another sleep
    /// than the one shown.
    nonisolated static func applySleepBoundaries(
        _ newSleep: SleepData,
        to updated: inout HRVSession,
        sessionStart: Date
    ) {
        updated.sleepSnapshot = newSleep
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: newSleep.sleepStart.flatMap { MillisecondOffset.between($0, and: sessionStart) },
            sleepEndMs: newSleep.sleepEnd.flatMap { MillisecondOffset.between($0, and: sessionStart) },
            recordingDurationMs: recordingDurationMs(of: updated)
        )
        if let start = clamped.sleepStartMs { updated.sleepStartMs = start }
        if let end = clamped.sleepEndMs { updated.sleepEndMs = end }
        applySegments(newSleep, to: &updated, sessionStart: sessionStart)
    }

    /// Split nights get a fresh segment array. A single-segment night clears
    /// any stale multi-segment array so it cannot disagree with the snapshot.
    nonisolated private static func applySegments(
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
    nonisolated static func recordingDurationMs(of session: HRVSession) -> Int64 {
        guard let last = session.rrSeries?.points.last else {
            let seconds = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
            return Int64(max(0, seconds) * 1000)
        }
        return last.endMs
    }

    /// Apply the new sleep, re-classify and re-score on the archived copy,
    /// under the archive lock (`SessionArchive.update`), so an edit made while
    /// the sleep was being fetched (a rating, tags, a sleep edit) is kept, not
    /// overwritten with the copy the sweep loaded; the skip rules run again on
    /// that copy. Then sync. Nothing here writes to Apple Health; sleep
    /// reaches it only through `HealthWriteAndObserve.exportSessionMetrics`, when
    /// `exportSleepData` is on and Emuqu is the night's only sleep source.
    private func persistRetroApply(
        _ newSleep: SleepData, sessionId: UUID, sessionEnd: Date, inputs: SleepBoundaryWrite.Inputs
    ) -> HRVSession? {
        var written: HRVSession?
        do {
            try archive.update(sessionId, requestingReupload: false) { stored in
                written = Self.retroApplied(newSleep, to: &stored, sessionEnd: sessionEnd, inputs: inputs)
            }
        } catch {
            debugLog("[ReanalysisService] Sleep retro-apply: save failed for \(sessionId.uuidString.prefix(8)): \(error)")
            return nil
        }
        guard let written else { return nil }
        queueUpload(written)
        return written
    }

    /// The skip rules on the archived copy, then the new sleep, the
    /// re-classification and the re-score. Nil (copy unchanged) when a rule
    /// now skips the session, e.g. the user adjusted its sleep meanwhile.
    private static func retroApplied(
        _ newSleep: SleepData, to stored: inout HRVSession, sessionEnd: Date, inputs: SleepBoundaryWrite.Inputs
    ) -> HRVSession? {
        guard shouldRetroApply(to: stored, newSleep: newSleep, sessionEnd: sessionEnd) else { return nil }
        applySleepBoundaries(newSleep, to: &stored, sessionStart: stored.startDate)
        SleepBoundaryWrite.rescore(&stored, sessionEnd: sessionEnd, inputs: inputs)
        return stored
    }

    // MARK: - Manual Window Reanalysis

    /// Reanalyze a session at a specific timestamp (for manual window selection).
    func reanalyzeAtPosition(_ inputSession: HRVSession, targetMs: Int64) async -> HRVAnalysisResult? {
        let session = hydrated(latestArchivedCopy(of: inputSession))
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
        let session = hydrated(latestArchivedCopy(of: inputSession))
        // Preserve the frozen training context from the original session.
        let frozenTraining = session.trainingSnapshot ?? session.analysisResult?.trainingContext
        let appliedResult = Self.manualResult(result, frozenTraining: frozenTraining)
        var updatedSession = session
        preserveAutoWindow(of: session, on: &updatedSession)
        updatedSession.analysisResult = appliedResult
        updatedSession.windowUserAdjusted = true
        reclassifyHRVQuality(of: &updatedSession, result: appliedResult)
        updatedSession.refreshSleepHeartRate(replacing: session)
        applyDeterministicScore(to: &updatedSession, result: appliedResult, training: frozenTraining)
        let persisted = await persistManualAnalysis(updatedSession, originalId: session.id)
        if let persisted { reexportIfReadingsChanged(from: session, to: persisted) }
        return persisted
    }

    /// The picked window's result, marked as a reanalysis, carrying the
    /// session's frozen training context when it has one.
    private static func manualResult(_ result: HRVAnalysisResult, frozenTraining: TrainingContext?) -> HRVAnalysisResult {
        var applied = result
        applied.isReanalysis = true
        if let frozenTraining { applied.trainingContext = frozenTraining }
        return applied
    }

    /// The archived copy of `session` when there is one, so a manual pick
    /// starts from what the archive holds now (a sleep edit, merge or rescore
    /// made after the sheet captured its copy), not the sheet's copy. Falls
    /// back to `session` when it is not archived or the read fails; a failed
    /// read is logged at `.error` (`ArchivedSessionRead`).
    ///
    /// A recording the archive folded into another night is that night
    /// (`SessionArchive.archivedId(of:)`), which holds its beats: the pick is
    /// applied there. Archiving the sheet's copy instead merged the recording
    /// in again, which kept the night's own window and dropped the pick.
    private func latestArchivedCopy(of session: HRVSession) -> HRVSession {
        ArchivedSessionRead.read(archive.archivedId(of: session.id), from: archive, caller: "manualWindow").session ?? session
    }

    /// Keep frozen snapshots so manual reanalysis remains deterministic and local.
    private func applyDeterministicScore(
        to session: inout HRVSession, result: HRVAnalysisResult, training: TrainingContext?
    ) {
        guard !Self.keepsStoredScore(session, baseline: scoringBaseline(for: session)) else { return }
        let scored = deterministicRecoveryScore(for: session, result: result)
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
            queueUpload(sessionToUpload)
            debugLog("[ReanalysisService] Applied manual analysis to session \(originalId)")
            return updatedSession
        } catch {
            debugLog("[ReanalysisService] Failed to save manual analysis: \(error)")
            return nil
        }
    }

    /// Update a session's sleep from `sleepData`, off the main actor. The
    /// returned task's value is `true` only when the updated session was
    /// actually persisted. A `Void` result would let a user's manual timeline
    /// edit die in a log line while the editor UI confirms success.
    /// User-adjustment call sites must check the value and surface failure;
    /// automatic callers may ignore it (discardable).
    ///
    /// Edits run one after another in the order they were made: each waits
    /// for the one before (`pendingSleepEdit`), so a slow earlier edit never
    /// lands over a later one.
    @discardableResult
    func updateSessionSleepBoundaries(sessionId: UUID, sleepData: SleepData, isUserAdjustment: Bool = false) -> Task<Bool, Never> {
        let previous = pendingSleepEdit
        let edit = Task<Bool, Never> {
            _ = await previous?.value
            return await self.runSleepBoundaryUpdate(sessionId: sessionId, sleepData: sleepData, isUserAdjustment: isUserAdjustment)
        }
        pendingSleepEdit = edit
        return edit
    }

    /// One sleep edit: the session is read off the main actor, then written
    /// (`writeUntilCurrent`). False on missing start or end, a session not
    /// in the archive, an automatic update that does not apply, inputs that
    /// kept changing, or an error (logged at `.error`). A recording folded
    /// into another night is that night (`SessionArchive.archivedId(of:)`).
    private func runSleepBoundaryUpdate(sessionId: UUID, sleepData: SleepData, isUserAdjustment: Bool) async -> Bool {
        guard let edit = SleepBoundaryWrite.Edit(sleepData: sleepData, isUserAdjustment: isUserAdjustment) else {
            debugLog("[UpdateSleepBounds] Bailed: sleepStart or sleepEnd is nil")
            return false
        }
        let archive = archive
        do {
            guard let read = try await Task.detached(priority: .userInitiated, operation: { try archive.retrieve(archive.archivedId(of: sessionId)) }).value else {
                debugLog("[UpdateSleepBounds] Bailed: session \(sessionId.uuidString.prefix(8)) not in archive")
                return false
            }
            guard let landed = try await writeUntilCurrent(edit, from: read) else { return false }
            reportSleepUpdate(landed.session, sleepData: sleepData, oldMinutes: landed.previous.sleepSnapshot?.nightSleepMinutes ?? 0, isUserAdjustment: isUserAdjustment)
            Task { await self.finishSleepWrite(from: landed.previous, to: landed.session) }
            return true
        } catch {
            debugLog("[ReanalysisService] Failed to update sleep boundaries for \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return false
        }
    }

    /// Writes `edit` from `read` (`writeSleepEdit`); when an input changed
    /// since the read (`.inputsChanged`), runs again from the stored copy, up
    /// to `RescoreWrite.runs` times. The session as written and the copy it
    /// was written from; nil when the edit was
    /// declined, the session is no longer archived, or the inputs kept
    /// changing (logged).
    private func writeUntilCurrent(
        _ edit: SleepBoundaryWrite.Edit, from read: HRVSession
    ) async throws -> (session: HRVSession, previous: HRVSession)? {
        var current = read
        for _ in 1 ... RescoreWrite.runs {
            let outcome = try await writeSleepEdit(edit, readFrom: current)
            if case .inputsChanged(let stored) = outcome {
                current = stored
                continue
            }
            guard let written = outcome.written else { return nil }
            return (written, current)
        }
        debugLog("[UpdateSleepBounds] Inputs kept changing while the sleep edit ran — giving up")
        return nil
    }

    /// One write: the re-score inputs captured here, on the main actor
    /// (`sleepRescoreInputs`, anchored to `endDate ?? startDate`), then
    /// `SleepBoundaryWrite.write` on a detached task.
    private func writeSleepEdit(
        _ edit: SleepBoundaryWrite.Edit, readFrom read: HRVSession
    ) async throws -> SleepBoundaryWrite.Outcome {
        await prepareScoringBaseline(for: read)
        let inputs = sleepRescoreInputs(for: read, sessionEnd: read.endDate ?? read.startDate)
        let archive = archive
        return try await Task.detached(priority: .userInitiated) {
            try SleepBoundaryWrite.write(edit, readFrom: read, inputs: inputs, to: archive)
        }.value
    }

    /// What a sleep re-score of `session` reads from the main actor: the
    /// baseline, typical sleep and scoring config (`rescoreContext`), and
    /// the training context built for `sessionEnd`, asked for only when the
    /// session has an analysis but no training context of its own.
    func sleepRescoreInputs(for session: HRVSession, sessionEnd: Date) -> SleepBoundaryWrite.Inputs {
        let needsFallback = session.analysisResult != nil
            && session.trainingSnapshot == nil && session.analysisResult?.trainingContext == nil
        return SleepBoundaryWrite.Inputs(
            context: rescoreContext(for: session),
            fallbackTraining: needsFallback ? trainingContextProvider(sessionEnd) : nil
        )
    }

    private func reportSleepUpdate(
        _ session: HRVSession, sleepData: SleepData, oldMinutes: Int, isUserAdjustment: Bool
    ) {
        debugLog("[ReanalysisService] Updated sleep data for session \(session.id.uuidString.prefix(8)): \(oldMinutes)min → \(sleepData.nightSleepMinutes)min\(isUserAdjustment ? " (user adjustment)" : "")")
        Task { @MainActor in self.onArchiveChanged() }
        let sessionToUpload = session
        queueUpload(sessionToUpload)
    }

    /// Diagnostic result from training snapshot repair.
    struct TrainingRepairResult {
        let totalSessions: Int
        var candidates: Int
        var nilContext: Int
        var repaired: Int
        var errors: Int
        /// Sessions left as stored because HealthKit did not answer the
        /// workout query for their date.
        var unanswered: Int = 0
        /// The pass was cancelled before it reached every session.
        var stoppedEarly = false
        var sampleLog: String = ""

        /// Every session was read and answered, and every repair written.
        var coversEverySession: Bool {
            unanswered == 0 && errors == 0 && !stoppedEarly
        }
    }

    /// Recompute training snapshots for all completed sessions from HealthKit.
    /// Anchors each session to 5 AM on the morning it ended so the EWMA
    /// matches the original morning capture (through yesterday's training).
    /// Repair one session's snapshot when it is complete and analysed.
    private func repairSnapshot(
        ofSessionAt index: Int, in sessions: ArchivedSessions, into result: inout TrainingRepairResult
    ) async {
        // An unread session counts as an error, not as one with nothing to repair.
        guard let session = await sessions.session(at: index) else { return result.errors += 1 }
        guard session.state == .complete, session.analysisResult != nil else { return }
        result.candidates += 1
        await repairSnapshot(for: session, into: &result)
    }

    func repairTrainingSnapshots(
        sessions: ArchivedSessions,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> TrainingRepairResult {
        // An analysed session has a mean RMSSD in the index.
        let analysed = sessions.filter { $0.meanRMSSD != nil }
        debugLog("[ReanalysisService] Training repair: \(analysed.count) analysed of \(sessions.count) sessions")

        var result = TrainingRepairResult(
            totalSessions: sessions.count, candidates: 0,
            nilContext: 0, repaired: 0, errors: 0
        )

        for index in 0 ..< analysed.count {
            if Task.isCancelled { result.stoppedEarly = true; break }
            progress(index, analysed.count)
            await repairSnapshot(ofSessionAt: index, in: analysed, into: &result)
        }

        progress(analysed.count, analysed.count)
        Task { @MainActor in self.onArchiveChanged() }
        debugLog("[ReanalysisService] Training repair complete: \(result.repaired)/\(result.candidates) updated, \(result.nilContext) nil context, \(result.unanswered) unanswered, \(result.errors) errors")
        return result
    }

    /// Rebuild one session's training snapshot and persist it, folding the
    /// outcome into `result`. A date HealthKit did not answer the workout
    /// query for (the store locked, a timeout) leaves the session as stored:
    /// read as no workouts, it would rewrite the snapshot with a load built
    /// from the archive's workouts alone.
    ///
    /// Kept as its own function so the repair loop's body stays short.
    private func repairSnapshot(for session: HRVSession, into result: inout TrainingRepairResult) async {
        let referenceDate = Self.morningAnchor(for: session)
        guard let load = await answeredTrainingLoad(for: session, at: referenceDate, into: &result) else { return }
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

    /// The training load as of `referenceDate`; nil, counted as unanswered,
    /// when HealthKit did not answer the workout query.
    private func answeredTrainingLoad(
        for session: HRVSession, at referenceDate: Date, into result: inout TrainingRepairResult
    ) async -> HealthKitManager.TrainingLoad? {
        guard let load = await healthKit.calculateTrainingLoadIfAnswered(relativeTo: referenceDate) else {
            debugLog("[ReanalysisService] Training repair: HealthKit did not answer for \(session.id.uuidString.prefix(8)), left as stored")
            result.unanswered += 1
            return nil
        }
        return load
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

    /// Write the fresh context and recompute frozen readiness against it on
    /// the archived copy, under the archive lock (`SessionArchive.update`),
    /// so a concurrent edit is not clobbered. Throws when the session is no
    /// longer archived or the write fails.
    private func persistSnapshot(_ freshContext: TrainingContext, onto session: HRVSession) throws {
        var updated = session
        try archive.update(session.id, requestingReupload: false) { stored in
            stored.trainingSnapshot = freshContext
            stored.analysisResult?.trainingContext = freshContext
            if let breakdown = stored.scoreBreakdown {
                stored.frozenReadiness = Self.computeFrozenReadiness(
                    compositeScore: breakdown.compositeScore, trainingContext: freshContext
                )
            }
            updated = stored
        }
        let synced = updated
        queueUpload(synced)
    }

    /// Unlink a merged segment: strip its beats from the parent's series
    /// (`NightBeatsEdit.replaceBeats`, so what is indexed into them moves and
    /// the span follows the beats kept), drop the link, archive, and analyse
    /// the night again from what it keeps. False (link kept, nothing
    /// written) when the parent or the link is missing, when the segment
    /// can't be read so its beats can't be located, or when the write fails.
    /// False too, with the night put back as it was, when a night that was
    /// analysed cannot be analysed again without the segment: its analysis
    /// and score would describe beats it no longer holds.
    @discardableResult
    func unlinkSegment(segmentId: UUID, fromSession sessionId: UUID) async -> Bool {
        do {
            guard let linked = try archive.retrieve(sessionId), var session = Self.unlinking(segmentId, from: linked),
                  stripSegmentPoints(segmentId: segmentId, from: &session) else { return false }
            try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            debugLog("[ReanalysisService] Unlinked segment \(segmentId.uuidString.prefix(8)) from session \(sessionId.uuidString.prefix(8)) — \(session.linkedSessionIds?.count ?? 0) segments remaining")
            return try await reanalyzeAfterUnlink(session, linked: linked)
        } catch {
            debugLog("[ReanalysisService] Failed to unlink segment: \(error)", level: .error)
            return false
        }
    }

    /// `session` without the link to `segmentId`; nil when it has none.
    private static func unlinking(_ segmentId: UUID, from session: HRVSession) -> HRVSession? {
        guard var links = session.linkedSessionIds, links.contains(segmentId) else { return nil }
        links.removeAll { $0 == segmentId }
        var unlinked = session
        unlinked.linkedSessionIds = links.isEmpty ? nil : links
        return unlinked
    }

    /// Load the unlinked session to find its time range, then remove the
    /// points that fall within that range from the parent's series. False
    /// only when the unlinked session can't be read: its range is unknown, so
    /// its beats would stay in the parent's series and score. A parent with
    /// no beats, or a segment with no span, has nothing to strip (true).
    ///
    /// The strip window is anchored to the SERIES origin, not the session
    /// origin: `series.points[].t_ms` are re-based to `series.startDate`, and
    /// for a merged split-night series that differs from `session.startDate`.
    /// Using `session.startDate` shifted the window and stripped the wrong
    /// beats. Identical for the common non-merged case where the two origins
    /// coincide.
    private func stripSegmentPoints(segmentId: UUID, from session: inout HRVSession) -> Bool {
        guard let unlinked = archive.retrieveOrLog(segmentId) else {
            debugLog("[ReanalysisService] Unlink refused: segment \(segmentId.uuidString.prefix(8)) can't be read, so its beats can't be located", level: .error)
            return false
        }
        guard let series = session.rrSeries, !series.points.isEmpty else { return true }
        let segStartMs = MillisecondOffset.between(unlinked.startDate, and: series.startDate, fallback: 0)
        let segDurationMs = Self.segmentDurationMs(of: unlinked)
        guard segDurationMs > 0 else { return true }
        let segEndMs = segStartMs + segDurationMs
        let originalCount = series.points.count
        let cleanedPoints = series.points.filter { $0.t_ms < segStartMs || $0.t_ms > segEndMs }
        NightBeatsEdit.replaceBeats(of: &session, with: cleanedPoints)
        debugLog("[ReanalysisService] Stripped \(originalCount - cleanedPoints.count) RR points from unlinked segment time range (\(segStartMs)-\(segEndMs) ms)")
        return true
    }

    /// The segment's own span, from its stored duration or, failing that, the
    /// last beat of its series.
    private static func segmentDurationMs(of unlinked: HRVSession) -> Int64 {
        if let dur = unlinked.duration { return Int64(dur * 1000) }
        return unlinked.rrSeries?.points.last?.t_ms ?? 0
    }

    /// The night analysed again without the segment's beats: in full, or,
    /// for a window the user picked and still holds, scored over it. A night
    /// that held no analysis has none to bring up to date. When the analysis
    /// fails the night is put back as it was (`linked`) and false returned.
    /// Then Apple Health gets the night without the segment's beats,
    /// compared with the night as it was while `linked`.
    private func reanalyzeAfterUnlink(_ session: HRVSession, linked: HRVSession) async throws -> Bool {
        var final = session
        if session.analysisResult != nil {
            guard let reanalyzed = await analysedAfterBeatsEdit(session) else {
                debugLog("[ReanalysisService] Reanalysis after unlink failed — the unlink is undone", level: .error)
                try archive.archive(linked, skipSameNightMerge: false, requestingReupload: true)
                onArchiveChanged()
                return false
            }
            final = reanalyzed
        }
        reexportIfReadingsChanged(from: linked, to: final)
        onArchiveChanged()
        let uploaded = final
        queueUpload(uploaded)
        return true
    }

    /// A night whose beats an edit changed, analysed again in full, or, for
    /// a window the user picked and still holds, scored over it. Nil when
    /// neither could be done.
    func analysedAfterBeatsEdit(_ night: HRVSession) async -> HRVSession? {
        if let reanalysed = await reanalyzeSession(night, preserveManualWindows: true) { return reanalysed }
        guard night.windowUserAdjusted == true else { return nil }
        return await recomputeScoreOnly(sessionId: night.id)
    }
}

/// What reading one session from the archive found. A read that throws (a
/// corrupt or undecryptable file, a hash mismatch, a storage error) is not
/// "not archived": callers that fall back to the copy they were given must
/// still see the failure, so `read` logs it at `.error`, which files it in
/// the Recent Problems catalog.
enum ArchivedSessionRead: Sendable {
    case stored(HRVSession)
    case notArchived
    case unreadable

    /// The archived copy, when the read found one.
    var session: HRVSession? {
        if case .stored(let session) = self { return session }
        return nil
    }

    /// Read `sessionId` from `archive`. `caller` names the path in the log line.
    static func read(_ sessionId: UUID, from archive: SessionArchive, caller: String) -> ArchivedSessionRead {
        do {
            guard let stored = try archive.retrieve(sessionId) else { return .notArchived }
            return .stored(stored)
        } catch {
            debugLog("[ReanalysisService] \(caller): archive read of \(sessionId.uuidString.prefix(8)) failed: \(error)", level: .error)
            return .unreadable
        }
    }
}
