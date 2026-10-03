import CoreLocation
import Foundation
import HealthKit

// MARK: - HealthKit Workout Export
//
// Publishes a completed Emuqu workout as a native `HKWorkout` + its
// supporting samples (HR, distance, active energy, route). Once written, the
// workout appears in Apple Fitness, Apple Health, and is readable by any
// third-party app the user has linked to HealthKit (TrainingPeaks via HK,
// Athlytic, Zones for Training, etc.).
//
// Uses the modern `HKWorkoutBuilder` + `HKWorkoutRouteBuilder` APIs
// introduced in iOS 17 — the old `HKWorkout(activityType:start:end:...)`
// initialiser is deprecated. The builder pattern also lets us add sample
// types incrementally without re-constructing the workout on each field.
//
// Energy calculation: uses the same METs × 3.5 × kg × min / 200 formula
// that the post-summary shows, with the user's real body weight from
// settings. Reference: Ainsworth 2011, Compendium of Physical Activities.

enum HealthKitWorkoutExport {
    /// Save a finished workout to HealthKit. Idempotent only by caller —
    /// calling twice writes two workouts. Safe to call without auth; it just
    /// fails cleanly with `.authorizationNotGranted`. Errors are surfaced via
    /// thrown exceptions so the caller can log; Emuqu's current
    /// policy is to ignore HK export failures and keep the in-app session
    /// canonical.
    ///
    /// The three sample-series builders are pure functions of the captured
    /// samples rather than inline blocks. `export` keeps the
    /// I/O and the ordering; the arithmetic that was tangled up with it is
    /// testable on its own, without a HealthKit store or a simulator.
    @MainActor
    static func export(
        session: HRVSession,
        store: HKHealthStore,
        bodyWeightKg: Double
    ) async throws {
        guard let metadata = session.workoutMetadata, let endDate = session.endDate else {
            throw ExportError.missingRequiredFields
        }
        guard isWritable(HKObjectType.workoutType(), in: store) else {
            throw ExportError.authorizationNotGranted
        }
        let workout = try await saveWorkout(
            metadata: metadata, startDate: session.startDate, endDate: endDate, bodyWeightKg: bodyWeightKg, store: store
        )
        await attachRouteToSavedWorkout(session: session, metadata: metadata, workout: workout, store: store)
        debugLog("[HKExport] saved workout \(session.id) as HKWorkout (sport=\(metadata.sport.rawValue), duration=\(Int(session.duration ?? 0))s)")
    }

    @MainActor
    private static func saveWorkout(
        metadata: WorkoutMetadata, startDate: Date, endDate: Date, bodyWeightKg: Double, store: HKHealthStore
    ) async throws -> HKWorkout {
        let builder = HKWorkoutBuilder(
            healthStore: store, configuration: workoutConfiguration(for: metadata.sport), device: .local()
        )
        try await builder.beginCollection(at: startDate)
        try await addSampleSeries(
            metadata: metadata, startDate: startDate, bodyWeightKg: bodyWeightKg, store: store, to: builder
        )
        try await builder.endCollection(at: endDate)
        guard let workout = try await builder.finishWorkout() else {
            throw ExportError.workoutNotSaved
        }
        return workout
    }

    /// The workout is already saved. A route that cannot be attached must not
    /// fail the export: the caller would leave the session unstamped, and the
    /// next backfill would save the same workout again.
    private static func attachRouteToSavedWorkout(
        session: HRVSession, metadata: WorkoutMetadata, workout: HKWorkout, store: HKHealthStore
    ) async {
        do {
            try await attachRoute(
                metadata: metadata, duration: session.duration, startDate: session.startDate,
                workout: workout, store: store
            )
        } catch {
            debugLog("[HKExport] workout \(session.id) saved without its route: \(error.localizedDescription)", level: .warning)
        }
    }

    private static func workoutConfiguration(for sport: Sport) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = hkActivity(for: sport)
        configuration.locationType = sport.usesGPS ? .outdoor : .indoor
        return configuration
    }

    /// Attaches each sample series the user lets Emuqu write.
    ///
    /// A builder rejects a batch whose type the user has switched off, and the
    /// whole export fails with it — so turning off Cycling Distance would stop
    /// every workout reaching Health. A series that cannot be written is left
    /// off instead; the workout itself still saves.
    @MainActor
    private static func addSampleSeries(
        metadata: WorkoutMetadata,
        startDate: Date,
        bodyWeightKg: Double,
        store: HKHealthStore,
        to builder: HKWorkoutBuilder
    ) async throws {
        let samples = metadata.samples ?? []
        let series = [
            heartRateSamples(from: samples, startDate: startDate),
            distanceSamples(from: samples, sport: metadata.sport, startDate: startDate),
            activeEnergySamples(from: samples, startDate: startDate, bodyWeightKg: bodyWeightKg)
        ]
        var skipped: [String] = []
        for batch in series {
            guard let type = batch.first?.sampleType else { continue }
            guard isWritable(type, in: store) else {
                skipped.append(type.identifier)
                continue
            }
            try await builder.addSamples(batch)
        }
        if !skipped.isEmpty {
            debugLog("[HKExport] writing is off in Health for \(skipped.joined(separator: ", ")) — workout saved without those samples")
        }
    }

    static func isWritable(_ type: HKObjectType, in store: HKHealthStore) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    // MARK: - Sample builders
    //
    // Kept out of `export` for its cyclomatic complexity.
    // Each is pure: same samples in, same HK samples out, no
    // store, no clock.

    /// ACSM MET→kcal constants. kcal/min = METs × 3.5 × kg / 200.
    /// Reference: Ainsworth 2011, Compendium of Physical Activities.
    private static let mlOxygenPerKgPerMET = 3.5
    private static let mlOxygenPerKcal = 200.0
    /// Below this a window is rounding noise and is not worth a sample.
    private static let minimumKcalPerSample = 0.01

    /// Per-tick heart rate, as instantaneous (zero-length) samples.
    static func heartRateSamples(from samples: [WorkoutSample], startDate: Date) -> [HKQuantitySample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        return samples.compactMap { s in
            guard let bpm = s.heartRate else { return nil }
            let when = startDate.addingTimeInterval(TimeInterval(s.offsetSec))
            let quantity = HKQuantity(
                unit: HKUnit(from: "count/min"),
                doubleValue: Double(bpm)
            )
            return HKQuantitySample(type: hrType, quantity: quantity, start: when, end: when)
        }
    }

    /// One delta-distance sample per tick, spanning the interval since the
    /// previous tick so Apple Health's distance bar graphs read as
    /// continuous. Picks the right quantity type for the sport; sports with
    /// no matching type (rowing, air bike, CrossFit) write no distance
    /// rather than adding erg metres to Walking + Running Distance.
    ///
    /// `delta.isFinite` defends against the (unlikely) case where
    /// dist arithmetic produces an infinity. NaN already short-circuits on
    /// `dist > lastDistance` (NaN > x is always false), but belt-and-suspenders
    /// before HKQuantity init.
    static func distanceSamples(
        from samples: [WorkoutSample],
        sport: Sport,
        startDate: Date
    ) -> [HKQuantitySample] {
        guard let distanceTypeId = distanceType(for: sport),
              let distType = HKQuantityType.quantityType(forIdentifier: distanceTypeId) else { return [] }
        var lastDistance: Double = 0
        var out: [HKQuantitySample] = []
        for (idx, s) in samples.enumerated() {
            guard let dist = s.distanceMeters, dist > lastDistance else { continue }
            let delta = dist - lastDistance
            guard delta.isFinite, delta > 0 else { continue }
            lastDistance = dist
            let prevOffset = idx > 0 ? TimeInterval(samples[idx - 1].offsetSec) : 0
            out.append(HKQuantitySample(
                type: distType, quantity: HKQuantity(unit: .meter(), doubleValue: delta),
                start: startDate.addingTimeInterval(prevOffset),
                end: startDate.addingTimeInterval(TimeInterval(s.offsetSec))
            ))
        }
        return out
    }

    /// The Health distance type for a sport, or nil when Health has none
    /// that fits.
    private static func distanceType(for sport: Sport) -> HKQuantityTypeIdentifier? {
        switch sport {
        case .bike, .indoorBike: .distanceCycling
        case .run, .trailRun, .walk, .hike, .treadmill: .distanceWalkingRunning
        case .row, .airBike, .crossFit: nil
        }
    }

    /// Per-window active energy. Better than one session total because it
    /// lets Apple Health plot calorie burn over time and attribute it to the
    /// right activity-ring minute.
    static func activeEnergySamples(
        from samples: [WorkoutSample],
        startDate: Date,
        bodyWeightKg: Double
    ) -> [HKQuantitySample] {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return [] }

        var out: [HKQuantitySample] = []
        for (idx, s) in samples.enumerated() {
            guard let mets = s.mets, mets > 0, mets.isFinite else { continue }
            let prevOffset = idx > 0 ? samples[idx - 1].offsetSec : s.offsetSec
            let durationSec = max(1, s.offsetSec - prevOffset)
            let minutes = Double(durationSec) / 60.0
            let kcal = (mets * mlOxygenPerKgPerMET * bodyWeightKg * minutes) / mlOxygenPerKcal
            // Explicit isFinite check belt-and-suspenders
            // before HKQuantity (raises NSException for NaN/Inf).
            guard kcal.isFinite, kcal > minimumKcalPerSample else { continue }
            let prevTime = startDate.addingTimeInterval(TimeInterval(prevOffset))
            let thisTime = startDate.addingTimeInterval(TimeInterval(s.offsetSec))
            let qty = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
            out.append(HKQuantitySample(type: energyType, quantity: qty, start: prevTime, end: thisTime))
        }
        return out
    }

    /// Attaches the GPS polyline to an already-persisted workout. No-op for
    /// indoor sports, a missing polyline, or a polyline that decodes empty.
    private static func attachRoute(
        metadata: WorkoutMetadata,
        duration: TimeInterval?,
        startDate: Date,
        workout: HKWorkout,
        store: HKHealthStore
    ) async throws {
        guard metadata.sport.usesGPS, let polyline = metadata.gpsPolyline else { return }
        guard isWritable(HKSeriesType.workoutRoute(), in: store) else {
            debugLog("[HKExport] writing is off in Health for workout routes — workout saved without its route")
            return
        }
        let track = GPXExporter.decode(
            polyline: polyline,
            startDate: startDate,
            duration: duration
        )
        guard !track.isEmpty else { return }

        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(track)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }

    // MARK: - Helpers

    private static func hkActivity(for sport: Sport) -> HKWorkoutActivityType {
        switch sport {
        case .run, .trailRun: return .running
        case .walk: return .walking
        case .hike: return .hiking
        case .bike: return .cycling
        case .indoorBike: return .cycling
        case .treadmill: return .running
        case .row: return .rowing
        case .airBike: return .cycling
        case .crossFit: return .crossTraining
        }
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case missingRequiredFields
        case authorizationNotGranted
        case workoutNotSaved

        var errorDescription: String? {
            switch self {
            case .missingRequiredFields: return String(localized: "Workout is missing required fields (start/end/metadata).", bundle: LanguageManager.appBundle)
            case .authorizationNotGranted: return String(localized: "Apple Health permission was not granted for workout export.", bundle: LanguageManager.appBundle)
            case .workoutNotSaved: return String(localized: "Apple Health finished the workout without saving it.", bundle: LanguageManager.appBundle)
            }
        }
    }
}
