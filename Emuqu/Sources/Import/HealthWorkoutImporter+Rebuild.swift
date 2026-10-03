import CoreLocation
import Foundation
import HealthKit

// Rebuilding a recording that died before it captured anything.
//
// The import list in `HealthWorkoutImporter+Queries` can only offer what Apple
// Health holds as a WORKOUT. When Emuqu's own recording crashes there is no
// such workout: the phone died before writing one, and the Watch discards its
// session because the phone is supposed to own the canonical copy. All that
// survives in Health is the passive record — steps, distance and heart rate,
// sampled the whole time regardless.
//
// That passive record is enough to give the hour back. It is not enough to say
// when the hour ended, because a crashed recording has no end; that comes from
// `ActivityBoutResolver`.

extension HealthWorkoutImporter {
    /// A recording that started and captured essentially nothing.
    struct InterruptedSession: Identifiable, Sendable, Equatable {
        /// The archived session's own id. Reused on rebuild so the result
        /// REPLACES the stub instead of leaving a one-second ghost beside the
        /// hour it should have been.
        let id: UUID
        let startDate: Date
        let sport: Sport
        let capturedSeconds: TimeInterval
    }

    /// Archived workouts short enough that nothing was captured.
    ///
    /// The threshold is the same one that rejects HealthKit's ghost workouts:
    /// under a minute is not a session, it is the wreckage of one. Anything
    /// longer is left alone — a rebuild replaces the session wholesale, and
    /// overwriting a real partial recording would destroy the part that DID
    /// survive.
    func interruptedSessions(
        archive: SessionArchive,
        days: Int = 30,
        now: Date = Date()
    ) -> [InterruptedSession] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let workouts = archive.entries(from: start, to: now).filter { $0.sessionType == .workout }
        let stubs = workouts
            .compactMap { Self.stub(from: $0, archive: archive) }
            .sorted { $0.startDate > $1.startDate }
        // One line saying what was scanned and what survived. Without it, "the
        // card didn't appear" is indistinguishable from "there was nothing to
        // show", and the two need completely different fixes.
        let shortest = workouts
            .map { entry -> String in
                let captured = entry.endDate.map { Int($0.timeIntervalSince(entry.date)) }
                return "\(entry.date): \(captured.map(String.init) ?? "no end")s"
            }
            .joined(separator: " | ")
        debugLog("[HealthImport] interrupted scan: \(workouts.count) workout(s) in the last \(days)d, \(stubs.count) short enough to rebuild (threshold \(Int(Self.minimumImportableDuration))s) — \(shortest)")
        return stubs
    }

    nonisolated private static func stub(
        from entry: SessionArchiveEntry,
        archive: SessionArchive
    ) -> InterruptedSession? {
        guard let end = entry.endDate else {
            debugLog("[HealthImport] workout \(entry.sessionId.uuidString.prefix(8)) at \(entry.date) has no end date — cannot tell whether it was interrupted", level: .warning)
            return nil
        }
        let captured = end.timeIntervalSince(entry.date)
        guard captured >= 0, captured < minimumImportableDuration else { return nil }
        // `?? nil` flattens the double optional: `retrieveLightweight` returns
        // an optional session, and `attempt` wraps its result in another.
        let stored = attempt("healthImport.readStub") { try archive.retrieveLightweight(entry.sessionId) } ?? nil
        guard let sport = stored?.workoutMetadata?.sport else {
            noteUnrebuildable(entry, captured: captured, readable: stored != nil)
            return nil
        }
        return InterruptedSession(
            id: entry.sessionId,
            startDate: entry.date,
            sport: sport,
            capturedSeconds: captured
        )
    }

    /// A stub that will not be offered for rebuild, and why.
    ///
    /// The rebuild needs the sport to know which passive speed and distance
    /// Apple Health even records for it, so a session whose file cannot be read
    /// — or that carries no sport — cannot be rebuilt without guessing, and a
    /// guess would attach a walker's pace to a ride.
    ///
    /// It is logged rather than dropped in silence because a crashed recording
    /// is exactly the session most likely to have a damaged file, and "the row
    /// I came here for isn't listed", with no explanation anywhere, is how this
    /// feature failed the first time.
    nonisolated private static func noteUnrebuildable(
        _ entry: SessionArchiveEntry, captured: TimeInterval, readable: Bool
    ) {
        let reason = readable ? "it records no sport" : "its file could not be read"
        debugLog(
            "[HealthImport] interrupted \(Int(captured))s workout \(entry.sessionId.uuidString.prefix(8)) at \(entry.date) not offered for rebuild: \(reason)",
            level: .warning
        )
    }

    /// Why a rebuild produced nothing, kept apart because the two reasons ask
    /// the user for completely different things.
    ///
    /// "Health has no activity there" is a fact about the day and there is
    /// nothing to do about it. "Health returned nothing at all" is almost
    /// always a permission that was never granted — a read Emuqu was not
    /// allowed to make comes back as an empty result with no error, which is
    /// indistinguishable from an empty day unless you notice that a phone in
    /// someone's pocket does not record zero steps for six hours. Reporting
    /// both as "no activity" sends a user with a fixable settings problem away
    /// believing their walk is gone.
    enum RebuildFailure: Error, Equatable {
        /// Steps came back, but none of them show movement after the start.
        case noActivityAfterStart
        /// Health returned no step samples whatsoever across the search window.
        case noSamplesAtAll
    }

    /// Which of the two failures this is, from the step samples alone.
    ///
    /// Pure so the distinction is testable without a health store — it decides
    /// which of two very different things the user is told, and getting it
    /// backwards sends someone with a fixable permission away believing their
    /// walk is gone.
    nonisolated static func failure(whenBoutNotFoundWith steps: [HealthSampleWindow]) -> RebuildFailure {
        steps.isEmpty ? .noSamplesAtAll : .noActivityAfterStart
    }

    /// Rebuild an interrupted recording from Apple Health's passive samples.
    func rebuild(_ stub: InterruptedSession) async -> Result<HRVSession, RebuildFailure> {
        await rebuild(startingAt: stub.startDate, sport: stub.sport, replacing: stub.id)
    }

    /// Rebuild an activity from Apple Health's passive samples for a start time
    /// the user supplies, with nothing left in the archive to hang it on.
    ///
    /// This exists because keying the rebuild to a leftover stub was wrong. A
    /// recording that dies in its first seconds leaves a one-second session,
    /// and deleting that junk row is the obvious thing for anyone to do — at
    /// which point the only route back to the hour they actually walked was
    /// deleted along with it. Health still has the steps, the heart rate and
    /// the distance; the archive's wreckage was never the thing that made the
    /// rebuild possible, only the thing that made it discoverable.
    ///
    /// `replacing` is nil here, so the result is a new session rather than an
    /// overwrite.
    func rebuild(
        startingAt startDate: Date,
        sport: Sport,
        replacing existingID: UUID? = nil
    ) async -> Result<HRVSession, RebuildFailure> {
        let searchEnd = startDate.addingTimeInterval(ActivityBoutResolver.maxBoutDuration)
        let steps = await stepWindows(from: startDate, to: searchEnd)
        guard let end = await boutEnd(from: startDate, to: searchEnd, steps: steps) else {
            let reason = Self.failure(whenBoutNotFoundWith: steps)
            debugLog("[HealthImport] rebuild found no bout for \(sport.rawValue) at \(startDate) — \(reason)", level: .warning)
            return .failure(reason)
        }
        let track = await rebuiltTrack(startDate: startDate, sport: sport, end: end, steps: steps)
        var session = ImportedWorkoutBuilder.buildSession(
            from: track,
            source: .appleHealthSamples,
            replacing: existingID
        )
        await applyRebuiltDistance(from: startDate, to: end, sport: sport, to: &session)
        await applyRebuiltSignals(from: startDate, to: end, sport: sport, to: &session)
        debugLog("[HealthImport] rebuilt \(sport.rawValue) \(startDate)…\(end) — \(Int(end.timeIntervalSince(startDate)))s, \(Int(session.workoutMetadata?.distanceMeters ?? 0))m")
        return .success(session)
    }

    /// When the activity stopped, preferring Apple's own judgement over ours.
    ///
    /// `appleExerciseTime` is the minute-by-minute record of when Apple
    /// considered the user to be exercising — recorded whether or not anything
    /// was recording a workout. It ends when the walk ends. Step counts do not:
    /// they keep accruing around the house afterwards, and every one of those
    /// samples inside the gap window drags the reconstructed workout longer.
    ///
    /// Steps remain the fallback, because exercise time is only written when
    /// the effort clears Apple's threshold — a slow amble can produce steps and
    /// no exercise minutes at all, and a short walk is still a walk.
    private func boutEnd(
        from start: Date,
        to searchEnd: Date,
        steps: [HealthSampleWindow]
    ) async -> Date? {
        let exercise = await quantityWindows(.appleExerciseTime, unit: .minute(), from: start, to: searchEnd)
        if let end = ActivityBoutResolver.end(ofBoutStartingAt: start, activity: exercise) { return end }
        return ActivityBoutResolver.end(ofBoutStartingAt: start, activity: steps)
    }

    /// Fill in what the passive record knows and a GPS-less rebuild otherwise
    /// cannot: pace, effort, and the only terrain signal Apple Health carries.
    private func applyRebuiltSignals(
        from start: Date,
        to end: Date,
        sport: Sport,
        to session: inout HRVSession
    ) async {
        async let speed = speedWindows(for: sport, from: start, to: end)
        async let effort = physicalEffortWindows(from: start, to: end)
        async let flights = cumulativeSum(.flightsClimbed, unit: .count(), from: start, to: end)
        await applySpeedAndEffort(speed: speed, effort: effort, start: start, to: &session)
        await applyElevation(flights: flights, to: &session)
    }

    /// The passive speed signal for this sport, or none.
    ///
    /// Apple Health records walking and running speed on its own; it records no
    /// passive speed for a bike, a rower or an air bike. Falling back to
    /// walking speed for those would attach a walking pace to a ride — a
    /// plausible number that is simply about a different activity.
    private func speedWindows(for sport: Sport, from start: Date, to end: Date) async -> [HealthSampleWindow] {
        let metersPerSecond = HKUnit.meter().unitDivided(by: .second())
        switch sport {
        case .run, .trailRun, .treadmill:
            return await quantityWindows(.runningSpeed, unit: metersPerSecond, from: start, to: end)
        case .walk, .hike:
            return await quantityWindows(.walkingSpeed, unit: metersPerSecond, from: start, to: end)
        case .bike, .indoorBike, .row, .airBike, .crossFit:
            return []
        }
    }

    /// Speed becomes pace; physical effort is already METs.
    ///
    /// Both are sampled far more coarsely than the per-second grid, so each
    /// value is held across the window it was measured over rather than
    /// interpolated — an average speed over five minutes is a statement about
    /// those five minutes, not about one instant inside them.
    private func applySpeedAndEffort(
        speed: [HealthSampleWindow],
        effort: [HealthSampleWindow],
        start: Date,
        to session: inout HRVSession
    ) {
        guard let samples = session.workoutMetadata?.samples, !samples.isEmpty else { return }
        let pace = Self.bySecond(speed, start: start, seconds: samples.count, transform: Self.pace)
        let mets = Self.bySecond(effort, start: start, seconds: samples.count) { $0 }
        session.workoutMetadata?.samples = samples.map {
            Self.filled($0, pace: pace[$0.offsetSec], mets: mets[$0.offsetSec])
        }
    }

    /// Pace is seconds per kilometre; HealthKit reports metres per second. A
    /// speed at or near zero divides into an infinity that later `Int(...)`
    /// conversions trap on, so it yields no pace rather than a huge one.
    nonisolated private static func pace(fromMetersPerSecond speed: Double) -> Double? {
        guard speed > 0.1, speed.isFinite else { return nil }
        return 1_000 / speed
    }

    /// A copy of the sample with pace and METs filled in where it had none.
    /// Anything already measured wins — this only fills gaps.
    nonisolated private static func filled(
        _ sample: WorkoutSample, pace: Double?, mets: Double?
    ) -> WorkoutSample {
        WorkoutSample(
            offsetSec: sample.offsetSec,
            heartRate: sample.heartRate,
            distanceMeters: sample.distanceMeters,
            paceSecPerKm: sample.paceSecPerKm ?? pace,
            cadenceStepsPerMin: sample.cadenceStepsPerMin,
            altitudeMeters: sample.altitudeMeters,
            alpha1: sample.alpha1,
            mets: sample.mets ?? mets,
            powerWatts: sample.powerWatts
        )
    }

    /// Spread each measurement window across the seconds it covers.
    nonisolated private static func bySecond(
        _ windows: [HealthSampleWindow],
        start: Date,
        seconds: Int,
        transform: (Double) -> Double?
    ) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for window in windows {
            guard window.value.isFinite, let value = transform(window.value) else { continue }
            let from = max(0, Int(window.start.timeIntervalSince(start)))
            let to = min(seconds - 1, Int(window.end.timeIntervalSince(start)))
            guard from <= to else { continue }
            for second in from ... to { out[second] = value }
        }
        return out
    }

    /// HealthKit defines one flight as ten feet of ascent, which is the only
    /// elevation figure the passive record offers. It is a coarse number and it
    /// is honest about being coarse — far better than reporting a hilly walk as
    /// flat. The count is HealthKit's deduplicated sum, so flights logged by
    /// both the iPhone and the Watch count once.
    private func applyElevation(
        flights: Double?,
        to session: inout HRVSession
    ) {
        guard let total = flights, total.isFinite, total > 0 else { return }
        session.workoutMetadata?.elevationGainMeters = total * Self.metersPerFlightClimbed
    }

    /// Ten feet, per HealthKit's own definition of `flightsClimbed`.
    nonisolated static let metersPerFlightClimbed: Double = 3.048

    private func rebuiltTrack(
        startDate: Date,
        sport: Sport,
        end: Date,
        steps: [HealthSampleWindow]
    ) async -> ImportedWorkoutTrack {
        let withinBout = steps.filter { $0.start < end && $0.end > startDate }
        return await ImportedWorkoutTrack(
            startDate: startDate,
            endDate: end,
            // No route: the recording died before it logged one, and Health
            // keeps a route only against a workout, which is exactly what is
            // missing here. Distance comes from the totals below instead.
            track: [],
            heartRateSamples: heartRateSamples(from: startDate, to: end),
            cadenceSamples: Self.cadenceSamples(from: withinBout),
            sport: sport
        )
    }

    /// Distance for the bout, summed from Health's own totals.
    ///
    /// The builder derives distance by walking a GPS track, and a rebuild has
    /// none — so without this the user gets their hour back showing zero
    /// kilometres.
    private func applyRebuiltDistance(
        from start: Date,
        to end: Date,
        sport: Sport,
        to session: inout HRVSession
    ) async {
        guard let meters = await totalDistance(from: start, to: end, sport: sport), meters > 0 else { return }
        session.workoutMetadata?.distanceMeters = meters
    }

    /// Sample windows for any quantity type, in the shape the bout resolver and
    /// the sample filler both take.
    ///
    /// No `.strictStartDate`, for the reason given on `stepWindows`: every one
    /// of these quantities is written as a batched window, so the sample
    /// covering the start of the bout usually began before it. Both consumers
    /// are window-aware — the resolver counts a straddling window, and
    /// `bySecond` clamps one to the seconds it actually covers — so matching on
    /// overlap gives them the sample they are written to handle instead of
    /// hiding it.
    private func quantityWindows(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> [HealthSampleWindow] {
        guard let type = HKTypes.quantity(identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await manager.runBoundedQuery(
            timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec
        ) { resolve in
            HKSampleQuery(
                sampleType: type, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                resolve(Self.windows(samples, unit: unit))
            }
        } ?? []
    }

    /// METs. The unit string is HealthKit's own canonical unit for
    /// `physicalEffort` — passing anything else to `doubleValue(for:)` throws
    /// an Objective-C exception rather than returning nil, so it is not a
    /// place to guess.
    private func physicalEffortWindows(from start: Date, to end: Date) async -> [HealthSampleWindow] {
        await quantityWindows(.physicalEffort, unit: HKUnit(from: "kcal/(kg*hr)"), from: start, to: end)
    }

    nonisolated private static func windows(
        _ samples: [HKSample]?, unit: HKUnit
    ) -> [HealthSampleWindow] {
        ((samples as? [HKQuantitySample]) ?? []).map {
            HealthSampleWindow(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    /// The passive distance type Apple Health records for this sport, or none.
    ///
    /// Same honesty as `speedWindows`: Health keeps a continuous
    /// walking/running distance and a continuous cycling distance, and keeps
    /// nothing passive for a rower, an air bike or a gym session. Reading
    /// walking distance for those would attach the metres the user covered
    /// walking to the machine they sat on.
    nonisolated static func passiveDistanceType(for sport: Sport) -> HKQuantityTypeIdentifier? {
        switch sport {
        case .run, .trailRun, .treadmill, .walk, .hike: .distanceWalkingRunning
        case .bike, .indoorBike: .distanceCycling
        case .row, .airBike, .crossFit: nil
        }
    }

    private func totalDistance(from start: Date, to end: Date, sport: Sport) async -> Double? {
        guard let identifier = Self.passiveDistanceType(for: sport) else { return nil }
        return await cumulativeSum(identifier, unit: .meter(), from: start, to: end)
    }

    /// HealthKit's cumulative sum over the bout, deduplicated across sources
    /// (an iPhone and a Watch both logging the same steps or flights count
    /// once), which raw sample queries are not.
    ///
    /// `.strictStartDate` here and NOT on the window queries above, deliberately:
    /// only samples that start inside the bout count, so one that began before
    /// it does not add amounts covered before the bout. A sample that starts
    /// inside and runs past the end still counts in full. The window queries
    /// ask "was there activity", for which overlap is the right rule.
    private func cumulativeSum(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date
    ) async -> Double? {
        guard let type = HKTypes.quantity(identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await manager.runBoundedQuery(
            timeout: HealthKitManager.backgroundAggregateQueryTimeoutSec
        ) { resolve in
            HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                resolve(statistics?.sumQuantity()?.doubleValue(for: unit))
            }
        }
    }
}
