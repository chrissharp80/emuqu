import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

extension HealthWriteAndObserve {
    // MARK: - HRV Export

    /// Export a session's SDNN to Apple Health, replacing every HRV sample the
    /// session wrote before (`HealthSampleReplacer`, `isOurHRVExport`).
    ///
    /// The samples are `hrvExportSamples`: SDNN in 5-minute windows across
    /// the recording, or the single summary when there aren't enough beats
    /// for a series. Apple Watch writes ~30–90 discrete HRV samples per night
    /// (one per 5–15 min window); the series replicates that pattern, so the
    /// strap's night shows in the Health app as an overnight trend rather
    /// than one dot. Each sample spans the window it represents, matching
    /// Apple's convention.
    ///
    /// SDNN only. HealthKit has no RMSSD type, and RMSSD values written into
    /// `.heartRateVariabilitySDNN` (marked only by an `HRVMetric=RMSSD`
    /// metadata key) show up in the Health app and in every app that does not
    /// read that key as SDNN readings they are not. Guideline 5.1.3(ii)
    /// forbids writing inaccurate data into HealthKit; the replacement removes
    /// RMSSD samples with that key along with the rest.
    ///
    /// One replacement covers both shapes, so a session re-exported as the
    /// other shape, or under a changed end date, never keeps its old SDNN
    /// beside the new one, and a failed save leaves the earlier export in
    /// place.
    func exportHRV(session: HRVSession, result: HRVAnalysisResult) async throws {
        guard access.isAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN),
              let samples = Self.hrvExportSamples(
                  session: session, result: result, sdnnType: sdnnType, version: HealthExportIdentity.nextSyncVersion()
              ) else { return }
        try await sampleReplacer.replace(
            samples, hrvReplacement(sdnnType: sdnnType, sessionId: session.id, span: Self.hrvSearchSpan(session: session, samples: samples))
        )
    }

    /// What a session writes as HRV, or nil to leave Health as it is.
    ///
    /// With at least 30 beats (≈ 30 seconds at 60 bpm), so ANY recording long
    /// enough for one analysable window gets the full series, which is what
    /// Athlytic / Training Today integrators need. When no 5-minute window had
    /// enough clean beats, or the recording is shorter, the measured SDNN is
    /// the single summary, dated at the session's end. An estimated SDNN
    /// (`HRVAnalysisResult.estimatedMetrics`, from an Elite HRV summary) is
    /// never written: Health would show it as a reading. A series attempt that
    /// leaves nothing to write returns empty, which removes the earlier
    /// export; a short recording with nothing to write returns nil. Every
    /// sample carries `version` as its sync version.
    nonisolated static func hrvExportSamples(
        session: HRVSession, result: HRVAnalysisResult, sdnnType: HKQuantityType, version: Int
    ) -> [HKQuantitySample]? {
        let summary = result.measuredSDNN.flatMap { summarySDNNSample($0, session: session, sdnnType: sdnnType, version: version) }
        guard let points = session.rrSeries?.points, points.count >= 30 else { return summary.map { [$0] } }
        let (series, _) = windowedHRVSamples(
            rrPoints: points, sdnnType: sdnnType, sessionStart: session.startDate, sessionId: session.id, version: version
        )
        guard series.isEmpty else { return series }
        return summary.map { [$0] } ?? []
    }

    /// The single summary SDNN, at the session's end, under the session's
    /// `HealthExportIdentity` summary identity (`{uuid}-sdnn`). Nil, with a
    /// warning logged, for a non-finite value: passing NaN/Inf to HKQuantity
    /// raises an NSException Swift `throws` can't catch (`HealthSampleFactory`
    /// refuses one too).
    nonisolated private static func summarySDNNSample(
        _ value: Double, session: HRVSession, sdnnType: HKQuantityType, version: Int
    ) -> HKQuantitySample? {
        guard value.isFinite else {
            debugLog("[HealthKit] HRV export: refusing non-finite SDNN (\(value)) for session \(session.id.uuidString.prefix(8))", level: .warning)
            return nil
        }
        let date = session.endDate ?? session.startDate
        return HealthSampleFactory.quantitySample(
            type: sdnnType, value: value, unit: .secondUnit(with: .milli), start: date, end: date,
            metadata: HealthExportIdentity.metadata(HealthExportIdentity.summary(sessionId: session.id, metric: .sdnn), version: version)
        )
    }

    /// Where a session's earlier HRV export is searched for: both shapes'
    /// windows together. The series' window runs from an hour before the
    /// start to a day after it (or the new series' end, if later), so a
    /// re-analysis that trimmed the night still reaches the earlier tail;
    /// the summary's runs 25 hours either side of the end date, so a summary
    /// exported under a different end date is reached too.
    nonisolated static func hrvSearchSpan(session: HRVSession, samples: [HKQuantitySample]) -> DateInterval {
        let date = session.endDate ?? session.startDate
        let start = min(session.startDate.addingTimeInterval(-3600), date.addingTimeInterval(-25 * 3600))
        let end = max(
            samples.map(\.endDate).max() ?? session.startDate,
            session.startDate.addingTimeInterval(24 * 3600),
            date.addingTimeInterval(25 * 3600)
        )
        return DateInterval(start: start, end: end)
    }

    /// One replacement of the session's HRV samples: this app's SDNN samples
    /// in `span` that `isOurHRVExport` matches, under the session's key.
    private func hrvReplacement(sdnnType: HKQuantityType, sessionId: UUID, span: DateInterval) -> HealthSampleReplacement {
        HealthSampleReplacement(
            type: sdnnType, span: span, timeout: HealthKitAccess.vitalsQueryTimeoutSec,
            label: "HRV export", serialKey: sessionId.uuidString,
            matches: { Self.isOurHRVExport($0, sessionId: sessionId) },
            writeTimeout: HealthKitAccess.backgroundAggregateQueryTimeoutSec
        )
    }

    /// Walk the beat stream in fixed 5-minute windows, returning every sample
    /// built plus the count of windows that produced any. Windows are laid on
    /// each beat's `exportTimeMs` (the wall clock where the stream recorded
    /// one), so samples after a dropped stretch land at the time they were
    /// recorded rather than shifted early by the lost minutes.
    nonisolated private static func windowedHRVSamples(
        rrPoints: [RRPoint],
        sdnnType: HKQuantityType,
        sessionStart: Date,
        sessionId: UUID,
        version: Int
    ) -> ([HKQuantitySample], Int) {
        let windowSizeMs: Int64 = 5 * 60 * 1000 // 5 minutes
        let endMs = rrPoints.map(\.exportTimeMs).max() ?? 0
        var samples: [HKQuantitySample] = []
        var windowStart: Int64 = 0
        var windowIndex = 0
        while windowStart < endMs {
            let windowEnd = windowStart + windowSizeMs
            let windowPoints = rrPoints.filter { $0.exportTimeMs >= windowStart && $0.exportTimeMs < windowEnd }
            let slot = HRVSampleSlot(
                type: sdnnType, sessionStart: sessionStart, windowMs: (windowStart, windowEnd),
                sessionId: sessionId, index: windowIndex, version: version
            )
            if let built = hrvSamplesForWindow(windowPoints: windowPoints, slot: slot) {
                samples.append(contentsOf: built)
                windowIndex += 1
            }
            windowStart += windowSizeMs
        }
        return (samples, windowIndex)
    }

    /// The SDNN sample for one 5-minute window, or nil when the window is too
    /// sparse to represent. Beats outside the valid RR range are dropped, then
    /// the same local-median ectopic gate the in-app SDNN uses
    /// (`TimeDomainAnalyzer.filterEctopicBeats`), so a premature beat and its
    /// compensatory pause don't inflate the exported value.
    nonisolated private static func hrvSamplesForWindow(
        windowPoints: [RRPoint],
        slot: HRVSampleSlot
    ) -> [HKQuantitySample]? {
        guard windowPoints.count >= 10 else { return nil }
        let orderedRRs = windowPoints.map { Double($0.rr_ms) }
        let validMask = orderedRRs.map { HRVConstants.RRInterval.isValid(Int($0)) }
        let validRRs = TimeDomainAnalyzer.filterEctopicBeats(zip(orderedRRs, validMask).filter { $0.1 }.map { $0.0 })
        guard validRRs.count >= 8 else { return nil }
        return hrvSample(Statistics.sampleStandardDeviation(validRRs), metric: .sdnn, label: "SDNN", slot: slot).map { [$0] }
    }

    /// SDNN = standard deviation of NN intervals.
    ///
    /// Uses the SAME ectopic gate and sample SD (÷N-1) path as the canonical
    /// in-app SDNN. `TimeDomainAnalyzer` computes SDNN via
    /// `Statistics.sampleStandardDeviation` (÷N-1); an export using
    /// population variance (÷N) writes an SDNN to Apple Health that is
    /// systematically smaller than the value the app shows for the same window
    /// (the gap is largest on short windows). Routing the export through the
    /// same helper makes the exported number match the app.
    ///
    /// Non-finite values and backwards windows are skipped
    /// (`HealthSampleFactory`): HealthKit raises an uncatchable NSException
    /// for either, so dropping the window beats crashing.
    nonisolated private static func hrvSample(_ value: Double, metric: HealthExportIdentity.Metric, label: String, slot: HRVSampleSlot) -> HKQuantitySample? {
        HealthSampleFactory.quantitySample(
            type: slot.type,
            value: value,
            unit: .secondUnit(with: .milli),
            start: slot.start, end: slot.end,
            metadata: HealthExportIdentity.metadata(
                HealthExportIdentity.seriesMember(sessionId: slot.sessionId, metric: metric, index: slot.index),
                version: slot.version, ["HRVMetric": label]
            )
        )
    }

    /// Where one exported HRV sample lands: which HK type, which 5-minute
    /// slice, the session-scoped identity that makes the export idempotent,
    /// and the export's sync version.
    private struct HRVSampleSlot {
        let type: HKQuantityType
        let start: Date
        let end: Date
        let sessionId: UUID
        let index: Int
        let version: Int

        /// The slot of the window `windowMs` milliseconds into the recording.
        init(
            type: HKQuantityType, sessionStart: Date, windowMs: (start: Int64, end: Int64),
            sessionId: UUID, index: Int, version: Int
        ) {
            self.type = type
            start = sessionStart.addingTimeInterval(Double(windowMs.start) / 1000)
            end = sessionStart.addingTimeInterval(Double(windowMs.end) / 1000)
            self.sessionId = sessionId
            self.index = index
            self.version = version
        }
    }

    /// Delete every HRV sample this app exported for a session deleted
    /// forever. `start...end` is the recording's span; the search reaches 25
    /// hours past either end, which covers both export shapes (the summary is
    /// dated at the end, the series from an hour before the start). It runs
    /// as a replacement with nothing to save, so it waits for an export of
    /// the same session still running. Without HealthKit there is nothing to
    /// delete. Errors propagate, so the caller can say the samples are still
    /// in Health.
    func removeExportedHRV(sessionId: UUID, from start: Date, to end: Date) async throws {
        guard access.isAvailable, let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        let padding: TimeInterval = 25 * 3600
        let span = DateInterval(start: start.addingTimeInterval(-padding), end: end.addingTimeInterval(padding))
        try await sampleReplacer.replace([], hrvReplacement(sdnnType: sdnnType, sessionId: sessionId, span: span))
    }

    /// Whether an ExternalUUID is one of the session's HRV exports: the SDNN
    /// summary and series (`HealthExportIdentity`), the RMSSD series earlier
    /// builds wrote, or the bare session UUID earlier builds gave the single
    /// summary SDNN. Exact for the summaries, prefix for the series, so it
    /// never reaches another metric's samples.
    nonisolated static func isOurHRVExport(_ externalUUID: String, sessionId: UUID) -> Bool {
        externalUUID == sessionId.uuidString
            || HealthExportIdentity.belongsToSession(externalUUID, sessionId: sessionId, metric: .sdnn)
            || HealthExportIdentity.isSeriesMember(externalUUID, sessionId: sessionId, metric: .rmssd)
    }
}
