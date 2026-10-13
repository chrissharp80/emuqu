import Foundation
import HealthKit

// Sleep export, the per-session metric exports and the sleep observer:
// writing nights back to HealthKit and watching for new ones. Querying and
// estimating a single night lives in `HealthKitManager+Sleep.swift`. (The
// multi-night trend reader that gave the file its name had no caller and
// was removed.)

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
    /// night. Uses ExternalUUID metadata to allow idempotent re-writes
    /// (delete + re-create).
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
            inBedStart: sleepData.inBedStart ?? sleepStart, sleepEnd: sleepEnd
        )
        guard !samples.isEmpty else { return }
        try await replacePreviousSleepExport(with: samples, sessionId: sessionId, sleepType: sleepType)
    }

    /// The new copy is saved before the session's previous export is
    /// removed, and nothing valid to write (the caller's empty check) leaves
    /// the previous export in place: deleted first, a save that failed left
    /// the night out of Apple Health altogether.
    private func replacePreviousSleepExport(with samples: [HKCategorySample], sessionId: UUID, sleepType: HKCategoryType) async throws {
        let previous = try await previousSleepExport(sessionId: sessionId, sleepType: sleepType)
        try await manager.healthStore.save(samples)
        if !previous.isEmpty { try await manager.healthStore.delete(previous) }
    }

    /// An overall inBed sample spanning the night, followed by one sample per
    /// stage interval. An interval that ends before it starts is left out
    /// (`HealthSampleFactory`), the inBed span included.
    nonisolated static func sleepExportSamples(
        sleepData: SleepData,
        sleepType: HKCategoryType,
        sessionId: UUID,
        inBedStart: Date,
        sleepEnd: Date
    ) -> [HKCategorySample] {
        let member: (String) -> String = { HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .sleep, suffix: $0) }
        let inBed = HealthSampleFactory.categorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: inBedStart,
            end: sleepEnd,
            metadata: [HKMetadataKeyExternalUUID: member("inbed"), "Source": "Emuqu"]
        )
        let stages = sleepData.stageIntervals.enumerated().compactMap { index, interval in
            HealthSampleFactory.categorySample(
                type: sleepType,
                value: hkSleepValue(for: interval.stage).rawValue,
                start: interval.start,
                end: interval.end,
                metadata: [HKMetadataKeyExternalUUID: member(String(index)), "Source": "Emuqu"]
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

    /// Delete previously exported sleep samples for a session (enables idempotent re-writes).
    private func previousSleepExport(sessionId: UUID, sleepType: HKCategoryType) async throws -> [HKSample] {
        let existingSamples = try await appWrittenSleepSamples(
            sleepType: sleepType,
            predicate: HKQuery.predicateForObjects(from: HKSource.default()),
            label: "previousSleepExport dedup"
        )
        return existingSamples.filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return HealthExportIdentity.belongsToSession(uuid, sessionId: sessionId, metric: .sleep)
        }
    }

    /// Bounded, FAIL CLOSED: reads our prior exports so we can delete them
    /// before re-writing. Timing out to empty would skip the delete and
    /// duplicate exported sleep rows (or report "0 deleted" while leaving the
    /// rows in place), so a stall throws — as a query error already does here —
    /// rather than proceeding on no data.
    private func appWrittenSleepSamples(sleepType: HKCategoryType, predicate: NSPredicate, label: String) async throws -> [HKSample] {
        try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.sleepQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(
                    sampleType: sleepType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, results, error in
                    resolve(HealthKitManager.sampleResult(results, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut(label)) }
        )
    }

    /// Delete ALL sleep samples this app has ever written to Apple Health.
    /// One-shot cleanup for polluted data. Returns the number of samples
    /// deleted so the UI can report it to the user.
    @discardableResult
    func deleteAllAppWrittenSleepSamples() async throws -> Int {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let existingSamples = try await appWrittenSleepSamples(
            sleepType: sleepType,
            predicate: HKQuery.predicateForObjects(from: Set([HKSource.default()])),
            label: "deleteAllAppWrittenSleepSamples"
        )
        guard !existingSamples.isEmpty else { return 0 }
        try await manager.healthStore.delete(existingSamples)
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

    /// HRV: windowed SDNN samples across the recording (HealthKit has no RMSSD
    /// type, so RMSSD is not written), falling back to a single summary when
    /// there aren't enough beats for the series or no 5-minute window had
    /// enough clean beats to write — so a session never reaches Health with
    /// no HRV at all.
    ///
    /// Threshold: 30 RR points (≈ 30 seconds at 60 bpm). The previous 100
    /// threshold meant a sub-2-minute reading collapsed to a single point — and
    /// even some quick-streaming sessions where the strap dropped signal early.
    /// With 30, ANY recording long enough for one analysable window gets the
    /// full series in Apple Health, which is what the beta tester (and
    /// Athlytic / Training Today integrators) need.
    ///
    /// An estimated SDNN (`HRVAnalysisResult.estimatedMetrics`, from an
    /// Elite HRV summary) is never written as the summary: Health would show
    /// it as a reading.
    private func exportHRVMetrics(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        do {
            guard try await windowedHRVWritten(session) == 0, let sdnn = result.measuredSDNN else { return nil }
            let date = session.endDate ?? session.startDate
            try await exportSDNN(value: sdnn, at: date, sessionId: session.id)
            return nil
        } catch {
            debugLog("[HealthKit Export] HRV export failed: \(error)")
            return error
        }
    }

    /// The windowed SDNN series for a session with at least 30 beats; how
    /// many samples it wrote (0 when too short to try, or no window qualified).
    private func windowedHRVWritten(_ session: HRVSession) async throws -> Int {
        guard let points = session.rrSeries?.points, points.count >= 30 else { return 0 }
        return try await exportWindowedHRV(from: points, sessionStart: session.startDate, sessionId: session.id)
    }

    /// HR: minute-level discrete samples (`exportHeartRateSeries`), with the
    /// same lower threshold so even short sessions become a real series.
    private func exportHRMetrics(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        do {
            if let points = session.rrSeries?.points, points.count >= 30 {
                try await manager.exportHeartRateSeries(from: points, sessionStart: session.startDate, sessionId: session.id)
            } else {
                let date = session.endDate ?? session.startDate
                try await manager.exportHeartRate(value: result.timeDomain.meanHR, at: date, sessionId: session.id)
            }
            return nil
        } catch {
            debugLog("[HealthKit Export] HR export failed: \(error)")
            return error
        }
    }

    /// RHR: one per night, from the overnight reading only.
    ///
    /// The app's resting heart rate is the overnight one (Help: "Your
    /// overnight heart rate from the strap's analysis window"). The median of
    /// a two-minute quick reading or a nap is a heart rate, not a resting
    /// heart rate, so those write none, and exporting one removes any
    /// resting heart rate already in Health under its identity.
    ///
    /// Only the nocturnal median is written. The session minimum used to
    /// stand in when it was missing, and a single lowest beat is not a resting
    /// heart rate by any definition; a night without the median writes none.
    private func exportRHRMetric(session: HRVSession, result: HRVAnalysisResult) async -> Error? {
        let date = session.endDate ?? session.startDate
        do {
            guard let restingHR = Self.restingHeartRateToExport(session: session, result: result) else {
                try await manager.removeExportedRestingHeartRate(at: date, sessionId: session.id)
                return nil
            }
            try await manager.exportRestingHeartRate(value: restingHR, at: date, sessionId: session.id)
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
        let predicate = manager.sleepReadExcludingOwnWrites(
            dateRange: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        )
        let samples = try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.sleepQueryTimeoutSec,
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

    /// Start observing HealthKit for new sleep data (e.g., Apple Watch sync).
    /// Each time new sleep samples arrive, `sleepDataVersion` is incremented
    /// so views can reactively re-fetch.
    func startObservingSleepData() {
        guard manager.isHealthKitAvailable else { return }
        stopObservingSleepData()
        guard let sleepType = HKTypes.category(.sleepAnalysis) else { return }
        let query = makeSleepObserverQuery(for: sleepType, owner: self)
        manager.sleepObserverQuery = query
        manager.healthStore.execute(query)
        // A failed registration (entitlement missing, access denied) means
        // the overnight cache warm and wake push only run while the app does.
        manager.healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { success, error in
            guard !success else { return }
            debugLog("[SleepObserver] Background delivery for sleep was not enabled: \(error?.localizedDescription ?? "no error given")", level: .warning)
        }
    }

    /// The reference date is the latest sample END: a night is filed under
    /// the morning it ends on, and a start (even the median one) from before
    /// midnight resolved to the previous night. The app's own sleep exports
    /// are ignored — they are not new data, and must not fire the wake push.
    fileprivate func handleSleepSamplesArrived(_ samples: [HKSample]) {
        let ownSource = HKSource.default()
        let categorySamples = samples.compactMap { $0 as? HKCategorySample }
            .filter { $0.sourceRevision.source != ownSource }
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
            let data = try await manager.fetchLastNightSleep(relativeTo: referenceDate)
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

/// The anchored query that watches for Watch-synced sleep samples.
///
/// Bounded to samples from the last two days, like the vitals observers: with
/// no predicate, the initial results were every sleep sample ever recorded,
/// read and discarded each time observation started. A night syncing late is
/// dated inside that window, and so is everything written later.
///
/// HealthKit delivers on its own queue. The version bump and the sample
/// handling both touch main-actor state, so they share one hop — if
/// the bump hops and the handler does not, `sleepDataVersion`
/// can publish before the samples it is announcing have been processed.
private func makeSleepObserverQuery(
    for sleepType: HKCategoryType,
    owner: HealthWriteAndObserve
) -> HKAnchoredObjectQuery {
    let recent = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-48 * 60 * 60), end: nil, options: [])
    let query = HKAnchoredObjectQuery(
        type: sleepType, predicate: recent, anchor: nil,
        limit: HKObjectQueryNoLimit
    ) { _, _, _, _, _ in
        // Initial results — nothing to do
    }
    // The manager owns this query, so the handler holds the manager weakly and
    // rebuilds the (stateless) helper when it fires.
    // The app's own sleep exports are not new data: filtered before the
    // version bump, so they do not set off a re-fetch of today's sleep.
    query.updateHandler = { [weak manager = owner.manager] _, newSamples, _, _, _ in
        let ownSource = HKSource.default()
        guard let manager, let samples = newSamples?.filter({ $0.sourceRevision.source != ownSource }), !samples.isEmpty else { return }
        Task { @MainActor in
            manager.sleepDataVersion += 1
            manager.writes.handleSleepSamplesArrived(samples)
        }
    }
    return query
}
