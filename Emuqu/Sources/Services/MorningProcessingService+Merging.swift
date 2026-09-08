import Foundation
import HealthKit
import UIKit

// Composite points, same-night superseding and the pipeline helpers. Members
// are internal rather than `private` because Swift's `private` does not reach
// across files.

extension MorningProcessingService {
    // MARK: - Composite Points

    /// Creates composite RR points by merging internal recording with streaming data.
    /// Uses DataSourceSelector for proper "choose best or merge diffs" logic:
    /// prefers internal (no BLE data loss), only adds streaming points to fill gaps.
    /// Deduplication uses wallClockMs for streaming alignment (raw t_ms drifts after BLE drops).
    func createCompositePoints(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]? {
        let internalPoints = internalSeries.points
        let streamingPoints = streamingSeries.points

        guard !internalPoints.isEmpty, !streamingPoints.isEmpty else {
            return nil
        }

        if let selection = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: internalSeries.sessionId,
            sessionStart: internalSeries.startDate
        ) {
            return selection.points
        }

        return nil
    }

    // MARK: - Same-Night Superseding

    /// Supersede same-night overnight sessions.
    ///
    /// Uses the configured sleep schedule (`overnightWindowStart`) to
    /// determine which sessions belong to the same biological night. Two sessions
    /// are same-night if their overnight window starts match — this correctly
    /// groups split-sleep segments (e.g., 1 AM and 7 AM) regardless of when they
    /// fall relative to midnight.
    ///
    /// The incoming session's beat count decides direction. If
    /// existing same-night entries have substantially more clean data, the new
    /// session shouldn't claim primary — link the new TO the existing as a
    /// child segment, not vice versa. Beta tester bug: a 22-min
    /// partial-backup recovery superseded Monday's 8-hour overnight session
    /// and ended up showing as Monday's dashboard score.
    func supersedeSameNightSession(newSession: inout HRVSession, sleepSchedule: SleepSchedule, sessionMergeMode: SessionMergeMode = .defaultGap) {
        guard newSession.sessionType == .overnight, sessionMergeMode != .off else { return }
        let newNightStart = sleepSchedule.overnightWindowStart(relativeTo: newSession.startDate)
        let existingLinkedIds = Set(newSession.linkedSessionIds ?? [])
        let newBeatCount = newSession.rrSeries?.points.count ?? 0
        for entry in archive.entries {
            guard entry.sessionType == .overnight,
                  entry.sessionId != newSession.id,
                  !existingLinkedIds.contains(entry.sessionId),
                  sleepSchedule.overnightWindowStart(relativeTo: entry.date) == newNightStart,
                  Self.newSessionMayClaimNight(over: entry, newBeatCount: newBeatCount)
            else { continue }
            var links = newSession.linkedSessionIds ?? []
            links.append(entry.sessionId)
            newSession.linkedSessionIds = links
        }
    }

    /// If the existing entry is substantially larger than the new
    /// session, do NOT add it to the new session's links. Adding the link
    /// makes the new session the "primary of the night" with existing demoted
    /// to a segment — wrong direction when existing has the real data.
    /// Skipping the link leaves the existing entry as primary; the new session
    /// is archived as a standalone sibling and the dashboard's
    /// most-recent-by-night selector still picks the larger one.
    ///
    /// "Substantially larger" = ≥ 4× as many beats. Tighter ratios (e.g. 1.5×)
    /// would also flag two legitimate split-night segments where one is much
    /// longer than the other. 4× is conservative enough that only true
    /// partial-recovery cases trip it.
    ///
    /// `meanRMSSD` stands in for "is this a meaningful overnight" — any entry
    /// that resolved RMSSD has enough beats for a valid analysis (≥ 60). That
    /// avoids a per-entry retrieve. The 1,000-beat (≈ 13 min) floor on the new
    /// session is the other half: below it the new session is almost certainly
    /// a partial recovery and must not claim the night.
    static func newSessionMayClaimNight(
        over entry: SessionArchiveEntry, newBeatCount: Int
    ) -> Bool {
        let entryIsRealOvernight = entry.recoveryScore != nil && entry.meanRMSSD != nil
        guard entryIsRealOvernight, newBeatCount > 0 else { return true }
        return newBeatCount >= 1_000
    }

    // MARK: - Private Helpers

    /// Backup raw RR data before any processing, off the main thread.
    /// Overnight sessions can serialize to 1.5MB+ JSON; doing this inline
    /// on the caller's actor caused morning-processing stalls.
    func backupRawDataAsync(points: [RRPoint], sessionId: UUID, deviceId: String?, dataSource: String) async {
        let backup = rawBackup
        await Task.detached(priority: .utility) {
            do {
                try backup.backup(points: points, sessionId: sessionId, deviceId: deviceId)
            } catch {
                debugLog("[MorningProcessingService] Warning: Failed to backup \(dataSource) RR data: \(error)")
            }
        }.value
    }

    /// Result of merging same-night sessions.
    struct MergeResult {
        let series: RRSeries
        let effectiveStartDate: Date
        let sameNightLinks: [UUID]
    }

    /// Build the RR series and merge same-night session data for combined window selection.
    func buildMergedSeries(
        points: [RRPoint],
        baseSession: HRVSession,
        sleepSchedule: SleepSchedule,
        sessionMergeMode: SessionMergeMode = .defaultGap
    ) -> MergeResult {
        let series = RRSeries(points: points, sessionId: baseSession.id, startDate: baseSession.startDate)
        guard baseSession.sessionType == .overnight, sessionMergeMode != .off else {
            return MergeResult(series: series, effectiveStartDate: baseSession.startDate, sameNightLinks: [])
        }
        let sameNight = sameNightSegments(baseSession: baseSession, points: points, sleepSchedule: sleepSchedule)
        guard !sameNight.links.isEmpty else {
            return MergeResult(series: series, effectiveStartDate: baseSession.startDate, sameNightLinks: [])
        }
        let segments = sameNight.segments.sorted { $0.startDate < $1.startDate }
        let effectiveStartDate = segments.first?.startDate ?? baseSession.startDate
        let mergedPoints = Self.offsetPoints(segments, to: effectiveStartDate)
        return MergeResult(
            series: RRSeries(points: mergedPoints, sessionId: baseSession.id, startDate: effectiveStartDate),
            effectiveStartDate: effectiveStartDate,
            sameNightLinks: sameNight.links
        )
    }

    /// One recording that belongs to the same biological night.
    struct NightSegment {
        let startDate: Date
        let points: [RRPoint]
    }

    /// Every archived overnight recording that shares this night's anchor,
    /// alongside the base session's own points.
    ///
    /// Very short sessions (< 30 min) are skipped — these are likely quick
    /// tests, demos, or accidental recordings that shouldn't contaminate
    /// overnight data.
    func sameNightSegments(
        baseSession: HRVSession, points: [RRPoint], sleepSchedule: SleepSchedule
    ) -> (segments: [NightSegment], links: [UUID]) {
        let nightStart = sleepSchedule.overnightWindowStart(relativeTo: baseSession.startDate)
        let alreadyLinked = Set(baseSession.linkedSessionIds ?? [])
        var segments = [NightSegment(startDate: baseSession.startDate, points: points)]
        var links: [UUID] = []
        for entry in archive.entries {
            guard entry.sessionType == .overnight, entry.sessionId != baseSession.id,
                  !alreadyLinked.contains(entry.sessionId),
                  sleepSchedule.overnightWindowStart(relativeTo: entry.date) == nightStart,
                  let archived = archive.retrieveOrLog(entry.sessionId),
                  let archivedSeries = archived.rrSeries, !archivedSeries.points.isEmpty
            else { continue }
            guard archivedSeries.durationMinutes >= 30 else {
                debugLog("[MorningProcessing] Skipping short session \(entry.sessionId) (\(String(format: "%.1f", archivedSeries.durationMinutes)) min) from same-night merge")
                continue
            }
            segments.append(NightSegment(startDate: archived.startDate, points: archivedSeries.points))
            links.append(entry.sessionId)
        }
        return (segments, links)
    }

    /// Offset each segment's t_ms and wallClockMs so all timestamps are
    /// relative to `effectiveStartDate`. This preserves the real-time gap
    /// between segments so charts show segment1 -> gap -> segment2 and the
    /// window selector searches the correct time range.
    static func offsetPoints(_ segments: [NightSegment], to effectiveStartDate: Date) -> [RRPoint] {
        segments.flatMap { segment -> [RRPoint] in
            let offsetMs = MillisecondOffset.between(segment.startDate, and: effectiveStartDate, fallback: 0)
            guard offsetMs != 0 else { return segment.points }
            return segment.points.map { $0.shifted(by: offsetMs) }
        }
    }

    /// Gap detection diagnostics (no-op; enable for development debugging).
    func logGapDetection(series _: RRSeries) {}

    /// Result of sleep data polling.
    /// Internal rather than private: the helpers that build it live in
    /// `MorningProcessingService+Analysis.swift`, and `private` is file-scoped.
    /// Still module-internal — nothing here escapes the app target.
    struct SleepPollResult {
        var sleepStartMs: Int64?
        var wakeTimeMs: Int64?
        var sleepBoundarySource: HealthKitManager.SleepBoundarySource
        var sleepSegments: [HRVSession.SleepSegmentMs]?
        var fetchedSleepData: SleepData?
    }

    /// `runAnalysis` with its wall-clock delta logged for the morning trace.
    func timedAnalysis(
        analyzingSession: HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        windowResult: WindowSelector.WindowSelectionResult?,
        trainingContext: TrainingContext?,
        ansConfig: HRVAnalysisPipeline.ANSConfiguration
    ) async -> HRVAnalysisResult? {
        let started = Date()
        let analysisResult = await runAnalysis(
            analyzingSession: analyzingSession, series: series, flags: flags,
            windowResult: windowResult, trainingContext: trainingContext, ansConfig: ansConfig
        )
        debugLog("[MorningTiming] HRV analysis: \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return analysisResult
    }

    /// Run HRV analysis using selected window or full series fallback.
    func runAnalysis(
        analyzingSession: HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        windowResult: WindowSelector.WindowSelectionResult?,
        trainingContext: TrainingContext?,
        ansConfig: HRVAnalysisPipeline.ANSConfiguration
    ) async -> HRVAnalysisResult? {
        if let recoveryWindow = windowResult?.recoveryWindow {
            return await analysisPipeline.analyzeWithWindow(
                session: analyzingSession, window: recoveryWindow, flags: flags,
                peakCapacity: windowResult?.peakCapacity,
                trainingContext: trainingContext, ansConfig: ansConfig
            )
        }
        if let peakCapacity = windowResult?.peakCapacity {
            return analysisPipeline.analyzeFullSeriesWithCapacity(
                series: series, flags: flags, peakCapacity: peakCapacity,
                trainingContext: trainingContext, ansConfig: ansConfig
            )
        }
        return analysisPipeline.analyzeFullSeries(
            series: series, flags: flags,
            trainingContext: trainingContext, ansConfig: ansConfig
        )
    }

    /// Build the final HRVSession from all analysis results.
    ///
    /// Takes grouped values rather than a long loose argument list: the one
    /// caller already holds every argument on three values it built itself,
    /// and a loose list makes a passed-but-ignored argument easy to miss.
    func buildFinalSession(
        analyzingSession: HRVSession,
        request: OvernightRequest,
        merged: MergeResult,
        phase: AnalysisPhaseResult
    ) -> HRVSession {
        let baseSession = request.baseSession
        let series = merged.series
        let sleepResult = phase.sleepResult
        // Clamp sleep boundaries
        let clamped = SleepBoundaryResolver.clamp(sleepStartMs: sleepResult.sleepStartMs, sleepEndMs: sleepResult.wakeTimeMs, recordingDurationMs: series.points.last?.endMs ?? 0)
        let summary = Self.dataSourceSummary(request, baseSession: baseSession, totalBeats: request.points.count)
        var finalSession = HRVSession(
            id: analyzingSession.id, startDate: analyzingSession.startDate,
            endDate: analyzingSession.endDate, state: phase.analysisResult != nil ? .complete : .failed,
            sessionType: baseSession.sessionType, rrSeries: series,
            analysisResult: phase.analysisResult, artifactFlags: phase.flags,
            deviceProvenance: baseSession.deviceProvenance, sleepStartMs: clamped.sleepStartMs,
            sleepEndMs: clamped.sleepEndMs, sleepSegments: sleepResult.sleepSegments,
            dataSourceSummary: summary
        )
        Self.carryForward(
            links: (baseSession.linkedSessionIds ?? []) + merged.sameNightLinks,
            sleep: sleepResult.fetchedSleepData, to: &finalSession
        )
        return finalSession
    }

    /// Carry forward linked session IDs from pause/resume or same-night merge,
    /// and snapshot sleep so the results screen shows it immediately.
    static func carryForward(
        links: [UUID], sleep: SleepData?, to session: inout HRVSession
    ) {
        if !links.isEmpty {
            session.linkedSessionIds = links
        }
        if let sleep {
            session.sleepSnapshot = sleep
        }
    }

    /// Provenance for the session: which source was selected, how the
    /// streaming and device beat counts compared, and how many reconnects it
    /// took to get there.
    static func dataSourceSummary(
        _ request: OvernightRequest,
        baseSession: HRVSession,
        totalBeats: Int
    ) -> HRVSession.DataSourceSummary {
        let streamingBeats = request.streamingBeats
        let deviceBeats = request.deviceBeats
        let beatDiffPercent: Double? = {
            guard let db = deviceBeats, db > 0, streamingBeats > 0 else { return nil }
            return (Double(abs(db - streamingBeats)) / Double(max(db, streamingBeats))) * 100.0
        }()
        return HRVSession.DataSourceSummary(
            selectedSource: request.dataSource,
            streamingBeats: streamingBeats,
            deviceBeats: deviceBeats,
            totalBeats: totalBeats,
            beatDifferencePercent: beatDiffPercent,
            reconnectCount: request.reconnectCount,
            deviceModel: baseSession.deviceProvenance?.deviceModel
        )
    }

    /// Compute composite recovery score.
    static func ansBalance(of result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    func computeRecoveryScore(
        for session: HRVSession,
        analysisResult: HRVAnalysisResult?,
        trainingContext: TrainingContext?,
        baselineTracker: BaselineTracker,
        settings: SettingsSnapshot,
        cachedTrainingLoad _: HealthKitManager.TrainingLoad?
    ) async -> (score: Double, breakdown: RecoveryScoreCalculator.ScoreBreakdown)? {
        guard let result = analysisResult else { return nil }
        let health = await scoringHealthData(for: session, result: result)
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baselineTracker.recoveryBaselineStats, sleepData: health.sleep,
                vitals: health.vitals, typicalSleepHours: settings.typicalSleepHours
            ),
            // Use training context from analysis result, or the one passed in
            trainingContext: result.trainingContext ?? trainingContext,
            config: settings.scoringConfig,
            ansBalance: Self.ansBalance(of: result)
        )
        return (RecoveryScoreCalculator.toTenScale(breakdown.compositeScore), breakdown)
    }

    /// Use frozen morning snapshots when available so the recovery score stays
    /// stable after acceptance (e.g. during reanalysis); otherwise fetch fresh.
    ///
    /// Strap-RHR override: see `attachVitalsSnapshot`.
    func scoringHealthData(
        for session: HRVSession, result: HRVAnalysisResult
    ) async -> (sleep: SleepData?, vitals: RecoveryVitals?) {
        if let frozenSleep = session.sleepSnapshot {
            return (frozenSleep, session.vitalsSnapshot)
        }
        let sessionEnd = session.endDate ?? session.startDate
        let sleepData = await freshSleepData(for: session, sessionEnd: sessionEnd)
        let fresh = await healthKit.fetchRecoveryVitals(relativeTo: sessionEnd)
        return (sleepData, fresh.withStrapNocturnalRHR(result.timeDomain.meanHR))
    }

    func freshSleepData(
        for session: HRVSession, sessionEnd: Date
    ) async -> SleepData? {
        do {
            let fetchedSleep = try await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: sessionEnd,
                rrPoints: session.rrSeries?.points
            )
            // Credit the day-before's qualifying nap toward 24h sleep duration.
            let napMinutes = await healthKit.fetchDaytimeNapMinutes(nightAnchoredAt: session.startDate)
            return napMinutes > 0 ? fetchedSleep.withNapSleepMinutes(napMinutes) : fetchedSleep
        } catch {
            debugLog("[MorningProcessingService] Recovery score sleep fetch failed: \(error)")
            return nil
        }
    }
}
