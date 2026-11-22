import Foundation

// Merge data-loss repair: rebuilds resumed overnight segments whose beat
// series lost the parent's beats to an earlier merge bug, from the archive
// alone. Split from `RRCollector+BackupRecovery.swift`, which keeps the
// backup, Trash and interrupted-workout recovery.

extension SessionRecoveryCoordinator {
    // MARK: - Merge Data Loss Repair

    /// Rebuilds a child night's beat series by appending it to its parent's,
    /// time-shifted so the two are continuous.
    ///
    /// Repairs sessions affected by the merge data-loss bug where background
    /// device refinement bypassed `collector.mergeParentSessionData()`, leaving resumed
    /// sessions with only the child's data instead of parent + child merged.
    ///
    /// A v5-corrupted child already contains a copy of the parent's beats at
    /// its head, so only the tail past `parentBeatCount` is the child's own
    /// data. The offset takes the LARGER of the parent's recorded duration
    /// and the wall-clock gap between the two start dates, so a child that
    /// began after a long pause is not folded back on top of the parent.
    nonisolated static func mergedRepairPoints(
        childSeries: RRSeries,
        parentSeries: RRSeries,
        childStartDate: Date,
        parentStartDate: Date,
        parentBeatCount: Int,
        isV5Corrupted: Bool,
        idPrefix: String
    ) -> [RRPoint] {
        let childOriginalPoints: [RRPoint]
        if isV5Corrupted {
            childOriginalPoints = Array(childSeries.points.suffix(from: parentBeatCount))
            debugLog("[Recovery] Session \(idPrefix) is v5-corrupted (\(childSeries.points.count) beats) — extracting \(childOriginalPoints.count) child beats")
        } else {
            childOriginalPoints = childSeries.points
        }
        let parentDurationMs = parentSeries.points.last?.endMs ?? parentSeries.points.last?.t_ms ?? 0
        let dateOffsetMs = MillisecondOffset.between(childStartDate, and: parentStartDate, fallback: 0)
        let offsetMs = max(parentDurationMs, dateOffsetMs)
        let merged = parentSeries.points + childOriginalPoints.map { $0.shifted(by: offsetMs) }
        debugLog("[Recovery] Session \(idPrefix) merged: \(parentBeatCount) parent + \(childOriginalPoints.count) child (offset \(offsetMs / 60000)min) = \(merged.count) beats")
        return merged
    }

    /// Process each linked session inline — at most 2 full sessions (child +
    /// parent) in memory at a time. A previous implementation accumulated ALL
    /// candidates into a repairWork array, potentially holding hundreds of MB
    /// simultaneously.
    nonisolated func repairMergeDataLoss() async -> MergeRepairOutcome {
        debugLog("[Recovery] ========== START repairMergeDataLoss ==========")
        let linkedEntries = await linkedOvernightEntries()
        var outcome = MergeRepairOutcome()
        for entry in linkedEntries {
            switch await repairLinkedSession(entry) {
            case .repaired: outcome.repaired += 1
            case .failed: outcome.failed += 1
            case .unchanged: break
            }
        }
        if outcome.repaired > 0 { await MainActor.run { collector.archiveSignal.notifyChanged() } }
        debugLog("[Recovery] ========== END repairMergeDataLoss: \(outcome.repaired) repaired, \(outcome.failed) failed ==========")
        return outcome
    }

    /// How many linked nights were rewritten, and how many needed it but
    /// could not be written (those are worth another run).
    struct MergeRepairOutcome {
        var repaired = 0
        var failed = 0
    }

    /// One linked night: rewritten, left as it was (healthy, unreadable or
    /// implausible), or needing a repair whose write failed.
    enum LinkedRepairResult {
        case repaired
        case unchanged
        case failed
    }

    /// Gather candidates on the main actor (archive access). Pre-filters using
    /// the index's `linkedSessionIds` — avoids loading sessions from disk just
    /// to check whether they have links (saves ~700KB per session).
    nonisolated private func linkedOvernightEntries() async -> [SessionArchiveEntry] {
        let entries = await MainActor.run { collector.archive.entries }
        let linkedEntries = entries.filter { entry in
            entry.sessionType == .overnight &&
                entry.linkedSessionIds != nil &&
                !(entry.linkedSessionIds?.isEmpty ?? true)
        }
        guard !linkedEntries.isEmpty else { return [] }
        let skipped = entries.filter { $0.sessionType == .overnight }.count - linkedEntries.count
        debugLog("[Recovery] Checking \(linkedEntries.count) linked sessions (skipped \(skipped) non-linked)")
        return linkedEntries
    }

    /// Load the child + parent, decide whether anything is wrong, and if so
    /// rebuild and re-archive.
    ///
    /// Only a segment resumed from its first link is a child
    /// (`SessionRecoveryMath.isResumedSegment`). Other linked nights are left
    /// as they are: a paused night that was resumed lists its segment first,
    /// and a night that superseded same-night siblings lists them, and
    /// rebuilding either onto that link would put another session's beats
    /// in front of its own.
    nonisolated private func repairLinkedSession(_ entry: SessionArchiveEntry) async -> LinkedRepairResult {
        guard let parentId = entry.linkedSessionIds?.first else { return .unchanged }
        // Full load needed for the rrSeries merge.
        guard let session = await MainActor.run(resultType: HRVSession?.self, body: { collector.archive.retrieveOrLog(entry.sessionId) }),
              let parent = await MainActor.run(resultType: HRVSession?.self, body: { collector.archive.retrieveOrLog(parentId) }),
              Self.isResumedChild(session, of: parent),
              let parentSeries = parent.rrSeries, !parentSeries.points.isEmpty,
              let childSeries = session.rrSeries, !childSeries.points.isEmpty
        else { return .unchanged }
        let damage = Self.mergeDamage(session: session, parent: parent, childSeries: childSeries, parentSeries: parentSeries)
        guard damage.needsRepair else { return .unchanged }
        guard let mergedPoints = Self.repairedPoints(
            entry: entry, session: session, parent: parent,
            childSeries: childSeries, parentSeries: parentSeries, damage: damage
        ) else { return .unchanged }
        let written = await rebuildAndArchive(session: session, parent: parent, mergedPoints: mergedPoints)
        return written ? .repaired : .failed
    }

    nonisolated private static func isResumedChild(_ session: HRVSession, of parent: HRVSession) -> Bool {
        SessionRecoveryMath.isResumedSegment(
            segmentId: session.id, segmentLinks: session.linkedSessionIds,
            segmentEnd: session.endDate ?? session.startDate,
            parentId: parent.id, parentLinks: parent.linkedSessionIds, parentPausedAt: parent.pausedDate
        )
    }

    /// What (if anything) is wrong with a merged child session.
    struct MergeDamage {
        let needsMerge: Bool
        let isV5Corrupted: Bool
        let summaryStale: Bool
        let startDateWrong: Bool

        var needsRepair: Bool { needsMerge || isV5Corrupted || summaryStale || startDateWrong }
    }

    nonisolated private static func mergeDamage(
        session: HRVSession, parent: HRVSession,
        childSeries: RRSeries, parentSeries: RRSeries
    ) -> MergeDamage {
        let childBeatCount = childSeries.points.count
        let parentBeatCount = parentSeries.points.count
        return MergeDamage(
            needsMerge: childBeatCount <= parentBeatCount,
            isV5Corrupted: SessionRecoveryMath.hasV5TimestampDiscontinuity(childSeries: childSeries, parentBeatCount: parentBeatCount),
            summaryStale: session.dataSourceSummary.map { $0.totalBeats != childBeatCount } ?? false,
            startDateWrong: session.startDate.timeIntervalSince(parent.startDate) > 1800
        )
    }

    /// The beat series the repaired session should carry, or nil when the
    /// result fails the sanity ceiling.
    nonisolated private static func repairedPoints(
        entry: SessionArchiveEntry, session: HRVSession, parent: HRVSession,
        childSeries: RRSeries, parentSeries: RRSeries, damage: MergeDamage
    ) -> [RRPoint]? {
        let parentBeatCount = parentSeries.points.count
        let mergedPoints: [RRPoint]
        if damage.needsMerge || damage.isV5Corrupted {
            mergedPoints = mergedRepairPoints(
                childSeries: childSeries, parentSeries: parentSeries,
                childStartDate: session.startDate, parentStartDate: parent.startDate,
                parentBeatCount: parentBeatCount, isV5Corrupted: damage.isV5Corrupted,
                idPrefix: String(entry.sessionId.uuidString.prefix(8))
            )
        } else {
            mergedPoints = childSeries.points
            debugLog("[Recovery] Session \(entry.sessionId.uuidString.prefix(8)) already merged (\(mergedPoints.count) beats) but needs re-analysis (summaryStale=\(damage.summaryStale), startDateWrong=\(damage.startDateWrong))")
        }
        let maxReasonableBeats = (parentBeatCount + childSeries.points.count) * 2
        guard mergedPoints.count <= maxReasonableBeats, mergedPoints.count < 200_000 else {
            debugLog("[Recovery] ❌ Session \(entry.sessionId.uuidString.prefix(8)) has unreasonable beat count (\(mergedPoints.count)) — skipping")
            return nil
        }
        return mergedPoints
    }

    /// Re-run the morning pipeline over the repaired beats, carry the user's
    /// own edits across, then archive and upload. The repaired session is
    /// anchored to the PARENT's start; only the beat series differs. A child
    /// with no end ends at its last beat, not at the time the repair runs.
    nonisolated private func rebuildAndArchive(session: HRVSession, parent: HRVSession, mergedPoints: [RRPoint]) async -> Bool {
        let lastBeatEnd = mergedPoints.last.map { parent.startDate.addingTimeInterval(Double($0.endMs) / 1000) }
        let baseSession = HRVSession(
            id: session.id, startDate: parent.startDate, endDate: session.endDate ?? lastBeatEnd ?? parent.startDate,
            state: .analyzing, sessionType: .overnight,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil,
            deviceProvenance: session.deviceProvenance,
            linkedSessionIds: session.linkedSessionIds, pausedDate: session.pausedDate
        )
        var repaired = await collector.processOvernightData(
            points: mergedPoints, baseSession: baseSession,
            dataSource: session.dataSourceSummary?.selectedSource ?? "streaming",
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            streamingBeats: session.dataSourceSummary?.streamingBeats ?? 0,
            deviceBeats: session.dataSourceSummary?.deviceBeats,
            isBackgroundRefinement: true
        )
        Self.carryUserEdits(from: session, to: &repaired)
        return await archiveRepaired(repaired, originalId: session.id, beatCount: mergedPoints.count)
    }

    /// Tags, notes, and the sleep-adjusted flag are the user's own work — the
    /// rebuilt session must not lose them. Vitals carry over only when the
    /// rebuild produced none.
    nonisolated private static func carryUserEdits(from session: HRVSession, to repaired: inout HRVSession) {
        repaired.tags = session.tags
        repaired.notes = session.notes
        repaired.sleepUserAdjusted = session.sleepUserAdjusted
        if repaired.vitalsSnapshot == nil, let oldVitals = session.vitalsSnapshot {
            repaired.vitalsSnapshot = oldVitals
        }
    }

    /// Upload immediately instead of accumulating — keeps peak memory low.
    nonisolated private func archiveRepaired(_ repairedSession: HRVSession, originalId: UUID, beatCount: Int) async -> Bool {
        do {
            let sessionToArchive = repairedSession
            _ = try await MainActor.run { try collector.archive.archive(sessionToArchive) }
            let syncSession = repairedSession
            // The sync manager is read on the main actor, so the upload Task
            // never reaches back through the collector.
            let cloudSync = await MainActor.run { collector.cloudSyncManager }
            Task { await cloudSync.forceReuploadSession(syncSession) }
            debugLog("[Recovery] Repaired session \(originalId.uuidString.prefix(8)): \(beatCount) beats, score \(repairedSession.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil")")
            return true
        } catch {
            debugLog("[Recovery] Failed to archive repaired session: \(error)", level: .error)
            return false
        }
    }
}
