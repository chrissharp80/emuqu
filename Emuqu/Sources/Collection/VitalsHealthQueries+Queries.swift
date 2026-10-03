import Foundation
import HealthKit

// MARK: - Recovery Vitals

extension VitalsHealthQueries {
    /// Fetch recovery vitals from last night's sleep (or a specific night for historical sessions)
    /// - Parameter referenceDate: Anchor date for the vitals query window. Defaults to now.
    ///   For historical sessions, pass the session's end date to fetch that night's vitals.
    func fetchRecoveryVitals(relativeTo referenceDate: Date = Date()) async -> HealthKitManager.RecoveryVitals {
        async let respRate = fetchRespiratoryRate(relativeTo: referenceDate)
        async let respBaseline = fetchRespiratoryRateBaseline(relativeTo: referenceDate)
        async let spo2 = fetchOxygenSaturation(relativeTo: referenceDate)
        async let spo2Min = fetchOxygenSaturationMin(relativeTo: referenceDate)
        async let temp = fetchWristTemperature(relativeTo: referenceDate)
        async let tempBaseline = fetchWristTemperatureBaseline(relativeTo: referenceDate)
        async let rhr = fetchRestingHeartRate(relativeTo: referenceDate)

        return await HealthKitManager.RecoveryVitals(
            respiratoryRate: respRate,
            respiratoryRateBaseline: respBaseline,
            oxygenSaturation: spo2,
            oxygenSaturationMin: spo2Min,
            wristTemperature: temp,
            wristTemperatureBaseline: tempBaseline,
            restingHeartRate: rhr
        )
    }

    /// Fetch respiratory rate around a reference date
    private func fetchRespiratoryRate(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, let respType = HKTypes.quantity(.respiratoryRate) else { return nil }
        // 24-hour window centered around the reference date's overnight period
        let predicate = Self.vitalsWindow(hours: 24, relativeTo: referenceDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: respType,
                predicate: predicate,
                limit: 10,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                resolve(Self.meanRespiratoryRate(samples: samples, error: error))
            }
        }
    }

    /// Trailing window of `hours` ending at the reference date, clamped to now.
    /// Every vitals read shares this shape.
    nonisolated private static func vitalsWindow(hours: Int, relativeTo referenceDate: Date) -> NSPredicate {
        let windowEnd = min(referenceDate, Date())
        // No force-unwrap: fall back to an empty window.
        let windowStart = Calendar.current.date(byAdding: .hour, value: -hours, to: windowEnd) ?? windowEnd
        return HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
    }

    nonisolated private static func vitalsWindow(days: Int, relativeTo referenceDate: Date) -> NSPredicate {
        let windowEnd = min(referenceDate, Date())
        // No force-unwrap: fall back to an empty window.
        let windowStart = Calendar.current.date(byAdding: .day, value: -days, to: windowEnd) ?? windowEnd
        return HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
    }

    /// The `days` before tonight's 24-hour reading window: ends where
    /// `vitalsWindow(hours: 24, ...)` begins, so a baseline built on it never
    /// contains the reading it is compared with.
    nonisolated private static func priorNightsWindow(days: Int, relativeTo referenceDate: Date) -> NSPredicate {
        let tonightStart = min(referenceDate, Date()).addingTimeInterval(-24 * 3600)
        let windowStart = Calendar.current.date(byAdding: .day, value: -days, to: tonightStart) ?? tonightStart
        return HKQuery.predicateForSamples(withStart: windowStart, end: tonightStart, options: .strictStartDate)
    }

    nonisolated private static func meanRespiratoryRate(samples: [HKSample]?, error: Error?) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Respiratory rate query error: \(error.localizedDescription)")
            return nil
        }
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
            debugLog("[HealthKitManager] No respiratory rate samples found in 24h window")
            return nil
        }
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        return samples.map { $0.quantity.doubleValue(for: perMinute) }.reduce(0, +) / Double(samples.count)
    }

    /// Fetch 7-day respiratory rate baseline relative to a date.
    ///
    /// Always tries HealthKit first. On success, the value is persisted to
    /// `RespiratoryBaselineCache` so future callers can fall back to it when
    /// HK is unreachable (e.g. morning processing on a still-locked phone,
    /// which returns `errorDatabaseInaccessible`). When HK returns nil/error,
    /// the cached value is returned — a baseline from a few days ago is the
    /// same physiology as today's, and far better than a frozen "no data"
    /// label.
    private func fetchRespiratoryRateBaseline(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, let respType = HKTypes.quantity(.respiratoryRate) else {
            return RespiratoryBaselineCache.read()?.value
        }
        let predicate = Self.vitalsWindow(days: 7, relativeTo: referenceDate)
        let liveValue: Double? = await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: respType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                resolve(Self.respiratoryBaselineValue(statistics: statistics, error: error))
            }
        }
        if let liveValue {
            RespiratoryBaselineCache.write(value: liveValue)
            return liveValue
        }
        return RespiratoryBaselineCache.read()?.value
    }

    nonisolated private static func respiratoryBaselineValue(statistics: HKStatistics?, error: Error?) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Respiratory baseline query error: \(error.localizedDescription)")
            return nil
        }
        guard let avg = statistics?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) else {
            debugLog("[HealthKitManager] No respiratory baseline data found in 7-day window")
            return nil
        }
        return avg
    }

    /// Fetch oxygen saturation around a reference date
    private func fetchOxygenSaturation(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, let spo2Type = HKTypes.quantity(.oxygenSaturation) else { return nil }
        let predicate = Self.vitalsWindow(hours: 24, relativeTo: referenceDate)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: spo2Type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                resolve(Self.spo2Percent(statistics?.averageQuantity(), error: error, label: "SpO2 query error", logMiss: true))
            }
        }
    }

    /// Fetch minimum SpO2 around a reference date
    private func fetchOxygenSaturationMin(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, let spo2Type = HKTypes.quantity(.oxygenSaturation) else { return nil }
        let predicate = Self.vitalsWindow(hours: 24, relativeTo: referenceDate)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: spo2Type,
                quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, statistics, error in
                resolve(Self.spo2Percent(statistics?.minimumQuantity(), error: error, label: "SpO2 min query error", logMiss: false))
            }
        }
    }

    /// HealthKit reports SpO2 as a fraction; the app displays a percentage.
    nonisolated private static func spo2Percent(_ quantity: HKQuantity?, error: Error?, label: String, logMiss: Bool) -> Double? {
        if let error {
            logSpO2Error(error, label: label)
            return nil
        }
        guard let value = quantity?.doubleValue(for: .percent()) else {
            if logMiss { debugLog("[HealthKitManager] No SpO2 data found in 24h window") }
            return nil
        }
        return value * 100
    }

    /// "No data available" is the dominant case for users who haven't taken an
    /// SpO2 reading in the last 24h — not a real error. Demoted to debug so the
    /// release log isn't fingerprinting that the user lacks SpO2 data and so
    /// triage logs aren't drowned in routine misses.
    nonisolated private static func logSpO2Error(_ error: Error, label: String) {
        let nsError = error as NSError
        let isMissingData = nsError.domain == HKErrorDomain
            && nsError.code == HKError.Code.errorNoData.rawValue
        guard !isMissingData else { return }
        debugLog("[HealthKitManager] \(label): \(error.localizedDescription)", level: .warning)
    }

    /// Fetch wrist temperature deviation around a reference date (iOS 16+)
    private func fetchWristTemperature(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, #available(iOS 16.0, *),
              let tempType = HKTypes.quantity(.appleSleepingWristTemperature)
        else { return nil }
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let predicate = Self.vitalsWindow(hours: 24, relativeTo: referenceDate)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: tempType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                resolve(Self.latestWristTemperatureDeviation(samples: samples, error: error))
            }
        }
    }

    nonisolated private static func latestWristTemperatureDeviation(samples: [HKSample]?, error: Error?) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Wrist temp query error: \(error.localizedDescription)")
            return nil
        }
        guard let sample = samples?.first as? HKQuantitySample else {
            debugLog("[HealthKitManager] No wrist temp samples found in 24h window")
            return nil
        }
        let deviation = wristTemperatureDeviation(sample.quantity.doubleValue(for: .degreeCelsius()))
        if deviation == nil {
            debugLog("[HealthKitManager] Wrist temp value out of expected range, ignoring")
        }
        return deviation
    }

    /// Puts a sample on one scale: values that already look like a deviation
    /// (-5 to +5°C) are kept, absolute readings (≈ 33-38°C) are offset by a
    /// fixed 36.5°C. That offset is a common scale, NOT a personal baseline: a
    /// reading only becomes a deviation from the user's own norm once the
    /// baseline (normalised the same way) is subtracted, which the recovery
    /// score does. Anything outside both ranges is not a temperature we can
    /// interpret.
    nonisolated private static func wristTemperatureDeviation(_ temp: Double) -> Double? {
        if temp >= -5, temp <= 5 { return temp }
        if temp >= 30, temp <= 42 { return temp - 36.5 }
        return nil
    }

    /// Fetch the wrist temperature baseline: the mean of the 7 days BEFORE the
    /// night being read, normalised the same way as that night's reading.
    ///
    /// The recovery score reads wrist temperature as tonight minus this value
    /// (`RecoveryScoreCalculator.wristTemperatureAgainstPersonalBaseline`). The
    /// window stops where tonight's 24-hour reading window starts, so tonight's
    /// own sample is not averaged into the baseline it is compared with.
    ///
    /// Same caching behavior as `fetchRespiratoryRateBaseline`: writes the
    /// last-known-good value to `WristTemperatureBaselineCache` on success and
    /// falls back to it when HK is unreachable.
    private func fetchWristTemperatureBaseline(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable, #available(iOS 16.0, *),
              let tempType = HKTypes.quantity(.appleSleepingWristTemperature)
        else { return WristTemperatureBaselineCache.read()?.value }
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let predicate = Self.priorNightsWindow(days: 7, relativeTo: referenceDate)
        let liveValue: Double? = await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: tempType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                resolve(Self.meanWristTemperatureDeviation(samples: samples, error: error))
            }
        }
        if let liveValue {
            WristTemperatureBaselineCache.write(value: liveValue)
            return liveValue
        }
        return WristTemperatureBaselineCache.read()?.value
    }

    /// Normalises each sample the same way `fetchWristTemperature` does, then
    /// averages whatever survived.
    nonisolated private static func meanWristTemperatureDeviation(samples: [HKSample]?, error: Error?) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Wrist temp baseline query error: \(error.localizedDescription)")
            return nil
        }
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
            debugLog("[HealthKitManager] No wrist temp baseline data found in 7-day window")
            return nil
        }
        let deviations = samples.compactMap {
            wristTemperatureDeviation($0.quantity.doubleValue(for: .degreeCelsius()))
        }
        guard !deviations.isEmpty else { return nil }
        return deviations.reduce(0, +) / Double(deviations.count)
    }

    // MARK: - Vitals Data Observer

    /// Start observing HealthKit for new vitals samples (Apple Watch sync).
    /// Apple Watch writes overnight respiratory rate, SpO2, wrist temperature,
    /// and resting HR MINUTES to HOURS after sleep ends — long after the user
    /// has tapped "I'm Up" and the vitalsSnapshot was captured. Each time a
    /// new sample arrives, `vitalsDataVersion` is incremented so views can
    /// reactively re-fetch and re-archive the session snapshot.
    func startObservingVitalsData() {
        guard manager.isHealthKitAvailable else { return }
        stopObservingVitalsData()
        for type in Self.observedVitalsTypes() {
            observeVitalsType(type)
        }
    }

    nonisolated private static func observedVitalsTypes() -> [HKQuantityType] {
        var types: [HKQuantityType] = []
        if let t = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) { types.append(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) { types.append(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.append(t) }
        if #available(iOS 16.0, *) {
            if let t = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) { types.append(t) }
        }
        return types
    }

    /// Bounded to samples from the last two days: with no predicate, the
    /// initial results were every sample of the type ever recorded, read and
    /// discarded each time observation started. Last night's late writes are
    /// dated inside that window, and so is everything written later.
    private func observeVitalsType(_ type: HKQuantityType) {
        let recent = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-48 * 60 * 60), end: nil, options: [])
        let query = HKAnchoredObjectQuery(
            type: type, predicate: recent, anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { _, _, _, _, _ in
            // Initial results — nothing to do.
        }
        query.updateHandler = { [weak manager] _, newSamples, _, _, _ in
            guard let manager, let samples = newSamples, !samples.isEmpty else { return }
            Task { @MainActor in
                manager.vitalsDataVersion += 1
            }
        }
        manager.vitalsObserverQueries.append(query)
        manager.healthStore.execute(query)
        manager.healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    /// Stop observing all vitals data queries.
    func stopObservingVitalsData() {
        for query in manager.vitalsObserverQueries {
            manager.healthStore.stop(query)
        }
        manager.vitalsObserverQueries.removeAll()
    }

    /// Fetch resting heart rate around a reference date.
    ///
    /// Reads HealthKit's purpose-built `.restingHeartRate` sample first — this is
    /// what Apple Watch writes once a day after computing the user's actual RHR.
    /// Falls back to the minimum `.heartRate` sample over a 24h window only when
    /// no RHR sample exists (older devices, users without an Apple Watch). The
    /// previous implementation always took the 24h `.heartRate` minimum, which
    /// conflated "lowest instantaneous beat" with "resting HR" and missed the
    /// authoritative Watch value entirely.
    ///
    /// Excludes our own RHR/HR writes. The app
    /// exports a daily `.restingHeartRate` sample and minute-level `.heartRate`
    /// samples; without that filter the "primary" RHR read could return the RHR
    /// WE wrote last night instead of the Watch's authoritative value, and the
    /// min-HR fallback could pick up our own exported HR series — both circular
    /// contamination.
    private func fetchRestingHeartRate(relativeTo referenceDate: Date = Date()) async -> Double? {
        guard manager.isHealthKitAvailable else { return nil }
        let calendar = Calendar.current
        let windowEnd = min(referenceDate, Date())
        let windowStart = calendar.date(byAdding: .hour, value: -36, to: windowEnd) ?? windowEnd  // no force-unwrap
        let datePredicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
        let predicate = manager.hrReadExcludingOwnWrites(dateRange: datePredicate)
        if let rhr = await watchRestingHeartRate(predicate: predicate) { return rhr }
        debugLog("[HealthKitManager] No .restingHeartRate sample found — falling back to the 36h heart-rate minimum")
        return await minimumHeartRate(predicate: predicate)
    }

    /// Apple Watch's daily RHR sample. Searches a 36-hour window so a
    /// late-syncing Watch (writes RHR after morning sync, sometimes hours later
    /// than the sleep session ended) is still picked up.
    private func watchRestingHeartRate(predicate: NSPredicate) async -> Double? {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: rhrType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                resolve(Self.firstQuantityBPM(samples, error, unit: bpm))
            }
        }
    }

    nonisolated private static func firstQuantityBPM(_ samples: [HKSample]?, _ error: Error?, unit: HKUnit) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Resting HR (.restingHeartRate) query error: \(error.localizedDescription)")
            return nil
        }
        return (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    /// 24h-window minimum heart rate. Only used when no `.restingHeartRate`
    /// sample exists at all.
    private func minimumHeartRate(predicate: NSPredicate) async -> Double? {
        guard let hrType = HKTypes.quantity(.heartRate) else { return nil }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, statistics, error in
                resolve(Self.minimumBPM(statistics, error, unit: bpm))
            }
        }
    }

    nonisolated private static func minimumBPM(_ statistics: HKStatistics?, _ error: Error?, unit: HKUnit) -> Double? {
        if let error {
            debugLog("[HealthKitManager] Heart rate fallback query error: \(error.localizedDescription)")
            return nil
        }
        return statistics?.minimumQuantity()?.doubleValue(for: unit)
    }

    // MARK: - Daily activity totals
    //
    // HealthKit-aggregated step / distance / flight totals across ALL
    // sources — iPhone CMPedometer, Apple Watch, third-party trackers.
    // The user wants TOTAL daily activity, not just iPhone-only
    // CMPedometer. The Fitness pill needs a workout-vs-passive split
    // built from these aggregates: workout steps come from
    // `fetchSumSteps(from: workoutStart, to: workoutEnd)`; passive
    // steps = total - workout.

    /// Last `days` days of HealthKit-aggregated activity. Most-recent first.
    /// `days` includes today, so days=7 returns today + 6 previous.
    func fetchDailyActivity(days: Int = 7) async -> [HealthKitManager.DailyActivity] {
        guard manager.isHealthKitAvailable else { return [] }
        let cal = Calendar.current
        let now = Date()
        var out: [HealthKitManager.DailyActivity] = []
        for offset in 0 ..< max(1, days) {
            guard let dayStart = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now)) else { continue }
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now
            await out.append(dailyActivity(dayStart: dayStart, dayEnd: min(dayEnd, now)))
        }
        return out
    }

    private func dailyActivity(dayStart: Date, dayEnd: Date) async -> HealthKitManager.DailyActivity {
        async let steps = fetchSumSteps(from: dayStart, to: dayEnd)
        async let distance = fetchSumDistance(from: dayStart, to: dayEnd)
        async let flights = fetchSumFlights(from: dayStart, to: dayEnd)
        return await HealthKitManager.DailyActivity(
            date: dayStart,
            stepCount: steps,
            distanceMeters: distance,
            flightsClimbed: flights
        )
    }

    /// Steps taken between two timestamps, summed across all sources.
    /// Pass [workoutStart, workoutEnd] for "steps during this workout."
    func fetchSumSteps(from start: Date, to end: Date) async -> Int {
        guard manager.isHealthKitAvailable, end > start else { return 0 }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return 0 }
        return await sumActivityQuantity(type: stepType, unit: .count(), from: start, to: end).map { Int($0) } ?? 0
    }

    /// Distance walked/run between two timestamps, in meters.
    func fetchSumDistance(from start: Date, to end: Date) async -> Double {
        guard manager.isHealthKitAvailable, end > start else { return 0 }
        guard let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return 0 }
        return await sumActivityQuantity(type: distType, unit: .meter(), from: start, to: end) ?? 0
    }

    /// Flights climbed between two timestamps. CMPedometer staircase-burst
    /// detection — does NOT capture gradual outdoor elevation gain.
    func fetchSumFlights(from start: Date, to end: Date) async -> Int {
        guard manager.isHealthKitAvailable, end > start else { return 0 }
        guard let flightsType = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) else { return 0 }
        return await sumActivityQuantity(type: flightsType, unit: .count(), from: start, to: end).map { Int($0) } ?? 0
    }

    /// Generic cumulative-sum statistics query for activity quantities.
    private func sumActivityQuantity(
        type: HKQuantityType,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await manager.runBoundedQuery(timeout: HealthKitManager.vitalsQueryTimeoutSec) { resolve in
            HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                resolve(value)
            }
        }
    }
}

// `DailyActivity` stays nested on the manager: it is the return type of the
// `fetchDailyActivity` forwarder and is named `HealthKitManager.DailyActivity`
// at every call site.
extension HealthKitManager {
    struct DailyActivity: Identifiable, Equatable, Sendable {
        let date: Date
        let stepCount: Int
        let distanceMeters: Double
        let flightsClimbed: Int
        var id: Date { date }
    }
}
