import Foundation
import HealthKit

// Sleep export, the per-session metric exports and the sleep observer:
// writing nights back to HealthKit and watching for new ones. Querying and
// estimating a single night lives in `HealthKitManager+Sleep.swift`.

extension HealthWriteAndObserve {
    // MARK: - Shared helpers

    /// HKSampleQuery hands back (results, error); exactly one is meaningful.
    nonisolated static func categoryResult(_ results: [HKSample]?, _ error: Error?) -> Result<[HKCategorySample], Error> {
        if let error { return .failure(error) }
        return .success(results as? [HKCategorySample] ?? [])
    }

    /// Mean efficiency of the nights whose wake was measured, or nil when none was.
    nonisolated static func averageMeasuredEfficiency(_ sleepData: [SleepData]) -> Double? {
        let measured = sleepData.compactMap(\.measuredSleepEfficiency)
        guard !measured.isEmpty else { return nil }
        return measured.reduce(0, +) / Double(measured.count)
    }

    // MARK: - Sleep Export

    /// Export sleep data to Apple Health as category samples.
    /// Creates one HKCategorySample per stage interval — asleep or awake only
    /// (see `hkSleepValue(for:)`) — plus an overall inBed sample spanning the
    /// night. The samples replace the session's earlier sleep export
    /// (`HealthSampleReplacer`, matched by the session's sleep identity, all
    /// dates searched): the new copy is saved before the earlier one is
    /// removed, and nothing valid to write leaves the earlier export in place.
    func exportSleepToHealthKit(sleepData: SleepData, sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sleepStart = sleepData.sleepStart, let sleepEnd = sleepData.sleepEnd else {
            debugLog("[HealthKitManager] No sleep boundaries to export")
            return
        }
        guard !sleepData.stageIntervals.isEmpty || sleepData.nightSleepMinutes > 0 else {
            debugLog("[HealthKitManager] No sleep data to export (empty)")
            return
        }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let samples = Self.sleepExportSamples(
            sleepData: sleepData, sleepType: sleepType, sessionId: sessionId,
            inBedStart: sleepData.inBedStart ?? sleepStart, sleepEnd: sleepEnd,
            version: HealthExportIdentity.nextSyncVersion()
        )
        guard !samples.isEmpty else { return }
        try await manager.sampleReplacer.replace(samples, Self.sleepReplacement(sleepType: sleepType, sessionId: sessionId))
    }

    /// Delete the sleep a session deleted forever exported: its sleep
    /// identity on any date, as an export replaces it, waiting for an export
    /// of the same session still running. Errors propagate.
    func removeExportedSleep(sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable, let sleepType = HKTypes.category(.sleepAnalysis) else { return }
        try await manager.sampleReplacer.replace([], Self.sleepReplacement(sleepType: sleepType, sessionId: sessionId))
    }

    /// One replacement of the session's sleep export: this app's sleep
    /// samples on any date carrying the session's sleep identity, under the
    /// session's key.
    private static func sleepReplacement(sleepType: HKCategoryType, sessionId: UUID) -> HealthSampleReplacement {
        HealthSampleReplacement(
            type: sleepType, span: nil, timeout: HeartRateHealthQueries.sleepQueryTimeoutSec,
            label: "sleep export", serialKey: sessionId.uuidString,
            matches: { HealthExportIdentity.belongsToSession($0, sessionId: sessionId, metric: .sleep) },
            writeTimeout: HeartRateHealthQueries.backgroundAggregateQueryTimeoutSec
        )
    }

    /// An overall inBed sample spanning the night, followed by one sample per
    /// stage interval. An interval that ends before it starts is left out
    /// (`HealthSampleFactory`), the inBed span included. Every sample carries
    /// `version` as its sync version.
    nonisolated static func sleepExportSamples(
        sleepData: SleepData,
        sleepType: HKCategoryType,
        sessionId: UUID,
        inBedStart: Date,
        sleepEnd: Date,
        version: Int
    ) -> [HKCategorySample] {
        let memberMetadata: (String) -> [String: Any] = {
            HealthExportIdentity.metadata(
                HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .sleep, suffix: $0), version: version
            )
        }
        let inBed = HealthSampleFactory.categorySample(
            type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: inBedStart, end: sleepEnd, metadata: memberMetadata("inbed")
        )
        let stages = sleepData.stageIntervals.enumerated().compactMap { index, interval in
            HealthSampleFactory.categorySample(
                type: sleepType, value: hkSleepValue(for: interval.stage).rawValue,
                start: interval.start, end: interval.end, metadata: memberMetadata(String(index))
            )
        }
        return (inBed.map { [$0] } ?? []) + stages
    }

    /// Every stage but awake is written as `.asleepUnspecified`.
    ///
    /// This export only runs on nights the app estimated from heart rate, and
    /// deep, core and REM there are a classifier's guess, not a measurement.
    /// Writing them as `.asleepDeep` / `.asleepREM` would put estimates into
    /// Health as if a sleep tracker had staged them, which Guideline
    /// 5.1.3(ii) forbids. Asleep-versus-awake is what the data supports.
    nonisolated private static func hkSleepValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        stage == .awake ? .awake : .asleepUnspecified
    }

    /// Delete ALL sleep samples this app has ever written to Apple Health,
    /// with or without an export identity. One-shot cleanup for polluted
    /// data. The read is bounded and fails closed: a stall throws rather than
    /// report "0 deleted" while the rows stay. Returns the number of samples
    /// deleted so the UI can report it to the user.
    @discardableResult
    func deleteAllAppWrittenSleepSamples() async throws -> Int {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let store = manager.sampleReplacer.store
        let existingSamples = try await store.ownSamples(
            of: sleepType, in: nil, timeout: HeartRateHealthQueries.sleepQueryTimeoutSec, label: "deleteAllAppWrittenSleepSamples"
        )
        guard !existingSamples.isEmpty else { return 0 }
        try await store.delete(existingSamples)
        debugLog("[HealthKitManager] Deleted \(existingSamples.count) app-written sleep sample(s) from Apple Health")
        return existingSamples.count
    }

    /// Export all enabled metrics from a completed session to Apple Health.
    /// Called automatically after session acceptance when HealthKit export is enabled.
    ///
    /// A session built from Apple Health data (`CloudSessionPayload
    /// .isHealthKitSourced`) writes nothing: its readings are already in
    /// Health, and a copy would carry Emuqu as their source.
    ///
    /// Each export is wrapped in its own do/catch so a failure in one metric
    /// (e.g., HealthKit permission denied for HR) does not block the others.
    /// A sequential `try await` chain lets a single failure stop all
    /// downstream exports, which shows up as a single data point in Apple
    /// Health.
    ///
    /// Every metric is attempted whatever the others did; afterwards the
    /// first failure is thrown, so the caller learns an export failed.
    func exportSessionMetrics(from session: HRVSession) async throws {
        guard let result = session.analysisResult, !CloudSessionPayload.isHealthKitSourced(session) else { return }
        let settings = manager.settingsProvider()
        var failures: [Error] = []
        if settings.exportSDNN, let error = await exportHRVMetrics(session: session, result: result) { failures.append(error) }
        if settings.exportHeartRate, let error = await exportHRMetrics(session: session, result: result) { failures.append(error) }
        if settings.exportRestingHeartRate, let error = await exportRHRMetric(session: session, result: result) { failures.append(error) }
        if settings.exportSleepData, let error = await exportSleepIfSoleSource(session: session) { failures.append(error) }
        if let first = failures.first { throw first }
    }

    /// HRV: windowed SDNN across the recording, or the single measured
    /// summary (`exportHRV`); HealthKit has no RMSSD type, so RMSSD is not
    /// written.
    private func exportHRVMetrics(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        do {
            try await exportHRV(session: session, result: result)
            return nil
        } catch {
            debugLog("[HealthKit Export] HRV export failed: \(error)")
            return error
        }
    }

    /// HR: minute-level discrete samples (`exportHeartRateSeries`), with the
    /// same lower threshold so even short sessions become a real series.
    private func exportHRMetrics(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        do {
            if let points = session.rrSeries?.points, points.count >= 30 {
                try await manager.heartRate.exportHeartRateSeries(from: points, sessionStart: session.startDate, sessionId: session.id)
            } else {
                let date = session.endDate ?? session.startDate
                try await manager.heartRate.exportHeartRate(value: result.timeDomain.meanHR, at: date, sessionId: session.id)
            }
            return nil
        } catch {
            debugLog("[HealthKit Export] HR export failed: \(error)")
            return error
        }
    }

    /// RHR: one per night, from the overnight reading only.
    ///
    /// Resting heart rate is an overnight measure: the median of a two-minute
    /// quick reading or a nap is a heart rate, not a resting heart rate, so
    /// those write none, and exporting one removes any resting heart rate
    /// already in Health under its identity. Health receives the whole
    /// night's median, not the analysis-window mean the app shows as the
    /// night's heart rate (Help: "from the strap's analysis window"), so the
    /// two can differ by a few beats per minute.
    ///
    /// Only the nocturnal median is written. The session minimum never stands
    /// in: a single lowest beat is not a resting heart rate by any definition,
    /// so a night without the median writes none.
    private func exportRHRMetric(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        let date = session.endDate ?? session.startDate
        do {
            guard let restingHR = Self.restingHeartRateToExport(session: session, result: result) else {
                try await manager.heartRate.removeExportedRestingHeartRate(at: date, sessionId: session.id)
                return nil
            }
            try await manager.heartRate.exportRestingHeartRate(value: restingHR, at: date, sessionId: session.id)
            return nil
        } catch {
            debugLog("[HealthKit Export] RHR export failed: \(error)")
            return error
        }
    }

    /// The resting heart rate a session writes to Health: an overnight
    /// reading's nocturnal median, or nil.
    nonisolated static func restingHeartRateToExport(session: HRVSession, result: HRVAnalysisResult) -> Double? {
        guard session.sessionType == .overnight else { return nil }
        return result.ansMetrics?.nocturnalMedianHR
    }

    /// Sleep export — strictly gated. We only write to Apple Health when WE are
    /// the sole source of truth: no Apple-native sleep samples existed for this
    /// night, the strap session was active, and we derived sleep from HR drop
    /// patterns. This covers the "forgot the Watch / don't own one" case where
    /// the app is filling a real gap.
    ///
    /// We do NOT write when:
    ///   - Watch already recorded sleep (boundarySource == .healthKit or
    ///     .hrValidated). Writing back would contaminate future reads by
    ///     stomping the Watch's authoritative boundaries with our
    ///     interpretation of them.
    ///   - Source is .recordingBounds (placeholder, no real detection).
    ///
    /// This is the only caller of `exportSleepToHealthKit`; the timeline
    /// editor does not export an edited night separately.
    ///
    /// The resolver's HR-estimated source is not proof on its own: a Watch
    /// read that timed out at wake (a busy store) also lands there. So the
    /// night is checked again right before writing, and a check that finds
    /// another source's sleep, or can't complete, skips the export.
    private func exportSleepIfSoleSource(session: HRVSession) async -> Error? {
        guard let sleepData = session.sleepSnapshot else { return nil }
        let weAreTheOnlySource =
            sleepData.boundarySource == .hrEstimated ||
            sleepData.boundarySource == .healthKitHREstimated
        guard weAreTheOnlySource, let start = sleepData.inBedStart ?? sleepData.sleepStart,
              let end = sleepData.sleepEnd, let sleepType = HKTypes.category(.sleepAnalysis) else { return nil }
        do {
            let otherSource = try await otherSourceWroteSleep(from: start, to: end, sleepType: sleepType)
            guard !otherSource else {
                debugLog("[HealthKit Export] Sleep export skipped: another source has recorded this night")
                return nil
            }
            try await exportSleepToHealthKit(sleepData: sleepData, sessionId: session.id)
            return nil
        } catch {
            debugLog("[HealthKit Export] Sleep export failed: \(error)")
            return error
        }
    }

    /// Whether another source (the Watch, the iPhone) has written sleep in
    /// `start...end`. Bounded and FAIL CLOSED: a timeout throws, so the export
    /// is skipped rather than written beside a night the store didn't return.
    private func otherSourceWroteSleep(from start: Date, to end: Date, sleepType: HKCategoryType) async throws -> Bool {
        let predicate = manager.sleepQueries.sleepReadExcludingOwnWrites(
            dateRange: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        )
        let samples = try await manager.heartRate.runBoundedThrowingQuery(
            timeout: HeartRateHealthQueries.sleepQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, results, error in
                    resolve(Self.categoryResult(results, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut("sleep export source check")) }
        )
        return !samples.isEmpty
    }

    // MARK: - Sleep Data Observer

    /// Start observing HealthKit for new sleep data (e.g., Apple Watch sync),
    /// through `HealthSampleWatch`: an observer query that background delivery
    /// wakes, reading what was added since the last read, across launches.
    /// Each time other sources' sleep samples arrive, `sleepDataVersion` is
    /// incremented so views can reactively re-fetch, the night's cache is
    /// warmed and the wake-triggered push is considered. Starting again
    /// replaces the running query and reads nothing twice: one read per
    /// anchor runs at a time, the next from the anchor it kept.
    func startObservingSleepData() {
        guard manager.isHealthKitAvailable else { return }
        stopObservingSleepData()
        guard let sleepType = HKTypes.category(.sleepAnalysis) else { return }
        let query = makeSleepObserverQuery(for: sleepType, owner: self)
        manager.sleepObserverQuery = query
        manager.healthStore.execute(query)
        // A failed registration (entitlement missing, access denied) means
        // the overnight cache warm and wake push only run while the app does.
        manager.healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { @Sendable success, error in
            guard !success else { return }
            debugLog("[SleepObserver] Background delivery for sleep was not enabled: \(error?.localizedDescription ?? "no error given")", level: .warning)
        }
    }

    /// The reference date is the latest sample END: a night is filed under
    /// the morning it ends on, and a start (even the median one) from before
    /// midnight resolved to the previous night. The app's own sleep exports
    /// never reach here (`HealthSampleWatch.othersSamples`) — they are not
    /// new data, and must not fire the wake push.
    fileprivate func handleSleepSamplesArrived(_ samples: [HKSample]) {
        let categorySamples = samples.compactMap { $0 as? HKCategorySample }
        guard let freshestEnd = categorySamples.map(\.endDate).max() else { return }
        scheduleSleepCacheWarm(referenceDate: freshestEnd)
        // Wake-triggered morning push. If the freshest sleep sample we just
        // received has an endDate inside the wake-detection window (last 90
        // min) and the scheduler hasn't already fired today, deliver the
        // morning push immediately instead of waiting for the fixed-time
        // fallback. Gating + freshness checks live inside the scheduler so all
        // observer fires can safely call this — repeated calls on the same
        // morning are cheap no-ops.
        Task { @MainActor in
            await AppDependencies.current.services.morningNotificationScheduler.deliverWakeTriggeredPushIfAppropriate(sleepEnd: freshestEnd)
        }
    }

    /// Warm the SleepDataCache for the night these samples belong to. The
    /// observer fires the moment Apple Watch syncs — often mid-night or within
    /// minutes of wake. Caching the processed SleepData here means the morning
    /// "I'm Up" path reads it instantly instead of burning the 30 s poll retry
    /// loop.
    ///
    /// Debounced. Apple Watch syncs in bursts; any in-flight
    /// warm task is cancelled so only the trailing batch's fetch lands. The
    /// short sleep before the actual fetch gives a window for the next observer
    /// fire to cancel us first.
    private func scheduleSleepCacheWarm(referenceDate: Date) {
        Task { @MainActor [weak manager] in
            manager?.writes.restartSleepCacheWarmTask(referenceDate: referenceDate)
        }
    }

    @MainActor
    private func restartSleepCacheWarmTask(referenceDate: Date) {
        manager.sleepCacheWarmTask?.cancel()
        manager.sleepCacheWarmTask = Task { @MainActor [weak manager] in
            await sleepQuietly(1_500_000_000, context: "restartSleepCacheWarmTask") // 1.5 s coalesce
            guard !Task.isCancelled, let manager else { return }
            await manager.writes.warmSleepCache(referenceDate: referenceDate)
        }
    }

    /// A locked phone (errorDatabaseInaccessible) or missing permissions leaves
    /// the cache as-is; the next observer fire after unlock will populate it.
    @MainActor
    private func warmSleepCache(referenceDate: Date) async {
        do {
            let data = try await manager.sleepQueries.fetchLastNightSleep(relativeTo: referenceDate)
            if data.nightSleepMinutes > 0 {
                SleepDataCache.write(data)
            }
        } catch {
            debugLog("[SleepObserver] cache warm fetch failed: \(error.localizedDescription)", level: .info)
        }
    }

    /// Stop observing sleep data.
    func stopObservingSleepData() {
        if let query = manager.sleepObserverQuery {
            manager.healthStore.stop(query)
            manager.sleepObserverQuery = nil
        }
    }
}

/// The query that watches for Watch-synced sleep samples
/// (`HealthSampleWatch`). Samples that arrived while the app was not
/// running, including on the background launch HealthKit makes for them,
/// are delivered when it starts.
///
/// HealthKit delivers on its own queue. The version bump and the sample
/// handling both touch main-actor state, so they share one hop — if
/// the bump hops and the handler does not, `sleepDataVersion`
/// can publish before the samples it is announcing have been processed.
@MainActor
private func makeSleepObserverQuery(
    for sleepType: HKCategoryType,
    owner: HealthWriteAndObserve
) -> HKObserverQuery {
    // The manager owns this query, so the handler holds the manager weakly and
    // rebuilds the (stateless) helper when it fires.
    HealthSampleWatch.observerQuery(
        for: sleepType, anchorKey: "HealthSampleWatch.sleepAnchor.v1", store: owner.manager.healthStore
    ) { [weak manager = owner.manager] samples in
        guard let manager else { return }
        Task { @MainActor in
            manager.sleepDataVersion += 1
            manager.writes.handleSleepSamplesArrived(samples)
        }
    }
}
