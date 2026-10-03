import Foundation
import HealthKit
import os

// MARK: - Bounded HealthKit query execution (single source of truth)
//
// `HKSampleQuery` / `HKStatisticsQuery` have NO built-in timeout.
// At wake the HealthKit store is busy ingesting the Watch's overnight data, and
// any unbounded query can hang for many seconds — a field log
// caught a daytime-resting-HR query hanging 19 SECONDS before returning, and
// because it was awaited inline in morning HRV analysis it stalled the whole
// morning and froze the record screen. This extension is the ONE place a
// HealthKit query continuation lives: every raw query is executed through
// `runBoundedQuery` / `runBoundedThrowingQuery`, which enforce a timeout +
// `manager.healthStore.stop(query)` + resume-once on EVERY query. No raw
// `withCheckedContinuation { … execute }` should exist outside here.
//
// (Lives in this file, which is already a compiled target member, rather than a
// standalone file — a new standalone .swift would need adding to the Xcode
// target's explicit file list to be built.)
extension HeartRateHealthQueries {
    // MARK: Per-query-type timeouts (ENGINEERING BOUNDS — not science)
    //
    // Two tiers:
    //  • UI-critical reads awaited inline in morning processing → short (a few
    //    seconds). Every one is an OPTIONAL refinement that already falls back to
    //    nil / a cached value, so timing out and proceeding is correct, not
    //    lossy — showing the score now beats blocking on a slow store.
    //  • Large background aggregations (e.g. 400-day workout history) → a
    //    generous DEADLOCK BACKSTOP: long enough that a legitimately large query
    //    finishes, short enough that a genuinely wedged store still recovers.
    //    This is NOT a latency bound (those queries are off the UI critical path).

    /// UI-critical morning vitals reads (respiratory rate, SpO2, wrist temp, resting HR).
    nonisolated static let vitalsQueryTimeoutSec: TimeInterval = 6.0
    /// UI-critical sleep reads on the morning path.
    nonisolated static let sleepQueryTimeoutSec: TimeInterval = 8.0
    /// UI-critical HRV (SDNN / mindful-minutes) reads on the morning path.
    nonisolated static let hrvQueryTimeoutSec: TimeInterval = 6.0
    /// Large background aggregations (workout history, training load, heat) —
    /// a deadlock backstop, not a UI-latency bound.
    nonisolated static let backgroundAggregateQueryTimeoutSec: TimeInterval = 30.0

    // MARK: Bounded executors

    /// Run an HKQuery bounded by `timeout`, resolving to `nil` if it doesn't
    /// answer in time. `makeQuery` builds the query and MUST call the supplied
    /// `resolve` closure exactly once from its result handler. On timeout the
    /// query is `stop()`-ed and the call resolves to `nil`. Resume-once guarded
    /// (the result handler and the timeout can race). Non-throwing: use for the
    /// many reads that already treat any failure as "no data → nil".
    ///
    /// `resolve` is `@Sendable` and `T` is constrained to `Sendable`. Every
    /// caller passes `resolve` straight into an `HKQuery` result handler, which
    /// HealthKit declares `@Sendable`; without those annotations each of the
    /// ~50 call sites raised "capture of 'resolve' with non-Sendable type in a
    /// '@Sendable' closure" under strict concurrency — the single largest block
    /// of concurrency diagnostics in the app.
    func runBoundedQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (T?) -> Void) -> HKQuery
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let finish = Self.resumeOnce(continuation)
            let query = makeQuery { finish($0) }
            manager.healthStore.execute(query)
            // Stopping an already-finished query is a harmless no-op; `finish`
            // is idempotent, so the timeout losing the race changes nothing.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak healthStore = manager.healthStore] in
                healthStore?.stop(query)
                finish(nil)
            }
        }
    }

    /// A resume-once wrapper around a continuation.
    ///
    /// `OSAllocatedUnfairLock` rather than `NSLock` + a mutable capture: it
    /// owns the flag, so it is `Sendable` over `Bool` and needs no
    /// `nonisolated(unsafe)` escape — same single-resume guarantee, one fewer
    /// thing for `check_unchecked_sendable.sh` to have to trust.
    nonisolated private static func resumeOnce<T: Sendable>(
        _ continuation: CheckedContinuation<T?, Never>
    ) -> @Sendable (T?) -> Void {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return { value in
            guard !claimResume(resumed) else { return }
            continuation.resume(returning: value)
        }
    }

    /// Throwing variant: for queries whose callers distinguish a real failure
    /// from "no data". `makeQuery` MUST call `resolve` once with a `Result`. On
    /// timeout the query is stopped and `onTimeout()` supplies the result — e.g.
    /// `.success([])` to proceed with none, or `.failure(…)` to surface a stall.
    ///
    /// Same `Sendable` annotation reasoning as `runBoundedQuery` above.
    func runBoundedThrowingQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (Result<T, Error>) -> Void) -> HKQuery,
        onTimeout: @escaping @Sendable () -> Result<T, Error>
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let finish = Self.resumeResultOnce(continuation)
            let query = makeQuery(finish)
            manager.healthStore.execute(query)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak healthStore = manager.healthStore] in
                healthStore?.stop(query)
                finish(onTimeout())
            }
        }
    }

    /// A resume-once wrapper around a throwing continuation. Both the query
    /// callback and the timeout can fire; only the first one resumes.
    nonisolated private static func resumeResultOnce<T: Sendable>(
        _ continuation: CheckedContinuation<T, Error>
    ) -> @Sendable (Result<T, Error>) -> Void {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return { result in
            guard !claimResume(resumed) else { return }
            continuation.resume(with: result)
        }
    }

    /// True when someone already claimed the resume — the caller must stand down.
    nonisolated private static func claimResume(_ resumed: OSAllocatedUnfairLock<Bool>) -> Bool {
        resumed.withLock { state -> Bool in
            let already = state
            state = true
            return already
        }
    }
}

// MARK: - Heart Rate queries and writes

extension HeartRateHealthQueries {
    /// Hard timeout for the daytime-resting-HR query. It's an optional analysis
    /// input awaited inline in morning processing, so it must never stall the
    /// morning if the HealthKit store is slow (see `fetchDaytimeRestingHR`).
    nonisolated static let daytimeRestingHRQueryTimeoutSec: TimeInterval = 4.0

    // MARK: - Read predicate (exclude our own writes)

    /// Predicate that excludes HR/RHR samples written by this
    /// app itself. Mirrors `sleepReadExcludingOwnWrites`. The
    /// app WRITES heart rate (`exportHeartRate` / `exportHeartRateSeries`)
    /// and resting heart rate (`exportRestingHeartRate`) back to HealthKit
    /// when export is enabled. Every HR/RHR READ must therefore exclude
    /// `HKSource.default()` (this app), or it reads its own derived values
    /// back in as "ground truth" — the same circular contamination the
    /// sleep reads already guard against (e.g. a min-HR fallback picks up
    /// our own minute-level series, or the daily RHR read returns the RHR
    /// we exported last night instead of the Watch's authoritative value).
    /// AND this with the date-range predicate before any HR read.
    func hrReadExcludingOwnWrites(dateRange: NSPredicate) -> NSPredicate {
        let ownSourcePredicate = HKQuery.predicateForObjects(from: Set([HKSource.default()]))
        let notFromUs = NSCompoundPredicate(notPredicateWithSubpredicate: ownSourcePredicate)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [dateRange, notFromUs])
    }

    // MARK: - Daytime Heart Rate

    /// Fetch daytime resting heart rate for HR dip calculation
    /// Uses median HR from afternoon/evening of the day before the sleep recording
    /// This provides a stable "awake resting" baseline for nocturnal dip calculation
    /// - Parameter sleepDate: The date of the sleep recording (morning wake time)
    /// - Returns: Median daytime resting HR in bpm, or nil if insufficient data
    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double? {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let hrType = HKTypes.quantity(.heartRate) else { return nil }
        let samples = try await daytimeHRSamples(hrType: hrType, sleepDate: sleepDate)
        guard samples.count >= 10 else {
            debugLog("[HealthKitManager] Insufficient HR samples for daytime resting HR: \(samples.count)")
            return nil
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        // Median for robustness against spikes (activity, stress, etc.)
        return Self.median(samples.map { $0.quantity.doubleValue(for: bpm) })
    }

    /// Query daytime resting HR from the user's configured awake window before
    /// sleep. This captures "awake resting" periods while avoiding morning
    /// grogginess and late-night wind-down; the window is derived from the
    /// sleep schedule.
    ///
    /// Excludes our own HR writes.
    ///
    /// Bounded via the shared `runBoundedThrowingQuery` wrapper (single source
    /// of truth for timeout + manager.healthStore.stop + resume-once). `HKSampleQuery`
    /// has no built-in timeout, and at wake the HealthKit store is busy
    /// ingesting the Watch's overnight data — a field log caught
    /// this exact query hanging 19 SECONDS before returning "insufficient
    /// samples", and since it's awaited inline in the morning HRV analysis it
    /// stalled the whole morning and froze the record screen mid-transition.
    /// Daytime resting HR is an OPTIONAL refinement to the ANS metrics — the
    /// analysis is fully valid without it — so on timeout we proceed with no
    /// samples (→ nil via the caller's `count >= 10` guard) rather than making
    /// the user wait on a busy store.
    private func daytimeHRSamples(hrType: HKQuantityType, sleepDate: Date) async throws -> [HKQuantitySample] {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: manager.sleepSchedule.daytimeHRStart(relativeTo: sleepDate),
            end: manager.sleepSchedule.daytimeHREnd(relativeTo: sleepDate),
            options: .strictStartDate
        )
        return try await boundedHRSamples(
            hrType: hrType,
            predicate: hrReadExcludingOwnWrites(dateRange: datePredicate),
            timeout: Self.daytimeRestingHRQueryTimeoutSec
        )
    }

    /// Ascending, unbounded-limit HR read that degrades to no samples if the
    /// store doesn't answer within `timeout`.
    private func boundedHRSamples(hrType: HKQuantityType, predicate: NSPredicate, timeout: TimeInterval) async throws -> [HKQuantitySample] {
        try await runBoundedThrowingQuery(
            timeout: timeout,
            makeQuery: { resolve in
                HKSampleQuery(
                    sampleType: hrType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, results, error in
                    resolve(Self.quantityResult(results, error))
                }
            },
            onTimeout: { .success([]) }
        )
    }

    nonisolated private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    }

    /// Fetch heart rate samples during a recording period with detailed metadata
    /// Returns array of (timestamp, HR, source app, interval) tuples
    /// Useful for understanding HR sampling patterns and data sources
    ///
    /// Excludes our own HR writes. With export on,
    /// the recording window overlaps the minute-level HR series WE wrote for
    /// that same session, so an unfiltered read would treat our derived HR as
    /// additional ground-truth samples.
    ///
    /// Bounded read (single source of truth). A night-window HR read feeds
    /// nadir/stat analysis in the morning pipeline; on timeout proceed with
    /// none (→ `calculateHRStats` returns nil via its `count >= 10` guard)
    /// rather than freezing the morning on a slow store.
    func fetchHeartRateSamplesDetailed(from start: Date, to end: Date) async throws -> [HeartRateSample] {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let hrType = HKTypes.quantity(.heartRate) else { return [] }
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples = try await boundedHRSamples(
            hrType: hrType,
            predicate: hrReadExcludingOwnWrites(dateRange: datePredicate),
            timeout: Self.sleepQueryTimeoutSec
        )
        return Self.detailedSamples(samples)
    }

    /// Build detailed sample data with source and interval information. Source
    /// prefers the bundle ID and falls back to the human-readable source name.
    nonisolated private static func detailedSamples(_ samples: [HKQuantitySample]) -> [HeartRateSample] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var detailedSamples: [HeartRateSample] = []
        var previousDate: Date?
        for sample in samples {
            let date = sample.startDate
            let bundleId = sample.sourceRevision.source.bundleIdentifier
            detailedSamples.append(HeartRateSample(
                date: date,
                hr: sample.quantity.doubleValue(for: bpm),
                source: bundleId.isEmpty ? sample.sourceRevision.source.name : bundleId,
                interval: previousDate.map { date.timeIntervalSince($0) }
            ))
            previousDate = date
        }
        return detailedSamples
    }

    /// Fetch heart rate samples during a recording period
    /// Returns array of (timestamp, HR) tuples for all HR samples in the time range
    /// Useful for calculating nadir HR and HR statistics from Apple Watch data
    func fetchHeartRateSamples(from start: Date, to end: Date) async throws -> [(date: Date, hr: Double)] {
        let detailed = try await fetchHeartRateSamplesDetailed(from: start, to: end)
        return detailed.map { (date: $0.date, hr: $0.hr) }
    }

    /// Calculate HR statistics from HealthKit samples during a recording
    /// Returns (mean, min, max, nadir time) or nil if insufficient data
    func calculateHRStats(from start: Date, to end: Date) async throws -> HeartRateStats? {
        let samples = try await fetchHeartRateSamples(from: start, to: end)

        guard samples.count >= 10 else {
            debugLog("[HealthKitManager] Insufficient HR samples for stats: \(samples.count)")
            return nil
        }

        let hrValues = samples.map(\.hr)
        let mean = hrValues.reduce(0, +) / Double(hrValues.count)
        let min = hrValues.min() ?? 0
        let max = hrValues.max() ?? 0

        // Find nadir (lowest HR) timestamp
        guard let nadirSample = samples.min(by: { $0.hr < $1.hr }) else {
            return nil
        }
        let nadirTime = nadirSample.date

        return HeartRateStats(mean: mean, min: min, max: max, nadirTime: nadirTime)
    }

    // MARK: - HR Writes

    /// Idempotent write: delete any of OUR previously-written samples for this
    /// session (matched by ExternalUUID) before saving the new set, so
    /// re-analysing the same session never duplicates rows in Apple Health.
    ///
    /// The export path must not blindly `save()`: any
    /// re-analysis / re-export would write a second copy, and users would see
    /// doubled HR rows. HealthKit only lets an app delete samples it authored, so the
    /// delete query below can only ever remove Emuqu's own prior write.
    private func deleteThenSave(
        _ samples: [HKQuantitySample],
        of type: HKQuantityType,
        start: Date,
        end: Date,
        matches externalUUIDMatch: @escaping (String) -> Bool
    ) async throws {
        let existing = try await priorSamples(of: type, start: start, end: end)
        let stale = existing.filter { sample in
            guard let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return externalUUIDMatch(uuid)
        }
        if !stale.isEmpty {
            try await manager.healthStore.delete(stale)
        }
        if !samples.isEmpty {
            try await manager.healthStore.save(samples)
        }
    }

    /// Bounded, but FAIL CLOSED on timeout: this reads OUR prior samples so we
    /// can delete them before re-saving. An empty result would skip the delete
    /// and re-create the duplicate Apple Health rows the idempotent
    /// write exists to prevent, so a timed-out dedup read must abort the export (logged,
    /// non-fatal) rather than proceed on no data.
    private func priorSamples(of type: HKQuantityType, start: Date, end: Date) async throws -> [HKSample] {
        // Widen a zero-length window by 1s so instant samples are queryable.
        let queryEnd = end > start ? end : start.addingTimeInterval(1)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: queryEnd, options: [])
        return try await runBoundedThrowingQuery(
            timeout: Self.vitalsQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                    resolve(Self.sampleResult(results, error))
                }
            },
            onTimeout: { .failure(HealthKitManager.HealthKitError.queryTimedOut("deleteThenSave dedup")) }
        )
    }

    /// HKSampleQuery hands back (results, error); exactly one is meaningful.
    nonisolated static func sampleResult(_ results: [HKSample]?, _ error: Error?) -> Result<[HKSample], Error> {
        if let error { return .failure(error) }
        return .success(results ?? [])
    }

    /// Same shape, narrowed to quantity samples for the HR reads.
    nonisolated static func quantityResult(_ results: [HKSample]?, _ error: Error?) -> Result<[HKQuantitySample], Error> {
        if let error { return .failure(error) }
        return .success(results as? [HKQuantitySample] ?? [])
    }

    /// Export mean heart rate to Apple Health
    func exportHeartRate(value: Double, at date: Date, sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        // Validate HR is finite (HR computed from RR can
        // be NaN if intervals are zero / corrupted).
        guard value.isFinite else {
            debugLog("[HealthKit] exportHeartRate: refusing non-finite value (\(value))", level: .warning)
            return
        }
        guard let hrType = HKTypes.quantity(.heartRate) else { return }
        let quantity = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: value)
        let externalUUID = HealthExportIdentity.summary(sessionId: sessionId, metric: .heartRate)
        let metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID,
            "Source": "Emuqu"
        ]
        let sample = HKQuantitySample(type: hrType, quantity: quantity, start: date, end: date, metadata: metadata)
        // Exact match: "-hr" must NOT swallow the "-hr-<n>" minute series.
        try await deleteThenSave([sample], of: hrType, start: date, end: date) { $0 == externalUUID }
    }

    /// Export resting heart rate to Apple Health
    func exportRestingHeartRate(value: Double, at date: Date, sessionId: UUID) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard value.isFinite else {
            debugLog("[HealthKit] exportRestingHeartRate: refusing non-finite value (\(value))", level: .warning)
            return
        }
        guard let rhrType = HKTypes.quantity(.restingHeartRate) else { return }
        let quantity = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: value)
        let externalUUID = HealthExportIdentity.summary(sessionId: sessionId, metric: .restingHeartRate)
        let metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID,
            "Source": "Emuqu"
        ]
        let sample = HKQuantitySample(type: rhrType, quantity: quantity, start: date, end: date, metadata: metadata)
        try await deleteThenSave([sample], of: rhrType, start: date, end: date) { $0 == externalUUID }
    }

    // MARK: - Heart Rate Series Export

    /// Export minute-level heart rate as individual discrete samples.
    ///
    /// Not `HKQuantitySeriesSampleBuilder` — Apple's "efficient" API that
    /// packages many readings under one logical sample. That works at the
    /// storage layer but the iOS Health app's "Show All Data" list counts a
    /// series as **one entry**: users see a single row and report "you only
    /// write one data point" even though it contains ~480 minute-level
    /// readings inside.
    ///
    /// Writing individual `HKQuantitySample` objects (one per minute), the way
    /// `exportWindowedHRV` does, makes every minute visible as its own sample
    /// in the list. Storage cost is negligible for ~480 samples/night.
    /// `internal` so HealthKitManager+SleepTrends.swift's `exportSessionMetrics`
    /// can call this across files.
    func exportHeartRateSeries(
        from rrPoints: [RRPoint],
        sessionStart: Date,
        sessionId: UUID
    ) async throws {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let hrType = HKTypes.quantity(.heartRate) else { return }
        let samples = Self.minuteHRSamples(rrPoints: rrPoints, hrType: hrType, sessionStart: sessionStart, sessionId: sessionId)
        // The cleanup covers this session's earlier export wherever it ran,
        // not just the span of the new samples: a re-analysis that trimmed
        // the night (or left no minutes at all) must not leave the old rows
        // beside the new ones. Matching is by this session's identity, so
        // the wide window touches nothing else.
        let cleanupEnd = max(samples.last?.endDate ?? sessionStart, sessionStart.addingTimeInterval(24 * 3600))
        try await deleteThenSave(
            samples, of: hrType, start: sessionStart, end: cleanupEnd
        ) { HealthExportIdentity.isSeriesMember($0, sessionId: sessionId, metric: .heartRate) }
        debugLog("[HealthKit Export] Wrote \(samples.count) minute-level HR samples")
    }

    /// One HR value per minute, computed from the valid RR intervals inside
    /// that minute. Minutes with fewer than two beats, or with no valid RR at
    /// all, are skipped — and skipped minutes do NOT consume a sample index, so
    /// the ExternalUUID suffixes stay contiguous.
    nonisolated private static func minuteHRSamples(
        rrPoints: [RRPoint],
        hrType: HKQuantityType,
        sessionStart: Date,
        sessionId: UUID
    ) -> [HKQuantitySample] {
        let endMs = rrPoints.last?.t_ms ?? 0
        let minuteMs: Int64 = 60 * 1000
        var samples: [HKQuantitySample] = []
        var windowStart: Int64 = 0
        while windowStart < endMs {
            let windowEnd = windowStart + minuteMs
            let windowPoints = rrPoints.filter { $0.t_ms >= windowStart && $0.t_ms < windowEnd }
            if let hr = meanHR(of: windowPoints) {
                samples.append(hrSample(
                    hr, type: hrType, sessionStart: sessionStart, sessionId: sessionId,
                    index: samples.count, windowStartMs: windowStart, windowEndMs: windowEnd
                ))
            }
            windowStart += minuteMs
        }
        return samples
    }

    nonisolated private static func hrSample(
        _ hr: Double, type: HKQuantityType, sessionStart: Date, sessionId: UUID,
        index: Int, windowStartMs: Int64, windowEndMs: Int64
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: hr),
            start: sessionStart.addingTimeInterval(Double(windowStartMs) / 1000),
            end: sessionStart.addingTimeInterval(Double(windowEndMs) / 1000),
            metadata: [
                HKMetadataKeyExternalUUID: HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .heartRate, index: index),
                "Source": "Emuqu"
            ]
        )
    }

    nonisolated private static func meanHR(of windowPoints: [RRPoint]) -> Double? {
        guard windowPoints.count >= 2 else { return nil }
        let validRRs = windowPoints.map { Double($0.rr_ms) }.filter { HRVConstants.RRInterval.isValid(Int($0)) }
        guard !validRRs.isEmpty else { return nil }
        return 60000.0 / (validRRs.reduce(0, +) / Double(validRRs.count))
    }
}
