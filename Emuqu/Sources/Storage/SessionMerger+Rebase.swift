import Foundation

// MARK: - Moving a session onto a shared clock
//
// A session's beats, sleep bounds, sleep segments and analysis windows are
// all counted in milliseconds from its own start. Before two sessions are
// merged, each is moved onto the clock they share, so every one of those
// fields means the same moment afterwards that it meant before.

extension SessionMerger {
    /// `session` re-counted from `clockStart`, which is no later than its own
    /// start. Its id, its beats' order and every field not measured from its
    /// start are kept.
    static func onClock(_ session: HRVSession, startingAt clockStart: Date) -> HRVSession {
        let offsetMs = MillisecondOffset.between(session.startDate, and: clockStart, fallback: 0)
        guard offsetMs != 0 || session.startDate != clockStart else { return session }
        var moved = copy(of: session, startDate: clockStart)
        moved.rrSeries = session.rrSeries.map { series in
            RRSeries(
                points: rebased(series.points, from: series.startDate, onto: clockStart),
                sessionId: session.id, startDate: clockStart
            )
        }
        moved.sleepStartMs = session.sleepStartMs.map { $0 + offsetMs }
        moved.sleepEndMs = session.sleepEndMs.map { $0 + offsetMs }
        moved.sleepSegments = session.sleepSegments?.map {
            HRVSession.SleepSegmentMs(startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs)
        }
        moved.analysisResult = session.analysisResult.map { shifted($0, by: offsetMs) }
        moved.autoWindowResult = session.autoWindowResult.map { shifted($0, by: offsetMs) }
        return moved
    }

    /// `result` with every time it holds moved `offsetMs` later. Its beat
    /// indices are untouched: shifting a whole series keeps their order.
    static func shifted(_ result: HRVAnalysisResult, by offsetMs: Int64) -> HRVAnalysisResult {
        guard offsetMs != 0 else { return result }
        var moved = result
        moved.windowStartMs = result.windowStartMs.map { $0 + offsetMs }
        moved.windowEndMs = result.windowEndMs.map { $0 + offsetMs }
        moved.organizedRecoveryZones = result.organizedRecoveryZones?.map {
            HRVAnalysisResult.TimeRange(startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs)
        }
        moved.overnightNadirTimeMs = result.overnightNadirTimeMs.map { $0 + offsetMs }
        return moved
    }

    // MARK: Window indices

    /// `result`'s window, an index range into `source`, re-pointed at the same
    /// beats in `merged`. Both series must already be on one clock. Beats the
    /// merge put before the window move it along by their number.
    static func reindexed(
        _ result: HRVAnalysisResult, from source: [RRPoint], onto merged: [RRPoint]
    ) -> HRVAnalysisResult {
        let start = mergedIndex(of: result.windowStart, in: source, onto: merged)
        let end = mergedIndex(of: result.windowEnd, in: source, onto: merged)
        guard start != result.windowStart || end != result.windowEnd else { return result }
        return withWindow(result, start: start, end: end)
    }

    /// Where `source[index]` sits in `merged`: the first merged beat no more
    /// than the duplicate tolerance before it. An index past the end maps
    /// past the source's last beat.
    private static func mergedIndex(of index: Int, in source: [RRPoint], onto merged: [RRPoint]) -> Int {
        guard let last = source.last, index >= 0 else { return index }
        let timeMs = index < source.count ? source[index].t_ms : last.endMs
        let target = timeMs - DataSourceSelector.duplicateToleranceMs
        var low = 0
        var high = merged.count
        while low < high {
            let mid = (low + high) / 2
            if merged[mid].t_ms < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// `result` with its window indices replaced and every other field kept.
    private static func withWindow(_ result: HRVAnalysisResult, start: Int, end: Int) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: start, windowEnd: end, timeDomain: result.timeDomain,
            frequencyDomain: result.frequencyDomain, nonlinear: result.nonlinear, ansMetrics: result.ansMetrics,
            artifactPercentage: result.artifactPercentage, cleanBeatCount: result.cleanBeatCount,
            analysisDate: result.analysisDate, windowStartMs: result.windowStartMs, windowEndMs: result.windowEndMs,
            windowMeanHR: result.windowMeanHR, windowHRStability: result.windowHRStability,
            windowSelectionReason: result.windowSelectionReason, windowRelativePosition: result.windowRelativePosition,
            isConsolidated: result.isConsolidated, isOrganizedRecovery: result.isOrganizedRecovery,
            windowClassification: result.windowClassification, organizedRecoveryZones: result.organizedRecoveryZones,
            peakCapacity: result.peakCapacity, trainingContext: result.trainingContext,
            analysisSegmentLabel: result.analysisSegmentLabel, isReanalysis: result.isReanalysis,
            overnightNadirHR: result.overnightNadirHR, overnightNadirTimeMs: result.overnightNadirTimeMs,
            overnightMinHR: result.overnightMinHR, overnightMaxHR: result.overnightMaxHR,
            overnightMeanHR: result.overnightMeanHR
        )
    }

    // MARK: Copy with a new start

    /// Number of stored properties `copy(of:startDate:)` carries across.
    /// A test compares it with `HRVSession`'s, so a field added to the
    /// session without being added here fails the build's tests rather than
    /// vanishing from merged sessions.
    static let copiedSessionFieldCount = 39

    /// `session` with `startDate` replaced and every other stored field kept.
    /// The fields measured from the start are the caller's to re-count.
    static func copy(of session: HRVSession, startDate: Date) -> HRVSession {
        var copy = HRVSession(
            id: session.id, startDate: startDate, endDate: session.endDate, state: session.state,
            sessionType: session.sessionType, rrSeries: session.rrSeries,
            analysisResult: session.analysisResult, artifactFlags: session.artifactFlags,
            recoveryScore: session.recoveryScore, tags: session.tags, notes: session.notes,
            importedMetrics: session.importedMetrics, deviceProvenance: session.deviceProvenance,
            sleepStartMs: session.sleepStartMs, sleepEndMs: session.sleepEndMs,
            sleepSegments: session.sleepSegments, linkedSessionIds: session.linkedSessionIds,
            pausedDate: session.pausedDate, dataSourceSummary: session.dataSourceSummary
        )
        copyDerivedFields(from: session, to: &copy)
        return copy
    }

    /// The stored fields the memberwise initializer does not take.
    private static func copyDerivedFields(from session: HRVSession, to copy: inout HRVSession) {
        copy.sourceSchemaVersion = session.sourceSchemaVersion
        copy.sleepSnapshot = session.sleepSnapshot
        copy.sleepUserAdjusted = session.sleepUserAdjusted
        copy.windowUserAdjusted = session.windowUserAdjusted
        copy.napRepaired = session.napRepaired
        copy.autoWindowResult = session.autoWindowResult
        copy.autoWindowScore = session.autoWindowScore
        copy.vitalsSnapshot = session.vitalsSnapshot
        copy.trainingSnapshot = session.trainingSnapshot
        copy.scoreBreakdown = session.scoreBreakdown
        copy.frozenReadiness = session.frozenReadiness
        copy.hrvDataQuality = session.hrvDataQuality
        copy.healthKitExportedAt = session.healthKitExportedAt
        copy.healthKitExportFailureCount = session.healthKitExportFailureCount
        copyUserFields(from: session, to: &copy)
    }

    /// What the user or the workout recorder attached to the session.
    private static func copyUserFields(from session: HRVSession, to copy: inout HRVSession) {
        copy.modifiedAt = session.modifiedAt
        copy.aiContext = session.aiContext
        copy.perceivedReadiness = session.perceivedReadiness
        copy.morningFeeling = session.morningFeeling
        copy.morningFeelingTags = session.morningFeelingTags
        copy.workoutMetadata = session.workoutMetadata
    }
}
