import CryptoKit
import Foundation

/// Shared store of current training metrics (CTL / ATL / TSB / ACWR).
///
/// The dashboard's `calculateTrainingMetrics` path and the AI's
/// `training.load.*` tools both read from here so they can never disagree
/// with each other. The AI tools do not read the
/// `HRVSession.trainingSnapshot` frozen at session-accept time for current
/// load, because a frozen snapshot does not pick up later scoring changes.
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
    /// When the last compute was published — the dirty flag too:
    /// `invalidate()` clears it to force the next rebuild.
    private(set) var lastUpdated: Date?
    /// When `current` was computed (restored from disk on launch). Unlike
    /// `lastUpdated`, an invalidation never clears it, so it is what an
    /// "as of" stamp reads (`TrainingLoadRegistry`).
    private(set) var computedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Whether a historical-series build has started and not yet landed.
    /// `needsRebuild` counts it as a result on its way, so refreshes during a
    /// cold build don't keep restarting it.
    @ObservationIgnored private var historicalBuildPending = false
    /// The latest disk write, which the next one waits for, so snapshots land
    /// in the order they were taken.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Day-indexed training-load series covering the last 400 days.
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

    /// How far back the historical series reaches. 400 days covers
    /// year-over-year queries with some slack. The live value replays its
    /// own `TrainingHealthQueries.ewmaLookbackDays` (180).
    private let lookbackDays: Int = 400

    /// Extra days the historical replay runs before the oldest kept day. The
    /// EWMA starts from zero, and 180 days (~4.3 CTL time constants) leaves
    /// under 2% of that zero seed in the oldest kept CTL; without it a
    /// year-ago CTL had only ~35 days of history behind it and read about
    /// half its real value.
    private let replayWarmUpDays: Int = 180

    /// Where the archived workouts are read from: their fingerprint and the
    /// series replay. The app's cache resolves `AppDependencies.current` at
    /// each read; a test passes its own archive.
    private let archiveSource: @Sendable () -> SessionArchive
    /// The user's settings, read for the load settings in force. The app's
    /// cache reads the settings manager of `AppDependencies.current` at each
    /// read; a test passes its own.
    private let settingsSource: @MainActor () -> UserSettings
    /// The cold-start snapshot file, or nil to keep nothing on disk.
    private let persistenceURL: URL?
    /// Seals the snapshot for the disk and opens it again.
    private let seal: JSONFileSeal

    /// A cache over `archive` and `settings`, persisted at `persistenceURL`
    /// sealed with `seal`. The defaults are the app's: the archive and
    /// settings of `AppDependencies.current`, `TrainingMetricsCache.json` in
    /// Application Support, the app's key. A test builds one entirely from
    /// its own, so it never reads or writes the app's stores.
    init(
        archive: @escaping @Sendable () -> SessionArchive = { AppDependencies.current.storage.sessionArchive },
        settings: @escaping @MainActor () -> UserSettings = { AppDependencies.current.app.settingsManager.settings },
        persistenceURL: URL? = TrainingMetricsCache.defaultPersistenceURL,
        seal: JSONFileSeal = .app
    ) {
        archiveSource = archive
        settingsSource = settings
        self.persistenceURL = persistenceURL
        self.seal = seal
        // Restore last-known metrics from disk FIRST so the dashboard
        // and AI see numbers immediately on cold launch (reconciled by refresh()).
        loadFromDisk()
        observers.add(Self.makeArchiveObserver { [weak self] in
            self?.invalidateIfWorkoutsChanged()
        })
    }

    /// Invalidate on archive writes so a just-finished workout's
    /// load reaches the dashboard AND the AI immediately (both read
    /// `dailySeries[today]`), instead of lagging behind `current`.
    ///
    /// But ONLY when the archive change actually touched a
    /// WORKOUT. Training load = f(workouts, resting/max HR, sex, FTP, day); an
    /// HRV overnight write (rescore, sleep-snapshot attach, CloudKit pull)
    /// can't change it. Invalidating on every write made the launch/morning
    /// storm of HRV writes each force a full HealthKit refetch + Banister
    /// replay. `invalidateIfWorkoutsChanged` gates on a cheap in-memory
    /// fingerprint of the workout entries so a real workout add/delete/edit
    /// still invalidates instantly while the HRV-write flood is ignored.
    /// Setting changes are caught by `needsRebuild` (`LoadSettings`), and
    /// changes only HealthKit can show by `unchangedMaxAgeSec`.
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

    /// Fingerprint of the archived workouts the published result reflects.
    /// Set by `publishCurrent`, and by `invalidateIfWorkoutsChanged` together
    /// with clearing `lastUpdated`.
    private var lastWorkoutFingerprint: String?
    /// Calendar day of the last full compute — a new day needs a fresh EWMA step
    /// even when the workout set is unchanged.
    private var lastComputedDay: Date?
    /// The load settings the published result was computed with.
    private var lastLoadSettings: LoadSettings?
    /// What the day-by-day series was last built for. Past days are a pure
    /// function of these, so the replay is skipped while they all hold.
    private var lastHistoricalKey: HistoricalKey?

    /// Cheap fingerprint of the archived WORKOUT set: each workout entry's id +
    /// `fileHash`. `fileHash` changes whenever that session file is rewritten,
    /// so this catches adds, deletes, AND metadata/load edits — while staying
    /// blind to the far-more-frequent HRV overnight writes that don't touch
    /// training load. Reads the in-memory index only (no disk, no HealthKit).
    ///
    /// A SHA-256 over the entries in a fixed order, not `Hasher`: `Hasher` is
    /// seeded per process, and this value is persisted, so a `Hasher` value
    /// restored on the next launch never matched and every cold launch paid
    /// the full rebuild the persistence exists to skip.
    private func workoutFingerprint() -> String {
        var digest = SHA256()
        let workouts = archiveSource().entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.sessionId.uuidString < $1.sessionId.uuidString }
        for entry in workouts {
            digest.update(data: Data("\(entry.sessionId.uuidString):\(entry.fileHash)\n".utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
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
    /// `loadFromDisk` keeps the SAVED timestamp, fingerprint and settings, so
    /// `needsRebuild` reconciles it on launch — a changed workout set, a new
    /// calendar day, changed load settings or an age past
    /// `unchangedMaxAgeSec` forces a fresh compute, so a stale value can never
    /// become authoritative.
    struct PersistedCache: Codable {
        let current: TrainingMetrics?
        let dailySeries: [Date: DaySample]
        let fingerprint: String
        let computedDay: Date?
        let savedAt: Date
        /// Nil in caches saved before settings were recorded; that reads as a
        /// settings change, so the first refresh after the update recomputes.
        let loadSettings: LoadSettings?
    }

    /// `TrainingMetricsCache.json` in Application Support, the app's
    /// snapshot file.
    nonisolated static let defaultPersistenceURL: URL? = {
        let fm = FileManager.default
        guard let dir = attempt("trainingMetricsCache.supportDir", { try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }) else { return nil }
        return dir.appendingPathComponent("TrainingMetricsCache.json")
    }()

    /// Persist the current cache state to disk, off the main actor
    /// (`writeSnapshot`). Best-effort: a failed write, a seal with no key
    /// reachable among them, leaves the previous file and just means the next
    /// cold launch rebuilds. Each write waits for the one before it, so an
    /// older snapshot (the publish's, with the previous series) can never
    /// land after a newer one (the series adoption's). Nothing is written
    /// before the first compute.
    private func persistToDisk() {
        guard let url = persistenceURL, let computedAt else { return }
        let snapshot = PersistedCache(
            current: current,
            dailySeries: dailySeries,
            fingerprint: lastWorkoutFingerprint ?? "",
            computedDay: lastComputedDay,
            savedAt: computedAt,
            loadSettings: lastLoadSettings
        )
        let previous = persistTask
        let seal = self.seal
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try Self.writeSnapshot(snapshot, to: url, seal: seal)
            } catch {
                debugLog("[TrainingMetricsCache] persist failed (previous file kept): \(error)", level: .warning)
            }
        }
    }

    /// Seals `snapshot` with `seal` and writes it atomically to `url` under
    /// `.completeFileProtectionUntilFirstUserAuthentication`, so a refresh
    /// while the phone is locked (after the first unlock of the boot) still
    /// lands. Throws, writing nothing, when it cannot be encoded, sealed or
    /// written; the training load is never written in the clear.
    nonisolated static func writeSnapshot(_ snapshot: PersistedCache, to url: URL, seal: JSONFileSeal = .app) throws {
        let sealed = try seal.sealJSON(snapshot, with: JSONEncoder())
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The snapshot stored at `url`, opened with `seal`: sealed, or plain
    /// JSON from a build that did not seal the file (replaced sealed by the
    /// next write). Nil when there is no file; throws when it cannot be read,
    /// opened (the key locked among them) or decoded.
    nonisolated static func readSnapshot(at url: URL, seal: JSONFileSeal = .app) throws -> PersistedCache? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try seal.openJSON(PersistedCache.self, from: Data(contentsOf: url), with: JSONDecoder())
    }

    /// Load the persisted snapshot on launch so the dashboard/AI see last-known
    /// numbers instantly. No file, or one that cannot be read, opened or
    /// decoded (logged) → nothing restored → the normal cold rebuild, whose
    /// first write replaces the file. Deliberately keeps the SAVED
    /// `lastUpdated` (not "now") so `needsRebuild` still ages it.
    private func loadFromDisk() {
        guard let url = persistenceURL,
              let snapshot = attempt("trainingMetricsCache.load", { try Self.readSnapshot(at: url, seal: seal) }) ?? nil
        else { return }
        current = snapshot.current
        dailySeries = snapshot.dailySeries
        lastWorkoutFingerprint = snapshot.fingerprint
        lastComputedDay = snapshot.computedDay
        lastLoadSettings = snapshot.loadSettings
        lastUpdated = snapshot.savedAt
        computedAt = snapshot.savedAt
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
    /// kicks off a background refresh when `needsRebuild` says the result
    /// may be out of date. Never blocks.
    func snapshot(reference: Date = Date()) -> TrainingMetrics? {
        if needsRebuild(reference: reference) {
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
    /// onto a single in-flight task: a caller that joins one gets that
    /// task's result, computed for ITS `reference` and `forMorningReading`,
    /// not the caller's. Every caller passes today and `false`, so the two
    /// agree in practice.
    ///
    /// Also repopulates `dailySeries` so historical-date queries have a
    /// day-by-day EWMA to look up against. The replay is cheap in-process;
    /// the bottleneck is the HealthKit fetch, which both share.
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

    /// Whether anything can have changed since the cached result
    /// (`TrainingMetricsCache.needsRebuild(lastUpdated:…)` holds the rule).
    ///
    /// AssistantViewModel.dispatch awaits `refresh()` on every send, so a
    /// result that cannot have changed is reused rather than refetched. A
    /// result is missing when the historical series hasn't landed yet even
    /// if `current` is warm, so the Fitness inline trend never reads an
    /// empty series.
    ///
    /// A cold launch restores `lastUpdated` from disk, so the persisted
    /// numbers show at once and are recomputed when they are older than
    /// `unchangedMaxAgeSec`.
    ///
    /// `invalidate()` (fired by a workout add/edit/delete) clears
    /// `lastUpdated` as its dirty flag while leaving the fingerprint updated,
    /// so the nil check forces the rebuild in that case.
    ///
    /// Internal rather than private so a test can check it against the
    /// archive and settings it built the cache from.
    func needsRebuild(reference: Date) -> Bool {
        let refDay = Calendar.current.startOfDay(for: reference)
        return Self.needsRebuild(
            lastUpdated: lastUpdated,
            hasResult: current != nil && (!dailySeries.isEmpty || historicalBuildPending),
            observedChange: workoutFingerprint() != lastWorkoutFingerprint,
            settingsChanged: currentLoadSettings() != lastLoadSettings,
            dayChanged: refDay != lastComputedDay,
            reference: reference
        )
    }

    /// The load settings in force now.
    private func currentLoadSettings() -> LoadSettings {
        LoadSettings(settingsSource())
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
    ///
    /// Publishes `current` as soon as the live metrics are in hand, THEN kick the
    /// 400-day historical series off in a detached task. Awaiting both
    /// before publishing `current` makes the dashboard's training fetch wait
    /// on work it doesn't need for the today-view, which is what fires the
    /// "Live data fetch timed out after 15 s" warning. AI fact-catalog
    /// callers that need the historical series await
    /// `awaitHistoricalSeries()` separately.
    ///
    /// One HealthKit fetch covers both: the series' replay window, which the
    /// live path trims to its own. The heart-rate anchors are resolved once
    /// and handed to both, so a day's load is the same number in `current`
    /// and in `dailySeries`.
    ///
    /// A task cancelled by `rebuildFromScratch` publishes nothing, so it can't
    /// overwrite the rebuild's result or clear the rebuild's registration.
    /// A task that finds HealthKit gone releases its registration, so a
    /// later refresh can start rather than await this finished task forever.
    @discardableResult
    private func startRefreshTask(reference: Date, forMorningReading: Bool) -> Task<Void, Never> {
        let settings = currentLoadSettings()
        let task = Task { [weak self] in
            guard let self else { return }
            guard let hk = self.healthKit else { return self.releaseRefreshTaskUnlessCancelled() }
            await self.recompute(healthKit: hk, reference: reference, forMorningReading: forMorningReading, settings: settings)
        }
        refreshTask = task
        return task
    }

    /// Clears `refreshTask` from inside the running refresh task, unless that
    /// task was cancelled (`rebuildFromScratch` has registered its own).
    private func releaseRefreshTaskUnlessCancelled() {
        guard !Task.isCancelled else { return }
        refreshTask = nil
    }

    /// The refresh task's work: fetch, compute and publish `current`, then
    /// start the series build if its inputs changed.
    ///
    /// A HealthKit workout query that failed or timed out (a locked store, a
    /// wedged daemon) publishes nothing: computed without the Watch and
    /// Strava workouts, the load would collapse, be stamped fresh, persisted
    /// and replayed into the series. The published result and the series
    /// stay as they were, still due for a rebuild, and the registration is
    /// released so the next refresh asks HealthKit again.
    private func recompute(
        healthKit hk: HealthKitManager, reference: Date, forMorningReading: Bool, settings: LoadSettings
    ) async {
        // The archived workouts this compute starts from; a workout archived
        // while it awaits HealthKit is not in it.
        let startFingerprint = workoutFingerprint()
        guard let hkWorkouts = await hk.fetchWorkoutsExtendedIfAnswered(
            days: lookbackDays + replayWarmUpDays, relativeTo: reference
        ) else {
            debugLog("[TrainingMetricsCache] HealthKit workout query failed or timed out — the published load is kept and the next refresh asks again", level: .warning)
            return releaseRefreshTaskUnlessCancelled()
        }
        let anchors = await hk.trainingHeartRateAnchors()
        let metrics = await hk.calculateTrainingMetrics(
            restingHR: anchors.restingHR, userMaxHR: anchors.maxHR, forMorningReading: forMorningReading,
            relativeTo: reference, preloadedHealthKitWorkouts: hkWorkouts
        )
        guard !Task.isCancelled else { return }
        current = metrics
        publishCurrent(reference: reference, settings: settings, workoutFingerprint: startFingerprint)
        let key = historicalKey(reference: reference, healthKitWorkouts: hkWorkouts, settings: settings, anchors: anchors)
        startHistoricalRebuildIfNeeded(reference: reference, workouts: hkWorkouts, key: key)
    }

    /// Stamps what this compute reflects — so the incremental gate can reuse it
    /// until the workouts or the day actually change — and persists it so the
    /// next cold launch shows it instantly. The fingerprint stamped is the one
    /// the compute started from; when the archived workouts changed while it
    /// ran, the result is published but left dirty (`lastUpdated` nil), so the
    /// next refresh recomputes with the new workout instead of reusing this.
    private func publishCurrent(reference: Date, settings: LoadSettings, workoutFingerprint startFingerprint: String) {
        let now = Date()
        computedAt = now
        lastUpdated = startFingerprint == workoutFingerprint() ? now : nil
        lastWorkoutFingerprint = startFingerprint
        lastComputedDay = Calendar.current.startOfDay(for: reference)
        lastLoadSettings = settings
        refreshTask = nil
        persistToDisk()
    }

    /// What a series build started now would reflect.
    private func historicalKey(
        reference: Date,
        healthKitWorkouts: [HealthKitManager.WorkoutSummary],
        settings: LoadSettings,
        anchors: TrainingLoadSeries.HeartRateAnchors
    ) -> HistoricalKey {
        HistoricalKey(
            archive: workoutFingerprint(), healthKit: Self.healthKitFingerprint(healthKitWorkouts),
            day: Calendar.current.startOfDay(for: reference), settings: settings, anchors: anchors
        )
    }

    /// Historical 400-day series — rebuilt when anything in its
    /// `HistoricalKey` changed (archived or HealthKit workouts, the day, the
    /// load settings, the heart-rate anchors) or it was never built. Refreshes
    /// that change none of them reuse it: past points are a pure function of
    /// those. Fire-and-forget; AI callers await it via
    /// `awaitHistoricalSeries()`.
    ///
    /// Each build is tagged with its key, and a result whose key is no longer
    /// the latest (a newer build started meanwhile) is discarded, so an older
    /// build finishing last can't stick.
    ///
    /// The replay runs `replayWarmUpDays` further back than it keeps.
    private func startHistoricalRebuildIfNeeded(
        reference: Date,
        workouts: [HealthKitManager.WorkoutSummary],
        key: HistoricalKey
    ) {
        guard key != lastHistoricalKey || (dailySeries.isEmpty && !historicalBuildPending) else { return }
        lastHistoricalKey = key
        historicalBuildPending = true
        let (keptDays, replayDays) = (lookbackDays, lookbackDays + replayWarmUpDays)
        let archive = archiveSource()
        historicalTask = Task.detached(priority: .utility) {
            let series = Self.buildDailySeries(
                reference: reference, lookbackDays: replayDays, archive: archive,
                healthKitWorkouts: workouts, anchors: key.anchors
            )
            let kept = Self.lastDays(keptDays, of: series, reference: reference)
            await self.adoptHistoricalSeries(kept, key: key)
        }
    }

    /// Lands a finished historical build unless a newer one has started since.
    private func adoptHistoricalSeries(_ series: [Date: DaySample], key: HistoricalKey) {
        guard key == lastHistoricalKey else { return }
        historicalBuildPending = false
        dailySeries = series
        // Persist again now the 400-day series has landed.
        persistToDisk()
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

    /// The samples from the `days` days up to `reference`; the warm-up days
    /// before them are dropped once they have done their job.
    nonisolated private static func lastDays(_ days: Int, of series: [Date: DaySample], reference: Date) -> [Date: DaySample] {
        let calendar = Calendar.current
        guard let oldest = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: reference)) else {
            return series
        }
        return series.filter { $0.key >= oldest }
    }

    /// Build the full daily ATL/CTL series by replaying the Banister
    /// EWMA forward over `lookbackDays` days, with the same day-load builder
    /// and EWMA step as the live value (`TrainingLoadSeries`) and the anchors
    /// the live value was computed with. Runs off the main actor so the
    /// replay doesn't block UI.
    nonisolated private static func buildDailySeries(
        reference: Date,
        lookbackDays: Int,
        archive: SessionArchive,
        healthKitWorkouts: [HealthKitManager.WorkoutSummary],
        anchors: TrainingLoadSeries.HeartRateAnchors
    ) -> [Date: DaySample] {
        let workouts = mergedWorkouts(
            reference: reference, lookbackDays: lookbackDays, archive: archive, healthKitWorkouts: healthKitWorkouts
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let firstDay = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let daily = TrainingLoadSeries.dailyLoad(
            workouts: workouts, firstDay: firstDay, lastDay: today, anchors: anchors, calendar: calendar
        )
        return TrainingLoadSeries.replay(daily).reduce(into: [Date: DaySample]()) { series, entry in
            series[entry.key] = DaySample(date: entry.key, atl: entry.value.atl, ctl: entry.value.ctl, trimp: daily[entry.key] ?? 0)
        }
    }

    /// The workout set the replay runs over: the same archive-authoritative
    /// merge as the live-metrics path (`mergeArchiveAuthoritative`), so
    /// `dailySeries` (trajectory chart / AI history) and `current` can't
    /// diverge on a workout's load.
    ///
    /// `fromAppArchive` is nonisolated and uses
    /// `archive.retrieveLightweight` internally (skipping the `rrSeries`
    /// decode), so this runs off the main thread. `archive` is the cache's
    /// archive, resolved on the main actor when the build started.
    nonisolated private static func mergedWorkouts(
        reference: Date,
        lookbackDays: Int,
        archive: SessionArchive,
        healthKitWorkouts: [HealthKitManager.WorkoutSummary]
    ) -> [HealthKitManager.WorkoutSummary] {
        let archiveWorkouts = HealthKitManager.WorkoutSummary.fromAppArchive(
            archive: archive, days: lookbackDays, relativeTo: reference
        )
        return HealthKitManager.mergeArchiveAuthoritative(archive: archiveWorkouts, healthKit: healthKitWorkouts)
    }

    /// Invalidate the cache so the next `snapshot()` or `refresh()`
    /// triggers a re-read. Its one caller is `invalidateIfWorkoutsChanged`,
    /// on an archive write that changed the archived workouts. No HealthKit
    /// observer calls it: another app's workout reaches the cache when the
    /// result ages past `unchangedMaxAgeSec`.
    func invalidate() {
        lastUpdated = nil
    }

    /// Delete All My Data: drops the published metrics and the day-by-day
    /// series, and every marker that would let a refresh reuse them. A refresh
    /// or series build in flight is cancelled and its result discarded, so
    /// neither publishes or persists the erased figures. The purge's sweep
    /// removed the file; a removal is queued behind any write still pending,
    /// so a write that lands after the sweep is removed again.
    func forgetAfterPurge() {
        refreshTask?.cancel()
        refreshTask = nil
        historicalTask?.cancel()
        historicalTask = nil
        historicalBuildPending = false
        lastHistoricalKey = nil
        current = nil
        dailySeries = [:]
        lastUpdated = nil
        computedAt = nil
        lastWorkoutFingerprint = nil
        lastComputedDay = nil
        lastLoadSettings = nil
        guard let url = persistenceURL else { return }
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            attempt("trainingMetricsCache.remove") { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Force a full recompute from scratch, bypassing the incremental gate — the
    /// user-facing "Rebuild training load" safety valve (Settings ▸ Diagnostics)
    /// for when the cached series looks wrong (e.g. an external change the
    /// fingerprint couldn't see, or suspected drift). Clears every reuse marker
    /// so the next `refresh()` re-decodes all workouts and replays the EWMA.
    func rebuildFromScratch() async {
        lastWorkoutFingerprint = nil
        lastComputedDay = nil
        lastLoadSettings = nil
        lastUpdated = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastHistoricalKey = nil
        historicalBuildPending = false
        dailySeries = [:]
        await refresh(reference: Date(), forMorningReading: false)
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
