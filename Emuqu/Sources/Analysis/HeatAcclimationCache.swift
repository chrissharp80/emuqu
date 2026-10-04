import Foundation

/// Shared store of the user's current heat-acclimatization state.
///
/// Mirrors `TrainingMetricsCache`: the Load/Trajectory card, the AI's
/// `heat.acclimation.*` facts, and the per-workout summary all read from
/// here so they can never disagree.
///
/// **Data source.** Heat exposure comes only from weather recorded at the
/// time of each outdoor workout: the snapshot an in-app recording saves at
/// finish (`WorkoutMetadata.weatherSnapshot`). Outdoor workouts in Apple
/// Health that the app did not record are counted, so the card can say what
/// it found, but they add no exposure because they reach this cache without
/// weather. A workout with no recorded weather is left out of heat load
/// rather than scored on weather looked up afterwards: no weather archive
/// the app may use commercially exists, and a guess would be scored as fact.
///
/// Cold start: a brand-new user (or one with no recent heat) sees a genuine
/// 0 that builds from their first hot session.
@Observable
@MainActor
final class HeatAcclimationCache {
    static let shared = HeatAcclimationCache()

    /// Current status — drives a self-explaining card instead of one that
    /// silently hides when there is nothing to score.
    private(set) var status: Status = .computing
    private(set) var lastUpdated: Date?

    /// Convenience for callers that only care about a ready readout.
    var current: Readout? {
        if case let .ready(r) = status { return r }
        return nil
    }

    enum Status: Equatable {
        /// First compute hasn't finished.
        case computing
        /// We have a readout to show.
        case ready(Readout)
        /// No outdoor workouts in the window, in the app or in Apple Health.
        case noOutdoorWorkouts
        /// Outdoor workouts exist but none has weather recorded with it.
        /// Carries the count so the card (and the user) can see what was found.
        case noRecordedWeather(outdoorWorkouts: Int)
    }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let observers = NotificationTokens()

    /// Heat tracking is a feature the user turns on from the card, where it
    /// is explained. Both entry points — the card (`refresh()`) and the
    /// assistant's `heat.acclimation.*` facts (`currentAwaitingRefresh()`) —
    /// return without computing while it is off.
    private var trackingEnabled: Bool {
        AppDependencies.current.app.settingsManager.settings.heatTrackingEnabled
    }

    /// Persisted last readout so the card shows the previous value
    /// immediately on launch instead of a spinner while a fresh compute runs.
    private static let readoutKey = "FlowRecovery.heat.lastReadout"

    /// A representative location older builds stored to look up past
    /// weather. Nothing writes them now; they are still removed on erase so
    /// a location saved by an older build doesn't outlive "Delete All My Data".
    private static let legacyCoordinateKeys = [
        "FlowRecovery.heat.representativeLat",
        "FlowRecovery.heat.representativeLon"
    ]

    /// Remove all persisted heat-acclimation state. Called from
    /// `DataPurgeService.purgeAllUserData` and when heat tracking is turned off.
    static func clearPersistedData() {
        for key in legacyCoordinateKeys + [readoutKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func persistReadout(_ readout: Readout) {
        if let data = attempt("heatAcclimation.encode", { try JSONEncoder().encode(readout) }) {
            UserDefaults.standard.set(data, forKey: readoutKey)
        }
    }

    private static func loadPersistedReadout() -> Readout? {
        guard let data = UserDefaults.standard.data(forKey: readoutKey) else { return nil }
        return try? JSONDecoder().decode(Readout.self, from: data)
    }

    /// Everything a surface needs to render the heat readout.
    struct Readout: Equatable, Codable {
        let level: Double
        let band: HeatAcclimation.Band
        let latestStimulus: Double
        /// Days in the window that carried a real heat stimulus.
        let hotExposureCount: Int
        /// Outdoor workouts in the window with recorded weather.
        let attributedWorkoutCount: Int
        let adaptedWBGT: Double?
        let daysToTarget: Int?
        var hasHeatExposure: Bool { hotExposureCount > 0 }
        /// Whether there's enough to render the card — any outdoor workout
        /// with recorded weather, even on cool days (so the user sees
        /// "not acclimated yet" rather than nothing).
        var hasData: Bool { attributedWorkoutCount > 0 }
    }

    private let archive: SessionArchive
    private let maxAgeSec: TimeInterval = 300 // 5 min, matches TrainingMetricsCache

    init(archive: SessionArchive = AppDependencies.current.storage.sessionArchive) {
        self.archive = archive
        // Seed from the last persisted readout so the card shows
        // the previous value immediately instead of a spinner while a fresh
        // (archive + HealthKit) compute runs. `lastUpdated` stays nil so
        // refresh() still recomputes and swaps in the new value when ready.
        if let saved = Self.loadPersistedReadout() {
            status = .ready(saved)
        }
        observers.add(Self.makeArchiveObserver { [weak self] in self?.invalidate() })
    }

    /// `queue: nil`, not `.main`. A non-nil queue makes
    /// `post` block the posting thread until the block finishes on that queue.
    /// Archive writes post from background threads, so `.main` adds a
    /// synchronous main-queue round-trip to every write (and deadlocks when
    /// main is itself waiting on those writes). This block only schedules a
    /// `Task { @MainActor }`, so running it on the posting thread is
    /// equivalent — minus the blocking wait. See `ArchiveSignal.init`.
    private static func makeArchiveObserver(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveChanged,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in onChange() }
        }
    }

    deinit { observers.removeAll() }

    func invalidate() {
        lastUpdated = nil
    }

    /// Recompute the status if stale. Async: reads the archive and HealthKit
    /// workouts, then replays. Safe to call from view `.task`/`.onAppear`.
    func refresh() {
        guard trackingEnabled else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAgeSec, case .ready = status {
            return
        }
        if refreshTask != nil { return }
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            guard let self else { return }
            let computed = await self.computeStatus()
            self.status = computed
            self.cacheIfSettled(computed)
        }
    }

    /// Every computed status is settled: nothing here waits on a location fix
    /// or the network, so a retry before the next archive change would give
    /// the same answer.
    private func cacheIfSettled(_ computed: Status) {
        switch computed {
        case let .ready(readout):
            lastUpdated = Date()
            Self.persistReadout(readout) // survive relaunch → no cold spinner
        case .noOutdoorWorkouts, .noRecordedWeather:
            lastUpdated = Date()
        case .computing:
            lastUpdated = nil
        }
    }

    /// Await a fresh-enough readout — used by the AI fact path so the
    /// assistant gets a real value on the first ask instead of nil.
    func currentAwaitingRefresh() async -> Readout? {
        // Asking the assistant is not the same as turning the feature on; the
        // card's button is where that choice is explained and made.
        guard trackingEnabled else { return nil }
        if let current, let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAgeSec {
            return current
        }
        let computed = await computeStatus()
        status = computed
        cacheIfSettled(computed)
        return current
    }

    // MARK: - Compute

    /// One outdoor workout to score: when, how long, and the weather recorded
    /// with it, if any.
    struct WorkoutForHeat: Equatable {
        let date: Date
        let minutes: Double
        let weather: WorkoutWeatherSnapshot?
    }

    private func computeStatus() async -> Status {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -HeatConstants.replayLookbackDays, to: today) ?? today
        let workouts = await Self.mergingHealthKitWorkouts(into: archivedWorkouts(since: windowStart))
        guard !workouts.isEmpty else { return .noOutdoorWorkouts }
        let exposuresByDay = Self.exposuresByDay(workouts, calendar: calendar)
        guard !exposuresByDay.isEmpty else { return .noRecordedWeather(outdoorWorkouts: workouts.count) }
        return Self.replayReadout(
            exposuresByDay: exposuresByDay,
            attributedWorkoutCount: exposuresByDay.values.reduce(0) { $0 + $1.count },
            from: windowStart, to: today, calendar: calendar
        )
    }

    /// The app's own workout archive, outdoor sports only.
    ///
    /// Decoded OFF the main actor. This loop decrypts + JSON-decodes every
    /// workout in the replay window; running it inline on the @MainActor
    /// cache is the dominant first-load lag on the Fitness tab. Mirrors
    /// TrainingMetricsCache.buildDailySeries, which is also detached.
    private func archivedWorkouts(since windowStart: Date) async -> [WorkoutForHeat] {
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            archive.entries
                .filter { $0.sessionType == .workout && $0.date >= windowStart }
                .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "HeatAcclimationCache") }
                // Outdoor sports only: a treadmill or indoor-bike session
                // must not be scored on the outdoor weather.
                .filter { $0.workoutMetadata?.sport.usesGPS == true }
                .map(Self.workoutForHeat)
        }.value
    }

    nonisolated private static func workoutForHeat(_ session: HRVSession) -> WorkoutForHeat {
        let end = session.endDate ?? session.startDate
        return WorkoutForHeat(
            date: session.startDate,
            minutes: max(0, end.timeIntervalSince(session.startDate) / 60.0),
            weather: session.workoutMetadata?.weatherSnapshot
        )
    }

    /// Each workout's exposure from the weather recorded with it, grouped by
    /// day. A workout without recorded weather is left out.
    static func exposuresByDay(
        _ workouts: [WorkoutForHeat],
        calendar: Calendar
    ) -> [Date: [HeatAcclimation.Exposure]] {
        var exposuresByDay: [Date: [HeatAcclimation.Exposure]] = [:]
        for w in workouts {
            guard let weather = w.weather else { continue }
            exposuresByDay[calendar.startOfDay(for: w.date), default: []].append(
                HeatAcclimation.Exposure(
                    tempC: weather.temperatureC,
                    relativeHumidity: weather.relativeHumidityPercent,
                    durationMinutes: w.minutes
                )
            )
        }
        return exposuresByDay
    }

    /// Fold HealthKit's outdoor workouts in alongside the in-app archive.
    ///
    /// A session recorded in the app and mirrored to HealthKit appears in both
    /// sources, so anything within half an hour of an archived workout is
    /// treated as the same session and dropped — double-counting it would
    /// inflate the day's heat stimulus. HealthKit workouts are compared only
    /// against the archive, never against each other, so two separate Watch
    /// sessions 20 minutes apart both count. Their weather comes from the
    /// workout's HealthKit metadata when Apple Watch saved it.
    private static func mergingHealthKitWorkouts(
        into workouts: [WorkoutForHeat]
    ) async -> [WorkoutForHeat] {
        var merged = workouts
        let hkWorkouts = await AppDependencies.current.collection.healthKitManager.fetchOutdoorWorkoutsForHeat(
            days: HeatConstants.replayLookbackDays
        )
        for w in hkWorkouts {
            let isDuplicate = workouts.contains { abs($0.date.timeIntervalSince(w.date)) < 1800 }
            if isDuplicate { continue }
            merged.append(WorkoutForHeat(date: w.date, minutes: w.durationMinutes, weather: w.weather))
        }
        return merged
    }

    /// Gap-fill every day in the window so rest days decay, then replay the
    /// whole series. A day with no exposure is a real input, not a missing one.
    private static func replayReadout(
        exposuresByDay: [Date: [HeatAcclimation.Exposure]],
        attributedWorkoutCount: Int,
        from windowStart: Date,
        to today: Date,
        calendar: Calendar
    ) -> Status {
        let (dayInputs, hotExposureCount) = gapFilledDays(
            exposuresByDay: exposuresByDay, from: windowStart, to: today, calendar: calendar
        )
        let series = HeatAcclimation.replay(dayInputs)
        let level = series.last?.level ?? 0
        return .ready(Readout(
            level: level,
            band: HeatAcclimation.band(for: level),
            latestStimulus: series.last?.stimulus ?? 0,
            hotExposureCount: hotExposureCount,
            attributedWorkoutCount: attributedWorkoutCount,
            adaptedWBGT: HeatAcclimation.adaptedWBGT(for: level),
            daysToTarget: HeatAcclimation.daysToTarget(current: level)
        ))
    }

    private static func gapFilledDays(
        exposuresByDay: [Date: [HeatAcclimation.Exposure]],
        from windowStart: Date,
        to today: Date,
        calendar: Calendar
    ) -> ([HeatAcclimation.DayInput], Int) {
        var dayInputs: [HeatAcclimation.DayInput] = []
        var hotExposureCount = 0
        var d = windowStart
        while d <= today {
            let stimulus = HeatAcclimation.dailyStimulus(exposuresByDay[d] ?? [])
            if stimulus > 0 { hotExposureCount += 1 }
            dayInputs.append(.init(date: d, stimulus: stimulus))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return (dayInputs, hotExposureCount)
    }

    /// Map a persisted in-app workout + its captured weather to an exposure.
    static func exposure(
        from session: HRVSession,
        weather: WorkoutWeatherSnapshot
    ) -> HeatAcclimation.Exposure {
        let end = session.endDate ?? session.startDate
        let minutes = max(0, end.timeIntervalSince(session.startDate) / 60.0)
        return HeatAcclimation.Exposure(
            tempC: weather.temperatureC,
            relativeHumidity: weather.relativeHumidityPercent,
            durationMinutes: minutes
        )
    }
}
