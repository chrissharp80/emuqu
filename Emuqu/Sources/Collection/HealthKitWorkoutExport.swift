import CoreLocation
import Foundation
import HealthKit

// MARK: - HealthKit Workout Export
//
// Publishes a completed Emuqu workout as a native `HKWorkout` + its
// supporting samples (distance, active energy, route, and heart rate when
// Apple Health export of heart rate is on). Once written, the
// workout appears in Apple Fitness, Apple Health, and is readable by any
// third-party app the user has linked to HealthKit (TrainingPeaks via HK,
// Athlytic, Zones for Training, etc.).
//
// Uses the modern `HKWorkoutBuilder` + `HKWorkoutRouteBuilder` APIs
// introduced in iOS 17 — the old `HKWorkout(activityType:start:end:...)`
// initialiser is deprecated. The builder pattern also lets us add sample
// types incrementally without re-constructing the workout on each field.
//
// Energy calculation: the METs × 3.5 × kg × min / 200 formula the
// post-summary also uses, with the user's real body weight from settings,
// applied tick interval by tick interval (ticks without METs add nothing).
// The post-summary card applies it once to the average METs over the active
// time, so the two totals can differ when ticks lack METs or have gaps.
// Reference: Ainsworth 2011, Compendium of Physical Activities.
//
// Pauses: `WorkoutSample.offsetSec` counts active seconds only, while
// Health keeps the wall clock. Every sample is placed at its wall-clock
// moment (`WorkoutWallClock`), and each pause goes in as a pause/resume
// event pair, so Health's duration and pace leave the paused time out.

enum HealthKitWorkoutExport {
    /// Save a finished workout to HealthKit. Idempotent only by caller —
    /// calling twice writes two workouts. Safe to call without auth; it just
    /// fails cleanly with `.authorizationNotGranted`. Errors are surfaced via
    /// thrown exceptions so the caller can log; Emuqu's current
    /// policy is to ignore HK export failures and keep the in-app session
    /// canonical.
    ///
    /// Heart rate goes with the workout only when `writesHeartRate` is true,
    /// which by default is the Apple Health export setting with its heart-rate
    /// switch (`writesWorkoutHeartRate`), as the Health permission text and
    /// the privacy policy say. Data that came from Apple Health is never
    /// written back, because a copy would carry Emuqu as its source
    /// (`sampleOptions(for:bodyWeightKg:writesHeartRate:)`):
    /// - heart rate on the rows `healthKitHROffsets` lists, and all of a
    ///   workout recorded with Apple Watch heart rate (older ones carry no
    ///   list): the Watch already saved it;
    /// - every sample series of a workout rebuilt from Apple Health's own
    ///   samples: its heart rate, distance and effort are Health's. Only the
    ///   workout itself is saved, with no samples and no route, since Health
    ///   had no workout for that hour.
    ///
    /// The three sample-series builders are pure functions of the captured
    /// samples rather than inline blocks. `export` keeps the
    /// I/O and the ordering; the arithmetic that was tangled up with it is
    /// testable on its own, without a HealthKit store or a simulator.
    @MainActor
    static func export(
        session: HRVSession,
        store: HKHealthStore,
        bodyWeightKg: Double,
        writesHeartRate: Bool = writesWorkoutHeartRate
    ) async throws {
        guard let metadata = session.workoutMetadata, let endDate = session.endDate else {
            throw ExportError.missingRequiredFields
        }
        guard isWritable(HKObjectType.workoutType(), in: store) else {
            throw ExportError.authorizationNotGranted
        }
        let workout = try await saveWorkout(
            metadata: metadata, startDate: session.startDate, endDate: endDate,
            samples: sampleOptions(for: session, bodyWeightKg: bodyWeightKg, writesHeartRate: writesHeartRate),
            store: store
        )
        if !CloudSessionPayload.isHealthKitSourced(session) {
            await attachRouteToSavedWorkout(session: session, metadata: metadata, workout: workout, store: store)
        }
        debugLog("[HKExport] saved workout \(session.id) as HKWorkout (sport=\(metadata.sport.rawValue), duration=\(Int(session.duration ?? 0))s)")
    }

    /// Whether a saved workout carries its heart rate: Apple Health export on,
    /// with its heart-rate switch on.
    @MainActor
    static var writesWorkoutHeartRate: Bool {
        writesHeartRate(with: AppDependencies.current.app.settingsManager.settings)
    }

    static func writesHeartRate(with settings: UserSettings) -> Bool {
        settings.enableHealthKitExport && settings.exportHeartRate
    }

    /// What goes into the workout's sample series besides the samples themselves.
    struct SampleOptions: Equatable {
        let bodyWeightKg: Double
        let writesHeartRate: Bool
        /// Distance and active energy. False when Apple Health supplied them.
        let writesDistanceAndEnergy: Bool
    }

    /// Which sample series a session's export writes. A session built from
    /// Apple Health data (`CloudSessionPayload.isHealthKitSourced`) writes
    /// none, and Apple Watch heart rate is never written back.
    static func sampleOptions(for session: HRVSession, bodyWeightKg: Double, writesHeartRate: Bool) -> SampleOptions {
        let fromHealth = CloudSessionPayload.isHealthKitSourced(session)
        let watchHeartRate = CloudSessionPayload.hasAppleWatchHeartRate(session)
        return SampleOptions(
            bodyWeightKg: bodyWeightKg,
            writesHeartRate: writesHeartRate && !fromHealth && !watchHeartRate,
            writesDistanceAndEnergy: !fromHealth
        )
    }

    @MainActor
    private static func saveWorkout(
        metadata: WorkoutMetadata, startDate: Date, endDate: Date, samples options: SampleOptions, store: HKHealthStore
    ) async throws -> HKWorkout {
        let builder = HKWorkoutBuilder(
            healthStore: store, configuration: workoutConfiguration(for: metadata.sport), device: .local()
        )
        let clock = WorkoutWallClock(startDate: startDate, pauseSpans: metadata.pauseSpans)
        try await builder.beginCollection(at: startDate)
        try await addSampleSeries(metadata: metadata, clock: clock, options: options, store: store, to: builder)
        let events = pauseEvents(of: clock, endDate: endDate)
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }
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
        clock: WorkoutWallClock,
        options: SampleOptions,
        store: HKHealthStore,
        to builder: HKWorkoutBuilder
    ) async throws {
        let samples = options.writesDistanceAndEnergy ? metadata.samples ?? [] : []
        let series = [
            options.writesHeartRate ? heartRateSamples(of: metadata, clock: clock) : [],
            distanceSamples(from: samples, sport: metadata.sport, clock: clock),
            activeEnergySamples(from: samples, clock: clock, bodyWeightKg: options.bodyWeightKg)
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

    /// A pause event where each pause began and a resume event where the
    /// workout went on, so Health's duration and pace leave the paused time
    /// out. A pause still running at `endDate` (stopped while paused) gets no
    /// resume, and the builder counts it as paused to the end; one that began
    /// at or after `endDate` is left out, as the builder takes no event
    /// outside the workout.
    static func pauseEvents(of clock: WorkoutWallClock, endDate: Date) -> [HKWorkoutEvent] {
        clock.pauses().filter { $0.start < endDate }.flatMap { pause -> [HKWorkoutEvent] in
            let resume: [HKWorkoutEvent] = pause.end < endDate ? [workoutEvent(.resume, at: pause.end)] : []
            return [workoutEvent(.pause, at: pause.start)] + resume
        }
    }

    /// Pause and resume events are moments: a zero-length interval.
    private static func workoutEvent(_ type: HKWorkoutEventType, at date: Date) -> HKWorkoutEvent {
        HKWorkoutEvent(type: type, dateInterval: DateInterval(start: date, duration: 0), metadata: nil)
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

    /// The workout's own heart rate: the rows Apple Health filled are left out.
    private static func heartRateSamples(of metadata: WorkoutMetadata, clock: WorkoutWallClock) -> [HKQuantitySample] {
        heartRateSamples(
            from: metadata.samples ?? [], clock: clock, skipping: Set(metadata.healthKitHROffsets ?? [])
        )
    }

    /// Per-tick heart rate, as instantaneous (zero-length) samples at each
    /// tick's wall-clock moment, leaving out the rows at `skipping` offsets
    /// (heart rate read from Apple Health).
    static func heartRateSamples(
        from samples: [WorkoutSample], clock: WorkoutWallClock, skipping healthKitOffsets: Set<Int> = []
    ) -> [HKQuantitySample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        return samples.compactMap { s in
            guard let bpm = s.heartRate, !healthKitOffsets.contains(s.offsetSec) else { return nil }
            let when = clock.date(atActiveOffset: s.offsetSec)
            return HealthSampleFactory.quantitySample(
                type: hrType, value: Double(bpm), unit: HKUnit(from: "count/min"), start: when, end: when
            )
        }
    }

    /// One delta-distance sample per tick, spanning the interval since the
    /// previous tick so Apple Health's distance bar graphs read as
    /// continuous. Picks the right quantity type for the sport; sports with
    /// no matching type (rowing, air bike, CrossFit) write no distance
    /// rather than adding erg metres to Walking + Running Distance.
    ///
    /// The ticks are taken in time order, so each sample's span runs forwards
    /// even when a merged or recovered list arrives out of order. A span
    /// starts where the last written delta ended (the workout start before
    /// the first), so a delta that built up over ticks that did not advance
    /// covers all of them, not just the last tick interval. Spans sit on the
    /// wall clock and never cross a pause (`WorkoutWallClock.interval`).
    /// `delta.isFinite` defends against the (unlikely) case where
    /// dist arithmetic produces an infinity. NaN already short-circuits on
    /// `dist > lastDistance` (NaN > x is always false).
    static func distanceSamples(
        from samples: [WorkoutSample],
        sport: Sport,
        clock: WorkoutWallClock
    ) -> [HKQuantitySample] {
        guard let distanceTypeId = distanceType(for: sport),
              let distType = HKQuantityType.quantityType(forIdentifier: distanceTypeId) else { return [] }
        var lastDistance: Double = 0
        var spanStart = 0
        var out: [HKQuantitySample] = []
        for s in inTimeOrder(samples) {
            guard let dist = s.distanceMeters, dist > lastDistance else { continue }
            let delta = dist - lastDistance
            guard delta.isFinite, delta > 0 else { continue }
            lastDistance = dist
            let span = clock.interval(fromActiveOffset: spanStart, to: s.offsetSec)
            let sample = HealthSampleFactory.quantitySample(
                type: distType, value: delta, unit: .meter(), start: span.start, end: span.end
            )
            spanStart = s.offsetSec
            if let sample { out.append(sample) }
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
    /// right activity-ring minute. The kcal are worked out over the active
    /// seconds between ticks; the sample sits on the wall clock and never
    /// crosses a pause (`WorkoutWallClock.interval`).
    static func activeEnergySamples(
        from samples: [WorkoutSample],
        clock: WorkoutWallClock,
        bodyWeightKg: Double
    ) -> [HKQuantitySample] {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return [] }

        let ordered = inTimeOrder(samples)
        var out: [HKQuantitySample] = []
        for (idx, s) in ordered.enumerated() {
            guard let mets = s.mets, mets > 0, mets.isFinite else { continue }
            // The first tick covers the time since the workout began.
            let prevOffset = idx > 0 ? ordered[idx - 1].offsetSec : 0
            let durationSec = max(1, s.offsetSec - prevOffset)
            let minutes = Double(durationSec) / 60.0
            let kcal = (mets * mlOxygenPerKgPerMET * bodyWeightKg * minutes) / mlOxygenPerKcal
            guard kcal > minimumKcalPerSample else { continue }
            let span = clock.interval(fromActiveOffset: prevOffset, to: s.offsetSec)
            let sample = HealthSampleFactory.quantitySample(
                type: energyType, value: kcal, unit: .kilocalorie(), start: span.start, end: span.end
            )
            if let sample { out.append(sample) }
        }
        return out
    }

    /// The ticks sorted by offset. Live ticks already are; a merged or
    /// recovered list may not be, and a span from a later tick back to an
    /// earlier one is not a sample HealthKit can hold.
    private static func inTimeOrder(_ samples: [WorkoutSample]) -> [WorkoutSample] {
        samples.sorted { $0.offsetSec < $1.offsetSec }
    }

    /// Attaches the GPS polyline to an already-persisted workout. No-op for
    /// indoor sports, a missing polyline, or a polyline that decodes empty.
    ///
    /// The route keeps `GPXExporter.decode`'s evenly spread times and is not
    /// moved around pauses: the polyline stores no fix times, and fixes keep
    /// coming while paused (the map shows where the user went), at a rate
    /// that cannot be told from the active one, so there is no correct way
    /// to split the points between active and paused time.
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

// MARK: - Wall clock

/// Where a workout's active (pause-excluded) seconds, the clock of
/// `WorkoutSample.offsetSec`, fall on the wall clock Apple Health keeps. The
/// same rule as `WorkoutMetadata.wallClockSeconds(forActiveOffset:)`, from a
/// start date: the active second plus every pause that began before it.
struct WorkoutWallClock {
    let startDate: Date
    /// The workout's pauses, in the order they began.
    let pauseSpans: [WorkoutPauseSpan]

    init(startDate: Date, pauseSpans: [WorkoutPauseSpan]? = nil) {
        self.startDate = startDate
        self.pauseSpans = (pauseSpans ?? []).sorted { $0.atElapsed < $1.atElapsed }
    }

    /// The moment of active second `offset`. A tick at the second a pause
    /// began was taken before that pause.
    func date(atActiveOffset offset: Int) -> Date {
        let pausedBefore = pauseSpans.filter { $0.atElapsed < offset }.reduce(0.0) { $0 + $1.seconds }
        return startDate.addingTimeInterval(Double(offset) + pausedBefore)
    }

    /// The stretch of a quantity that built up between active seconds
    /// `start` and `end`. It ends at `end`'s moment. When a pause began in
    /// it, it starts where the last such pause ended, so no sample spans a
    /// pause and Health never counts paused time as moving: the amount from
    /// before that pause is put after it. With 1 Hz ticks that is the one
    /// tick interval the pause interrupted.
    func interval(fromActiveOffset start: Int, to end: Int) -> (start: Date, end: Date) {
        let endDate = date(atActiveOffset: end)
        guard let lastPause = pauseSpans.last(where: { $0.atElapsed >= start && $0.atElapsed < end }) else {
            return (start: date(atActiveOffset: start), end: endDate)
        }
        return (start: endDate.addingTimeInterval(-Double(end - lastPause.atElapsed)), end: endDate)
    }

    /// Each pause on the wall clock: the moment it began and the moment the
    /// workout resumed. Pauses that began at the same active second follow
    /// one another.
    func pauses() -> [(start: Date, end: Date)] {
        var pausedBefore = 0.0
        return pauseSpans.map { span in
            let began = startDate.addingTimeInterval(Double(span.atElapsed) + pausedBefore)
            pausedBefore += span.seconds
            return (start: began, end: began.addingTimeInterval(span.seconds))
        }
    }
}
