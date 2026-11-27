import Foundation

/// Re-scoring sessions that are already archived: a single Reanalyze, the
/// bulk passes a settings change or a repair runs over every night, the
/// one-shot session-data migrations, and the listeners that notice sleep or
/// training data arriving after a night was scored
/// (`+Listeners`).
///
/// The composition root (`AppDependencies.collection.sessionReanalysis`)
/// builds the one instance from explicit dependencies: the archive, HealthKit,
/// the scoring context (settings, baseline tracker, training load) and the
/// archive signal it shares with the collector, the training-metrics cache,
/// and a `ReanalysisService` whose callbacks reach only those. Nothing here
/// reaches the collector. A rescored night the review card may hold is
/// announced with `.reanalysisRewroteArchivedSession`, which the collector
/// observes; the window, scoring and archive writes are the service's.
@MainActor
final class SessionReanalysisCoordinator {
    /// The reanalysis engine: window selection, scoring and the archive
    /// writes. Manual windows, sleep-boundary edits and segment unlinks call
    /// it directly (`AppDependencies.collection.reanalysisService`).
    let service: ReanalysisService
    let archive: SessionArchive
    /// Sleep and vitals re-reads for a night whose Health data changed.
    let healthKit: any HealthKitServiceProtocol
    /// The sleep-data version a new Watch sleep sync bumps.
    let healthObservation: HealthObservation
    /// The nap read the one-shot nap repair makes (`SessionDataMigrations`).
    let sleepQueries: SleepHealthQueries
    let scoring: SessionScoringContext
    let archiveSignal: ArchiveSignal
    /// Resolved when a reanalysis first warms it, not at launch: building the
    /// cache reads and decrypts its snapshot from disk.
    private let trainingMetricsCache: @MainActor () -> TrainingMetricsCache

    /// Tokens for the block observers `startListening` registers, removed in
    /// `deinit`; block observers are not released with their owner.
    let notificationObservers = NotificationTokens()

    /// Sessions being reanalysed now. Pull-to-refresh, the sleep-delta
    /// rescore and the training-cache-heal rescore can ask for the same
    /// session within seconds; a second request gets the archived copy and
    /// queues one trailing pass (`pendingReanalyses`) instead of a competing run.
    var inFlightReanalyses: Set<UUID> = []
    /// Sessions asked for again while in flight: each gets one trailing pass.
    var pendingReanalyses: Set<UUID> = []

    /// Reentrancy guard for `autoRefreshTodaysSleepIfImproved`. Apple writes
    /// sleep in STAGES (each bumps `sleepDataVersion`), so without this the
    /// overlapping invocations each read the session before any sibling wrote,
    /// all detect the source upgrade, and all post a rescore → a redundant
    /// double reanalysis. `…Pending` records that a bump arrived mid-run so
    /// exactly one trailing pass runs against the freshly-written state.
    var isAutoRefreshingSleep = false
    var autoRefreshSleepPending = false

    init(
        service: ReanalysisService,
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        healthObservation: HealthObservation,
        sleepQueries: SleepHealthQueries,
        scoring: SessionScoringContext,
        archiveSignal: ArchiveSignal,
        trainingMetricsCache: @escaping @MainActor () -> TrainingMetricsCache
    ) {
        self.service = service
        self.archive = archive
        self.healthKit = healthKit
        self.healthObservation = healthObservation
        self.sleepQueries = sleepQueries
        self.scoring = scoring
        self.archiveSignal = archiveSignal
        self.trainingMetricsCache = trainingMetricsCache
    }

    deinit {
        notificationObservers.removeAll()
    }

    /// Install the saved-session listeners: the rescore request, the CloudKit
    /// snapshot backfill (which also drains what an earlier launch left
    /// queued), and HealthKit sleep arrival. The composition root calls it
    /// once, on the instance it builds at launch.
    func startListening() {
        installRescoreListener()
        installCloudKitSnapshotBackfillListener()
        observeHealthKitSleep()
    }

    // MARK: - Reanalysis

    /// Re-analyze a session with current algorithms. This updates the HRV
    /// analysis (window, metrics) but keeps the frozen trainingSnapshot on the
    /// session: reanalysis only changes HRV and sleep.
    ///
    /// Re-entrancy guard: a request for a session already being reanalysed
    /// returns the archived copy (`coalescedInFlightSession`) and queues one
    /// trailing pass over the freshly written session, since it may carry
    /// newer inputs (sleep that landed after the running pass read HealthKit),
    /// as `autoRefreshTodaysSleepIfImproved` does.
    ///
    /// `preserveManualWindow: true` is for an automatic pass: a night whose
    /// window the user picked (`windowUserAdjusted`, read from the archived
    /// copy) is left alone and nil is returned, as the bulk pass does.
    func reanalyzeSession(
        _ session: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery, preserveManualWindow: Bool = false
    ) async -> HRVSession? {
        if inFlightReanalyses.contains(session.id) {
            pendingReanalyses.insert(session.id)
            return await coalescedInFlightSession(session)
        }
        inFlightReanalyses.insert(session.id)
        defer { inFlightReanalyses.remove(session.id) }
        var result = await reanalyzeOnce(session, method: method, preserveManualWindow: preserveManualWindow)
        while pendingReanalyses.remove(session.id) != nil {
            debugLog("[Reanalyze] trailing pass for \(session.id.uuidString.prefix(8)) — requested while in flight")
            result = await reanalyzeOnce(session, method: method, preserveManualWindow: preserveManualWindow) ?? result
        }
        return result
    }

    /// One pass over the session as it is on disk now, with the training load
    /// as of the session's day held for the pass. A window picked by hand on
    /// that copy ends the pass first when `preserveManualWindow` is set.
    private func reanalyzeOnce(
        _ session: HRVSession, method: WindowSelectionMethod, preserveManualWindow: Bool
    ) async -> HRVSession? {
        let fullSession = await fullSessionFromDisk(session)
        if preserveManualWindow, fullSession.windowUserAdjusted == true {
            debugLog("[Reanalyze] \(session.id.uuidString.prefix(8)) keeps the window picked by hand, not reanalysed")
            return nil
        }
        let sessionDate = fullSession.endDate ?? fullSession.startDate
        let pastDay = await scoring.holdPastDayTrainingLoad(asOf: sessionDate)
        defer { if let pastDay { scoring.releasePastDayTrainingLoad(pastDay) } }
        await warmTrainingMetricsCacheIfCold()
        return await service.reanalyzeSession(fullSession, method: method)
    }

    /// The current session, not nil: at the call site a nil reads as "no RR
    /// data", so pull-to-refresh would report missing beats whenever a manual
    /// reanalyze coincided with the auto-rescore a fresh Apple-sleep sync
    /// starts. The in-flight run finishes and bumps the archive signal.
    private func coalescedInFlightSession(_ session: HRVSession) async -> HRVSession? {
        debugLog("[Reanalyze] suppressing duplicate run for \(session.id.uuidString.prefix(8)) — already in flight")
        let archive = self.archive
        let id = session.id
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(id, caller: "reanalyze.inFlightCoalesce") ?? session
        }.value
    }

    /// Callers hand over sessions loaded without their beats (the
    /// dashboard's `retrieveLightweightOrLog` copies), and
    /// `ReanalysisService.reanalyzeSession` refuses one with no rrSeries. The
    /// full session is re-read from disk, off the main actor, so that gate
    /// sees what is stored.
    private func fullSessionFromDisk(_ session: HRVSession) async -> HRVSession {
        let archive = self.archive
        let sessionId = session.id
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(sessionId, caller: "SessionReanalysis.reanalyzeSession") ?? session
        }.value
    }

    /// Fill the shared training-metrics cache before a reanalysis, only when
    /// it is cold or empty, and anchored at now (`refresh()`), the anchor the
    /// rest of the app uses for it. Anchoring it at the session's date would
    /// republish the cache with that morning's values and change the
    /// dashboard's TRAINING LOAD card every time the user tapped Reanalyze.
    private func warmTrainingMetricsCacheIfCold() async {
        let cache = trainingMetricsCache()
        let isCold = cache.current == nil
            || ((cache.current?.atl ?? 0) == 0 && (cache.current?.ctl ?? 0) == 0)
        guard isCold else { return }
        await cache.refresh()
    }

    // MARK: - Bulk passes

    /// Re-analyze all sessions with current algorithms. Each session runs
    /// through `reanalyzeSession`, so it gets the same past-day training load,
    /// warm cache and in-flight guard as a single Reanalyze. Returns
    /// (updated, skipped) where skipped counts sessions with manual window
    /// overrides.
    func reanalyzeAllSessions(
        from: Date? = nil, to: Date? = nil, progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (updated: Int, skipped: Int) {
        await service.reanalyzeAllSessions(
            sessions: archivedSessions, from: from, to: to,
            reanalyzeOne: { await self.reanalyzeSession($0) },
            progress: progress
        )
    }

    /// Reprocess sleep for every overnight session using current settings,
    /// so a changed sleep setting applies to past nights. Workouts, naps,
    /// quick readings and breathing sessions are skipped. For each night:
    ///   1. Re-runs the sleep pipeline (picking up the current augmentation setting)
    ///   2. Backfills a `sleepSnapshot` from HRV/RR data when none existed before
    ///   3. Recalculates the recovery score with the updated sleep data
    /// It never writes sleep to Apple Health.
    func retroApplySleepSettings(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int {
        await service.retroApplySleepSettings(sessions: archivedSessions, progress: progress)
    }

    /// Recompute training snapshots from HealthKit workout history for all
    /// archived sessions, for sessions whose ATL/CTL/TSB drifted from the
    /// frozen morning values.
    func repairTrainingSnapshots(
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> ReanalysisService.TrainingRepairResult {
        await service.repairTrainingSnapshots(sessions: archivedSessions, progress: progress)
    }

    /// Run the one-shot session-data repairs (`SessionDataMigrations`), each
    /// gated by its own UserDefaults flag.
    func runDeferredSessionMigrationsIfNeeded() async {
        await SessionDataMigrations(
            archive: archive,
            healthKit: healthKit,
            sleepQueries: sleepQueries,
            settingsManager: scoring.settingsManager,
            baselineTracker: scoring.baselineTracker,
            reanalysisService: service
        ).runAllIfNeeded()
    }

    /// Every archived session, newest first, decoded one at a time as a
    /// pass reaches it.
    private var archivedSessions: ArchivedSessions {
        ArchivedSessions(archive: archive, caller: "SessionReanalysis")
    }
}

// MARK: - Rewritten-session announcement

extension Notification.Name {
    /// Posted on the main actor by `SessionReanalysisCoordinator` after it
    /// rewrote a saved session; the object is an `ArchivedSessionRewrite`.
    /// `RRCollector.installArchivedCopyListener` carries it onto the review
    /// card when the card holds that night.
    static let reanalysisRewroteArchivedSession = Notification.Name("SessionReanalysis.rewroteArchivedSession")
}

/// A saved session as reanalysis wrote it.
struct ArchivedSessionRewrite: Sendable {
    let session: HRVSession
    /// True for a rescore, which reaches the review card only while a night
    /// awaits acceptance; false for a sleep refresh.
    let onlyWhileAwaitingAcceptance: Bool
}
