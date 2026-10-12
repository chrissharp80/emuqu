import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

extension HealthWriteAndObserve {
    // MARK: - SDNN Export

    /// Export SDNN (Standard Deviation of NN intervals) to Apple Health
    /// Uses the standard heartRateVariabilitySDNN type to match Apple Watch HRV format
    ///
    /// Validates the value BEFORE constructing HKQuantity. Passing
    /// NaN/Inf to HKQuantity raises NSInvalidArgumentException, which Swift
    /// `throws` can't catch. SDNN comes from RR analysis and CAN be NaN if the
    /// filter window produced no valid intervals.
    ///
    /// The sample carries the session's `HealthExportIdentity` summary
    /// identity (`{uuid}-sdnn`). Every HRV sample the session wrote before —
    /// by either export path, under either identity — is deleted first
    /// (`deleteOurHRVSamples`), over a day either side of `date` so an export
    /// made under a different end date is reached too.
    func exportSDNN(value: Double, at date: Date, sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard value.isFinite else {
            debugLog("[HealthKit] exportSDNN: refusing non-finite value (\(value)) for session \(sessionId.uuidString.prefix(8))", level: .warning)
            return
        }
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        try await deleteOurHRVSamples(sessionId: sessionId, from: date.addingTimeInterval(-25 * 3600), to: date.addingTimeInterval(25 * 3600))
        let sample = HealthSampleFactory.quantitySample(
            type: sdnnType, value: value, unit: .secondUnit(with: .milli), start: date, end: date,
            metadata: [HKMetadataKeyExternalUUID: HealthExportIdentity.summary(sessionId: sessionId, metric: .sdnn), "Source": "Emuqu"]
        )
        guard let sample else { return }
        try await manager.healthStore.save(sample)
    }

    // MARK: - Windowed HRV Export

    /// Export SDNN in 5-minute rolling windows across the session.
    ///
    /// Apple Watch writes ~30–90 discrete HRV samples per night (one per
    /// 5–15 min window). This replicates that pattern so the chest-strap data
    /// appears as a full overnight trend in the Health app, instead of a single
    /// invisible dot. Each sample's `startDate…endDate` spans the 5-min window
    /// it represents, matching Apple's convention.
    ///
    /// SDNN only. HealthKit has no RMSSD type, and RMSSD values written into
    /// `.heartRateVariabilitySDNN` (as earlier builds did, marked only by an
    /// `HRVMetric=RMSSD` metadata key) show up in the Health app and in every
    /// app that does not read that key as SDNN readings they are not.
    /// Guideline 5.1.3(ii) forbids writing inaccurate data into HealthKit. The
    /// re-export below deletes those old RMSSD samples along with the rest.
    ///
    /// This function is idempotent across re-export (e.g. after reanalysis):
    /// every sample we wrote previously for this session is deleted first via
    /// the `HKMetadataKeyExternalUUID` prefix predicate, then the fresh series
    /// is written. Without that, reanalysis would silently double-write — old
    /// + new samples coexisting in Health for the same windows. The cleanup
    /// also removes a single summary SDNN an earlier export wrote for the
    /// session, so the two paths never leave both.
    /// `internal` so HealthKitManager+SleepTrends.swift's `exportSessionMetrics`
    /// can call this across files.
    ///
    /// Returns how many samples were written: 0 when no 5-minute window had
    /// enough clean beats, so the caller can write the single summary instead.
    @discardableResult
    func exportWindowedHRV(
        from rrPoints: [RRPoint],
        sessionStart: Date,
        sessionId: UUID
    ) async throws -> Int {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return 0 }
        let (samples, windowCount) = Self.windowedHRVSamples(
            rrPoints: rrPoints, sdnnType: sdnnType, sessionStart: sessionStart, sessionId: sessionId
        )
        // A failed cleanup aborts the export (the caller logs it): writing
        // anyway would add a second copy of the night beside the first. The
        // span is padded like the HR cleanup: a re-analysis that trimmed the
        // night must still reach the earlier export's tail.
        let cleanupEnd = max(samples.last?.endDate ?? sessionStart, sessionStart.addingTimeInterval(24 * 3600))
        try await deleteOurHRVSamples(sessionId: sessionId, from: sessionStart.addingTimeInterval(-3600), to: cleanupEnd)
        guard !samples.isEmpty else { return 0 }
        try await manager.healthStore.save(samples)
        debugLog("[HealthKit Export] Wrote \(samples.count) windowed SDNN samples across \(windowCount) windows")
        return samples.count
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
        sessionId: UUID
    ) -> ([HKQuantitySample], Int) {
        let windowSizeMs: Int64 = 5 * 60 * 1000 // 5 minutes
        let endMs = rrPoints.map(\.exportTimeMs).max() ?? 0
        var samples: [HKQuantitySample] = []
        var windowStart: Int64 = 0
        var windowIndex = 0
        while windowStart < endMs {
            let windowEnd = windowStart + windowSizeMs
            let windowPoints = rrPoints.filter { $0.exportTimeMs >= windowStart && $0.exportTimeMs < windowEnd }
            if let built = hrvSamplesForWindow(
                windowPoints: windowPoints, sdnnType: sdnnType, sessionStart: sessionStart,
                sessionId: sessionId, windowStartMs: windowStart, windowEndMs: windowEnd,
                windowIndex: windowIndex
            ) {
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
        sdnnType: HKQuantityType,
        sessionStart: Date,
        sessionId: UUID,
        windowStartMs: Int64,
        windowEndMs: Int64,
        windowIndex: Int
    ) -> [HKQuantitySample]? {
        guard windowPoints.count >= 10 else { return nil }
        let orderedRRs = windowPoints.map { Double($0.rr_ms) }
        let validMask = orderedRRs.map { HRVConstants.RRInterval.isValid(Int($0)) }
        let validRRs = TimeDomainAnalyzer.filterEctopicBeats(zip(orderedRRs, validMask).filter { $0.1 }.map { $0.0 })
        guard validRRs.count >= 8 else { return nil }
        let sampleStart = sessionStart.addingTimeInterval(Double(windowStartMs) / 1000)
        let sampleEnd = sessionStart.addingTimeInterval(Double(windowEndMs) / 1000)
        let slot = HRVSampleSlot(
            type: sdnnType, start: sampleStart, end: sampleEnd,
            sessionId: sessionId, index: windowIndex
        )
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
            metadata: [
                HKMetadataKeyExternalUUID: HealthExportIdentity.seriesMember(sessionId: slot.sessionId, metric: metric, index: slot.index),
                "Source": "Emuqu",
                "HRVMetric": label
            ]
        )
    }

    /// Where one exported HRV sample lands: which HK type, which 5-minute
    /// slice, and the session-scoped identity that makes the export idempotent.
    private struct HRVSampleSlot {
        let type: HKQuantityType
        let start: Date
        let end: Date
        let sessionId: UUID
        let index: Int
    }

    /// Delete every HRV sample this app wrote for the session in
    /// `start...end` (`isOurHRVExport`): the summary SDNN, the SDNN series and
    /// the old RMSSD series, among this app's own samples only, so samples
    /// written by Apple Watch or other apps are never touched. Both export
    /// paths call it, so a session re-exported through the other path, or
    /// under a changed end date, does not keep its old SDNN beside the new
    /// one. Errors propagate: the caller skips the save rather than
    /// duplicate the night.
    private func deleteOurHRVSamples(sessionId: UUID, from start: Date, to end: Date) async throws {
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        let samples = try await ownExternalUUIDSDNNSamples(sdnnType: sdnnType, start: start, end: end)
        let mine = samples.filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return Self.isOurHRVExport(uuid, sessionId: sessionId)
        }
        guard !mine.isEmpty else { return }
        try await manager.healthStore.delete(mine)
        debugLog("[HealthKit Export] Re-export idempotency: deleted \(mine.count) prior HRV samples for session \(sessionId.uuidString.prefix(8))")
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

    /// This app's SDNN samples carrying an ExternalUUID in `start...end`.
    ///
    /// Bounded, FAIL CLOSED (dedup-before-delete for re-export idempotency):
    /// an empty result on timeout would skip the delete and let duplicates
    /// accumulate, so a stall throws (as a query error already does here).
    private func ownExternalUUIDSDNNSamples(sdnnType: HKQuantityType, start: Date, end: Date) async throws -> [HKQuantitySample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
            HKQuery.predicateForObjects(from: Set([HKSource.default()])),
            HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        ])
        return try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.vitalsQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(
                    sampleType: sdnnType, predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: nil
                ) { _, samples, error in
                    resolve(HealthKitManager.quantityResult(samples, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut("deleteOurSDNNSamples")) }
        )
    }
}
