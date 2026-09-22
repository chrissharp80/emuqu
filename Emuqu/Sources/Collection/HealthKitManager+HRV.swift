import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

// MARK: - Apple Watch Breathe App HRV + SDNN export

extension HealthWriteAndObserve {
    /// Start observing HealthKit for a completed Apple Watch Breathe session.
    ///
    /// Uses `HKAnchoredObjectQuery` on both `mindfulSession` and `heartRateVariabilitySDNN`.
    /// The anchored query's `updateHandler` fires immediately when new samples arrive in
    /// HealthKit — no polling needed. Background delivery is enabled so detection works
    /// even when the app is backgrounded.
    ///
    /// - Parameter onNewReading: Called on the main actor when a Breathe session is detected
    func startObservingBreatheHRV(onNewReading: @escaping (HealthKitManager.BreatheHRVReading) -> Void) {
        guard manager.isHealthKitAvailable else { return }
        stopObservingBreatheHRV()
        let listenStart = Date()
        manager.breatheListenStartDate = listenStart
        manager.breatheCallback = onNewReading
        manager.breatheDetected = false
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        manager.healthStore.execute(baselineSDNNSnapshotQuery(sdnnType: sdnnType, listenStart: listenStart))
    }

    /// Snapshot the current latest SDNN UUID so we can detect new ones.
    ///
    /// Deliberately NOT routed through the bounded-query wrapper.
    /// This baseline snapshot MUST complete before `setupBreatheObservers`
    /// starts the anchored observers; if a timeout nulled the baseline, the
    /// first pre-existing SDNN sample would read as "new" and fire a false
    /// Breathe detection. It's a one-shot `limit: 1` latest-sample read (near
    /// instant) run off the UI path at observer setup, so leaving it unbounded
    /// is correct — preserving the "baseline before observers" invariant.
    private func baselineSDNNSnapshotQuery(sdnnType: HKQuantityType, listenStart: Date) -> HKSampleQuery {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return HKSampleQuery(sampleType: sdnnType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak manager] _, samples, _ in
            guard let manager else { return }
            let uuid = samples?.first?.uuid
            Task { @MainActor in
                manager.baselineSDNNSampleUUID = uuid
                manager.writes.setupBreatheObservers(listenStart: listenStart)
            }
        }
    }

    /// Configure HKAnchoredObjectQuery on mindfulSession and SDNN. The update handlers
    /// fire immediately when new samples land in HealthKit — no polling needed.
    private func setupBreatheObservers(listenStart: Date) {
        guard let mindfulType = HKTypes.category(.mindfulSession),
              let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN)
        else { return }
        let sdnnQuery = breatheAnchoredQuery(type: sdnnType, listenStart: listenStart)
        let mindfulQuery = breatheAnchoredQuery(type: mindfulType, listenStart: listenStart)
        manager.breatheObserverQueries = [sdnnQuery, mindfulQuery]
        manager.healthStore.execute(sdnnQuery)
        manager.healthStore.execute(mindfulQuery)
        // Enable background delivery so update handlers fire even when the app is backgrounded
        manager.healthStore.enableBackgroundDelivery(for: mindfulType, frequency: .immediate) { _, _ in
        }
        manager.healthStore.enableBackgroundDelivery(for: sdnnType, frequency: .immediate) { _, _ in
        }
        startBreathePollTimer(listenStart: listenStart)
        // One immediate check in case data already synced before queries were set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak manager] in
            manager?.writes.checkForBreatheCompletion(since: listenStart)
        }
    }

    /// Anchored query whose `updateHandler` fires the instant a new sample of
    /// this type arrives. The initial-results handler is a no-op — the baseline
    /// was already captured via the snapshot query.
    private func breatheAnchoredQuery(type: HKSampleType, listenStart: Date) -> HKAnchoredObjectQuery {
        let query = HKAnchoredObjectQuery(
            type: type, predicate: nil, anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { _, _, _, _, _ in
        }
        query.updateHandler = { [weak manager] _, newSamples, _, _, _ in
            guard let samples = newSamples, !samples.isEmpty else { return }
            Task { @MainActor in manager?.writes.breathePollTick(listenStart: listenStart) }
        }
        return query
    }

    /// Safety-net poll timer: `HKAnchoredObjectQuery` updateHandlers can be
    /// delayed or miss events if Watch data synced before the queries were
    /// registered. Polls every 5 s as a fallback, with a 5-minute hard timeout.
    private func startBreathePollTimer(listenStart: Date) {
        DispatchQueue.main.async { [weak manager] in
            manager?.breathePollTimer = makeBreathePollTimer { [weak manager] in
                manager?.writes.breathePollTick(listenStart: listenStart)
            }
        }
    }

    private func breathePollTick(listenStart: Date) {
        guard !manager.breatheDetected else { return }
        let elapsed = Date().timeIntervalSince(listenStart)
        guard elapsed <= 300 else { // 5 minutes
            debugLog("[HealthKitManager] Breathe observation timed out after \(Int(elapsed))s — stopping")
            stopObservingBreatheHRV()
            return
        }
        checkForBreatheCompletion(since: listenStart)
    }

    /// Unified check called by both observer queries and the safety-net timer.
    ///
    /// Strategy 1 — a new SDNN sample with a different UUID from the baseline
    /// (fast path). Works when the Breathe session + SDNN arrive AFTER the user
    /// tapped "Listen".
    ///
    /// Strategy 2 — find a recent mindfulSession and its corresponding SDNN.
    /// Works when the user completed a Breathe session BEFORE tapping "Listen"
    /// (data already synced to HealthKit — Strategy 1 misses it because the
    /// SDNN UUID matches the baseline snapshot).
    private func checkForBreatheCompletion(since listenStart: Date) {
        guard !manager.breatheDetected else { return }
        // Strong `self` (a value holding the manager) keeps the manager alive
        // for the duration of the check, which is what a check needs.
        Task {
            if let reading = await checkForNewSDNN() {
                deliverBreatheReading(reading)
                return
            }
            if let reading = await fetchSDNNFromMindfulSession() {
                deliverBreatheReading(reading)
            }
        }
    }

    /// Deliver the detected reading to the callback on the main actor. Guards against double delivery.
    @MainActor
    private func deliverBreatheReading(_ reading: HealthKitManager.BreatheHRVReading) {
        guard !manager.breatheDetected, let callback = manager.breatheCallback else { return }
        manager.breatheDetected = true
        stopObservingBreatheHRV()
        callback(reading)
    }

    /// Stop all Breathe observation (observer queries, background delivery, timer).
    func stopObservingBreatheHRV() {
        for query in manager.breatheObserverQueries {
            manager.healthStore.stop(query)
        }
        manager.breatheObserverQueries = []
        manager.breathePollTimer?.invalidate()
        manager.breathePollTimer = nil
        manager.breatheListenStartDate = nil
        manager.baselineSDNNSampleUUID = nil
        manager.breatheCallback = nil
    }

    /// Check if a new SDNN sample has appeared since we started listening.
    /// Compares against the baseline snapshot UUID — not time-based, so unaffected
    /// by Watch sync delays or timestamp differences.
    private func checkForNewSDNN() async -> HealthKitManager.BreatheHRVReading? {
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let sample: HKQuantitySample? = await manager.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: sdnnType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                resolve((samples as? [HKQuantitySample])?.first)
            }
        }

        guard let sample, sample.uuid != manager.baselineSDNNSampleUUID else { return nil }

        return HealthKitManager.BreatheHRVReading(
            date: sample.startDate,
            sdnn: sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
            sourceName: sample.sourceRevision.source.name
        )
    }

    /// Look for a recent mindfulSession, then find the corresponding SDNN sample
    /// within that session's time window. Searches 60 minutes back from NOW (not
    /// from listenStart) so it finds sessions the user completed before tapping
    /// "Listen" — the most common flow is: do Breathe on Watch → data syncs →
    /// open app → tap Listen.
    private func fetchSDNNFromMindfulSession() async -> HealthKitManager.BreatheHRVReading? {
        guard let mindfulType = HKTypes.category(.mindfulSession) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600), end: nil, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let session: HKCategorySample? = await manager.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: mindfulType, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                resolve((samples as? [HKCategorySample])?.first)
            }
        }
        guard let session else {
            debugLog("[HealthKitManager] No mindfulSession in last 60 min")
            return nil
        }
        return await breatheReading(for: session, sort: sort)
    }

    /// Look for an SDNN sample within ±5 minutes of the mindful session window.
    /// Apple Watch may write the SDNN a few minutes after the Breathe session
    /// ends, so ±2 min was too tight and missed valid readings.
    private func breatheReading(for session: HKCategorySample, sort: NSSortDescriptor) async -> HealthKitManager.BreatheHRVReading? {
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return nil }
        let windowStart = session.startDate.addingTimeInterval(-300)
        let windowEnd = session.endDate.addingTimeInterval(300)
        let sdnnPredicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])
        let sdnnSample: HKQuantitySample? = await manager.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: sdnnType, predicate: sdnnPredicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                resolve((samples as? [HKQuantitySample])?.first)
            }
        }
        guard let sdnnSample else {
            debugLog("[HealthKitManager] mindfulSession found (\(session.startDate) – \(session.endDate)) but no SDNN within ±5 min window (\(windowStart) – \(windowEnd))")
            return nil
        }
        return HealthKitManager.BreatheHRVReading(
            date: session.startDate,
            sdnn: sdnnSample.quantity.doubleValue(for: .secondUnit(with: .milli)),
            sourceName: sdnnSample.sourceRevision.source.name
        )
    }

    /// Query HealthKit for recent SDNN and mindfulSession samples so the user
    /// can verify whether Watch data is actually reaching the iPhone.
    func runBreatheDiagnostics() async {
        guard manager.isHealthKitAvailable,
              let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN),
              let mindfulType = HKTypes.category(.mindfulSession)
        else { return }
        // Calendar.date(byAdding:) is optional; fall back to the
        // anchor date so the window collapses to "now…now" (empty
        // result) instead of crashing on a force-unwrap.
        let last24h = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        let recent = HKQuery.predicateForSamples(withStart: last24h, end: nil, options: [])
        let latestSDNN = await latestSample(sdnnType) as? HKQuantitySample
        let diag = await HealthKitManager.BreatheDiagnostics(
            lastSDNNDate: latestSDNN?.startDate,
            lastSDNNValue: latestSDNN?.quantity.doubleValue(for: .secondUnit(with: .milli)),
            lastSDNNSource: latestSDNN?.sourceRevision.source.name,
            lastMindfulDate: (latestSample(mindfulType) as? HKCategorySample)?.startDate,
            mindfulSessionCount24h: sampleCount(mindfulType, predicate: recent),
            sdnnCount24h: sampleCount(sdnnType, predicate: recent)
        )
        await MainActor.run { self.manager.breatheDiagnostics = diag }
    }

    /// Most recent sample of a type, at any time.
    private func latestSample(_ type: HKSampleType) async -> HKSample? {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                resolve(samples?.first)
            }
        }
    }

    private func sampleCount(_ type: HKSampleType, predicate: NSPredicate) async -> Int {
        await manager.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                resolve(samples?.count ?? 0)
            }
        } ?? 0
    }

    // MARK: - SDNN Export

    /// Export SDNN (Standard Deviation of NN intervals) to Apple Health
    /// Uses the standard heartRateVariabilitySDNN type to match Apple Watch HRV format
    ///
    /// Validates the value BEFORE constructing HKQuantity. Passing
    /// NaN/Inf to HKQuantity raises NSInvalidArgumentException, which Swift
    /// `throws` can't catch. SDNN comes from RR analysis and CAN be NaN if the
    /// filter window produced no valid intervals.
    func exportSDNN(value: Double, at date: Date, sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard value.isFinite else {
            debugLog("[HealthKit] exportSDNN: refusing non-finite value (\(value)) for session \(sessionId.uuidString.prefix(8))", level: .warning)
            return
        }
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        try await deletePriorBareSDNN(sdnnType: sdnnType, at: date, sessionId: sessionId)
        let sample = HKQuantitySample(
            type: sdnnType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: value),
            start: date, end: date,
            metadata: [HKMetadataKeyExternalUUID: sessionId.uuidString, "Source": "Emuqu"]
        )
        try await manager.healthStore.save(sample)
    }

    /// Idempotent re-export. This sample's ExternalUUID
    /// is the bare session UUID, which the windowed-HRV prefix sweep
    /// (`-sdnn-`/`-rmssd-`) does NOT cover, so re-analysis would duplicate it.
    /// Delete our exact prior write first. Exact match only — a prefix test
    /// would also swallow the `-sdnn-<n>` / `-rmssd-<n>` series.
    ///
    /// Bounded, FAIL CLOSED: this reads OUR prior sample so we can delete it
    /// before re-saving. Timing out to empty would skip the delete and
    /// duplicate the row, so a stalled dedup read throws (like any query error
    /// here already does) rather than proceeding on no data.
    private func deletePriorBareSDNN(sdnnType: HKQuantityType, at date: Date, sessionId: UUID) async throws {
        let exactUUID = sessionId.uuidString
        let predicate = HKQuery.predicateForSamples(withStart: date, end: date.addingTimeInterval(1), options: [])
        let existing: [HKQuantitySample] = try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.vitalsQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(sampleType: sdnnType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                    resolve(HealthKitManager.quantityResult(results, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut("exportSDNN dedup")) }
        )
        let mine = existing.filter { ($0.metadata?[HKMetadataKeyExternalUUID] as? String) == exactUUID }
        if !mine.isEmpty { try await manager.healthStore.delete(mine) }
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
    /// + new samples coexisting in Health for the same windows.
    /// `internal` so HealthKitManager+Sleep.swift's `exportSessionMetrics`
    /// can call this across files.
    func exportWindowedHRV(
        from rrPoints: [RRPoint],
        sessionStart: Date,
        sessionId: UUID
    ) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        let (samples, windowCount) = Self.windowedHRVSamples(
            rrPoints: rrPoints, sdnnType: sdnnType, sessionStart: sessionStart, sessionId: sessionId
        )
        do {
            try await deleteOurSDNNSamples(sessionId: sessionId)
        } catch {
            debugLog("[HealthKitManager] could not delete the previous SDNN samples for \(sessionId); the new ones are still written: \(error.localizedDescription)", level: .warning)
        }
        guard !samples.isEmpty else { return }
        try await manager.healthStore.save(samples)
        debugLog("[HealthKit Export] Wrote \(samples.count) windowed SDNN samples across \(windowCount) windows")
    }

    /// Walk the beat stream in fixed 5-minute windows, returning every sample
    /// built plus the count of windows that produced any.
    nonisolated private static func windowedHRVSamples(
        rrPoints: [RRPoint],
        sdnnType: HKQuantityType,
        sessionStart: Date,
        sessionId: UUID
    ) -> ([HKQuantitySample], Int) {
        let windowSizeMs: Int64 = 5 * 60 * 1000 // 5 minutes
        let endMs = rrPoints.last?.t_ms ?? 0
        var samples: [HKQuantitySample] = []
        var windowStart: Int64 = 0
        var windowIndex = 0
        while windowStart < endMs {
            let windowEnd = windowStart + windowSizeMs
            let windowPoints = rrPoints.filter { $0.t_ms >= windowStart && $0.t_ms < windowEnd }
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
    /// sparse to represent. SDNN is order-independent, so it uses the valid
    /// beats alone.
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
        let validRRs = zip(orderedRRs, validMask).filter { $0.1 }.map { $0.0 }
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
    /// Uses the SAME sample SD (÷N-1) path as the canonical in-app
    /// SDNN. `TimeDomainAnalyzer` computes SDNN via
    /// `Statistics.sampleStandardDeviation` (÷N-1); an export using
    /// population variance (÷N) writes an SDNN to Apple Health that is
    /// systematically smaller than the value the app shows for the same window
    /// (the gap is largest on short windows). Routing the export through the
    /// same helper makes the exported number match the app.
    ///
    /// Non-finite values are skipped:
    /// `HKQuantity(unit:doubleValue:)` raises an uncatchable NSException for
    /// NaN/Inf, so dropping the window beats crashing.
    nonisolated private static func hrvSample(_ value: Double, metric: HealthExportIdentity.Metric, label: String, slot: HRVSampleSlot) -> HKQuantitySample? {
        guard value.isFinite else { return nil }
        return HKQuantitySample(
            type: slot.type,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: value),
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

    /// Delete previously-written SDNN+RMSSD samples for a given session.
    /// Matches by `HKMetadataKeyExternalUUID` prefix (`{uuid}-sdnn-`, `{uuid}-rmssd-`)
    /// so we never touch samples written by Apple Watch or other apps. Failures
    /// are non-fatal — the next save will accumulate, but losing idempotency
    /// is better than blocking the export entirely.
    private func deleteOurSDNNSamples(sessionId: UUID) async throws {
        guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
        let samples = try await allExternalUUIDSDNNSamples(sdnnType: sdnnType)
        let prefix = sessionId.uuidString
        let mine = samples.filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return uuid.hasPrefix("\(prefix)-sdnn-") || uuid.hasPrefix("\(prefix)-rmssd-")
        }
        guard !mine.isEmpty else { return }
        try await manager.healthStore.delete(mine)
        debugLog("[HealthKit Export] Re-export idempotency: deleted \(mine.count) prior HRV samples for session \(prefix.prefix(8))")
    }

    /// Bounded, FAIL CLOSED (dedup-before-delete for re-export idempotency):
    /// an empty result on timeout would skip the delete and let duplicates
    /// accumulate, so a stall throws (as a query error already does here).
    private func allExternalUUIDSDNNSamples(sdnnType: HKQuantityType) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)
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

/// The 5 s breathe-poll timer, built apart from the instance that owns it.
///
/// Scheduled on the main run loop, so `tick` fires on the main actor.
/// `assumeIsolated` states that rather than hopping: a hop would delay each
/// tick by a run-loop turn, defeating a safety net whose whole job is to catch
/// a missed `HKAnchoredObjectQuery` update.
private func makeBreathePollTimer(tick: @escaping @MainActor @Sendable () -> Void) -> Timer {
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        MainActor.assumeIsolated { tick() }
    }
}
