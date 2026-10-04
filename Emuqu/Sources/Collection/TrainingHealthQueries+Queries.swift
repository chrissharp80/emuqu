import CoreLocation
import Foundation
import HealthKit
import os

// MARK: - Training Load & Fitness Data

extension TrainingHealthQueries {
    /// VO2max trend over the last `days` days. Returns
    /// (latest, oldestInWindow, sampleCount). Latest is the most-recent
    /// sample value; oldestInWindow is the earliest sample within the
    /// window so the caller (or AI) can compute change = latest -
    /// oldestInWindow. nil tuple when the user has zero samples.
    func fetchVO2MaxTrend(days: Int = 30) async -> (latest: Double, oldestInWindow: Double, sampleCount: Int)? {
        guard manager.isHealthKitAvailable, let vo2Type = HKTypes.quantity(.vo2Max) else { return nil }
        let windowStart = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: vo2Type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                resolve(Self.vo2Trend(from: samples))
            }
        }
    }

    nonisolated private static func vo2Trend(from samples: [HKSample]?) -> (latest: Double, oldestInWindow: Double, sampleCount: Int)? {
        let vo2Unit = HKUnit(from: "ml/kg*min")
        let values = (samples ?? []).compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: vo2Unit) }
        guard let latest = values.last, let oldest = values.first else { return nil }
        return (latest, oldest, values.count)
    }

    /// Deduplicate workouts that cover the same physical session.
    ///
    /// Two rules, both required:
    ///   1. Start times within 5 minutes of each other (protects against
    ///      back-to-back distinct workouts being collapsed).
    ///   2. Either matching type OR overlapping time ranges by >= 60 % of
    ///      the shorter workout — which catches the case where Emuqu
    ///      exports a session as (say) Walk and Apple's auto-detection or a
    ///      paired Watch writes a parallel HKWorkout labelled Run for the
    ///      SAME physical activity. A "type must match" check leaves
    ///      both in the recent-workouts list.
    ///
    /// Ties broken by data richness (HR > maxHR > calories).
    nonisolated static func deduplicateWorkouts(_ workouts: [HealthKitManager.WorkoutSummary]) -> [HealthKitManager.WorkoutSummary] {
        guard workouts.count > 1 else { return workouts }
        let sorted = workouts.sorted { $0.date < $1.date }
        var result: [HealthKitManager.WorkoutSummary] = []
        var consumed = Set<Int>()
        for i in sorted.indices where !consumed.contains(i) {
            result.append(collapseDuplicates(from: i, in: sorted, consumed: &consumed))
        }
        return result
    }

    /// Absorb every later workout that covers the same physical session into
    /// the one starting at `i`, returning whichever copy carries the richest data.
    ///
    /// The scan window was widened from a 5-min break to 30 min so a session
    /// and its own HealthKit back-fill still collapse even when their start
    /// times drift apart (the archive start and the Apple-Health export start
    /// rarely align to the minute). Same-type near-starts still merge on the
    /// tight 5-min rule; drifted or differently-typed copies merge only on a
    /// STRONG span overlap (≥60% of the shorter), which won't fuse two
    /// genuinely distinct back-to-back workouts.
    nonisolated private static func collapseDuplicates(from i: Int, in sorted: [HealthKitManager.WorkoutSummary], consumed: inout Set<Int>) -> HealthKitManager.WorkoutSummary {
        var best = sorted[i]
        for j in (i + 1) ..< sorted.count where !consumed.contains(j) {
            let other = sorted[j]
            let gap = other.date.timeIntervalSince(best.date)
            guard gap <= 1800 else { break }
            let sameTypeNearStart = other.workoutType == best.workoutType && gap <= 300
            guard sameTypeNearStart || overlaps(best, other) else { continue }
            consumed.insert(j)
            if workoutDataScore(other) > workoutDataScore(best) {
                best = other
            }
        }
        return best
    }

    /// Merge workouts with the H10 ARCHIVE authoritative for anything the app
    /// recorded. The app's own recordings carry the strap-derived
    /// load (hrTSS / continuous Banister TRIMP integrated off the RR series).
    /// HealthKit is consulted ONLY to pick up training the app did NOT record
    /// (a workout done on another app / device). So keep EVERY archive workout
    /// and add only HealthKit workouts that don't overlap one in time.
    ///
    /// Why: HealthKit's copy of an H10 session is a DEGRADED duplicate — Apple's
    /// arithmetic-mean HR (higher than the strap's RR-harmonic mean), no RR — and
    /// re-scoring it through the Banister exponential over-inflates load: an H10
    /// walk of true load ~54/85 surfaced as ~113 in CTL/ATL. The strap wins by
    /// construction, so there is no "which copy scores higher" tie-break to get
    /// wrong. This is the ONE place archive-vs-HealthKit precedence lives, so the
    /// live-metrics builder and the historical-series builder can't diverge.
    nonisolated static func mergeArchiveAuthoritative(
        archive: [HealthKitManager.WorkoutSummary],
        healthKit: [HealthKitManager.WorkoutSummary],
        additional: [HealthKitManager.WorkoutSummary] = []
    ) -> [HealthKitManager.WorkoutSummary] {
        // Drop any HealthKit workout that strongly overlaps an archive workout —
        // it's the same session we already hold with strap precision. `overlaps`
        // requires ≥60% of the shorter session's span, so genuinely separate
        // external training (e.g. a ride logged only in Strava at another time)
        // is kept. You can't do two time-overlapping workouts at once, so this
        // never drops a distinct session.
        let externalHealthKit = healthKit.filter { hk in
            !archive.contains { overlaps($0, hk) }
        }
        // Among the KEPT set, external copies can still duplicate each other
        // (Strava + Apple's auto-detected copy of the same un-recorded ride) —
        // collapse those with the normal dedup. Archive workouts don't duplicate
        // each other, and no HealthKit twin of an archive workout remains.
        return deduplicateWorkouts(archive + externalHealthKit + additional)
    }

    nonisolated private static func endDate(of w: HealthKitManager.WorkoutSummary) -> Date {
        w.date.addingTimeInterval(w.durationMinutes * 60.0)
    }

    /// Overlap test: intersection >= 60 % of the shorter workout's duration.
    nonisolated private static func overlaps(_ a: HealthKitManager.WorkoutSummary, _ b: HealthKitManager.WorkoutSummary) -> Bool {
        let aEnd = endDate(of: a), bEnd = endDate(of: b)
        let intersectionStart = max(a.date, b.date)
        let intersectionEnd = min(aEnd, bEnd)
        let overlap = intersectionEnd.timeIntervalSince(intersectionStart)
        guard overlap > 0 else { return false }
        let shorter = min(a.durationMinutes, b.durationMinutes) * 60.0
        guard shorter > 0 else { return false }
        return overlap / shorter >= 0.6
    }

    /// Score a workout by data richness for dedup tie-breaking.
    /// `precomputedLoad` is scored highest (8) so that
    /// when an HK workout and an archive workout describe the same
    /// session, the archive copy wins. The archive copy is the one
    /// carrying powerTSS via `preferredTrainingLoad`; without this
    /// bump, the HK copy could outscore it on averageHR + maxHR
    /// alone and the daily TRIMP builder would fall back to the
    /// HR-only Banister estimate even when power was recorded.
    nonisolated private static func workoutDataScore(_ workout: HealthKitManager.WorkoutSummary) -> Int {
        var score = 0
        if workout.precomputedLoad != nil { score += 8 }
        if workout.averageHR != nil { score += 4 }
        if workout.maxHR != nil { score += 2 }
        if workout.caloriesBurned != nil { score += 1 }
        return score
    }

    /// Fetch recent workouts (last N days)
    func fetchRecentWorkouts(days: Int = 7, relativeTo referenceDate: Date = Date()) async -> [HealthKitManager.WorkoutSummary] {
        await fetchWorkouts(days: days, relativeTo: referenceDate)
    }

    /// Shared implementation for fetching workouts over a given number of days.
    /// Both `fetchRecentWorkouts` and `fetchWorkoutsExtended` delegate here.
    ///
    /// The fetch window is anchored to START OF DAY for the oldest day we care
    /// about. Previous code used `referenceDate - N days`, which kept the same
    /// wall-clock time — so a 6 AM dashboard call missed any workout on day -N
    /// that happened after 6 AM, while a 9 PM call swept in most of it. The CTL
    /// EWMA then disagreed with itself between morning and evening dashboard
    /// openings on the same day. Anchoring to start-of-day -N gives a stable,
    /// full-day window.
    ///
    /// Bounded via the deadlock-backstop timeout (off the UI critical path).
    /// The handler already returns [] on any failure, so timing out to [] is
    /// identical to the existing no-data path — no new risk to the CTL/ATL
    /// aggregation, just a ceiling so a wedged store can't hang the rebuild.
    private func fetchWorkouts(days: Int, relativeTo referenceDate: Date) async -> [HealthKitManager.WorkoutSummary] {
        guard manager.isHealthKitAvailable else { return [] }
        let calendar = Calendar.current
        let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: startOfReferenceDay) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: referenceDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                resolve(Self.workoutSummaries(samples))
            }
        } ?? []
    }

    nonisolated private static func workoutSummaries(_ samples: [HKSample]?) -> [HealthKitManager.WorkoutSummary] {
        guard let workouts = samples as? [HKWorkout] else { return [] }
        return deduplicateWorkouts(workouts.compactMap(Self.summary(for:)))
    }

    /// Drop ghost workouts: HealthKit (often via Strava sync, Apple
    /// auto-detection, or third-party watch faces) sometimes writes a
    /// zero/near-zero-duration HKWorkout alongside the real one — usually a
    /// different activityType (e.g. a 0-second "Run" next to a real "Walk").
    /// They survive dedup because their intersection with the real workout is
    /// zero seconds, so `overlaps()` returns false and the type-mismatch branch
    /// keeps both. Anything under a minute can't be a real session and produces
    /// TRIMP ≈ 0 anyway, so we filter at the source where every downstream
    /// caller (dashboard, training detail, daily TRIMP buildup) benefits.
    nonisolated private static func summary(for workout: HKWorkout) -> HealthKitManager.WorkoutSummary? {
        let duration = workout.duration / 60.0 // Convert to minutes
        guard duration >= 1.0 else { return nil }
        let hr = heartRateStats(for: workout)
        return HealthKitManager.WorkoutSummary(
            date: workout.startDate,
            type: workout.workoutActivityType,
            durationMinutes: duration,
            caloriesBurned: activeCalories(for: workout),
            averageHR: hr.average,
            maxHR: hr.max
        )
    }

    nonisolated private static func activeCalories(for workout: HKWorkout) -> Double? {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let stats = workout.statistics(for: energyType)
        else { return nil }
        return stats.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    nonisolated private static func heartRateStats(for workout: HKWorkout) -> (average: Double?, max: Double?) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let hrStats = workout.statistics(for: hrType)
        else { return (nil, nil) }
        let bpm = HKUnit(from: "count/min")
        return (
            hrStats.averageQuantity()?.doubleValue(for: bpm),
            hrStats.maximumQuantity()?.doubleValue(for: bpm)
        )
    }

    /// Pull the full GPS route of the workout overlapping `[start, end]` from
    /// HealthKit — used to recover a route whose phone-side GPS died mid-
    /// session (e.g. an app crash). Prefers a workout recorded by ANOTHER
    /// source (the Apple Watch) over our own written copy, since ours only
    /// holds the truncated phone track. Returns nil when there's no matching
    /// workout, no route series, or no locations (so the caller can fall back).
    func fetchWorkoutRoute(from start: Date, to end: Date) async -> [CLLocation]? {
        guard manager.isHealthKitAvailable, end > start else { return nil }
        guard let workout = await bestOverlappingWorkout(from: start, to: end) else { return nil }
        guard let route = await routeSeries(for: workout) else { return nil }
        let locations = await routeLocations(route)
        return locations.isEmpty ? nil : locations.sorted { $0.timestamp < $1.timestamp }
    }

    /// Best overlapping workout — prefers an external (Watch) source and the
    /// longest duration (the full recording, not a stub). Watch + phone
    /// start/stop rarely align to the second, so the window is padded.
    private func bestOverlappingWorkout(from start: Date, to end: Date) async -> HKWorkout? {
        let pad: TimeInterval = 15 * 60
        let predicate = HKQuery.predicateForSamples(
            withStart: start.addingTimeInterval(-pad),
            end: end.addingTimeInterval(pad),
            options: []
        )
        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve(Self.preferredWorkout((samples as? [HKWorkout]) ?? []))
            }
        }
    }

    nonisolated private static func preferredWorkout(_ workouts: [HKWorkout]) -> HKWorkout? {
        let ownSource = HKSource.default()
        let usable = workouts.filter { $0.duration >= 60 }
        let external = usable.filter { $0.sourceRevision.source != ownSource }
        let pool = external.isEmpty ? usable : external
        return pool.max(by: { $0.duration < $1.duration })
    }

    /// The workout's GPS route series, if it has one.
    ///
    /// Internal rather than private: `HealthWorkoutImporter` rebuilds external
    /// workouts and needs the same route, and a second copy of this query would
    /// be a second thing to keep correct.
    func routeSeries(for workout: HKWorkout) async -> HKWorkoutRoute? {
        await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve((samples as? [HKWorkoutRoute])?.first)
            }
        }
    }

    /// Stream the route's CLLocations (delivered in batches).
    func routeLocations(_ route: HKWorkoutRoute) async -> [CLLocation] {
        await withCheckedContinuation { executeRouteQuery(route, cont: $0) }
    }

    /// `HKWorkoutRouteQuery` delivers locations in batches on an arbitrary
    /// queue and calls back repeatedly until `done`. The accumulator and the
    /// resume flag were plain captured `var`s, which is a data race the
    /// compiler flags under strict concurrency and which is real: nothing
    /// ordered the batch appends against each other. A single lock owns both,
    /// so batches accumulate atomically and the continuation still resumes
    /// exactly once.
    private func executeRouteQuery(
        _ route: HKWorkoutRoute,
        cont: CheckedContinuation<[CLLocation], Never>
    ) {
        let state = OSAllocatedUnfairLock(initialState: (accumulated: [CLLocation](), resumed: false))
        manager.healthStore.execute(HKWorkoutRouteQuery(route: route) { _, locs, done, _ in
            guard let finished = Self.accumulateRouteBatch(state, locs: locs, done: done) else { return }
            cont.resume(returning: finished)
        })
    }

    /// Non-nil exactly once: the full accumulation, on the batch that reports
    /// `done` first.
    nonisolated private static func accumulateRouteBatch(
        _ state: OSAllocatedUnfairLock<(accumulated: [CLLocation], resumed: Bool)>,
        locs: [CLLocation]?,
        done: Bool
    ) -> [CLLocation]? {
        state.withLock { state in
            if let locs { state.accumulated.append(contentsOf: locs) }
            guard done, !state.resumed else { return nil }
            state.resumed = true
            return state.accumulated
        }
    }

    /// Total walking/running distance (meters) logged by sources OTHER than
    /// this app over `[start, end]` — i.e. the Apple Watch / iPhone pedometer,
    /// which record distance continuously even without a started workout. This
    /// recovers the real distance of a workout whose GPS died mid-session: the
    /// movement was still counted. Excludes our own written samples so we don't
    /// double-count the (short) distance the app already wrote for the workout.
    func fetchPassiveDistanceMeters(from start: Date, to end: Date) async -> Double {
        guard manager.isHealthKitAvailable, end > start,
              let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        else { return 0 }

        let timePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let notOwnSource = NSCompoundPredicate(
            notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePredicate, notOwnSource])

        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: distType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                resolve(statistics?.sumQuantity()?.doubleValue(for: .meter()) ?? 0)
            }
        } ?? 0
    }

    /// Check whether any HealthKit workout exists in a specific time range.
    /// Used to detect if the user exercised between two sleep sessions —
    /// if so, the second sleep shouldn't be merged into the first.
    func hasWorkoutInRange(from start: Date, to end: Date) async -> Bool {
        guard manager.isHealthKitAvailable, end > start else { return false }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve(Self.foundWorkout(samples, from: start, to: end))
            }
        } ?? false
    }

    nonisolated private static func foundWorkout(_ samples: [HKSample]?, from start: Date, to end: Date) -> Bool {
        let found = (samples?.count ?? 0) > 0
        if found {
            debugLog("[HealthKitManager] Found workout between \(start) and \(end) — skipping sleep merge")
        }
        return found
    }

    /// Fetch workouts for extended period (needed for CTL calculation)
    func fetchWorkoutsExtended(days: Int = 60, relativeTo referenceDate: Date = Date()) async -> [HealthKitManager.WorkoutSummary] {
        await fetchWorkouts(days: days, relativeTo: referenceDate)
    }

    /// Fetch Apple's computed resting heart rate from HealthKit.
    /// This is a daily metric derived by Apple Watch from all-day HR monitoring,
    /// more stable than instantaneous minimum HR for TRIMP calculations.
    /// Internal (not private) so `TrainingMetricsCache.buildDailySeries` resolves
    /// resting HR the SAME way as `calculateTrainingMetrics` — see the note
    /// there. Both must use one source or their HR-backed TRIMP diverges.
    func fetchAppleRestingHR() async -> Double? {
        guard manager.isHealthKitAvailable else { return nil }
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            debugLog("[HealthKitManager] Resting heart rate type unavailable")
            return nil
        }
        let value = await latestQuantityValue(rhrType, unit: HKUnit.count().unitDivided(by: .minute()))
        if let value { WorkoutLoadRestingHR.record(value) }
        return value
    }

    /// Fetch latest VO2max from HealthKit
    func fetchVO2Max() async -> Double? {
        guard manager.isHealthKitAvailable, let vo2Type = HKTypes.quantity(.vo2Max) else { return nil }
        let vo2 = await latestQuantityValue(vo2Type, unit: HKUnit(from: "ml/kg*min"))
        if vo2 == nil { debugLog("[HealthKitManager] No VO2max data found") }
        return vo2
    }

    /// Most recent sample of a quantity type, in the requested unit.
    private func latestQuantityValue(_ type: HKQuantityType, unit: HKUnit) async -> Double? {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                resolve((samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
        }
    }

    /// Calculate TrainingPeaks-style ATL/CTL/TSB using exponentially weighted moving averages
    /// - ATL: 7-day time constant (acute training load / "fatigue")
    /// - CTL: 42-day time constant (chronic training load / "fitness")
    /// - TSB: CTL - ATL ("form" or freshness)
    /// - forMorningReading: If true, calculates through YESTERDAY (morning readings reflect overnight recovery)
    func calculateTrainingMetrics(
        restingHR: Double = 60,
        userMaxHR: Double? = nil,
        forMorningReading: Bool = true,
        relativeTo referenceDate: Date = Date(),
        additionalWorkouts: [HealthKitManager.WorkoutSummary] = [],
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]? = nil
    ) async -> HealthKitManager.TrainingMetrics {
        let effectiveRHR = await fetchAppleRestingHR() ?? restingHR
        let allWorkouts = await mergedTrainingWorkouts(
            referenceDate: referenceDate,
            additionalWorkouts: additionalWorkouts,
            preloadedHealthKitWorkouts: preloadedHealthKitWorkouts
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let dailyTrimp = buildDailyTrimp(
            workouts: allWorkouts, effectiveRHR: effectiveRHR, userMaxHR: userMaxHR,
            today: today, forMorningReading: forMorningReading, calendar: calendar
        )
        var metrics = Self.metrics(
            dailyTrimp: dailyTrimp, load: computeEWMA(dailyTrimp: dailyTrimp, today: today, calendar: calendar),
            allWorkouts: allWorkouts, today: today, calendar: calendar, forMorningReading: forMorningReading
        )
        await applyVO2Max(to: &metrics)
        return metrics
    }

    nonisolated private static func metrics(
        dailyTrimp: [Date: Double],
        load: (atl: Double, ctl: Double),
        allWorkouts: [HealthKitManager.WorkoutSummary],
        today: Date,
        calendar: Calendar,
        forMorningReading: Bool
    ) -> HealthKitManager.TrainingMetrics {
        let todayTrimp = dailyTrimp[today] ?? 0
        let (atl, ctl) = loadWithTodayApplied(load, todayTrimp: todayTrimp, forMorningReading: forMorningReading)
        return HealthKitManager.TrainingMetrics(
            atl: atl, ctl: ctl, tsb: ctl - atl,
            dailyTrimp: dailyTrimp, todayTrimp: todayTrimp,
            todayWorkouts: allWorkouts.filter { calendar.isDate($0.date, inSameDayAs: today) },
            recentWorkouts: recentWorkouts(allWorkouts, today: today, calendar: calendar)
        )
    }

    /// 180 days = ~4.3× the CTL time constant of 42. Convergence math:
    ///   (1 - 1/42)^180 ≈ 1.3 % residual seed influence
    /// Below that the seed (or a too-short window) materially compresses CTL,
    /// especially for users whose training volume has changed in the last 60
    /// days — the user's report of an implausibly low CTL is consistent with a 120-day
    /// window (5 % residual) plus an averaged seed pulling CTL toward the older,
    /// lower-volume tail. With 180 days + a clean zero seed (see `computeEWMA`),
    /// CTL converges to the genuine 42-day EWMA of recent training.
    ///
    /// `additionalWorkouts` lets the caller fold in explicit
    /// extras. ALSO: this ALWAYS folds in the app's own SessionArchive entries
    /// automatically. If the merge happened only in
    /// `TrainingMetricsCache.refresh`, the repair path
    /// (`calculateTrainingLoad → calculateTrainingMetrics`), session-acceptance,
    /// and reanalyze paths would all see HealthKit-only and write ATL=CTL=0 back into
    /// the frozen snapshot when HK is empty. Doing the merge HERE means every
    /// caller gets it for free — repair actually repairs, acceptance freezes the
    /// right value, etc.
    ///
    /// Accepts a preloaded workout list to avoid double-fetching
    /// when `TrainingMetricsCache.refresh()` already pulled the same 180-day
    /// window for its `current` calculation and is about to call us again
    /// (indirectly via `buildDailySeries`) for the historical replay.
    ///
    /// `fromAppArchive` does not require the main actor (see its
    /// doc-comment) and runs in a detached task: this type is main-actor
    /// isolated, and the 100+ lightweight decodes on main produce a 20 s
    /// tap-to-Start hang.
    ///
    /// Archive (H10) is authoritative; HealthKit only fills in training the app
    /// didn't record — see `mergeArchiveAuthoritative`. (Was
    /// `deduplicateWorkouts(healthKitWorkouts + archiveWorkouts + …)`, which let
    /// a degraded HealthKit copy of an H10 workout inflate the load.)
    private func mergedTrainingWorkouts(
        referenceDate: Date,
        additionalWorkouts: [HealthKitManager.WorkoutSummary],
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]?
    ) async -> [HealthKitManager.WorkoutSummary] {
        let healthKitWorkouts: [HealthKitManager.WorkoutSummary]
        if let preloaded = preloadedHealthKitWorkouts {
            healthKitWorkouts = preloaded
        } else {
            healthKitWorkouts = await fetchWorkoutsExtended(days: 180, relativeTo: referenceDate)
        }
        let archive = AppDependencies.current.storage.sessionArchive
        let archiveWorkouts = await Task.detached(priority: .userInitiated) {
            HealthKitManager.WorkoutSummary.fromAppArchive(archive: archive, days: 180, relativeTo: referenceDate)
        }.value
        return Self.mergeArchiveAuthoritative(
            archive: archiveWorkouts,
            healthKit: healthKitWorkouts,
            additional: additionalWorkouts
        )
    }

    /// The last `days` of training: every archive workout plus the HealthKit
    /// ones that don't overlap it (`mergeArchiveAuthoritative`).
    private func recentMergedWorkouts(days: Int, relativeTo referenceDate: Date) async -> [HealthKitManager.WorkoutSummary] {
        let healthKitWorkouts = await fetchRecentWorkouts(days: days, relativeTo: referenceDate)
        let archive = AppDependencies.current.storage.sessionArchive
        let archiveWorkouts = await Task.detached(priority: .userInitiated) {
            HealthKitManager.WorkoutSummary.fromAppArchive(archive: archive, days: days, relativeTo: referenceDate)
        }.value
        return Self.mergeArchiveAuthoritative(archive: archiveWorkouts, healthKit: healthKitWorkouts)
    }

    /// Apply today as a discrete EWMA step — exact e^(-1/τ) decay to match
    /// `computeEWMA` (Banister/Busso; TrainingPeaks convention). Morning
    /// readings stop at yesterday, so they skip the step entirely.
    nonisolated private static func loadWithTodayApplied(
        _ load: (atl: Double, ctl: Double),
        todayTrimp: Double,
        forMorningReading: Bool
    ) -> (atl: Double, ctl: Double) {
        guard !forMorningReading else { return load }
        let atlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.acuteDays))
        let ctlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.chronicDays))
        return (
            todayTrimp * (1 - atlDecay) + load.atl * atlDecay,
            todayTrimp * (1 - ctlDecay) + load.ctl * ctlDecay
        )
    }

    /// `Calendar.date` returns optional; falls back to `today` so
    /// the recent-workouts filter degrades to "none" rather than crashing on
    /// the rare invalid-component case.
    nonisolated private static func recentWorkouts(_ all: [HealthKitManager.WorkoutSummary], today: Date, calendar: Calendar) -> [HealthKitManager.WorkoutSummary] {
        let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: today) ?? today
        return all.filter { $0.date >= fourteenDaysAgo }.sorted { $0.date > $1.date }
    }

    /// Fold the latest VO2max + 30-day trend into the metrics
    /// snapshot so the sync `TrainingMetricsCache.snapshot()` path makes them
    /// visible to the AI tool layer without an async hop. Both stay nil when no
    /// HealthKit data exists.
    private func applyVO2Max(to metrics: inout HealthKitManager.TrainingMetrics) async {
        metrics.vo2MaxLatest = await fetchVO2Max()
        guard let trend = await fetchVO2MaxTrend(days: 30) else { return }
        metrics.vo2MaxChange30Days = trend.latest - trend.oldestInWindow
        metrics.vo2MaxSampleCount30Days = trend.sampleCount
    }

    /// Build daily TRIMP totals from workouts over the EWMA lookback window.
    /// Pre-populates every day with 0 so rest days correctly decay the EWMA
    /// (a missing dictionary key would silently skip the day's iteration in
    /// `computeEWMA`, holding CTL artificially high). Workouts are summed
    /// per local-calendar day so two same-day sessions don't double-count
    /// the day's slot.
    private func buildDailyTrimp(
        workouts: [HealthKitManager.WorkoutSummary], effectiveRHR: Double, userMaxHR: Double?,
        today: Date, forMorningReading: Bool, calendar: Calendar
    ) -> [Date: Double] {
        // Fall back to `today` if -1 day fails (won't happen for
        // any sane calendar, but no force-unwrap).
        let ewmaEndDate = forMorningReading
            ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
            : today
        var dailyTrimp: [Date: Double] = [:]
        for dayOffset in 0 ..< Self.ewmaLookbackDays {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: ewmaEndDate) {
                dailyTrimp[date] = 0
            }
        }
        let earliestBucket = calendar.date(byAdding: .day, value: -(Self.ewmaLookbackDays - 1), to: ewmaEndDate) ?? ewmaEndDate
        accumulateWorkoutLoads(
            workouts, into: &dailyTrimp, effectiveRHR: effectiveRHR, userMaxHR: userMaxHR,
            today: today, earliestBucket: earliestBucket, calendar: calendar
        )
        Self.clampDailyCeiling(&dailyTrimp)
        return dailyTrimp
    }

    /// Per-day physiological ceiling — final backstop so a dedup miss (two
    /// copies of one session) or any single corrupt load can't stack a day's
    /// TRIMP past what a human can produce. Set well above a hard
    /// multi-session day, so it only ever clips clearly-broken values.
    nonisolated private static func clampDailyCeiling(_ dailyTrimp: inout [Date: Double]) {
        for day in Array(dailyTrimp.keys) where (dailyTrimp[day] ?? 0) > TrainingConstants.TRIMP.maxDailyLoad {
            dailyTrimp[day] = TrainingConstants.TRIMP.maxDailyLoad
        }
    }

    /// Lookback window for the EWMA chain. 180 days ≈ 4.3× the 42-day CTL
    /// time constant — long enough that a zero seed contributes < 2 % to
    /// today's CTL, so we don't need the older "seed from average" hack.
    nonisolated static let ewmaLookbackDays = 180

    /// Calculate comprehensive training load
    /// - forMorningReading: If true, calculates through yesterday (for stored morning HRV context)
    ///                      If false, includes today's training (for live current-state display)
    ///
    /// The recent workouts, weekly load and days since a hard workout come
    /// from the same archive-authoritative merge as the ATL/CTL metrics, so a
    /// strap workout that never reached HealthKit counts in all of them.
    func calculateTrainingLoad(days: Int = 7, forMorningReading: Bool = true, relativeTo referenceDate: Date = Date()) async -> HealthKitManager.TrainingLoad {
        let workouts = await recentMergedWorkouts(days: days, relativeTo: referenceDate)
        let vo2Max = await fetchVO2Max()
        let vo2Trend = await fetchVO2MaxTrend(days: 30)
        let metrics = await calculateTrainingMetrics(forMorningReading: forMorningReading, relativeTo: referenceDate)
        // Weekly load score: sum of intensity scores, normalised to 7 days, capped at 100.
        let weeklyLoad = min(workouts.reduce(0) { $0 + $1.intensityScore } / Double(max(days, 1)) * 7, 100)
        var load = HealthKitManager.TrainingLoad(
            vo2Max: vo2Max,
            recentWorkouts: workouts,
            weeklyLoadScore: weeklyLoad,
            daysSinceHardWorkout: HealthKitManager.TrainingLoad.daysSinceHardWorkout(in: workouts, relativeTo: referenceDate),
            acuteChronicRatio: metrics.acuteChronicRatio,
            metrics: metrics
        )
        if let trend = vo2Trend {
            load.vo2MaxChange30Days = trend.latest - trend.oldestInWindow
            load.vo2MaxSampleCount30Days = trend.sampleCount
        }
        return load
    }
}

// MARK: - File-scope helpers
//
// Each names no member of HealthKitManager and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.

/// Only counts workouts that fall inside the zero-filled
/// window. `calculateTrainingMetrics` is sometimes handed a 400-day
/// HealthKit set (the cache preloads that width for its historical series)
/// while `buildDailyTrimp` only zero-fills `ewmaLookbackDays` (180). A
/// workout OLDER than the fill window lands in a bucket with no surrounding
/// rest days, so `computeEWMA` steps onto it without decaying across the
/// gap → CTL biased HIGH. That also made the dashboard/AI number (built
/// from the 400-day set) drift ABOVE the trajectory chart and the frozen
/// `trainingSnapshot` (both 180-day). Clamping the workout window to the
/// fill window keeps span==span, so every caller agrees regardless of
/// whether workouts were preloaded. Future-dated records (corrupt clock /
/// bad third-party import) are skipped for the same reason.
///
/// Uses `effectiveLoad` instead of `calculateTrimp` so
/// power-backed sessions feed powerTSS into the daily buildup that drives
/// ATL/CTL/TSB. Falls back to HR-based Banister TRIMP only when no
/// precomputed load is present (i.e. for HK-sourced workouts that never
/// went through our analyzer). One debug line per power-backed workout lets
/// the next log prove the chain is taking the right path.
private func accumulateWorkoutLoads(
    _ workouts: [HealthKitManager.WorkoutSummary], into dailyTrimp: inout [Date: Double],
    effectiveRHR: Double, userMaxHR: Double?,
    today: Date, earliestBucket: Date, calendar: Calendar
) {
    var powerBackedDays = 0
    var hrBackedDays = 0
    for workout in workouts {
        let workoutDay = calendar.startOfDay(for: workout.date)
        guard workoutDay <= today, workoutDay >= earliestBucket else { continue }
        dailyTrimp[workoutDay, default: 0] += workout.effectiveLoad(restingHR: effectiveRHR, maxHR: userMaxHR)
        if workout.precomputedLoadSource == "power" { powerBackedDays += 1 } else { hrBackedDays += 1 }
    }
    if powerBackedDays + hrBackedDays > 0 {
        debugLog("[HealthKitManager.TrainingLoad] dailyTRIMP built from \(workouts.count) workouts — \(powerBackedDays) power-backed, \(hrBackedDays) HR-backed")
    }
}

/// Compute ATL (7-day) and CTL (42-day) EWMA through yesterday using Banister model.
/// Seeds from 0 because the lookback window is long enough that initial
/// conditions wash out. The previous version seeded from the window's
/// average, which biased CTL toward the older tail of the window — a
/// user whose volume has changed in the last 60 days would see a CTL
/// pulled below their genuine recent EWMA.
private func computeEWMA(dailyTrimp: [Date: Double], today: Date, calendar _: Calendar) -> (atl: Double, ctl: Double) {
    // EXACT exponential decay `e^(-1/τ)`, the form used by
    // TrainingPeaks / intervals.icu / GoldenCheetah and the Banister/Busso
    // impulse-response model. A `1/τ` linear approximation is ~7% off
    // on ATL (τ=7): 1/7=0.1429 vs 1-e^(-1/7)=0.1331 — enough that the app's
    // fatigue/TSB would not match those references. CTL (τ=42) barely moves.
    // PMC EWMA: CTL τ=42d, ATL τ=7d; X_today = load·(1−e^(−1/τ)) +
    // X_yesterday·e^(−1/τ); TSB = CTL−ATL — Coggan Performance Manager Chart
    // (TrainingPeaks); decay λ=1−e^(−1/τ) per GoldenCheetah/intervals.icu.
    let atlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.acuteDays)), ctlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.chronicDays))
    let sortedDays = dailyTrimp.keys.sorted()

    var atl: Double = 0
    var ctl: Double = 0
    for date in sortedDays where date < today {
        let dayTrimp = dailyTrimp[date] ?? 0
        atl = dayTrimp * (1 - atlDecay) + atl * atlDecay
        ctl = dayTrimp * (1 - ctlDecay) + ctl * ctlDecay
    }
    return (atl, ctl)
}
