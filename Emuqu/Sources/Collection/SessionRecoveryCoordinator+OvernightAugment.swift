import Foundation
import os

// Pulling an overnight session's full recording back off the strap and
// merging it into the archived night: reconnect, download, merge with the
// stream, re-score, and undo the merge when the night cannot be analysed.

extension SessionRecoveryCoordinator {
    /// "Pull from strap & re-merge" for an OVERNIGHT session that scored
    /// streaming-only — e.g. Bluetooth dropped overnight so the morning device
    /// fetch was skipped and only the (possibly truncated) live stream was
    /// scored. The H10 keeps its full-night internal file until the next
    /// recording clears it, so this reconnects, downloads it, merges with the archived stream
    /// (device-preferred, stream fills gaps), and re-scores through the
    /// saved-session reanalysis the caller hands in
    /// (`SessionReanalysisCoordinator.reanalyzeSession`) so the HRV window +
    /// recovery score are recomputed from the fuller data. Overnight sibling
    /// of `augmentWorkoutFromStrap`.
    func augmentOvernightFromStrap(
        sessionId: UUID, rescoringWith reanalysis: SessionReanalysisCoordinator
    ) async -> OvernightAugmentResult {
        guard let session = archive.retrieveOrLog(sessionId) else { return .failed }
        // Nothing to add if the device recording is already in the mix.
        if let src = session.dataSourceSummary?.selectedSource, src == "internal" || src == "composite" {
            return .alreadyMerged
        }
        guard await reconnectStrapForAugment() else { return .notReachable }
        guard let strap = await pullStrapRecording(for: session) else { return .noStrapData }
        let (strapRR, existing) = (strap.points, session.rrSeries?.points ?? [])
        let selection = DataSourceSelector.selectBestSource(
            streamingPoints: existing, internalPoints: strapRR,
            sessionId: sessionId, sessionStart: session.startDate
        )
        guard let mergedPoints = overnightMergePoints(selection: selection, existing: existing, strapRR: strapRR),
              let updated = persistMergedOvernight(
                session: session, mergedPoints: mergedPoints, selection: selection, existingCount: existing.count, strap: strap
              ) else { return .failed }
        return await rescoreAugmentedOvernight(updated, merging: session, strap: strap, streamedCount: existing.count, with: reanalysis)
    }

    /// The selector's points, or the strap's when it chose nothing and the
    /// strap holds more. Nil when the archived stream would stay as it is:
    /// relabelling it as strap data would report a merge that never happened.
    private func overnightMergePoints(
        selection: DataSourceSelector.SelectionResult?, existing: [RRPoint], strapRR: [RRPoint]
    ) -> [RRPoint]? {
        if let selected = selection?.points { return selected.isEmpty ? nil : selected }
        return strapRR.count > existing.count ? strapRR : nil
    }

    /// The merged night is analysed again from its beats (`NightBeatsEdit`):
    /// a window the user picked stays and is scored, and any other is chosen
    /// again. When that fails the merge is undone (`undoOvernightMerge`), the
    /// strap's download kept as a rescue backup, and the result says it
    /// failed: a night holding the strap's beats under the stream's analysis
    /// and score is never left behind.
    ///
    /// Apple Health gets the night with the strap's beats, compared with the
    /// night as it was before the merge (`before`): the reanalysis compares
    /// with the merged copy it read, which already holds them.
    private func rescoreAugmentedOvernight(
        _ updated: HRVSession, merging before: HRVSession, strap: PulledStrapRecording, streamedCount: Int, with reanalysis: SessionReanalysisCoordinator
    ) async -> OvernightAugmentResult {
        guard let rescored = await Self.analysedAfterBeatsEdit(updated, with: reanalysis) else {
            undoOvernightMerge(before, mergedCount: updated.rrSeries?.points.count ?? 0, strap: strap)
            return .failed
        }
        await MainActor.run { archiveSignal.notifyChanged() }
        reanalysis.service.reexportIfReadingsChanged(from: before, to: rescored)
        let mergedBeatCount = rescored.rrSeries?.points.count ?? 0
        debugLog("[RRCollector] augmentOvernight: merged \(strap.points.count) strap + \(streamedCount) streamed → \(mergedBeatCount) beats, source=\(rescored.dataSourceSummary?.selectedSource ?? "?")")
        return .merged(source: rescored.dataSourceSummary?.selectedSource ?? "internal", beats: mergedBeatCount, score: rescored.recoveryScore)
    }

    /// A night whose beats an edit changed, analysed again: in full, or, for
    /// a window the user picked and still holds, scored over it. Nil when
    /// neither could be done.
    static func analysedAfterBeatsEdit(_ night: HRVSession, with reanalysis: SessionReanalysisCoordinator) async -> HRVSession? {
        if let reanalysed = await reanalysis.reanalyzeSession(night, preserveManualWindow: true) { return reanalysed }
        guard night.windowUserAdjusted == true else { return nil }
        return await reanalysis.service.recomputeScoreOnly(sessionId: night.id)
    }

    /// Puts the night back as it was before the strap's beats were merged,
    /// while it still holds the merged beats, and keeps the download aside.
    private func undoOvernightMerge(_ before: HRVSession, mergedCount: Int, strap: PulledStrapRecording) {
        let archive = archive
        let restored = attempt("augmentOvernight.undo") { try Self.undoMerge(before, mergedCount: mergedCount, in: archive) }
        keepUnsavedDownload(strap.recording)
        debugLog("[RRCollector] augmentOvernight: the merged night could not be analysed — \(restored == true ? "merge undone" : "could not undo the merge")", level: .error)
    }

    /// Writes `before`'s beats and derived fields back, while the stored copy
    /// still holds the `mergedCount` merged beats. Whether it wrote.
    nonisolated static func undoMerge(_ before: HRVSession, mergedCount: Int, in archive: SessionArchive) throws -> Bool {
        try archive.updateIfChanged(before.id) { stored in
            guard (stored.rrSeries?.points.count ?? 0) == mergedCount else { return false }
            restoreBeatsAndDerivedFields(of: before, in: &stored)
            return true
        }
    }

    /// The beats and every field computed from them, as `before` had them.
    nonisolated static func restoreBeatsAndDerivedFields(of before: HRVSession, in stored: inout HRVSession) {
        stored.rrSeries = before.rrSeries
        stored.dataSourceSummary = before.dataSourceSummary
        stored.artifactFlags = before.artifactFlags
        stored.analysisResult = before.analysisResult
        stored.autoWindowResult = before.autoWindowResult
        stored.windowUserAdjusted = before.windowUserAdjusted
        stored.endDate = before.endDate
        stored.sleepStartMs = before.sleepStartMs
        stored.sleepEndMs = before.sleepEndMs
    }

    /// Reconnect so the strap's stored recording is reachable (BLE likely
    /// dropped overnight).
    private func reconnectStrapForAugment() async -> Bool {
        strapRecorder.beginTransfer()
        return await strapRecorder.reconnectForTransfer()
    }

    /// Persist merged points + updated provenance. This must be written BEFORE
    /// re-analysis, because `SessionReanalysisCoordinator.reanalyzeSession` re-loads the archived session
    /// from disk (and re-archives the rescored result itself).
    ///
    /// Only the beats and their provenance are written, onto the stored copy
    /// under the archive's lock (`SessionArchive.updateIfChanged`): the strap
    /// download takes seconds to minutes, and a feeling, a sleep update or a
    /// note saved meanwhile is in the stored copy, not in `session`, which was
    /// read before it. Nothing is written when the stored beats are no longer
    /// the ones merged (another merge landed first) or the night was deleted.
    ///
    /// A night that cannot be written keeps the strap's download as a rescue
    /// backup (`keepUnsavedDownload`).
    private func persistMergedOvernight(
        session: HRVSession, mergedPoints: [RRPoint],
        selection: DataSourceSelector.SelectionResult?, existingCount: Int, strap: PulledStrapRecording
    ) -> HRVSession? {
        let summary = mergedSummary(session: session, mergedCount: mergedPoints.count, selection: selection,
                                    existingCount: existingCount, strapCount: strap.points.count)
        let written: HRVSession?
        do {
            written = try Self.writeMergedBeats(mergedPoints, summary: summary, into: session.id, replacing: existingCount, in: archive)
        } catch {
            debugLog("[RRCollector] augmentOvernight: archive failed: \(error)")
            written = nil
        }
        if written == nil { keepUnsavedDownload(strap.recording) } else { strapRecorder.device.noteSaved(strap.recording) }
        return written
    }

    /// Puts `points` and `summary` on the archived copy of `sessionId`, with
    /// what is indexed into the beats moved with them and the span following
    /// them (`NightBeatsEdit.replaceBeats`), and changes nothing else; nil,
    /// with nothing written, when that copy no longer holds `replacing`
    /// beats. Returns the copy as written.
    nonisolated static func writeMergedBeats(
        _ points: [RRPoint], summary: HRVSession.DataSourceSummary, into sessionId: UUID, replacing beatCount: Int, in archive: SessionArchive
    ) throws -> HRVSession? {
        var written: HRVSession?
        try archive.updateIfChanged(sessionId) { stored in
            guard (stored.rrSeries?.points.count ?? 0) == beatCount else { return false }
            NightBeatsEdit.replaceBeats(of: &stored, with: points)
            stored.dataSourceSummary = summary
            written = stored
            return true
        }
        return written
    }

    /// The provenance of a night after the strap's recording was merged in.
    private func mergedSummary(
        session: HRVSession, mergedCount: Int, selection: DataSourceSelector.SelectionResult?, existingCount: Int, strapCount: Int
    ) -> HRVSession.DataSourceSummary {
        HRVSession.DataSourceSummary(
            selectedSource: selection?.normalizedSource ?? "internal",
            streamingBeats: existingCount,
            deviceBeats: strapCount,
            totalBeats: mergedCount,
            beatDifferencePercent: nil,
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: session.dataSourceSummary?.deviceModel
        )
    }
}
