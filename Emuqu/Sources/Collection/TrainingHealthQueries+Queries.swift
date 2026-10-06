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

    /// Stream the route's CLLocations (delivered in batches). Empty when the
    /// query fails, or when HealthKit has not reported the last batch within
    /// `backgroundAggregateQueryTimeoutSec` — the bound the workout and
    /// route-series queries before it already have — so a route query that
    /// never reports done cannot hang the caller awaiting it.
    func routeLocations(_ route: HKWorkoutRoute) async -> [CLLocation] {
        await manager.runBoundedQuery(timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec) { resolve in
            Self.routeQuery(route, resolve: resolve)
        } ?? []
    }

    /// `HKWorkoutRouteQuery` delivers locations in batches on an arbitrary
    /// queue and calls back repeatedly until `done`. A single lock owns the
    /// accumulator and the resolved flag, so batches accumulate atomically
    /// and `resolve` runs once with the whole route; an error resolves nil.
    nonisolated private static func routeQuery(
        _ route: HKWorkoutRoute,
        resolve: @escaping @Sendable ([CLLocation]?) -> Void
    ) -> HKQuery {
        let state = OSAllocatedUnfairLock(initialState: (accumulated: [CLLocation](), resumed: false))
        return HKWorkoutRouteQuery(route: route) { _, locs, done, error in
            if let error {
                debugLog("[TrainingHealthQueries] Route query failed: \(error.localizedDescription)", level: .warning)
                return resolve(nil)
            }
            guard let finished = Self.accumulateRouteBatch(state, locs: locs, done: done) else { return }
            resolve(finished)
        }
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
    /// - restingHR / userMaxHR: the anchors HR-only workouts are scored
    ///   against. Nil resolves them the one way every training-load path does
    ///   (`trainingHeartRateAnchors`: Apple's resting HR, else the user's
    ///   setting; the user's max HR).
    /// - forMorningReading: If true, calculates through YESTERDAY (morning readings reflect overnight recovery)
    func calculateTrainingMetrics(
        restingHR: Double? = nil,
        userMaxHR: Double? = nil,
        forMorningReading: Bool = true,
        relativeTo referenceDate: Date = Date(),
        additionalWorkouts: [HealthKitManager.WorkoutSummary] = [],
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]? = nil
    ) async -> HealthKitManager.TrainingMetrics {
        let anchors = await heartRateAnchors(restingHR: restingHR, maxHR: userMaxHR)
        let allWorkouts = await mergedTrainingWorkouts(
            referenceDate: referenceDate,
            additionalWorkouts: additionalWorkouts,
            preloadedHealthKitWorkouts: preloadedHealthKitWorkouts
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let dailyTrimp = Self.buildDailyTrimp(
            workouts: allWorkouts, anchors: anchors, today: today,
            forMorningReading: forMorningReading, calendar: calendar
        )
        var metrics = Self.metrics(
            dailyTrimp: dailyTrimp, allWorkouts: allWorkouts, today: today,
            calendar: calendar, forMorningReading: forMorningReading
        )
        await applyVO2Max(to: &metrics)
        return metrics
    }

    /// The heart-rate anchors training load scores HR-only workouts against:
    /// Apple's measured resting HR when Health has one, else the user's
    /// resting-HR setting, and the user's max HR. The live metrics and the
    /// cache's day-by-day series both resolve them here.
    func trainingHeartRateAnchors() async -> TrainingLoadSeries.HeartRateAnchors {
        let apple = await fetchAppleRestingHR()
        let settings = AppDependencies.current.app.settingsManager.settings
        return .resolve(
            appleRestingHR: apple, settingRestingHR: settings.effectiveRestingHR, settingMaxHR: settings.effectiveMaxHR
        )
    }

    /// The caller's anchors, with any it left nil resolved by `trainingHeartRateAnchors`.
    private func heartRateAnchors(restingHR: Double?, maxHR: Double?) async -> TrainingLoadSeries.HeartRateAnchors {
        if let restingHR, let maxHR { return .init(restingHR: restingHR, maxHR: maxHR) }
        let resolved = await trainingHeartRateAnchors()
        return .init(restingHR: restingHR ?? resolved.restingHR, maxHR: maxHR ?? resolved.maxHR)
    }

    /// Morning readings stop at yesterday, so today's load is not applied;
    /// the live view takes today as one more EWMA step.
    nonisolated private static func metrics(
        dailyTrimp: [Date: Double],
        allWorkouts: [HealthKitManager.WorkoutSummary],
        today: Date,
        calendar: Calendar,
        forMorningReading: Bool
    ) -> HealthKitManager.TrainingMetrics {
        let todayTrimp = dailyTrimp[today] ?? 0
        let lastDay = forMorningReading ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today) : today
        let load = TrainingLoadSeries.point(through: lastDay, in: dailyTrimp)
        return HealthKitManager.TrainingMetrics(
            atl: load.atl, ctl: load.ctl, tsb: load.tsb,
            dailyTrimp: dailyTrimp, todayTrimp: todayTrimp,
            todayWorkouts: allWorkouts.filter { calendar.isDate($0.date, inSameDayAs: today) },
            recentWorkouts: recentWorkouts(allWorkouts, today: today, calendar: calendar)
        )
    }

    /// The workouts the live metrics are built from: the last
    /// `ewmaLookbackDays` of HealthKit workouts (or the caller's preloaded
    /// list, which may reach further back; `buildDailyTrimp` drops anything
    /// older than its window) merged with the app's own archive.
    ///
    /// `additionalWorkouts` lets the caller fold in explicit extras. The
    /// archive merge happens here rather than in `TrainingMetricsCache` so
    /// every caller gets it: the repair path
    /// (`calculateTrainingLoad → calculateTrainingMetrics`), session
    /// acceptance and reanalysis would otherwise see HealthKit only and
    /// freeze ATL=CTL=0 into the snapshot when HealthKit is empty.
    ///
    /// `fromAppArchive` does not require the main actor (see its
    /// doc-comment) and runs in a detached task: this type is main-actor
    /// isolated, and the 100+ lightweight decodes on main produce a 20 s
    /// tap-to-Start hang.
    ///
    /// Archive (H10) is authoritative; HealthKit only fills in training the app
    /// didn't record — see `mergeArchiveAuthoritative`.
    private func mergedTrainingWorkouts(
        referenceDate: Date,
        additionalWorkouts: [HealthKitManager.WorkoutSummary],
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]?
    ) async -> [HealthKitManager.WorkoutSummary] {
        let healthKitWorkouts: [HealthKitManager.WorkoutSummary]
        if let preloaded = preloadedHealthKitWorkouts {
            healthKitWorkouts = preloaded
        } else {
            healthKitWorkouts = await fetchWorkoutsExtended(days: Self.ewmaLookbackDays, relativeTo: referenceDate)
        }
        let archive = AppDependencies.current.storage.sessionArchive
        let archiveWorkouts = await Task.detached(priority: .userInitiated) {
            HealthKitManager.WorkoutSummary.fromAppArchive(archive: archive, days: Self.ewmaLookbackDays, relativeTo: referenceDate)
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

    /// Daily load over the EWMA lookback window, through today
    /// (`TrainingLoadSeries.dailyLoad`, the builder the cache's series uses
    /// too). The window's oldest day is `ewmaLookbackDays` before the last
    /// EWMA day (yesterday for a morning reading, else today). Today is
    /// always bucketed, so a morning reading still reports today's load
    /// without stepping the EWMA with it.
    nonisolated private static func buildDailyTrimp(
        workouts: [HealthKitManager.WorkoutSummary], anchors: TrainingLoadSeries.HeartRateAnchors,
        today: Date, forMorningReading: Bool, calendar: Calendar
    ) -> [Date: Double] {
        let ewmaEndDate = forMorningReading
            ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
            : today
        let earliestBucket = calendar.date(byAdding: .day, value: -(ewmaLookbackDays - 1), to: ewmaEndDate) ?? ewmaEndDate
        let daily = TrainingLoadSeries.dailyLoad(
            workouts: workouts, firstDay: earliestBucket, lastDay: today, anchors: anchors, calendar: calendar
        )
        logLoadSources(workouts, from: earliestBucket, through: today, calendar: calendar)
        return daily
    }

    /// One line per build saying how many workouts were scored by power and
    /// how many by heart rate, so a log shows which path the load took.
    nonisolated private static func logLoadSources(
        _ workouts: [HealthKitManager.WorkoutSummary], from first: Date, through last: Date, calendar: Calendar
    ) {
        let inWindow = workouts.filter { (first ... last).contains(calendar.startOfDay(for: $0.date)) }
        guard !inWindow.isEmpty else { return }
        let powerBacked = inWindow.filter { $0.precomputedLoadSource == "power" }.count
        debugLog("[HealthKitManager.TrainingLoad] dailyTRIMP built from \(inWindow.count) workouts — \(powerBacked) power-backed, \(inWindow.count - powerBacked) other")
    }

    /// Lookback window for the live EWMA chain. 180 days ≈ 4.3× the 42-day
    /// CTL time constant, so the zero seed leaves e^(−180/42) ≈ 1.4 % of
    /// the CTL of 180 days ago in today's CTL — no "seed from average"
    /// (that biased CTL toward the older, lower-volume tail).
    nonisolated static let ewmaLookbackDays = 180

    /// Calculate comprehensive training load
    /// - forMorningReading: If true, calculates through yesterday (for stored morning HRV context)
    ///                      If false, includes today's training (for live current-state display)
    ///
    /// The recent workouts, weekly load and days since a hard workout come
    /// from the same archive-authoritative merge as the ATL/CTL metrics, so a
    /// strap workout that never reached HealthKit counts in all of them, and
    /// all of them use the same resolved heart-rate anchors.
    func calculateTrainingLoad(days: Int = 7, forMorningReading: Bool = true, relativeTo referenceDate: Date = Date()) async -> HealthKitManager.TrainingLoad {
        let workouts = await recentMergedWorkouts(days: days, relativeTo: referenceDate)
        let vo2Max = await fetchVO2Max()
        let vo2Trend = await fetchVO2MaxTrend(days: 30)
        let anchors = await trainingHeartRateAnchors()
        let metrics = await calculateTrainingMetrics(
            restingHR: anchors.restingHR, userMaxHR: anchors.maxHR,
            forMorningReading: forMorningReading, relativeTo: referenceDate
        )
        var load = Self.trainingLoad(
            workouts: workouts, days: days, anchors: anchors, vo2Max: vo2Max,
            metrics: metrics, relativeTo: referenceDate
        )
        if let trend = vo2Trend {
            load.vo2MaxChange30Days = trend.latest - trend.oldestInWindow
            load.vo2MaxSampleCount30Days = trend.sampleCount
        }
        return load
    }

    /// The training load from already-fetched parts. Weekly load score: the
    /// sum of intensity scores, normalised to 7 days, capped at 100. Intensity
    /// and "hard" are both judged against `anchors`.
    static func trainingLoad(
        workouts: [HealthKitManager.WorkoutSummary],
        days: Int,
        anchors: TrainingLoadSeries.HeartRateAnchors,
        vo2Max: Double?,
        metrics: HealthKitManager.TrainingMetrics,
        relativeTo referenceDate: Date
    ) -> HealthKitManager.TrainingLoad {
        let intensity = workouts.reduce(0) { $0 + $1.intensityScore(anchors: anchors) }
        return HealthKitManager.TrainingLoad(
            vo2Max: vo2Max,
            recentWorkouts: workouts,
            weeklyLoadScore: min(intensity / Double(max(days, 1)) * 7, 100),
            daysSinceHardWorkout: HealthKitManager.TrainingLoad.daysSinceHardWorkout(
                in: workouts, anchors: anchors, relativeTo: referenceDate
            ),
            acuteChronicRatio: metrics.acuteChronicRatio,
            metrics: metrics
        )
    }
}
