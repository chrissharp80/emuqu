import Foundation
import HealthKit

// Sleep trends and export: aggregating nights and writing them back to
// HealthKit. Querying and estimating a single night lives in
// `HealthKitManager+Sleep.swift`.

extension HealthWriteAndObserve {
    // MARK: - Sleep Trends

    /// Fetch sleep data for the past N days
    /// - Parameters:
    ///   - days: Number of days to look back (default 7)
    ///   - referenceDate: Anchor date to look back from. Defaults to now.
    ///     For historical sessions, pass the session date to get trends from that time.
    /// - Returns: Array of SleepData for each night, sorted newest first
    ///
    /// Uses the same processing pipeline as fetchSleepData and fetchLastNightSleep:
    /// source dedup → session grouping → overlap merge → split-night detection → assembly.
    func fetchSleepTrend(days: Int = 7, relativeTo referenceDate: Date = Date()) async throws -> [SleepData] {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let allSamples = try await trendSamples(sleepType: sleepType, days: days, referenceDate: referenceDate)
        // Each night becomes one row-3 resolve: no session, watch-only.
        let nights = Self.byNight(allSamples).map { nightDate, nightSamples in
            (nightDate, nightContext(nightDate: nightDate, nightSamples: nightSamples))
        }
        // One resolve per night — detached, because this type is main-actor
        // isolated.
        let results = await Task.detached(priority: .userInitiated) {
            nights.map { nightDate, context in Self.redated(SleepResolver.resolve(context).sleepData, to: nightDate) }
        }.value
        return results.sorted { $0.date > $1.date }
    }

    /// Samples bucketed by biological night, anchored on each sample's end date.
    nonisolated private static func byNight(_ samples: [HKCategorySample]) -> [Date: [HKCategorySample]] {
        let calendar = Calendar.current
        return Dictionary(grouping: samples) { calendar.startOfDay(for: $0.endDate) }
    }

    /// No `.strictStartDate` for the trend window read.
    /// Samples are re-bucketed by biological night by the caller and
    /// each night is clipped to its bedtime window by the resolver, so
    /// including a stage that started before the window opened recovers the
    /// first stage of a night without mis-assigning it.
    ///
    /// Bounded, FAIL OPEN: a stalled read degrades to an empty trend rather
    /// than throwing, matching the "no samples in the window" path — a trend
    /// chart is informational and must not break the screen it sits on.
    private func trendSamples(sleepType: HKCategoryType, days: Int, referenceDate: Date) async throws -> [HKCategorySample] {
        let endDate = min(referenceDate, Date())
        // Calendar.date(byAdding:) is optional; fall back
        // to endDate to make the window empty rather than crash.
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) ?? endDate
        let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        let predicate = manager.sleepReadExcludingOwnWrites(dateRange: datePredicate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.sleepQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(
                    sampleType: sleepType, predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]
                ) { _, results, error in
                    resolve(Self.categoryResult(results, error))
                }
            },
            onTimeout: { .success([]) }
        )
    }

    /// HKSampleQuery hands back (results, error); exactly one is meaningful.
    nonisolated static func categoryResult(_ results: [HKSample]?, _ error: Error?) -> Result<[HKCategorySample], Error> {
        if let error { return .failure(error) }
        return .success(results as? [HKCategorySample] ?? [])
    }

    /// The resolver input for one night. The caller re-dates each result to
    /// the calendar night so trend grouping stays consistent.
    private func nightContext(nightDate: Date, nightSamples: [HKCategorySample]) -> SleepResolver.Context {
        let config = SleepMergingConfig.defaultProcessing()
        return SleepResolver.Context(
            sessionBounds: nil,
            linkedSessionBounds: [],
            watchSamples: nightSamples,
            rrPoints: [],
            bedtimeWindow: DateInterval(
                start: manager.sleepSchedule.overnightWindowStart(relativeTo: nightDate),
                end: manager.sleepSchedule.overnightWindowEnd(relativeTo: nightDate)
            ),
            enhanceWithRR: false,
            autoSleepExtension: nil,
            fallbackDate: nightDate,
            splitGapMinutes: config.awakeGapSplitMinutes
        )
    }

    nonisolated private static func redated(_ resolved: SleepData, to nightDate: Date) -> SleepData {
        SleepData(
            date: nightDate,
            inBedStart: resolved.inBedStart,
            sleepStart: resolved.sleepStart,
            sleepEnd: resolved.sleepEnd,
            totalSleepMinutes: resolved.nightSleepMinutes,
            inBedMinutes: resolved.inBedMinutes,
            deepSleepMinutes: resolved.deepSleepMinutes,
            remSleepMinutes: resolved.remSleepMinutes,
            awakeMinutes: resolved.awakeMinutes,
            sleepEfficiency: resolved.sleepEfficiency,
            boundarySource: resolved.boundarySource,
            segments: resolved.segments,
            stageIntervals: resolved.stageIntervals,
            boundaryValidation: nil,
            hrSleepQuality: nil,
            splitGapMinutes: resolved.splitGapMinutes
        )
    }

    /// Analyze sleep trends from recent data
    func analyzeSleepTrend(from sleepData: [SleepData]) -> SleepTrendStats {
        guard sleepData.count >= 2 else {
            return SleepTrendStats(
                averageSleepMinutes: sleepData.first.map { Double($0.nightSleepMinutes) } ?? 0,
                averageDeepSleepMinutes: sleepData.first?.deepSleepMinutes.map { Double($0) },
                averageEfficiency: sleepData.first?.sleepEfficiency ?? 0,
                trend: .insufficient,
                nightsAnalyzed: sleepData.count
            )
        }
        let deepValues = sleepData.compactMap(\.deepSleepMinutes)
        return SleepTrendStats(
            averageSleepMinutes: sleepData.map { Double($0.nightSleepMinutes) }.reduce(0, +) / Double(sleepData.count),
            averageDeepSleepMinutes: deepValues.isEmpty ? nil : Double(deepValues.reduce(0, +)) / Double(deepValues.count),
            averageEfficiency: sleepData.map(\.sleepEfficiency).reduce(0, +) / Double(sleepData.count),
            trend: Self.sleepTrendDirection(sleepData),
            nightsAnalyzed: sleepData.count
        )
    }

    /// Direction from comparing the first half against the second half (newer
    /// vs older — `sleepData` is newest-first). ±10 % is the band that reads as
    /// "stable".
    nonisolated private static func sleepTrendDirection(_ sleepData: [SleepData]) -> SleepTrendStats.SleepTrend {
        let midpoint = sleepData.count / 2
        let newerHalf = Array(sleepData.prefix(midpoint))
        let olderHalf = Array(sleepData.suffix(from: midpoint))
        let newerAvg = newerHalf.map { Double($0.nightSleepMinutes) }.reduce(0, +) / Double(max(1, newerHalf.count))
        let olderAvg = olderHalf.map { Double($0.nightSleepMinutes) }.reduce(0, +) / Double(max(1, olderHalf.count))
        let changePct = olderAvg > 0 ? ((newerAvg - olderAvg) / olderAvg) * 100 : 0
        if changePct > 10 { return .improving }
        if changePct < -10 { return .declining }
        return .stable
    }

    // MARK: - Sleep Export

    /// Export sleep data to Apple Health as category samples.
    /// Creates one HKCategorySample per stage interval using the detailed stage breakdown
    /// (deep, core, REM, awake). Also writes an overall inBed sample spanning sleep start to end.
    /// Uses ExternalUUID metadata to allow idempotent re-writes (delete + re-create).
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
        // Delete any previously written samples for this session (idempotent re-write)
        try await deletePreviousSleepExport(sessionId: sessionId)
        let samples = Self.sleepExportSamples(
            sleepData: sleepData, sleepType: sleepType, sessionId: sessionId,
            inBedStart: sleepData.inBedStart ?? sleepStart, sleepEnd: sleepEnd
        )
        try await manager.healthStore.save(samples)
    }

    /// An overall inBed sample spanning the night, followed by one sample per
    /// stage interval.
    nonisolated private static func sleepExportSamples(
        sleepData: SleepData,
        sleepType: HKCategoryType,
        sessionId: UUID,
        inBedStart: Date,
        sleepEnd: Date
    ) -> [HKCategorySample] {
        let member: (String) -> String = { HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .sleep, suffix: $0) }
        var samples = [HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: inBedStart,
            end: sleepEnd,
            metadata: [HKMetadataKeyExternalUUID: member("inbed"), "Source": "Emuqu"]
        )]
        for (index, interval) in sleepData.stageIntervals.enumerated() {
            samples.append(HKCategorySample(
                type: sleepType,
                value: hkSleepValue(for: interval.stage).rawValue,
                start: interval.start,
                end: interval.end,
                metadata: [HKMetadataKeyExternalUUID: member(String(index)), "Source": "Emuqu"]
            ))
        }
        return samples
    }

    /// Pre-iOS-16 HealthKit has no per-stage asleep values, so everything but
    /// awake collapses to the generic `.asleep`.
    nonisolated private static func hkSleepValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        guard #available(iOS 16.0, *) else {
            return stage == .awake ? .awake : .asleep
        }
        switch stage {
        case .deep: return .asleepDeep
        case .core: return .asleepCore
        case .rem: return .asleepREM
        case .awake: return .awake
        case .unspecified: return .asleepUnspecified
        }
    }

    /// Delete previously exported sleep samples for a session (enables idempotent re-writes).
    func deletePreviousSleepExport(sessionId: UUID) async throws {
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }

        let existingSamples = try await appWrittenSleepSamples(
            sleepType: sleepType,
            predicate: HKQuery.predicateForObjects(from: HKSource.default()),
            label: "deletePreviousSleepExport dedup"
        )
        let toDelete = existingSamples.filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return HealthExportIdentity.belongsToSession(uuid, sessionId: sessionId, metric: .sleep)
        }
        if !toDelete.isEmpty {
            try await manager.healthStore.delete(toDelete)
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
    /// Each export is wrapped in its own do/catch so a failure in one metric
    /// (e.g., HealthKit permission denied for HR) does not block the others.
    /// A sequential `try await` chain lets a single failure stop all
    /// downstream exports, which shows up as a single data point in Apple
    /// Health.
    func exportSessionMetrics(from session: HRVSession) async throws {
        guard let result = session.analysisResult else { return }
        let settings = manager.settingsProvider()
        if settings.exportSDNN { await exportHRVMetrics(session: session, result: result) }
        if settings.exportHeartRate { await exportHRMetrics(session: session, result: result) }
        if settings.exportRestingHeartRate { await exportRHRMetric(session: session, result: result) }
        if settings.exportSleepData { await exportSleepIfSoleSource(session: session) }
    }

    /// HRV: windowed SDNN+RMSSD samples across the recording, falling back to a
    /// single summary only when there literally aren't enough beats for one
    /// 5-min window.
    ///
    /// Threshold: 30 RR points (≈ 30 seconds at 60 bpm). The previous 100
    /// threshold meant a sub-2-minute reading collapsed to a single point — and
    /// even some quick-streaming sessions where the strap dropped signal early.
    /// With 30, ANY recording long enough for one analysable window gets the
    /// full series in Apple Health, which is what the beta tester (and
    /// Athlytic / Training Today integrators) need.
    private func exportHRVMetrics(session: HRVSession, result: HRVAnalysisResult) async {
        do {
            if let points = session.rrSeries?.points, points.count >= 30 {
                try await exportWindowedHRV(from: points, sessionStart: session.startDate, sessionId: session.id)
            } else {
                let date = session.endDate ?? session.startDate
                try await exportSDNN(value: result.timeDomain.sdnn, at: date, sessionId: session.id)
            }
        } catch {
            debugLog("[HealthKit Export] HRV export failed: \(error)")
        }
    }

    /// HR: minute-level series via HKQuantitySeriesSampleBuilder, with the same
    /// lower threshold so even short sessions become a real series.
    private func exportHRMetrics(session: HRVSession, result: HRVAnalysisResult) async {
        do {
            if let points = session.rrSeries?.points, points.count >= 30 {
                try await manager.exportHeartRateSeries(from: points, sessionStart: session.startDate, sessionId: session.id)
            } else {
                let date = session.endDate ?? session.startDate
                try await manager.exportHeartRate(value: result.timeDomain.meanHR, at: date, sessionId: session.id)
            }
        } catch {
            debugLog("[HealthKit Export] HR export failed: \(error)")
        }
    }

    /// RHR: one per day (matches Apple Watch convention).
    private func exportRHRMetric(session: HRVSession, result: HRVAnalysisResult) async {
        do {
            let date = session.endDate ?? session.startDate
            let restingHR = result.ansMetrics?.nocturnalMedianHR ?? result.timeDomain.minHR
            try await manager.exportRestingHeartRate(value: restingHR, at: date, sessionId: session.id)
        } catch {
            debugLog("[HealthKit Export] RHR export failed: \(error)")
        }
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
    ///   - User explicitly edited via timeline editor (sleepUserAdjusted) —
    ///     that edit round-trips via `exportSleepToHealthKit` directly from the
    ///     editor flow, not from here.
    private func exportSleepIfSoleSource(session: HRVSession) async {
        guard let sleepData = session.sleepSnapshot else { return }
        let weAreTheOnlySource =
            sleepData.boundarySource == .hrEstimated ||
            sleepData.boundarySource == .healthKitHREstimated
        guard weAreTheOnlySource else { return }
        do {
            try await exportSleepToHealthKit(sleepData: sleepData, sessionId: session.id)
        } catch {
            debugLog("[HealthKit Export] Sleep export failed: \(error)")
        }
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
        manager.healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { _, _ in
        }
    }

    /// Pick the median sample time as the reference date so a single straggling
    /// stage entry doesn't reroute the cache to the wrong night. Categories the
    /// cache pipeline can't process are skipped.
    fileprivate func handleSleepSamplesArrived(_ samples: [HKSample]) {
        let categorySamples = samples.compactMap { $0 as? HKCategorySample }
        guard !categorySamples.isEmpty else { return }
        let referenceDate = categorySamples[categorySamples.count / 2].startDate
        scheduleSleepCacheWarm(referenceDate: referenceDate)
        // Wake-triggered morning push. If the freshest sleep sample we just
        // received has an endDate inside the wake-detection window (last 90
        // min) and the scheduler hasn't already fired today, deliver the
        // morning push immediately instead of waiting for the fixed-time
        // fallback. Gating + freshness checks live inside the scheduler so all
        // observer fires can safely call this — repeated calls on the same
        // morning are cheap no-ops.
        let freshestEnd = categorySamples.map(\.endDate).max() ?? referenceDate
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
/// HealthKit delivers on its own queue. The version bump and the sample
/// handling both touch main-actor state, so they share one hop — if
/// the bump hops and the handler does not, `sleepDataVersion`
/// can publish before the samples it is announcing have been processed.
private func makeSleepObserverQuery(
    for sleepType: HKCategoryType,
    owner: HealthWriteAndObserve
) -> HKAnchoredObjectQuery {
    let query = HKAnchoredObjectQuery(
        type: sleepType, predicate: nil, anchor: nil,
        limit: HKObjectQueryNoLimit
    ) { _, _, _, _, _ in
        // Initial results — nothing to do
    }
    // The manager owns this query, so the handler holds the manager weakly and
    // rebuilds the (stateless) helper when it fires.
    query.updateHandler = { [weak manager = owner.manager] _, newSamples, _, _, _ in
        guard let manager, let samples = newSamples, !samples.isEmpty else { return }
        Task { @MainActor in
            manager.sleepDataVersion += 1
            manager.writes.handleSleepSamplesArrived(samples)
        }
    }
    return query
}
