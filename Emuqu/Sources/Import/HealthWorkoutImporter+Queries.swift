import CoreLocation
import Foundation
import HealthKit

// The HealthKit half of `HealthWorkoutImporter`. Kept separate from the policy
// so the decisions — what counts as a workout, which sport, what is a duplicate
// — stay testable without a health store, a device, or a user who has actually
// been for a run.

extension HealthWorkoutImporter {
    /// Workouts in Apple Health from the last `days` that Emuqu does not
    /// already have, newest first.
    ///
    /// Emuqu's own writes are excluded at the query, not filtered afterwards:
    /// the app exports every workout it records back to Apple Health, so
    /// without that exclusion the import list would be mostly the user's own
    /// history offering to import itself.
    func candidates(
        days: Int = 30,
        archive: SessionArchive,
        now: Date = Date()
    ) async -> [Candidate] {
        guard manager.isHealthKitAvailable else { return [] }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let workouts = await externalWorkouts(from: start, to: now)
        let archived = archive.entries(from: start, to: now)
            .filter { $0.sessionType == .workout }
            .map(\.date)
        return workouts
            .compactMap(Self.candidate(for:))
            .filter { !Self.isAlreadyArchived(start: $0.startDate, existingStarts: archived) }
            .sorted { $0.startDate > $1.startDate }
    }

    /// Rebuild one candidate into an archivable session.
    ///
    /// Returns nil when the workout has gone from HealthKit between listing and
    /// import (the user deleted it in the Health app, or the source app
    /// resynced) — the caller reports that rather than archiving an empty
    /// session.
    func session(for candidate: Candidate) async -> HRVSession? {
        guard let workout = await workout(withID: candidate.id) else { return nil }
        let track = await importedTrack(for: workout, candidate: candidate)
        var session = ImportedWorkoutBuilder.buildSession(
            from: track,
            source: .appleHealth(sourceName: candidate.sourceName)
        )
        Self.applyTotals(from: candidate, to: &session)
        return session
    }

    // MARK: - Assembling one workout

    private func importedTrack(for workout: HKWorkout, candidate: Candidate) async -> ImportedWorkoutTrack {
        async let locations = routeLocations(for: workout)
        async let heartRates = heartRateSamples(from: candidate.startDate, to: candidate.endDate)
        async let cadence = cadenceSamples(from: candidate.startDate, to: candidate.endDate)
        return await ImportedWorkoutTrack(
            startDate: candidate.startDate,
            endDate: candidate.endDate,
            track: locations,
            heartRateSamples: heartRates,
            cadenceSamples: cadence,
            sport: candidate.sport
        )
    }

    /// HealthKit's own totals win over anything derived from the track, and
    /// the weather Apple Watch saved with the workout is kept on it.
    ///
    /// A workout can have a distance and no route at all — a treadmill run, an
    /// indoor bike, a Strava activity synced without GPS. The builder derives
    /// distance by walking the track, so for those it derives zero, and the
    /// user sees a run they know was 10 km listed as 0 km. The recorded total
    /// is the better number whenever there is one.
    nonisolated private static func applyTotals(from candidate: Candidate, to session: inout HRVSession) {
        guard var metadata = session.workoutMetadata else { return }
        if let distance = candidate.distanceMeters, distance > 0,
           (metadata.distanceMeters ?? 0) <= 0 {
            metadata.distanceMeters = distance
        }
        if let weather = candidate.weather {
            metadata.weatherSnapshot = weather
        }
        session.workoutMetadata = metadata
    }

    // MARK: - Queries

    /// Every workout in the window that this app did not write.
    private func externalWorkouts(from start: Date, to end: Date) async -> [HKWorkout] {
        let inWindow = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let notOurs = NSCompoundPredicate(
            notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [inWindow, notOurs])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await manager.runBoundedQuery(
            timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec
        ) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                resolve((samples as? [HKWorkout]) ?? [])
            }
        } ?? []
    }

    private func workout(withID id: UUID) async -> HKWorkout? {
        await manager.runBoundedQuery(
            timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec
        ) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForObject(with: id),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve((samples as? [HKWorkout])?.first)
            }
        }
    }

    /// The workout's GPS track, or empty for an indoor or route-less workout.
    private func routeLocations(for workout: HKWorkout) async -> [CLLocation] {
        let training = manager.training
        guard let route = await training.routeSeries(for: workout) else { return [] }
        return await training.routeLocations(route)
    }

    /// The workout's heart rate, from whichever source recorded it.
    ///
    /// Internal rather than private for the same reason as `stepWindows`: the
    /// rebuild path in `+Rebuild` needs the identical query over a window it
    /// worked out for itself, and a second copy would be a second thing to
    /// keep correct.
    ///
    /// A failed read is an import with no HR rather than no import: the
    /// distance, route and elevation are still worth having, and the reason is
    /// logged rather than swallowed the way `try?` would swallow it.
    func heartRateSamples(from start: Date, to end: Date) async -> [(Date, Int)] {
        do {
            return Self.usableHeartRates(try await manager.fetchHeartRateSamples(from: start, to: end))
        } catch {
            debugLog("[HealthImport] heart rate read failed: \(error.localizedDescription)", level: .warning)
            return []
        }
    }

    /// `Int(...)` on a non-finite Double traps, and an out-of-range value is
    /// not a heart rate — drop both rather than carry them into the charts.
    nonisolated private static func usableHeartRates(
        _ samples: [(date: Date, hr: Double)]
    ) -> [(Date, Int)] {
        samples.compactMap { sample in
            guard sample.hr.isFinite, sample.hr > 0, sample.hr < 300 else { return nil }
            return (sample.date, Int(sample.hr.rounded()))
        }
    }

    private func cadenceSamples(from start: Date, to end: Date) async -> [(Date, Double)] {
        Self.cadenceSamples(from: await stepWindows(from: start, to: end))
    }

    /// Raw step windows in a time range. Shared with the rebuild path, which
    /// needs them twice over: once to work out when the activity stopped, and
    /// once to turn them into cadence.
    ///
    /// The predicate takes no `.strictStartDate`, and that is the whole
    /// difference between finding the walk and missing its first minutes.
    /// HealthKit writes step counts as batched windows, so the sample covering
    /// the moment a recording began almost always STARTED before it — a
    /// strict-start predicate drops exactly that sample, and
    /// `ActivityBoutResolver` is written to count it ("the user was already
    /// walking when the recording began"). With no option the predicate matches
    /// any sample overlapping the range, which is what the resolver is reading.
    func stepWindows(from start: Date, to end: Date) async -> [HealthSampleWindow] {
        guard let stepType = HKTypes.quantity(.stepCount) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await manager.runBoundedQuery(
            timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec
        ) { resolve in
            HKSampleQuery(
                sampleType: stepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve(Self.stepWindows(samples))
            }
        } ?? []
    }

    nonisolated private static func stepWindows(_ samples: [HKSample]?) -> [HealthSampleWindow] {
        ((samples as? [HKQuantitySample]) ?? []).map {
            HealthSampleWindow(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: .count()))
        }
    }

    // MARK: - Candidate mapping

    nonisolated private static func candidate(for workout: HKWorkout) -> Candidate? {
        guard workout.duration >= minimumImportableDuration else { return nil }
        let isIndoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool ?? false
        guard let sport = sport(for: workout.workoutActivityType, isIndoor: isIndoor) else { return nil }
        return Candidate(
            id: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            sport: sport,
            sourceName: workout.sourceRevision.source.name,
            distanceMeters: distance(of: workout),
            weather: sport.usesGPS
                ? WorkoutWeatherSnapshot(healthKitMetadata: workout.metadata, observedAt: workout.startDate)
                : nil
        )
    }

    /// `HKQuantityType(_:)` rather than `HKTypes.quantity(_:)` here and below:
    /// the failable helper exists so a caller can abandon a query when a type
    /// is unavailable, and there is no query to abandon — these are statistics
    /// already attached to a workout the caller is holding.
    nonisolated private static func distance(of workout: HKWorkout) -> Double? {
        let walkRun = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))
        let cycling = workout.statistics(for: HKQuantityType(.distanceCycling))
        let sum = (walkRun ?? cycling ?? rowingDistance(of: workout))?.sumQuantity()?.doubleValue(for: .meter())
        guard let sum, sum.isFinite, sum > 0 else { return nil }
        return sum
    }

    /// Rowing distance is an iOS 18 HealthKit type; earlier systems have none.
    nonisolated private static func rowingDistance(of workout: HKWorkout) -> HKStatistics? {
        guard #available(iOS 18.0, *) else { return nil }
        return workout.statistics(for: HKQuantityType(.distanceRowing))
    }

}
