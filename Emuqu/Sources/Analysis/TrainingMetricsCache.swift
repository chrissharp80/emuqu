import Foundation

/// Shared store of current training metrics (CTL / ATL / TSB / ACWR).
///
/// The dashboard's `calculateTrainingMetrics` path and the AI's
/// `training.load.*` tools both read from here so they can never disagree
/// with each other. Before this cache existed, the AI tools read from the
/// stale `HRVSession.trainingSnapshot` frozen at session-accept time,
/// which returned pre-TRIMP-fix values for weeks after the Banister 0.64
/// scaling correction landed.
///
/// Refresh is async + HealthKit-sourced. Sync callers (AI fact resolver)
/// get a snapshot of the last-known value immediately and — when stale —
/// trigger a background refresh so the *next* resolve is fresher.
/// Async callers (dashboard foreground) `await refresh()` for
/// guaranteed-current numbers.
@Observable
@MainActor
final class TrainingMetricsCache {
    static let shared = TrainingMetricsCache()

    private(set) var current: TrainingMetrics?
    private(set) var lastUpdated: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Day-indexed training-load series covering the last ~400 days.
    /// Keyed by `startOfDay(local)`; value is that day's (atl, ctl, trimp).
    /// Populated during `refresh()` so historical lookups ("what was my
    /// CTL last month?" / "how has ATL trended?") answer from this map
    /// synchronously without blocking on a HealthKit call per query.
    ///
    /// Range is bounded because HealthKit queries get slower the wider
    /// you go, and users asking about multi-year history genuinely need
    /// a longer-lookback fetch the user can wait for (future work:
    /// background extended refresh for year-over-year queries).
    /// Observable so surfaces showing an inline training-load
    /// trend (e.g. the Fitness tab's trajectory card) re-render when the
    /// detached historical-series build lands, instead of reading an empty
    /// map on first appear and never updating.
    private(set) var dailySeries: [Date: DaySample] = [:]

    struct DaySample: Codable {
        let date: Date
        let atl: Double
        let ctl: Double
        let trimp: Double
        var tsb: Double { ctl - atl }
    }

    /// Max age before a snapshot is considered stale. Stale reads still
    /// return the cached value (callers never block on `.snapshot()`),
    /// but they schedule a background refresh so the next read is fresh.
    private let maxAgeSec: TimeInterval = 300 // 5 min — matches typical provider prompt-cache TTL

    /// How far back to fetch workouts on refresh. 400 days covers
    /// year-over-year queries with some slack for the 42-day CTL window
    /// anchoring a year-ago date.
    private let lookbackDays: Int = 400

    private init() {
        // Restore last-known metrics from disk FIRST so the dashboard
        // and AI see numbers immediately on cold launch (reconciled by refresh()).
        loadFromDisk()
        observers.add(Self.makeArchiveObserver { [weak self] in
            self?.invalidateIfWorkoutsChanged()
        })
    }

    /// Invalidate on archive writes so a just-finished workout's
    /// load reaches the dashboard AND the AI immediately (both read
    /// `dailySeries[today]`), instead of lagging up to 5 min behind `current`.
    ///
    /// But ONLY when the archive change actually touched a
    /// WORKOUT. Training load = f(workouts, resting/max HR); an HRV overnight
    /// write (rescore, sleep-snapshot attach, CloudKit pull) can't change it.
    /// The prior "invalidate on ANY write" made the launch/morning storm of
    /// HRV writes each force a full 400-day HealthKit refetch + Banister
    /// replay — the "app is slow to start / load looked unstable" cost
    /// (dailyTRIMP was rebuilt up to 10×/day). `invalidateIfWorkoutsChanged`
    /// gates on a cheap in-memory fingerprint of the workout entries so a
    /// real workout add/delete/edit still invalidates instantly while the
    /// HRV-write flood is ignored. (HR-setting changes are picked up by the
    /// 5-min TTL, exactly as before — they never invalidated this cache.)
    ///
    /// `queue: nil`, not `.main`. A non-nil queue makes
    /// `post` block the posting thread until the block finishes on that queue.
    /// Archive writes post from background threads, so `.main` added a
    /// synchronous main-queue round-trip to every write (and deadlocked when
    /// main was itself waiting on those writes). This block only schedules a
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

    /// Fingerprint of the last workout set that invalidated the cache. `nil`
    /// until the first archive change, so the first change always invalidates.
    private var lastWorkoutFingerprint: Int?
    /// Calendar day of the last full compute — a new day needs a fresh EWMA step
    /// even when the workout set is unchanged.
    private var lastComputedDay: Date?
    /// Workout fingerprint at the last 400-day historical-series (`dailySeries`)
    /// build. The historical series only changes when the WORKOUT SET changes
    /// (past days are a pure function of past workouts), so we skip the expensive
    /// 400-day Banister replay on new-day / time-only refreshes.
    private var lastHistoricalFingerprint: Int?
    /// Staleness bound applied ONLY when nothing observably changed (same workout
    /// set AND same calendar day). Training load = f(workouts, RHR, maxHR, day),
    /// so when those are unchanged the prior result is still valid and re-decoding
    /// 100+ workout files + replaying the EWMA every 5 min is pure waste (the
    /// recompute-everything-every-time cost the user hit). Changes we CAN observe
    /// cheaply (app-recorded workout add/edit/delete) rebuild immediately via
    /// `invalidateIfWorkoutsChanged`; changes we can't (a workout logged in
    /// another app, an HR-setting edit) are picked up on this longer catch-all
    /// interval or via the Settings "Rebuild training load" action.
    private let unchangedMaxAgeSec: TimeInterval = 1800 // 30 min

    /// Cheap fingerprint of the archived WORKOUT set: each workout entry's id +
    /// `fileHash`. `fileHash` changes whenever that session file is rewritten,
    /// so this catches adds, deletes, AND metadata/load edits — while staying
    /// blind to the far-more-frequent HRV overnight writes that don't touch
    /// training load. Reads the in-memory index only (no disk, no HealthKit).
    private func workoutFingerprint() -> Int {
        var hasher = Hasher()
        for entry in AppDependencies.current.storage.sessionArchive.entries where entry.sessionType == .workout {
            hasher.combine(entry.sessionId)
            hasher.combine(entry.fileHash)
        }
        return hasher.finalize()
    }

    /// Invalidate ONLY when the workout set changed since the last invalidation.
    /// See the `init` note for why invalidation is conditional.
    private func invalidateIfWorkoutsChanged() {
        let fingerprint = workoutFingerprint()
        guard fingerprint != lastWorkoutFingerprint else { return }
        lastWorkoutFingerprint = fingerprint
        invalidate()
    }

    deinit { observers.removeAll() }

    @ObservationIgnored private let observers = NotificationTokens()

    // MARK: - Cross-launch persistence (cold-start)

    /// On-disk snapshot of the cache so a COLD LAUNCH shows last-known training
    /// metrics immediately instead of `nil` → "building baseline" while a full
    /// ~250-workout / 400-day Banister replay runs (a "~19s to populate" cost
    /// when nothing survives a launch). This is only a "show last-known while
    /// recomputing" placeholder:
    /// `loadFromDisk` keeps the SAVED timestamp/fingerprint, so `refresh()`'s
    /// existing incremental gate reconciles it on launch — a changed workout set
    /// or a new calendar day forces a fresh compute, so a stale value can never
    /// become authoritative.
    private struct PersistedCache: Codable {
        let current: TrainingMetrics?
        let dailySeries: [Date: DaySample]
        let fingerprint: Int
        let computedDay: Date?
        let savedAt: Date
    }

    private static let persistenceURL: URL? = {
        let fm = FileManager.default
        guard let dir = attempt("trainingMetricsCache.supportDir", { try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }) else { return nil }
        return dir.appendingPathComponent("TrainingMetricsCache.json")
    }()

    /// Persist the current cache state to disk, off the main actor. Best-effort:
    /// a failed write just means the next cold launch rebuilds (as it always did).
    private func persistToDisk() {
        guard let url = Self.persistenceURL else { return }
        let snapshot = PersistedCache(
            current: current,
            dailySeries: dailySeries,
            fingerprint: lastWorkoutFingerprint ?? 0,
            computedDay: lastComputedDay,
            savedAt: lastUpdated ?? Date()
        )
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                debugLog("[TrainingMetricsCache] persist failed: \(error)", level: .warning)
            }
        }
    }

    /// Load the persisted snapshot on launch so the dashboard/AI see last-known
    /// numbers instantly. Any decode failure → nil → the normal cold rebuild
    /// Deliberately keeps the SAVED `lastUpdated`
    /// (not "now") so `refresh()`'s TTL still fires a reconcile after launch.
    private func loadFromDisk() {
        guard let url = Self.persistenceURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistedCache.self, from: data)
        else { return }
        current = snapshot.current
        dailySeries = snapshot.dailySeries
        lastWorkoutFingerprint = snapshot.fingerprint
        lastComputedDay = snapshot.computedDay
        lastUpdated = snapshot.savedAt
        debugLog("[TrainingMetricsCache] restored persisted metrics (saved \(snapshot.savedAt), \(snapshot.dailySeries.count) day-samples) — will reconcile on refresh", level: .info)
    }

    // MARK: - Historical queries (sync, pre-computed via refresh)

    /// Sample on a specific local date (uses `startOfDay` for the lookup).
    /// Returns nil when the date is outside the cached window or the cache
    /// hasn't warmed yet.
    func sampleOn(date: Date) -> DaySample? {
        let key = Calendar.current.startOfDay(for: date)
        return dailySeries[key]
    }

    /// All samples with `date >= cutoff`, newest first. Returns `[]` when
    /// the cache is cold. Callers who want a sparse series (one entry per
    /// day even on zero-training days) get exactly that — every day in
    /// the cached window has an entry.
    func samplesSince(_ cutoff: Date) -> [DaySample] {
        dailySeries.values
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    /// Date range of the cached series, or nil when cold.
    var dataAvailabilityRange: ClosedRange<Date>? {
        let dates = dailySeries.keys
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }
        return earliest ... latest
    }

    /// Synchronous accessor for callers that can't `await` (the
    /// FactResolver's closures, for example). Returns whatever is
    /// cached — possibly `nil` on cold start, possibly stale — and
    /// kicks off a background refresh when the entry is past
    /// `maxAgeSec`. Never blocks.
    func snapshot(reference: Date = Date()) -> TrainingMetrics? {
        if needsRefresh(reference: reference) {
            scheduleRefresh()
        }
        return current
    }

    /// Injected HealthKit provider. Set once at app launch via
    /// `configure(healthKit:)` — the cache itself is a singleton, but
    /// the HealthKitManager is instance-owned by `RRCollector`, so we
    /// weave them together once rather than hard-coding a singleton
    /// where there isn't one.
    private weak var healthKit: HealthKitManager?

    /// Wire up the cache's HealthKit source. Safe to call multiple
    /// times; last-call wins. Called once from `EmuquApp` with
    /// `collector.healthKit`.
    func configure(healthKit: HealthKitManager) {
        self.healthKit = healthKit
    }

    /// Await a fresh refresh. Use when the caller genuinely needs the
    /// newest numbers — dashboard foreground, explicit refresh, post-
    /// workout-save re-materialize. Concurrent callers are coalesced
    /// onto a single in-flight task.
    ///
    /// Also repopulates `dailySeries` so historical-date queries have a
    /// day-by-day EWMA to look up against. This is O(400) in the worst
    /// case which is cheap in-process — the bottleneck is the HealthKit
    /// fetch, which we already pay for current-metrics.
    func refresh(reference: Date = Date(), forMorningReading: Bool = false) async {
        // Not yet wired — refresh is a no-op. The first caller to hit a cold
        // cache after configure() runs will succeed. (`startRefreshTask`
        // re-unwraps `healthKit` inside its task.)
        guard healthKit != nil else { return }
        guard needsRebuild(reference: reference) else { return }
        if let existing = refreshTask {
            _ = await existing.value
            return
        }
        _ = await startRefreshTask(reference: reference, forMorningReading: forMorningReading).value
    }

    /// Whether anything can actually have changed since the cached result.
    ///
    /// Fast-exit when the cache is fresh. AssistantViewModel.dispatch
    /// awaits `refresh()` on every send (so the AI sees the same training-load
    /// numbers as the dashboard); running the full HealthKit fetch when the
    /// cache is 30 seconds old would add ~100–500 ms to every AI send for no value.
    ///
    /// Also rebuilds when the historical daily series hasn't landed
    /// yet, even if `current` is fresh. A prior caller (dashboard / AI /
    /// reanalysis) can warm `current`/`lastUpdated` while the detached
    /// dailySeries build is still empty; without the `dailySeries.isEmpty`
    /// clause the Fitness inline trend reads an empty series and renders nothing.
    ///
    /// If the workout set AND the calendar day match what the
    /// persisted cache already reflects, the numbers CANNOT have changed (load
    /// is a pure function of workouts + resting/max HR + day). The rebuild is
    /// skipped ENTIRELY — no HealthKit fetch, no Banister replay — no matter how
    /// old the timestamp is; otherwise a cold launch would always rebuild (the
    /// restored `lastUpdated` is hours/days old), burning a full recompute to
    /// reproduce the identical numbers already on disk (Chris: "why do it at
    /// all? store what you need"). A workout add/edit/delete flips the
    /// fingerprint; a new calendar day rebuilds for the new EWMA step but does
    /// not replay the 400-day history (see startRefreshTask). HR-setting
    /// changes the fingerprint can't see are picked up on the next new-day
    /// rebuild, or via Settings "Rebuild training load".
    ///
    /// NOTE: `lastUpdated != nil` is REQUIRED — `invalidate()` (fired by a
    /// workout add/edit/delete) clears `lastUpdated` as its dirty flag while
    /// leaving the fingerprint updated, so `nothingChanged` can be true right
    /// after a real change; the nil check forces the rebuild in that case.
    private func needsRebuild(reference: Date) -> Bool {
        let refDay = Calendar.current.startOfDay(for: reference)
        let nothingChanged = workoutFingerprint() == lastWorkoutFingerprint && refDay == lastComputedDay
        if nothingChanged, lastUpdated != nil, current != nil, !dailySeries.isEmpty { return false }
        // Something changed (new workout, or a new day): rebuild, but throttle a
        // burst of rapid calls to `maxAgeSec` so they coalesce.
        if let updated = lastUpdated, reference.timeIntervalSince(updated) <= maxAgeSec, !dailySeries.isEmpty {
            return false
        }
        return true
    }

    /// Create, register (as `refreshTask`), and return the actual refresh
    /// task. The coalescing guard (`if let existing = refreshTask`) lives in
    /// the callers — this function MUST NOT re-enter it, or a caller running
    /// inside the task would await its own task and hang forever.
    ///
    /// Extracted so `scheduleRefresh()` can register a task
    /// WITHOUT routing through `refresh()`'s coalescing guard. A
    /// `scheduleRefresh` that sets `refreshTask = Task { await refresh() }`
    /// has `refresh()` see `refreshTask` (itself) non-nil, await
    /// `existing.value`, and deadlock permanently — freezing CTL/ATL/TSB/
    /// ACWR (and every AI send that awaits refresh()) for the process
    /// lifetime once the cache goes stale.
    @discardableResult
    /// Publish `current` as soon as the 120-day dashboard metrics are in hand,
    /// THEN kick the 400-day historical series off in a detached task.
    /// Awaiting both before publishing `current` makes the dashboard's training
    /// fetch wait on work (the 400-day Banister replay) it doesn't need for the
    /// today-view, which is what fires the "Live data fetch timed out after
    /// 15 s" warning. AI
    /// fact-catalog callers that need the historical series await
    /// `refreshHistorical()` separately.
    private func startRefreshTask(reference: Date, forMorningReading: Bool) -> Task<Void, Never> {
        let task = Task { [weak self] in
            guard let self, let hk = self.healthKit else { return }
            // Fetch the 180-day HealthKit workout list ONCE and
            // share it with the historical replay rather than fetching it twice
            // per refresh, milliseconds apart.
            let sharedHKWorkouts = await hk.fetchWorkoutsExtended(
                days: max(self.lookbackDays, 180), relativeTo: reference
            )
            self.current = await hk.calculateTrainingMetrics(
                forMorningReading: forMorningReading,
                relativeTo: reference,
                preloadedHealthKitWorkouts: sharedHKWorkouts
            )
            self.publishCurrent(reference: reference)
            self.startHistoricalRebuildIfNeeded(
                healthKit: hk, reference: reference, sharedHKWorkouts: sharedHKWorkouts
            )
        }
        refreshTask = task
        return task
    }

    /// Stamps what this compute reflects — so the incremental gate can reuse it
    /// until the workouts or the day actually change — and persists it so the
    /// next cold launch shows it instantly.
    private func publishCurrent(reference: Date) {
        lastUpdated = Date()
        lastWorkoutFingerprint = workoutFingerprint()
        lastComputedDay = Calendar.current.startOfDay(for: reference)
        refreshTask = nil
        persistToDisk()
    }

    /// Historical 400-day series — REBUILT ONLY WHEN THE WORKOUT SET CHANGED
    /// (or it was never built).
    ///
    /// Past daily-series points are a pure function of PAST
    /// workouts, so a new day or a time-based refresh can't change them, and
    /// today's point is sourced from `current` at the display layer
    /// (LoadTrajectoryLoader), not from this series. There is no reason to
    /// replay 400 days of Banister on every morning launch (Chris: don't
    /// rebuild 400 days unless it's actually needed). A workout
    /// add/edit/delete flips the fingerprint and triggers the rebuild; AI /
    /// Load-tab callers force one via `refreshHistorical()`. Fire-and-forget;
    /// AI callers await it.
    private func startHistoricalRebuildIfNeeded(
        healthKit hk: HealthKitManager,
        reference: Date,
        sharedHKWorkouts: [HealthKitManager.WorkoutSummary]
    ) {
        let histFingerprint = workoutFingerprint()
        guard dailySeries.isEmpty || histFingerprint != lastHistoricalFingerprint else { return }
        lastHistoricalFingerprint = histFingerprint
        historicalTask = Task.detached(priority: .utility) { [hkWorkouts = sharedHKWorkouts] in
            let series = await Self.buildDailySeries(
                healthKit: hk,
                reference: reference,
                lookbackDays: self.lookbackDays,
                preloadedHealthKitWorkouts: hkWorkouts
            )
            await MainActor.run {
                self.dailySeries = series
                // Persist again now the 400-day series has landed.
                self.persistToDisk()
            }
        }
    }

    // There is deliberately no `adoptExternalLiveSnapshot`-style API that lets the
    // Dashboard publish its OWN `calculateTrainingMetrics` back into the cache (a
    // second writer). The Dashboard reads
    // `AppDependencies.current.analysis.trainingMetricsCache.current` (DashboardV2View.swift) and never
    // computes its own, so there is exactly ONE writer of `current`
    // (`startRefreshTask`, + `loadFromDisk` placeholder) —
    // don't reintroduce a second one; route any new consumer through `refresh()`/`current`.

    /// Holds the currently-running 400-day historical-series build. AI
    /// fact-catalog callers that need the `dailySeries` populated can
    /// `await historicalTask?.value` to block until it finishes. The
    /// dashboard doesn't need it and never waits.
    @ObservationIgnored private(set) var historicalTask: Task<Void, Never>?

    /// Await the historical-series build if one is running. No-op if the
    /// series is already populated or no refresh has been kicked.
    func awaitHistoricalSeries() async {
        if let t = historicalTask { await t.value }
    }

    /// Build the full daily ATL/CTL series by replaying the Banister
    /// EWMA forward over `lookbackDays` days. Runs off the main actor
    /// so the EWMA loop doesn't block UI.
    nonisolated private static func buildDailySeries(
        healthKit: HealthKitManager,
        reference: Date,
        lookbackDays: Int,
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]? = nil
    ) async -> [Date: DaySample] {
        let workouts = await mergedWorkouts(
            healthKit: healthKit, reference: reference, lookbackDays: lookbackDays,
            preloadedHealthKitWorkouts: preloadedHealthKitWorkouts
        )
        let settings = await MainActor.run { AppDependencies.current.app.settingsManager.settings }
        // Resolve resting HR EXACTLY like `calculateTrainingMetrics`
        // (Apple's measured RHR, falling back to the user setting). Using only
        // `settings.effectiveRestingHR` here while the live path uses
        // Apple's value makes the same day's HR-backed TRIMP differ between
        // `current` (dashboard/AI) and `dailySeries` (trajectory chart).
        let restingHR = await healthKit.fetchAppleRestingHR() ?? Double(settings.effectiveRestingHR)
        let dailyTrimp = bucketTrimpByDay(
            workouts: workouts, reference: reference, lookbackDays: lookbackDays,
            restingHR: restingHR, userMaxHR: Double(settings.effectiveMaxHR)
        )
        return replayEWMA(dailyTrimp)
    }

    /// The workout set the replay runs over.
    ///
    /// Same archive-merge as the live-metrics path. Without it the
    /// AI's day-by-day ATL/CTL queries (`training.load.acwr_history`, etc.) see
    /// HK-only data and disagree with the live cache.
    ///
    /// Accepts a preloaded workout list so `refresh()` can fetch
    /// HealthKit once and share it.
    ///
    /// `fromAppArchive` is nonisolated and uses
    /// `archive.retrieveLightweight` internally (skipping the `rrSeries`
    /// decode). An `await MainActor.run { ... }` here would force 100+ AES-GCM +
    /// JSON decodes onto the main thread on every historical-series rebuild.
    nonisolated private static func mergedWorkouts(
        healthKit: HealthKitManager,
        reference: Date,
        lookbackDays: Int,
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]?
    ) async -> [HealthKitManager.WorkoutSummary] {
        let healthKitWorkouts: [HealthKitManager.WorkoutSummary]
        if let preloaded = preloadedHealthKitWorkouts {
            healthKitWorkouts = preloaded
        } else {
            healthKitWorkouts = await healthKit.fetchWorkoutsExtended(days: lookbackDays, relativeTo: reference)
        }
        let archiveWorkouts = HealthKitManager.WorkoutSummary.fromAppArchive(
            archive: AppDependencies.current.storage.sessionArchive, days: lookbackDays, relativeTo: reference
        )
        // Archive (H10) authoritative; HealthKit only fills gaps — same single
        // precedence rule as the live-metrics path, so `dailySeries` (trajectory
        // chart / AI history) and `current` can't diverge on a workout's load.
        return HealthKitManager.mergeArchiveAuthoritative(
            archive: archiveWorkouts, healthKit: healthKitWorkouts
        )
    }

    /// Bucket TRIMP by local start-of-day across the lookback window.
    ///
    /// Uses `effectiveLoad` (power-aware), NOT `calculateTrimp`
    /// (HR-only Banister), to MATCH `buildDailyTrimp`
    /// (TrainingHealthQueries+Queries.swift). These two builders feed
    /// the SAME TrainingMetricsCache and must not drift: the PDF reads `cache.current`
    /// (built with effectiveLoad) while Load & Trajectory reads
    /// `cache.dailySeries` (built here), so building this one with calculateTrimp
    /// made power-backed sessions full-powerTSS in one and HR-downgraded in the
    /// other — CTL 55/ATL 68 (PDF) vs CTL 38.2/ATL 45.6 (Trajectory) the same morning.
    /// `effectiveLoad` falls back to calculateTrimp when no precomputed load
    /// exists, so HR-only workouts are unaffected.
    nonisolated private static func bucketTrimpByDay(
        workouts: [HealthKitManager.WorkoutSummary],
        reference: Date,
        lookbackDays: Int,
        restingHR: Double,
        userMaxHR: Double
    ) -> [Date: Double] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: reference)
        guard let startDate = calendar.date(byAdding: .day, value: -lookbackDays, to: endDate) else { return [:] }
        var dailyTrimp: [Date: Double] = [:]
        for dayOffset in 0 ... lookbackDays {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: startDate) {
                dailyTrimp[date] = 0
            }
        }
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.date)
            // Skip future-dated records (corrupt clock / bad import) — mirrors
            // buildDailyTrimp so the two builders stay consistent.
            guard day <= endDate else { continue }
            dailyTrimp[day, default: 0] += workout.effectiveLoad(restingHR: restingHR, maxHR: userMaxHR)
        }
        return clippedToDailyCeiling(dailyTrimp)
    }

    /// Per-day physiological ceiling — mirrors buildDailyTrimp. Final backstop
    /// against dedup-miss stacking or a single corrupt load; only ever clips
    /// clearly-broken values.
    nonisolated private static func clippedToDailyCeiling(_ dailyTrimp: [Date: Double]) -> [Date: Double] {
        var dailyTrimp = dailyTrimp
        for day in Array(dailyTrimp.keys) where (dailyTrimp[day] ?? 0) > TrainingConstants.TRIMP.maxDailyLoad {
            dailyTrimp[day] = TrainingConstants.TRIMP.maxDailyLoad
        }
        return dailyTrimp
    }

    /// Seeds from ZERO, matching `HealthKitManager.computeEWMA`.
    /// A beta tester saw TSB jump -15 → -7 between two dashboard views ten
    /// minutes apart: a seed mismatch between this historical
    /// replay (then seeded from `avgDailyTrimp`) and the live
    /// `calculateTrainingMetrics` path (which seeds from 0). LoadTrajectoryView
    /// reads `dailySeries`; the AI/dashboard hero reads `current` (set by the
    /// live path). Two seeds → two different "today" numbers → the user sees TSB
    /// swap depending on which rendered first. A 180-day window means a zero
    /// seed contributes <2% to today's CTL, so this matches Banister convention
    /// without bias.
    ///
    /// Exact e^(-1/τ) decay, matching HealthKitManager.computeEWMA
    /// and the TrainingPeaks/intervals.icu/GoldenCheetah reference form (the
    /// `1/τ` linear approximation is ~7% off and makes this historical
    /// series disagree with the live `current` value).
    ///
    /// PMC EWMA: CTL τ=42d, ATL τ=7d; X_today = load·(1−e^(−1/τ)) +
    /// X_yesterday·e^(−1/τ); TSB = CTL−ATL — Coggan Performance Manager Chart
    /// (TrainingPeaks); decay λ=1−e^(−1/τ) per GoldenCheetah/intervals.icu.
    nonisolated private static func replayEWMA(_ dailyTrimp: [Date: Double]) -> [Date: DaySample] {
        let atlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.acuteDays))
        let ctlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.chronicDays))
        var atl: Double = 0
        var ctl: Double = 0
        var series: [Date: DaySample] = [:]
        for date in dailyTrimp.keys.sorted() {
            let trimp = dailyTrimp[date] ?? 0
            atl = trimp * (1 - atlDecay) + atl * atlDecay
            ctl = trimp * (1 - ctlDecay) + ctl * ctlDecay
            series[date] = DaySample(date: date, atl: atl, ctl: ctl, trimp: trimp)
        }
        return series
    }

    // MARK: - Continuous-time projection

    /// Continuous-time ATL/CTL/TSB at `reference`. Anchors on
    /// yesterday's daily-series bucket and decays exponentially to
    /// `reference`, then adds today's workout contributions decayed
    /// from each workout's start time. The result evolves smoothly
    /// second-to-second; calling it twice ten minutes apart with the
    /// same underlying data returns values that differ ONLY by the
    /// natural decay over those ten minutes (essentially zero).
    ///
    /// Answers Terence's "if 24 hours after a walk vs
    /// 3 hours after a walk, ATL should be different" complaint.
    /// Discrete daily Banister steps can't express that — the day's
    /// bucket is constant. Continuous time decays correctly:
    ///   • 3 hours after a TRIMP-80 walk: ATL ≈ +11.4
    ///   • 24 hours after the same walk:  ATL ≈ +9.9
    ///   • 7 days after the same walk:    ATL ≈ +4.2
    /// vs the discrete model where the "today" bucket stays at the
    /// same value all day regardless of when the workout happened.
    func continuousProjection(
        at reference: Date = Date(),
        restingHR: Double,
        maxHR: Double
    ) -> (atl: Double, ctl: Double, tsb: Double)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: reference)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return nil }
        // Anchor on yesterday's bucket — the last "fully cooked" Banister value.
        // The buckets DON'T include today (today is mutable as workouts land),
        // so this is the right baseline. Elapsed time runs from start-of-today.
        let elapsedDays = reference.timeIntervalSince(today) / 86_400.0
        // τ centralized in TrainingConstants.EWMA. NB: this is the CONTINUOUS-time
        // model (dX/dt = −X/τ + impulse), so the rate is 1/τ — that's correct here
        // and is NOT the discrete-EWMA `1−e^(−1/τ)`; the two models are different
        // on purpose (see the doc comment above).
        let tauATL = Double(TrainingConstants.EWMA.acuteDays)
        let tauCTL = Double(TrainingConstants.EWMA.chronicDays)
        let today0 = todayImpulses(at: reference, restingHR: restingHR, maxHR: maxHR, tauATL: tauATL, tauCTL: tauCTL)
        let atl = (sampleOn(date: yesterday)?.atl ?? 0) * exp(-elapsedDays / tauATL) + today0.atl
        let ctl = (sampleOn(date: yesterday)?.ctl ?? 0) * exp(-elapsedDays / tauCTL) + today0.ctl
        return (atl, ctl, ctl - atl)
    }

    /// Today's workout impulses, each decayed since its own start time. Pulled
    /// off `current` (already filtered to today in `calculateTrainingMetrics`).
    private func todayImpulses(
        at reference: Date,
        restingHR: Double,
        maxHR: Double,
        tauATL: Double,
        tauCTL: Double
    ) -> (atl: Double, ctl: Double) {
        var atl = 0.0
        var ctl = 0.0
        for workout in current?.todayWorkouts ?? [] {
            let dtSec = reference.timeIntervalSince(workout.date)
            let trimp = workout.effectiveLoad(restingHR: restingHR, maxHR: maxHR)
            guard dtSec >= 0, trimp > 0 else { continue }
            let dtDays = dtSec / 86_400.0
            atl += trimp * (1.0 / tauATL) * exp(-dtDays / tauATL)
            ctl += trimp * (1.0 / tauCTL) * exp(-dtDays / tauCTL)
        }
        return (atl, ctl)
    }

    /// Invalidate the cache so the next `snapshot()` or `refresh()`
    /// triggers a re-read. Called when a workout is recorded / deleted,
    /// when HealthKit reports background updates, etc.
    func invalidate() {
        lastUpdated = nil
    }

    /// Force a full recompute from scratch, bypassing the incremental gate — the
    /// user-facing "Rebuild training load" safety valve (Settings ▸ Diagnostics)
    /// for when the cached series looks wrong (e.g. an external change the
    /// fingerprint couldn't see, or suspected drift). Clears every reuse marker
    /// so the next `refresh()` re-decodes all workouts and replays the EWMA.
    func rebuildFromScratch() async {
        lastWorkoutFingerprint = nil
        lastComputedDay = nil
        lastUpdated = nil
        refreshTask?.cancel()
        refreshTask = nil
        dailySeries = [:]
        await refresh(reference: Date(), forMorningReading: false)
    }

    private func needsRefresh(reference: Date) -> Bool {
        guard let updated = lastUpdated else { return true }
        return reference.timeIntervalSince(updated) > maxAgeSec
    }

    private func scheduleRefresh() {
        // Register the refresh task DIRECTLY — never via `refresh()`, whose
        // coalescing guard would find this very task and await itself (the
        // self-deadlock). `startRefreshTask` registers
        // `refreshTask` internally, so the `== nil` check still coalesces
        // duplicate schedule requests.
        guard refreshTask == nil, healthKit != nil else { return }
        startRefreshTask(reference: Date(), forMorningReading: false)
    }
}
