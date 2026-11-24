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
// Compendium METs are gross: they include the 1 MET of resting metabolism.
// Health's Active Energy is energy above rest (Apple Watch writes basal
// energy separately), so the export writes net energy, METs − 1, floored at
// zero. The post-summary card shows gross kcal from the average METs over
// the active time, so the two totals differ by that resting share, and
// further when ticks lack METs or have gaps.
// Reference: Ainsworth 2011, Compendium of Physical Activities.
//
// Re-export: a session's workout, its samples and its route carry the
// session's identity as ExternalUUID and sync identifier
// (`HealthExportIdentity.metadata`). Exporting the session again (after a
// trim or a rebuild, or from a second device) saves the new copy first, then
// deletes what earlier exports of the session saved and HealthKit did not
// already replace, so Health keeps one copy.
//
// Pauses: `WorkoutSample.offsetSec` counts active seconds only, while
// Health keeps the wall clock. Every sample is placed at its wall-clock
// moment (`WorkoutWallClock`), and each pause goes in as a pause/resume
// event pair, so Health's duration and pace leave the paused time out.

enum HealthKitWorkoutExport {
    /// Save a finished workout to HealthKit, replacing every earlier export
    /// of the same session (`EarlierExport`). Safe to call without auth; it
    /// just fails cleanly with `.authorizationNotGranted`. Errors are
    /// surfaced via thrown exceptions so the caller can log; Emuqu's current
    /// policy is to ignore HK export failures and keep the in-app session
    /// canonical.
    ///
    /// The earlier exports are found before the save and deleted after it,
    /// so a failed save leaves them in Health. A failed delete throws after
    /// the new workout is saved: the caller then leaves the session
    /// unstamped, and the next export finds and deletes both earlier copies.
    /// A locked phone refuses Health reads but still takes writes (a stop
    /// from the Watch or the lock screen): the workout is saved without the
    /// earlier copies, which replace themselves through their sync identifier
    /// where they share it, and the rest are deleted on the next return to
    /// the app (`PendingWorkoutReplacements`).
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
    /// samples rather than inline blocks: `export` keeps the I/O and the
    /// ordering, and the arithmetic is testable on its own, without a HealthKit
    /// store or a simulator.
    @MainActor
    static func export(
        session: HRVSession,
        healthKit: HealthKitManager,
        bodyWeightKg: Double,
        writesHeartRate: Bool = writesWorkoutHeartRate
    ) async throws {
        guard let metadata = session.workoutMetadata, let endDate = session.endDate else {
            throw ExportError.missingRequiredFields
        }
        let store = healthKit.healthStore
        guard isWritable(HKObjectType.workoutType(), in: store) else {
            throw ExportError.authorizationNotGranted
        }
        let sampleStore = healthKit.sampleReplacer.store
        let earlier = try await EarlierExport.findUnlessLocked(sessionId: session.id, startDate: session.startDate, in: sampleStore)
        let stamp = ExportStamp(sessionId: session.id, version: HealthExportIdentity.nextSyncVersion())
        let saved = try await saveWorkout(
            metadata: metadata, startDate: session.startDate, endDate: endDate,
            samples: sampleOptions(for: session, bodyWeightKg: bodyWeightKg, writesHeartRate: writesHeartRate),
            stamp: stamp, store: store
        )
        let routeSaved = await attachRouteToSavedWorkout(session: session, metadata: metadata, workout: saved.workout, stamp: stamp, store: store)
        let keeping = saved.syncIds.union(routeSaved ? [stamp.routeIdentity] : [])
        try await replaceEarlier(earlier, keeping: keeping, of: session, sport: metadata.sport, in: sampleStore)
    }

    /// Deletes what the earlier exports saved, keeping `keeping` (HealthKit
    /// replaced those). With none read (a locked phone), notes the session
    /// so the next backfill deletes them (`PendingWorkoutReplacements`).
    @MainActor
    private static func replaceEarlier(
        _ earlier: EarlierExport?, keeping: Set<String>, of session: HRVSession, sport: Sport, in sampleStore: any HealthSampleStore
    ) async throws {
        guard let earlier else {
            PendingWorkoutReplacements.note(sessionId: session.id, startDate: session.startDate)
            debugLog("[HKExport] saved workout \(session.id) as HKWorkout (sport=\(sport.rawValue)) while Health could not be read; earlier copies are deleted on the next return to the app")
            return
        }
        try await earlier.delete(keeping: keeping, from: sampleStore)
        debugLog("[HKExport] saved workout \(session.id) as HKWorkout (sport=\(sport.rawValue), duration=\(Int(session.duration ?? 0))s), replacing \(earlier.workouts.count) earlier")
    }

    /// Delete every workout this app exported for a session deleted forever,
    /// with the samples and route saved with each. Found as the export finds
    /// earlier copies (`EarlierExport.find`); `startDate` is the recording's
    /// start, which finds a copy saved before workouts carried an identity.
    /// Without HealthKit there is nothing to delete. Errors propagate, so the
    /// caller can say the workout is still in Health.
    @MainActor
    static func removeExports(sessionId: UUID, startDate: Date, healthKit: HealthKitManager) async throws {
        guard healthKit.isHealthKitAvailable else { return }
        let sampleStore = healthKit.sampleReplacer.store
        let earlier = try await EarlierExport.find(sessionId: sessionId, startDate: startDate, in: sampleStore)
        try await earlier.delete(keeping: [], from: sampleStore)
        PendingWorkoutReplacements.clear(sessionId: sessionId)
        debugLog("[HKExport] removed \(earlier.workouts.count) exported workout(s) of \(sessionId.uuidString.prefix(8))")
    }

    /// Who an export's objects belong to, and which export wrote them: every
    /// object it saves carries an identity derived from `sessionId` and
    /// `version` as its sync version (`HealthExportIdentity.metadata`).
    struct ExportStamp: Equatable {
        let sessionId: UUID
        let version: Int

        /// The workout's own identity.
        var workoutIdentity: String {
            HealthExportIdentity.summary(sessionId: sessionId, metric: .workout)
        }

        /// The route's identity.
        var routeIdentity: String {
            HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .workout, suffix: "route")
        }

        /// The metadata of the workout itself.
        var metadataOfWorkout: [String: Any] {
            HealthExportIdentity.metadata(workoutIdentity, version: version)
        }

        /// The metadata of the route.
        var metadataOfRoute: [String: Any] {
            HealthExportIdentity.metadata(routeIdentity, version: version)
        }

        /// The metadata of the `index`th sample of a `kind` series saved with
        /// the workout.
        func sampleMetadata(_ kind: String, index: Int) -> [String: Any] {
            HealthExportIdentity.metadata(
                HealthExportIdentity.seriesMember(sessionId: sessionId, metric: .workout, suffix: "\(kind)-\(index)"),
                version: version
            )
        }
    }

    /// What earlier exports of a session saved: the workouts, and the samples
    /// and routes saved with each, all from this app.
    @MainActor
    struct EarlierExport {
        let workouts: [HKWorkout]
        let samples: [HKSample]

        /// How far either side of the session's start an earlier copy is
        /// looked for. A rebuild keeps the session's start, so this only has
        /// to reach a workout whose start moved by a recovery, and the match
        /// is the session's identity, so it reaches nothing else.
        static let searchPadding: TimeInterval = 25 * 3600

        /// This app's workouts near `startDate` that `isEarlierExport`
        /// matches, and what was saved with each. The reads are bounded and
        /// fail closed: a read that does not answer throws, rather than go on
        /// as if there were nothing to replace.
        static func find(sessionId: UUID, startDate: Date, in store: any HealthSampleStore) async throws -> EarlierExport {
            let timeout = HealthKitManager.backgroundAggregateQueryTimeoutSec
            let span = searchSpan(around: startDate)
            let workouts = try await store.ownSamples(
                of: HKObjectType.workoutType(), in: span, timeout: timeout, label: "earlier workout export"
            ).compactMap { $0 as? HKWorkout }.filter { workout in
                isEarlierExport(
                    externalUUID: workout.metadata?[HKMetadataKeyExternalUUID] as? String,
                    startDate: workout.startDate, sessionId: sessionId, sessionStart: startDate
                )
            }
            var samples: [HKSample] = []
            for workout in workouts {
                for (type, _) in HealthKitManager.workoutExportSampleTypes {
                    samples += try await store.ownSamples(
                        of: type, savedWith: workout, timeout: timeout, label: "earlier workout samples"
                    )
                }
            }
            return EarlierExport(workouts: workouts, samples: samples)
        }

        /// What `find` reaches, and the samples of the session's workout
        /// series (`HealthExportIdentity.isSeriesMember`) in the same span: a
        /// workout saved without `find` replaced the earlier one through its
        /// sync identifier, and what that one held beyond the new copy's
        /// samples is saved with no workout now.
        static func findAfterLockedSave(sessionId: UUID, startDate: Date, in store: any HealthSampleStore) async throws -> EarlierExport {
            let found = try await find(sessionId: sessionId, startDate: startDate, in: store)
            var seen = Set((found.samples + found.workouts.map { $0 as HKSample }).map(\.uuid))
            var series: [HKSample] = []
            for (type, _) in HealthKitManager.workoutExportSampleTypes {
                let own = try await store.ownSamples(
                    of: type, in: searchSpan(around: startDate),
                    timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec, label: "earlier workout series"
                )
                series += own.filter { isSeriesMember($0, of: sessionId) && seen.insert($0.uuid).inserted }
            }
            return EarlierExport(workouts: found.workouts, samples: found.samples + series)
        }

        /// Whether a sample carries a member identity of the session's
        /// workout series (`HealthExportIdentity.isSeriesMember`).
        nonisolated private static func isSeriesMember(_ sample: HKSample, of sessionId: UUID) -> Bool {
            guard let externalUUID = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return HealthExportIdentity.isSeriesMember(externalUUID, sessionId: sessionId, metric: .workout)
        }

        /// The span `find` searches, `searchPadding` either side of `startDate`.
        private static func searchSpan(around startDate: Date) -> DateInterval {
            DateInterval(start: startDate.addingTimeInterval(-searchPadding), end: startDate.addingTimeInterval(searchPadding))
        }

        /// `find`, or nil when Health refuses the read because the phone is
        /// locked (`errorDatabaseInaccessible`; writes still go through).
        /// Every other error is thrown.
        static func findUnlessLocked(sessionId: UUID, startDate: Date, in store: any HealthSampleStore) async throws -> EarlierExport? {
            do {
                return try await find(sessionId: sessionId, startDate: startDate, in: store)
            } catch let error where isLockedRead(error) {
                debugLog("[HKExport] earlier exports of \(sessionId.uuidString.prefix(8)) not readable while the phone is locked", level: .warning)
                return nil
            }
        }

        /// Whether Health refused a read because protected data is locked.
        nonisolated static func isLockedRead(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == HKErrorDomain && nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue
        }

        /// Whether a workout this app saved is an export of the session: it
        /// carries the session's workout identity, or it carries no identity
        /// at all (saved before workouts had one) and starts in the same
        /// second as the session. Another session's export always carries
        /// its own identity, so it is never matched.
        nonisolated static func isEarlierExport(
            externalUUID: String?, startDate: Date, sessionId: UUID, sessionStart: Date
        ) -> Bool {
            guard let externalUUID else { return abs(startDate.timeIntervalSince(sessionStart)) < 1 }
            return HealthExportIdentity.isSummary(externalUUID, sessionId: sessionId, metric: .workout)
        }

        /// Delete the samples first, then the workouts, leaving out any whose
        /// sync identifier is in `keeping`: a new export saved under that
        /// identifier, and HealthKit replaced the earlier object with it.
        /// Each sample type is deleted on its own, so a type whose writing
        /// the user switched off (which HealthKit will not delete either)
        /// does not keep the others; the first error is thrown once all
        /// have been tried.
        func delete(keeping: Set<String>, from store: any HealthSampleStore) async throws {
            let left = (samples + workouts.map { $0 as HKSample }).filter { object in
                HealthExportIdentity.syncIdentifier(of: object).map { !keeping.contains($0) } ?? true
            }
            var firstError: Error?
            for group in Self.byType(left) {
                do {
                    try await store.delete(group)
                } catch {
                    let type = group.first?.sampleType.identifier ?? ""
                    debugLog("[HKExport] could not delete \(group.count) earlier \(type): \(error.localizedDescription)", level: .warning)
                    firstError = firstError ?? error
                }
            }
            if let firstError { throw firstError }
        }

        /// Delete everything found but the objects of the newest export: the
        /// highest sync version any found object carries. A workout saved
        /// while the earlier copies could not be read is the newest; what an
        /// earlier export left beside it carries a lower version, or none.
        /// Nothing is deleted when no found object carries a version, since
        /// then the newest copy is not among them.
        func deleteSuperseded(from store: any HealthSampleStore) async throws {
            let found = samples + workouts.map { $0 as HKSample }
            guard let newest = found.compactMap(HealthExportIdentity.syncVersion(of:)).max() else { return }
            let keeping = Set(found.filter { HealthExportIdentity.syncVersion(of: $0) == newest }
                .compactMap(HealthExportIdentity.syncIdentifier(of:)))
            try await delete(keeping: keeping, from: store)
        }

        /// The objects grouped by type, workouts last, so a workout is never
        /// deleted while samples saved with it remain.
        private static func byType(_ objects: [HKSample]) -> [[HKSample]] {
            let workoutType = HKObjectType.workoutType()
            let groups = Dictionary(grouping: objects) { $0.sampleType.identifier }
            let order = groups.keys.sorted { lhs, rhs in
                (lhs == workoutType.identifier ? 1 : 0, lhs) < (rhs == workoutType.identifier ? 1 : 0, rhs)
            }
            return order.compactMap { groups[$0] }
        }
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

    /// The saved workout and the sync identifiers of it and the samples
    /// saved with it.
    @MainActor
    private static func saveWorkout(
        metadata: WorkoutMetadata, startDate: Date, endDate: Date, samples options: SampleOptions,
        stamp: ExportStamp, store: HKHealthStore
    ) async throws -> (workout: HKWorkout, syncIds: Set<String>) {
        let builder = HKWorkoutBuilder(
            healthStore: store, configuration: workoutConfiguration(for: metadata.sport), device: .local()
        )
        let clock = WorkoutWallClock(startDate: startDate, pauseSpans: metadata.pauseSpans)
        try await builder.beginCollection(at: startDate)
        var syncIds = try await addSampleSeries(
            metadata: metadata, clock: clock, options: options, stamp: stamp, store: store, to: builder
        )
        let events = pauseEvents(of: clock, endDate: endDate)
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }
        try await builder.addMetadata(stamp.metadataOfWorkout)
        try await builder.endCollection(at: endDate)
        guard let workout = try await builder.finishWorkout() else {
            throw ExportError.workoutNotSaved
        }
        syncIds.insert(stamp.workoutIdentity)
        return (workout, syncIds)
    }

    /// The workout is already saved. A route that cannot be attached must not
    /// fail the export: the caller would leave the session unstamped, and the
    /// next backfill would save the same workout again. True when a route
    /// was saved. A workout built from Apple Health's samples gets none.
    private static func attachRouteToSavedWorkout(
        session: HRVSession, metadata: WorkoutMetadata, workout: HKWorkout, stamp: ExportStamp, store: HKHealthStore
    ) async -> Bool {
        guard !CloudSessionPayload.isHealthKitSourced(session) else { return false }
        do {
            return try await attachRoute(
                metadata: metadata, duration: session.duration, startDate: session.startDate,
                workout: workout, stamp: stamp, store: store
            )
        } catch {
            debugLog("[HKExport] workout \(session.id) saved without its route: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private static func workoutConfiguration(for sport: Sport) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = hkActivity(for: sport)
        configuration.locationType = sport.usesGPS ? .outdoor : .indoor
        return configuration
    }

    /// Attaches each sample series the user lets Emuqu write, and returns the
    /// sync identifiers of the samples it added.
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
        stamp: ExportStamp,
        store: HKHealthStore,
        to builder: HKWorkoutBuilder
    ) async throws -> Set<String> {
        let samples = options.writesDistanceAndEnergy ? metadata.samples ?? [] : []
        let series = [
            options.writesHeartRate ? heartRateSamples(of: metadata, clock: clock, stamp: stamp) : [],
            distanceSamples(from: samples, sport: metadata.sport, clock: clock, stamp: stamp),
            activeEnergySamples(from: samples, clock: clock, stamp: stamp, bodyWeightKg: options.bodyWeightKg)
        ]
        let writable = series.filter { $0.first.map { isWritable($0.sampleType, in: store) } ?? false }
        let skipped = series.compactMap { $0.first?.sampleType }.filter { !isWritable($0, in: store) }
        for batch in writable {
            try await builder.addSamples(batch)
        }
        if !skipped.isEmpty {
            debugLog("[HKExport] writing is off in Health for \(skipped.map(\.identifier).joined(separator: ", ")) — workout saved without those samples")
        }
        return Set(writable.joined().compactMap(HealthExportIdentity.syncIdentifier(of:)))
    }

    static func isWritable(_ type: HKObjectType, in store: HKHealthStore) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// A pause event where each pause began and a resume event where the
    /// workout went on, so Health's duration and pace leave the paused time
    /// out. A pause that runs to `endDate` (stopped while paused: the
    /// recorder ends the pause at the stop) gets no resume, and the builder
    /// counts it as paused to the end; one that began
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
    /// Resting metabolism, by the definition of the MET.
    private static let restingMETs = 1.0
    /// Below this a window is rounding noise and is not worth a sample.
    private static let minimumKcalPerSample = 0.01

    /// The workout's own heart rate: the rows Apple Health filled are left out.
    private static func heartRateSamples(
        of metadata: WorkoutMetadata, clock: WorkoutWallClock, stamp: ExportStamp
    ) -> [HKQuantitySample] {
        heartRateSamples(
            from: metadata.samples ?? [], clock: clock, stamp: stamp, skipping: Set(metadata.healthKitHROffsets ?? [])
        )
    }

    /// Per-tick heart rate, as instantaneous (zero-length) samples at each
    /// tick's wall-clock moment, leaving out the rows at `skipping` offsets
    /// (heart rate read from Apple Health). Each carries the export's
    /// `stamp`, numbered in the order written.
    static func heartRateSamples(
        from samples: [WorkoutSample], clock: WorkoutWallClock, stamp: ExportStamp, skipping healthKitOffsets: Set<Int> = []
    ) -> [HKQuantitySample] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        var out: [HKQuantitySample] = []
        for s in samples {
            guard let bpm = s.heartRate, !healthKitOffsets.contains(s.offsetSec) else { continue }
            let when = clock.date(atActiveOffset: s.offsetSec)
            let sample = HealthSampleFactory.quantitySample(
                type: hrType, value: Double(bpm), unit: HKUnit(from: "count/min"), start: when, end: when,
                metadata: stamp.sampleMetadata("hr", index: out.count)
            )
            if let sample { out.append(sample) }
        }
        return out
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
    /// `dist > lastDistance` (NaN > x is always false). Each carries the
    /// export's `stamp`, numbered in the order written.
    static func distanceSamples(
        from samples: [WorkoutSample],
        sport: Sport,
        clock: WorkoutWallClock,
        stamp: ExportStamp
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
                type: distType, value: delta, unit: .meter(), start: span.start, end: span.end,
                metadata: stamp.sampleMetadata("distance", index: out.count)
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
    /// seconds between ticks from the net METs (`netMETs`), so Health's
    /// Active Energy leaves out the resting metabolism Apple Watch already
    /// writes as basal energy; the sample sits on the wall clock and never
    /// crosses a pause (`WorkoutWallClock.interval`). Each carries the
    /// export's `stamp`, numbered in the order written.
    static func activeEnergySamples(
        from samples: [WorkoutSample],
        clock: WorkoutWallClock,
        stamp: ExportStamp,
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
            let kcal = (netMETs(mets) * mlOxygenPerKgPerMET * bodyWeightKg * minutes) / mlOxygenPerKcal
            guard kcal > minimumKcalPerSample else { continue }
            let span = clock.interval(fromActiveOffset: prevOffset, to: s.offsetSec)
            let sample = HealthSampleFactory.quantitySample(
                type: energyType, value: kcal, unit: .kilocalorie(), start: span.start, end: span.end,
                metadata: stamp.sampleMetadata("energy", index: out.count)
            )
            if let sample { out.append(sample) }
        }
        return out
    }

    /// The METs above rest: gross Compendium METs less the 1 MET of resting
    /// metabolism, never below zero.
    static func netMETs(_ grossMETs: Double) -> Double {
        max(0, grossMETs - restingMETs)
    }

    /// The ticks sorted by offset. Live ticks already are; a merged or
    /// recovered list may not be, and a span from a later tick back to an
    /// earlier one is not a sample HealthKit can hold.
    private static func inTimeOrder(_ samples: [WorkoutSample]) -> [WorkoutSample] {
        samples.sorted { $0.offsetSec < $1.offsetSec }
    }

    /// Attaches the GPS polyline to an already-persisted workout, under the
    /// export's route identity, and says whether a route was saved. No-op
    /// (false) for indoor sports, a missing polyline, or a polyline that
    /// decodes empty.
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
        stamp: ExportStamp,
        store: HKHealthStore
    ) async throws -> Bool {
        guard metadata.sport.usesGPS, let polyline = metadata.gpsPolyline else { return false }
        guard isWritable(HKSeriesType.workoutRoute(), in: store) else {
            debugLog("[HKExport] writing is off in Health for workout routes — workout saved without its route")
            return false
        }
        let track = GPXExporter.decode(
            polyline: polyline,
            startDate: startDate,
            duration: duration
        )
        guard !track.isEmpty else { return false }

        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(track)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: stamp.metadataOfRoute)
        return true
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

// MARK: - Replacements left for later

/// Sessions whose workout was saved while Health refused reads (a locked
/// phone), so the earlier copies it replaces could not be found. Kept in
/// `UserDefaults` (swept by Delete All My Data) as each session's start,
/// which `EarlierExport.find` needs, by session id.
@MainActor
enum PendingWorkoutReplacements {
    private static let key = "hkPendingWorkoutReplacements"

    static func pending() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func note(sessionId: UUID, startDate: Date) {
        var entries = pending()
        entries[sessionId.uuidString] = startDate.timeIntervalSince1970
        UserDefaults.standard.set(entries, forKey: key)
    }

    static func clear(sessionId: UUID) {
        var entries = pending()
        guard entries.removeValue(forKey: sessionId.uuidString) != nil else { return }
        UserDefaults.standard.set(entries, forKey: key)
    }

    /// For each pending session that no export holds
    /// (`HealthExportClaims`), find its exports (`EarlierExport.findAfterLockedSave`)
    /// and delete all but the newest (`EarlierExport.deleteSuperseded`), then
    /// forget it. A session
    /// whose read or delete fails stays pending for the next call.
    static func finish(in store: any HealthSampleStore) async {
        for (key, start) in pending() {
            guard let sessionId = UUID(uuidString: key) else {
                forget(key)
                continue
            }
            guard HealthExportClaims.claim(sessionId) else { continue }
            defer { HealthExportClaims.release(sessionId) }
            do {
                let earlier = try await HealthKitWorkoutExport.EarlierExport.findAfterLockedSave(
                    sessionId: sessionId, startDate: Date(timeIntervalSince1970: start), in: store
                )
                try await earlier.deleteSuperseded(from: store)
                clear(sessionId: sessionId)
            } catch {
                debugLog("[HKExport] earlier copies of \(key.prefix(8)) still to delete: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// Drop an entry whose key is not a session id.
    private static func forget(_ entry: String) {
        var entries = pending()
        entries.removeValue(forKey: entry)
        UserDefaults.standard.set(entries, forKey: key)
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
