import CoreLocation
import Foundation

/// Shared store of the user's current heat-acclimatization state.
///
/// Mirrors `TrainingMetricsCache`: the Load/Trajectory card, the AI's
/// `heat.acclimation.*` facts, and the per-workout summary all read from
/// here so they can never disagree.
///
/// **Data source.** Heat exposure is built primarily from the app's own
/// workout archive — each in-app outdoor session carries an exact GPS
/// polyline and (going forward) the weather captured at finish — and
/// supplemented by HealthKit outdoor workouts (Apple Watch / Garmin /
/// Strava) that don't duplicate an in-app session.
///
/// **Weather attribution is per-day AND per-location.** A correct
/// historical baseline must read the weather for the day *and the place*
/// each session happened. So each workout day is paired with that day's
/// hourly *historical* weather at the coordinate read from the workout's
/// own GPS polyline; the Open-Meteo archive is fetched per distinct
/// location (cached per coordinate, so training around one place is still a
/// single call, while travelling fetches each area). Rest days carry no
/// stimulus and need no lookup. Workouts that captured exact weather use it
/// directly; workouts with no GPS of their own (e.g. HealthKit-sourced)
/// fall back to the user's most-recent / current / persisted coordinate.
///
/// Cold start: a brand-new user (or one with no recent heat) sees a genuine
/// 0 that builds from their first hot session.
@Observable
@MainActor
final class HeatAcclimationCache {
    static let shared = HeatAcclimationCache()

    /// Current status — drives a self-explaining card instead of one that
    /// silently hides when a runtime dependency (location, workouts,
    /// network) is missing.
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
        /// No outdoor workouts found in Apple Health for the window.
        case noOutdoorWorkouts
        /// Outdoor workouts exist but we couldn't get a coordinate to look
        /// up the weather they happened in. Carries the count so the card
        /// (and the user) can see what was actually found.
        case needsLocation(outdoorWorkouts: Int)
        /// Had a coordinate but the historical-weather fetch failed.
        case weatherUnavailable(outdoorWorkouts: Int)
    }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let observers = NotificationTokens()

    /// Privacy: the Open-Meteo lookup runs only once the user has turned heat
    /// tracking on.
    ///
    /// The historical-weather fetch sends a coordinate to a third party, and
    /// the fallback coordinate can come from a live location fix, which can
    /// raise the location permission prompt. Merely showing the card used to
    /// count as consent: opening the Fitness tab asked for location and
    /// contacted Open-Meteo with nothing on screen saying why. The switch is
    /// now `UserSettings.heatTrackingEnabled`, off until the user taps the
    /// card's button next to its explanation. Both entry points — the card
    /// (`refresh()`) and the assistant's `heat.acclimation.*` facts
    /// (`currentAwaitingRefresh()`) — return without computing while it is
    /// off, and `fallbackCoordinate` checks it again, so a future caller that
    /// reaches `computeStatus` some other way still cannot reach the network.
    private var trackingEnabled: Bool {
        AppDependencies.current.app.settingsManager.settings.heatTrackingEnabled
    }

    /// In-memory cache of fetched weather windows, keyed by
    /// (rounded coordinate, window-end day) so attributing many workouts at
    /// the same place — or a recompute within the same day — makes one call
    /// per distinct location rather than one per workout.
    private var cachedHourlyByKey: [String: [WeatherService.HourlyWeather]] = [:]

    /// Insertion order for `cachedHourlyByKey`, oldest first, so the
    /// bounded-cap eviction (see `weatherWindow`) drops the least-recently
    /// added entry rather than an arbitrary dictionary slot.
    private var cachedHourlyKeyOrder: [String] = []

    /// Upper bound on distinct weather windows kept in memory. One entry
    /// per (rounded coordinate, window-end day); normal use is a handful,
    /// so this cap is never reached in practice — it only prevents unbounded
    /// growth if a caller attributes workouts across very many locations/days.
    private static let cachedHourlyCap = 200

    /// Persisted representative coordinate so heat works on a cold launch
    /// before a fresh location fix arrives.
    private static let coordLatKey = "FlowRecovery.heat.representativeLat"
    private static let coordLonKey = "FlowRecovery.heat.representativeLon"
    /// Persisted last readout so the card shows the previous value
    /// immediately on launch instead of a spinner while a fresh (network)
    /// compute runs.
    private static let readoutKey = "FlowRecovery.heat.lastReadout"

    /// Remove all persisted heat-acclimation state. The representative
    /// coordinate is PRECISE LOCATION, so this MUST run on data erasure —
    /// otherwise the lat/lon survive "Delete All My Data" (GDPR/CCPA
    /// Art. 17). Called from `DataPurgeService.purgeAllUserData`.
    static func clearPersistedData() {
        UserDefaults.standard.removeObject(forKey: coordLatKey)
        UserDefaults.standard.removeObject(forKey: coordLonKey)
        UserDefaults.standard.removeObject(forKey: readoutKey)
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
        /// Outdoor workouts in the window we could attribute weather to.
        let attributedWorkoutCount: Int
        let adaptedWBGT: Double?
        let daysToTarget: Int?
        var hasHeatExposure: Bool { hotExposureCount > 0 }
        /// Whether there's enough to render the card — any outdoor workout
        /// with attributed weather, even on cool days (so the user sees
        /// "not acclimated yet" rather than nothing).
        var hasData: Bool { attributedWorkoutCount > 0 }
    }

    private let archive: SessionArchive
    private let maxAgeSec: TimeInterval = 300 // 5 min, matches TrainingMetricsCache

    init(archive: SessionArchive = AppDependencies.current.storage.sessionArchive) {
        self.archive = archive
        // Seed from the last persisted readout so the card shows
        // the previous value immediately instead of a spinner while a fresh
        // (HealthKit + network) compute runs. `lastUpdated` stays nil so
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

    /// Recompute the status if stale. Async: fetches HealthKit workouts and
    /// (when the window/location changed) one weather range, then replays.
    /// Safe to call from view `.task`/`.onAppear`.
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

    /// Cache only a settled result. Transient blockers (no fix yet) stay stale
    /// so the next refresh retries.
    private func cacheIfSettled(_ computed: Status) {
        switch computed {
        case let .ready(readout):
            self.lastUpdated = Date()
            Self.persistReadout(readout) // survive relaunch → no cold spinner
        case .noOutdoorWorkouts:
            self.lastUpdated = Date()
        case .needsLocation:
            AppDependencies.current.location.ambientLocationService.start()
            self.lastUpdated = nil
        case .weatherUnavailable, .computing:
            self.lastUpdated = nil
        }
    }

    /// Await a fresh-enough readout — used by the AI fact path so the
    /// assistant gets a real value on the first ask instead of nil.
    func currentAwaitingRefresh() async -> Readout? {
        // Asking the assistant is not the same as agreeing to the lookup; the
        // card's button is where that choice is explained and made.
        guard trackingEnabled else { return nil }
        if let current, let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAgeSec {
            return current
        }
        let computed = await computeStatus()
        status = computed
        switch computed {
        case .ready, .noOutdoorWorkouts:
            lastUpdated = Date()
        default:
            lastUpdated = nil
        }
        if case let .ready(r) = computed { return r }
        return nil
    }

    // MARK: - Compute

    /// One outdoor workout to score: when, how long, where (from its own
    /// GPS), and any exact weather already captured.
    private struct WorkoutForHeat {
        let date: Date
        let minutes: Double
        let coord: CLLocationCoordinate2D?
        let exactWeather: WorkoutWeatherSnapshot?
    }

    private func computeStatus() async -> Status {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -HeatConstants.replayLookbackDays, to: today) ?? today
        let workouts = await Self.mergingHealthKitWorkouts(into: archivedWorkouts(since: windowStart))
        guard !workouts.isEmpty else { return .noOutdoorWorkouts }
        // Heat tracking is off — don't silently send a coordinate to
        // Open-Meteo. Report the same blocker the card already understands.
        guard let fallbackCoord = try? await fallbackCoordinate(for: workouts) else {
            return .weatherUnavailable(outdoorWorkouts: workouts.count)
        }
        let (exposuresByDay, triedAnyFetch) = await attributeWeather(
            to: workouts, fallbackCoord: fallbackCoord, windowStart: windowStart, calendar: calendar
        )
        guard !exposuresByDay.isEmpty else {
            return Self.blocker(triedAnyFetch: triedAnyFetch, outdoorWorkouts: workouts.count)
        }
        return Self.replayReadout(
            exposuresByDay: exposuresByDay, attributedWorkoutCount: exposuresByDay.count,
            from: windowStart, to: today, calendar: calendar
        )
    }

    /// Distinguish the blocker for the self-explaining card: never had a
    /// coordinate to even try → location; tried but the archive came back empty
    /// or unmatched → network.
    private static func blocker(triedAnyFetch: Bool, outdoorWorkouts: Int) -> Status {
        triedAnyFetch
            ? .weatherUnavailable(outdoorWorkouts: outdoorWorkouts)
            : .needsLocation(outdoorWorkouts: outdoorWorkouts)
    }

    /// A representative coordinate, ONLY for workouts that carry no GPS of
    /// their own (HealthKit-sourced, or an in-app session without a polyline).
    /// Workouts that DO have their own coordinate use it directly, so each
    /// historical day reads the weather at the place that session actually
    /// happened rather than one representative spot. Preference: most-recent
    /// recorded GPS, then a live fix, then the last persisted coordinate.
    ///
    /// Privacy: resolving and sending a coordinate for a
    /// historical-weather lookup is the disclosed-third-party path, so it is
    /// gated on the user having turned heat tracking on (`trackingEnabled`).
    /// Throws when they have not — the caller reports the same blocker the card
    /// already understands. When every workout already captured its own exact
    /// weather, no coordinate is needed and none is resolved.
    private func fallbackCoordinate(for workouts: [WorkoutForHeat]) async throws -> CLLocationCoordinate2D? {
        guard workouts.contains(where: { $0.exactWeather == nil }) else { return nil }
        guard trackingEnabled else { throw HeatGateError.trackingOff }
        return await resolveFallbackCoordinate(from: workouts)
    }

    /// The heat backfill was asked for weather while heat tracking is off.
    private enum HeatGateError: Error {
        case trackingOff
    }

    /// 1. PRIMARY source: the app's own workout archive — where in-app
    /// recordings live, each with an exact GPS polyline. The coordinate is read
    /// straight from the polyline (no permission, no HealthKit, no
    /// current-location dependency), along with any weather already captured at
    /// finalize.
    ///
    /// Decoded OFF the main actor. This loop decrypts +
    /// JSON-decodes every workout in the 60-day window (and GPX-decodes each
    /// polyline); running it inline on the @MainActor cache is the dominant
    /// first-load lag on the Fitness tab. Mirrors
    /// TrainingMetricsCache.buildDailySeries, which is also detached. Only the
    /// pure read/decode moves off-main; the weather/HealthKit/persist steps stay
    /// on the actor.
    private func archivedWorkouts(since windowStart: Date) async -> [WorkoutForHeat] {
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            archive.entries
                .filter { $0.sessionType == .workout && $0.date >= windowStart }
                .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "HeatAcclimationCache") }
                .map(Self.workoutForHeat)
        }.value
    }

    nonisolated private static func workoutForHeat(_ session: HRVSession) -> WorkoutForHeat {
        let end = session.endDate ?? session.startDate
        let duration = end.timeIntervalSince(session.startDate)
        let coord = session.workoutMetadata?.gpsPolyline.flatMap { poly in
            GPXExporter.decode(polyline: poly, startDate: session.startDate, duration: duration).first?.coordinate
        }
        return WorkoutForHeat(
            date: session.startDate,
            minutes: max(0, duration / 60.0),
            coord: coord,
            exactWeather: session.workoutMetadata?.weatherSnapshot
        )
    }

    /// 4. Attribute weather to each workout — exact captured weather first, else
    /// the historical weather at THE WORKOUT'S OWN location, averaged across THE
    /// HOURS THE SESSION ACTUALLY SPANNED (start → start+duration), so a run
    /// that begins cool and finishes in the heat of the day is scored on what it
    /// was really exposed to rather than the temperature at the minute it began.
    /// `weatherWindow` caches per coordinate, so a user who trains around one
    /// place still makes a single archive call, while a traveller correctly gets
    /// each area's weather for its sessions.
    ///
    /// Returns the exposures by day, and whether any network lookup was
    /// attempted — the caller uses that to tell a location blocker from a
    /// network one.
    ///
    /// Privacy: this is the path that sends a coordinate
    /// to Open-Meteo, which is why the caller gates it on `trackingEnabled`.
    private func attributeWeather(
        to workouts: [WorkoutForHeat],
        fallbackCoord: CLLocationCoordinate2D?,
        windowStart: Date,
        calendar: Calendar
    ) async -> ([Date: [HeatAcclimation.Exposure]], Bool) {
        var exposuresByDay: [Date: [HeatAcclimation.Exposure]] = [:]
        var triedAnyFetch = false
        for w in workouts {
            var conditions: (tempC: Double, rh: Double)?
            if let exact = w.exactWeather {
                conditions = (exact.temperatureC, exact.relativeHumidityPercent)
            } else if let coord = w.coord ?? fallbackCoord {
                triedAnyFetch = true
                let hourly = await weatherWindow(coord: coord, start: windowStart, end: Date())
                conditions = Self.conditions(forStart: w.date, minutes: w.minutes, in: hourly)
            }
            // No exact weather and no location to look it up: skip the session.
            guard let c = conditions else { continue }
            exposuresByDay[calendar.startOfDay(for: w.date), default: []].append(
                HeatAcclimation.Exposure(tempC: c.tempC, relativeHumidity: c.rh, durationMinutes: w.minutes)
            )
        }
        return (exposuresByDay, triedAnyFetch)
    }

    /// Fold HealthKit's outdoor workouts in alongside the in-app archive.
    ///
    /// A session recorded in the app and mirrored to HealthKit appears in both
    /// sources, so anything within half an hour of a workout we already have is
    /// treated as the same session and dropped — double-counting it would
    /// inflate the day's heat stimulus.
    private static func mergingHealthKitWorkouts(
        into workouts: [WorkoutForHeat]
    ) async -> [WorkoutForHeat] {
        var merged = workouts
        let hkWorkouts = await AppDependencies.current.collection.healthKitManager.fetchOutdoorWorkoutsForHeat(
            days: HeatConstants.replayLookbackDays
        )
        for w in hkWorkouts {
            let isDuplicate = merged.contains { abs($0.date.timeIntervalSince(w.date)) < 1800 }
            if isDuplicate { continue }
            merged.append(
                WorkoutForHeat(date: w.date, minutes: w.durationMinutes, coord: nil, exactWeather: nil)
            )
        }
        return merged
    }

    /// A representative coordinate for workouts that carry no GPS of their own.
    ///
    /// Preference order: the most recent workout that did record a position,
    /// then a live fix, then whatever was last persisted. Only ever called when
    /// some workout actually needs a weather lookup — see the `trackingEnabled`
    /// gate at the call site, which is the privacy boundary.
    private func resolveFallbackCoordinate(
        from workouts: [WorkoutForHeat]
    ) async -> CLLocationCoordinate2D? {
        var coord = workouts.sorted { $0.date > $1.date }.compactMap(\.coord).first
        if coord == nil { coord = await AppDependencies.current.location.ambientLocationService.currentCoordinate() }
        if coord == nil { coord = persistedCoordinate() }
        if let coord { persist(coord) }
        return coord
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

    /// Resolve the weather window, reusing the in-memory cache when the
    /// location + window-end day are unchanged.
    private func weatherWindow(
        coord: CLLocationCoordinate2D, start: Date, end: Date
    ) async -> [WeatherService.HourlyWeather] {
        let calendar = Calendar.current
        let endDay = Int(calendar.startOfDay(for: end).timeIntervalSince1970)
        let key = String(format: "%.2f,%.2f,%d", coord.latitude, coord.longitude, endDay)
        if let cached = cachedHourlyByKey[key], !cached.isEmpty {
            return cached
        }
        let hourly = await WeatherService.fetchArchiveRange(at: coord, startDate: start, endDate: end)
        if !hourly.isEmpty {
            if cachedHourlyByKey[key] == nil {
                cachedHourlyKeyOrder.append(key)
            }
            cachedHourlyByKey[key] = hourly
            // Bounded cap: evict oldest entries so the in-memory cache can't
            // grow without limit.
            while cachedHourlyKeyOrder.count > Self.cachedHourlyCap {
                let oldest = cachedHourlyKeyOrder.removeFirst()
                cachedHourlyByKey.removeValue(forKey: oldest)
            }
        }
        return hourly
    }

    private func persistedCoordinate() -> CLLocationCoordinate2D? {
        let lat = UserDefaults.standard.double(forKey: Self.coordLatKey)
        let lon = UserDefaults.standard.double(forKey: Self.coordLonKey)
        if lat != 0 || lon != 0 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private func persist(_ c: CLLocationCoordinate2D) {
        UserDefaults.standard.set(c.latitude, forKey: Self.coordLatKey)
        UserDefaults.standard.set(c.longitude, forKey: Self.coordLonKey)
    }

    /// Temperature and humidity the session was actually exposed to:
    /// every hourly reading from the hour the workout started through the
    /// hour it ended, averaged. A 90-minute run that starts at 6am and ends
    /// at 7:30am is scored on the 6am AND 7am conditions, not just 6am —
    /// which matters most exactly when it matters: long sessions pushing
    /// into the heat of the day. Falls back to the single nearest hour for a
    /// short session that sits between two hourly marks.
    private static func conditions(
        forStart start: Date,
        minutes: Double,
        in hourly: [WeatherService.HourlyWeather]
    ) -> (tempC: Double, rh: Double)? {
        guard !hourly.isEmpty else { return nil }
        let end = start.addingTimeInterval(max(minutes, 0) * 60)
        // From the hour mark at/just-before the start (−3599s grabs the
        // containing hour without pulling the previous full hour) through
        // the end.
        let windowStart = start.addingTimeInterval(-3599)
        let spanned = hourly.filter { $0.time >= windowStart && $0.time <= end }
        let samples = spanned.isEmpty
            ? [nearestHour(to: start, in: hourly)].compactMap { $0 }
            : spanned
        guard !samples.isEmpty else { return nil }
        let temp = samples.reduce(0.0) { $0 + $1.temperatureC } / Double(samples.count)
        let rh = samples.reduce(0.0) { $0 + $1.relativeHumidityPercent } / Double(samples.count)
        return (tempC: temp, rh: rh)
    }

    private static func nearestHour(
        to date: Date,
        in hourly: [WeatherService.HourlyWeather]
    ) -> WeatherService.HourlyWeather? {
        guard !hourly.isEmpty else { return nil }
        var best: WeatherService.HourlyWeather?
        var bestDelta = Double.greatestFiniteMagnitude
        for h in hourly {
            let delta = abs(h.time.timeIntervalSince(date))
            if delta < bestDelta { bestDelta = delta; best = h }
        }
        // Guard against attributing weather from a wildly different time
        // (e.g. a workout outside the fetched range).
        guard bestDelta <= 3 * 3600 else { return nil }
        return best
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
