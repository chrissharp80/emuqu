import Foundation
import os

/// RR interval collector - orchestrates Polar device recording and analysis.
///
/// The collector holds the dependencies and the shared state; most of the
/// behaviour lives on coordinators it builds on demand (`control` below, the
/// rest in +Coordinators). Each file listed extends the coordinator before it:
///   control (CollectorSessionControl) – +Bindings, +Streaming, +PauseResume,
///     +Discard
///   overnightStreaming (OvernightStreamingCoordinator) – +OvernightStreaming,
///     +OvernightArming
///   deviceRecording (DeviceRecordingSession) – +DeviceRecording
///   morning (MorningSessionPipeline) – +MorningProcessing, +OvernightGather,
///     +Analysis, +Acceptance
///   recovery (SessionRecoveryCoordinator) – +Recovery, +BackupRecovery,
///     +MergeRepair
///   import (SessionImport) – +Import
/// Extensions on the collector itself: +Lifecycle (persisted recording
/// state, data rescue, emergency backup), +RecordingCore, +Session,
/// +PriorSessions, and the collector-side halves of +Acceptance, +Streaming
/// and +Import.
///
/// Rescoring saved sessions is not the collector's: the composition root
/// owns `SessionReanalysisCoordinator`, built from the same scoring context,
/// baseline tracker and archive signal the collector is given. The collector
/// only takes the archived copy of a rescored night onto its review card
/// (`installArchivedCopyListener`).
@Observable
@MainActor
final class RRCollector {

    // MARK: - Morning Processing Status

    /// Drives the morning processing card in RecordView.
    enum MorningProcessingStatus: Equatable {
        case saving(beats: Int)
        case fetchingDevice(streamingBeats: Int)
        case waitingForSleep(beats: Int, attempt: Int)
        case analyzing(beats: Int, streamedBeats: Int, deviceBeats: Int?, source: String)
        case complete(beats: Int, streamedBeats: Int, deviceBeats: Int?, source: String)
    }

    /// The night being recorded: its strap backup, its ending, its arming loop.
    let overnightRun = OvernightRunState()

    /// The recording and paused-night markers a relaunch recovers from.
    var recordingStore: RecordingStateStore {
        RecordingStateStore(sessionState: sessionState, overnightRun: overnightRun)
    }

    // Archive update trigger — lives on a dedicated `ArchiveSignal` object so
    // views that only care about archive changes don't observe the full
    // collector (whose state also changes on BLE + streaming +
    // recording updates).
    //
    // Accessor so non-SwiftUI internals and tests can read
    // the value via `collector.archiveVersion`. SwiftUI views read
    // `archiveSignal` directly from the environment.
    var archiveVersion: Int { archiveSignal.version }

    // Proxied PolarManager state lives on a dedicated `DeviceStatus` object
    // so views that only care about BLE connection / battery / device
    // recording state don't re-render on every archive / streaming /
    // morning-processing property the collector also publishes.
    //
    // Writers: `CollectorBindings.setupBindings()` pushes PolarManager
    // updates into `deviceStatus`. SwiftUI views read `deviceStatus`
    // directly from the environment.

    // MARK: - Internal State (accessed by extension files)

    /// Tokens for the block-based NotificationCenter observers the
    /// collector registers (app lifecycle in `+Lifecycle`, the archived-copy
    /// listener in `+Acceptance`). Stored so `deinit` can remove them;
    /// discarding the `addObserver` return value leaks the observer (and the
    /// captured `self`) in tests/previews that build many collectors. Block
    /// observers are not released with the collector — they must be
    /// removed explicitly.
    @ObservationIgnored let notificationObservers = NotificationTokens()
    /// Rebuilds the baseline when the archive changes by a path that does not
    /// update it (`BaselineArchiveSync`); observing from `setupBindings`.
    @ObservationIgnored private(set) lazy var baselineArchiveSync = BaselineArchiveSync(
        archive: archive, baseline: baselineTracker,
        rebuild: { [weak rebuilder = baselineRebuild] in rebuilder?.rebuildFromArchive() }
    )
    var lastEmergencyFlush: Date?

    /// Process → analyse → accept. Built first: every other coordinator
    /// calls it, and it calls none of them.
    @ObservationIgnored private(set) lazy var morning: MorningSessionPipeline = MorningSessionPipeline(
        acceptanceService: acceptanceService, analysisPipeline: analysisPipeline, archive: archive, archiveSignal: archiveSignal,
        baselineRebuild: baselineRebuild, cloudSyncManager: cloudSyncManager, deviceStatus: deviceStatus, healthWrites: healthKit.writes, trainingQueries: healthKit.training,
        morningCoordination: morningCoordination, morningProcessingService: morningProcessingService,
        strapLink: polarManager.linkState, strapBattery: polarManager.battery,
        rawBackup: rawBackup, recordingStore: recordingStore, scoring: scoring, sessionState: sessionState,
        settingsManager: settingsManager, sleepBoundaryResolver: sleepBoundaryResolver, streamingLifecycle: streamingLifecycle
    )

    /// Overnight capture in streaming mode, and the gather that ends it.
    @ObservationIgnored private(set) lazy var overnightStreaming: OvernightStreamingCoordinator = OvernightStreamingCoordinator(
        archive: archive, baselineTracker: baselineTracker, cloudSyncManager: cloudSyncManager, healthWrites: healthKit.writes, sleepQueries: healthKit.sleepQueries, vitalsQueries: healthKit.vitals,
        morningCoordination: morningCoordination, overnightRun: overnightRun,
        strapLinkControl: polarManager.link, strapStream: polarManager.stream,
        strapRecorder: polarManager.recording,
        strapDiscovery: polarManager.discovery, strapBattery: polarManager.battery, rawBackup: rawBackup,
        recordingStore: recordingStore, services: services, sessionState: sessionState, settingsManager: settingsManager,
        streamingLifecycle: streamingLifecycle, morning: morning
    )

    /// Capture to the strap's own memory, and its download.
    @ObservationIgnored private(set) lazy var deviceRecording: DeviceRecordingSession = DeviceRecordingSession(
        archive: archive, archiveSignal: archiveSignal, artifactDetector: artifactDetector, baselineTracker: baselineTracker,
        sleepQueries: healthKit.sleepQueries, strapLink: polarManager.linkState, strapRecording: polarManager.deviceRecording,
        strapRecorder: polarManager.recording, rawBackup: rawBackup, reconciliation: reconciliation,
        recordingStore: recordingStore, scoring: scoring, sessionState: sessionState, strapGuards: strapGuards,
        streamingLifecycle: streamingLifecycle, verification: verification, windowSelector: windowSelector, morning: morning
    )

    /// Recovery of interrupted, lost and trashed recordings.
    @ObservationIgnored private(set) lazy var recovery: SessionRecoveryCoordinator = SessionRecoveryCoordinator(
        archive: archive, archiveSignal: archiveSignal, artifactDetector: artifactDetector, baselineTracker: baselineTracker,
        cloudSyncManager: cloudSyncManager, healthWrites: healthKit.writes, morningCoordination: morningCoordination,
        overnightRun: overnightRun, strapRecorder: polarManager.recording, rawBackup: rawBackup, recordingStore: recordingStore,
        scoring: scoring, services: services, sessionState: sessionState, settingsManager: settingsManager,
        strapGuards: strapGuards, streamingLifecycle: streamingLifecycle, windowSelector: windowSelector,
        deviceRecording: deviceRecording, morning: morning
    )

    /// Streaming sessions, pause/resume, and the view bindings.
    @ObservationIgnored private(set) lazy var control: CollectorSessionControl = CollectorSessionControl(
        archive: archive, archiveSignal: archiveSignal, baselineTracker: baselineTracker, cloudSyncManager: cloudSyncManager,
        deviceStatus: deviceStatus, morningCoordination: morningCoordination, overnightRun: overnightRun,
        strapLink: polarManager.linkState, strapStream: polarManager.stream, strapRecorder: polarManager.recording,
        strapBattery: polarManager.battery, rawBackup: rawBackup, recordingStore: recordingStore, services: services,
        sessionState: sessionState, settingsManager: settingsManager, strapGuards: strapGuards,
        streamingLifecycle: streamingLifecycle, morning: morning, overnightStreaming: overnightStreaming
    )

    /// The strap, Health and iCloud state republished for the views.
    @ObservationIgnored private(set) lazy var bindings: CollectorBindings = CollectorBindings(
        archive: archive, archiveSignal: archiveSignal, baselineArchiveSync: baselineArchiveSync, baselineRebuild: baselineRebuild,
        baselineTracker: baselineTracker, cloudSyncManager: cloudSyncManager, control: control, deviceStatus: deviceStatus,
        healthObservation: healthKit.observation, liveHRVMirror: liveHRVMirror, morningCoordination: morningCoordination,
        notificationObservers: notificationObservers, overnightRun: overnightRun,
        strapRecorder: polarManager.recording, strapStream: polarManager.stream, recovery: recovery,
        services: services, sessionState: sessionState, strapGuards: strapGuards, streamingLifecycle: streamingLifecycle
    )

    /// The few-minute streamed reading.
    @ObservationIgnored private(set) lazy var quickReading: QuickReadingSession = QuickReadingSession(
        analysisPipeline: analysisPipeline, archive: archive, archiveSignal: archiveSignal, artifactDetector: artifactDetector,
        baselineTracker: baselineTracker, cloudSyncManager: cloudSyncManager, deviceStatus: deviceStatus, trainingQueries: healthKit.training,
        overnightStreaming: overnightStreaming,
        strapStream: polarManager.stream, strapRecorder: polarManager.recording, strapBattery: polarManager.battery,
        rawBackup: rawBackup, recordingStore: recordingStore,
        scoring: scoring, sessionState: sessionState, settingsManager: settingsManager, strapGuards: strapGuards,
        streamingLifecycle: streamingLifecycle, streamingVerification: streamingVerification
    )

    // MARK: - Dependencies

    let polarManager: PolarManager
    let healthKit: HealthKitManager
    let archive: SessionArchive
    let rawBackup: RawRRBackup
    let artifactDetector: ArtifactDetector
    let windowSelector: WindowSelector
    let baselineTracker: BaselineTracker
    let reconciliation: ReconciliationManager
    let analysisPipeline: HRVAnalysisPipeline
    let sleepBoundaryResolver: SleepBoundaryResolver
    let settingsManager: SettingsManager
    /// Rebuilds the baseline from the archive at boot, after a CloudKit pull
    /// and after a night the baseline holds leaves the archive.
    let baselineRebuild: BaselineRebuilder
    /// The services the collector's parts read beyond its constructor
    /// arguments: the workout slot, the workout backups, the live-HRV broker,
    /// the diagnostics sampler and the beat-consistency priors.
    let services: CollectorServices
    let cloudSyncManager: CloudKitSyncManager
    let acceptanceService: SessionAcceptanceService
    let morningProcessingService: MorningProcessingService
    let archiveSignal: ArchiveSignal
    let deviceStatus: DeviceStatus
    let streamingLifecycle: StreamingLifecycle
    let morningCoordination: MorningCoordination
    let sessionState: SessionState
    /// Settings, baseline and training load the collector analyses and scores
    /// with; the composition root shares it with saved-session reanalysis.
    let scoring: SessionScoringContext

    /// The live HRV snapshot the assistant's broker reads from any thread.
    let liveHRVMirror = LiveHRVMirror()

    /// Data quality verification (overnight sessions - strict)
    let verification = Verification()

    /// Data quality verification (streaming - relaxed for short readings)
    let streamingVerification = Verification(config: Verification.Config(
        minPoints: QuickReadingSession.minimumQuickReadingBeats,
        minDurationHours: 0.025,
        maxArtifactPercent: 20.0,
        warnArtifactPercent: 10.0
    ))

    // MARK: - Computed Properties

    /// Async version that performs archive disk I/O on a background thread.
    /// Uses lightweight loading (skips rrSeries deserialization) for ~45x less
    /// JSON parsing. Call `retrieveFullSessionAsync` for the single session
    /// that needs chart data.
    func recentSessionsAsync(limit: Int?) async -> [HRVSession] {
        let allEntries = archive.store.entries
        let entries = limit.map { Array(allEntries.prefix($0)) } ?? allEntries
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            await Self.decodeInParallel(entries, archive: archive)
        }.value
    }

    /// Every archived session (lightweight), for a screen that charts the
    /// whole history, with the sessions that could not be read marked as
    /// such (`SessionLoad`). Cancelling the calling task cancels the load:
    /// no new read starts, and nil comes back rather than part of the
    /// history, so a caller never shows or acts on an incomplete list.
    func allSessionsAsync() async -> SessionLoad? {
        let entries = archive.store.entries
        let archive = self.archive
        let work = Task.detached(priority: .userInitiated) {
            await Self.decodeMarkingFailures(entries, archive: archive)
        }
        let sessions = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        return Task.isCancelled ? nil : sessions
    }

    /// At most this many sessions are read and decoded at once: enough to
    /// keep every core busy, without queuing a task for each archived session
    /// when a screen loads the whole history.
    nonisolated static var decodeWidth: Int { max(2, ProcessInfo.processInfo.activeProcessorCount) }

    /// Decrypt the sessions in PARALLEL, at most `decodeWidth` at a time.
    /// `retrieveLightweight` holds `archiveLock` only for the index lookup,
    /// not across the file read+decrypt, so a TaskGroup spreads the decode
    /// across cores instead of a one-at-a-time loop that leaves the dashboard
    /// lingering on empty placeholders. Each finished read starts the next;
    /// once the task is cancelled no new read starts, and the reads already
    /// running finish. Order is preserved by index; sessions that fail to
    /// decode are left out. Also the decode of
    /// `recentSessionsAsync(limit:before:type:)`.
    nonisolated static func decodeInParallel(_ entries: [SessionArchiveEntry], archive: SessionArchive) async -> [HRVSession] {
        await decodeMarkingFailures(entries, archive: archive).sessions
    }

    /// `decodeInParallel` that keeps a nil in place of each session that
    /// could not be read.
    nonisolated static func decodeMarkingFailures(_ entries: [SessionArchiveEntry], archive: SessionArchive) async -> SessionLoad {
        await withTaskGroup(of: (Int, HRVSession?).self) { group in
            let first = min(decodeWidth, entries.count)
            for index in 0 ..< first {
                addDecodeTask(&group, index: index, entry: entries[index], archive: archive)
            }
            let decoded = await drainRefilling(&group, entries: entries, next: first, archive: archive)
            return SessionLoad(ids: entries.map(\.sessionId), decoded: decoded)
        }
    }

    /// Collect each finished read and start the next unread entry in its
    /// place, until every started read has finished. No new read starts
    /// once the task is cancelled. Returns one slot per entry, in the
    /// entries' order: the session, or nil when it failed or was never read.
    nonisolated private static func drainRefilling(
        _ group: inout TaskGroup<(Int, HRVSession?)>,
        entries: [SessionArchiveEntry],
        next start: Int,
        archive: SessionArchive
    ) async -> [HRVSession?] {
        var next = start
        var decoded = [HRVSession?](repeating: nil, count: entries.count)
        while let finished = await group.next() {
            decoded[finished.0] = finished.1
            guard next < entries.count, !Task.isCancelled else { continue }
            addDecodeTask(&group, index: next, entry: entries[next], archive: archive)
            next += 1
        }
        return decoded
    }

    nonisolated private static func addDecodeTask(
        _ group: inout TaskGroup<(Int, HRVSession?)>,
        index: Int,
        entry: SessionArchiveEntry,
        archive: SessionArchive
    ) {
        group.addTask { (index, archive.retrieveLightweightOrLog(entry.sessionId)) }
    }

    /// Load a single full session (with rrSeries) on a background thread.
    /// Use this after picking the dashboard's active session to get chart data.
    func retrieveFullSessionAsync(_ id: UUID) async -> HRVSession? {
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(id)
        }.value
    }

    /// What the Record screen's Recover card offers: a recording the app has
    /// never downloaded, or one still running on the strap that no session of
    /// this app owns (left by a crash, or started on the strap). Recover stops
    /// a running one before it downloads. Neither the card's Recover nor its
    /// Discard is offered while another session owns the strap's recording
    /// (`StrapRecordingGuards.strapRecordingOwner`).
    var offersStrapRecovery: Bool {
        (strapGuards.hasUnrecoveredData || strapGuards.holdsOrphanedRecording) && strapGuards.strapRecordingOwner() == nil
    }

    // MARK: - Initialization

    /// Wiring-layer factory: a fully-configured collector over the services
    /// of `dependencies`, the container the app scene hands in. This is the
    /// canonical production entry point; every other layer receives the
    /// collector through the environment or initializer injection so tests
    /// and previews can swap dependencies without monkey-patching singletons.
    static func makeDefault(dependencies: AppDependencies) -> RRCollector {
        let collector = RRCollector(dependencies: dependencies)
        // Bound for the parts that ask about the live recording without
        // being handed the collector (`CollectorBox`).
        dependencies.app.collectorBox.collector = collector
        return collector
    }

    /// Cold-start: post-first-frame catch-up work kept out of
    /// `makeDefault()`. The baseline
    /// rebuild walks every archive entry from disk — on a CloudKit-restored
    /// install with hundreds of sessions this can take 200–500ms on iPhone
    /// 11. Calling `boot()` from `RootView.task` after the first frame
    /// removes it from the synchronous launch path.
    ///
    /// **Idempotent.** Safe to call multiple times; the rebuild only runs
    /// when the in-memory tracker is still empty (i.e. on first call) and
    /// flips `_didBootBaseline` to short-circuit subsequent calls.
    ///
    /// Deferring is safe: the dashboard's recovery-score path doesn't read
    /// baseline numbers until after a new reading is processed, and
    /// `runLaunchTask` starts well after boot() has a chance to run. The
    /// rebuild is best-effort recovery from CloudKit-restored state.
    ///
    /// No Polar BLE prewarm (`ensureApiReady()` shortly after launch) here:
    /// initializing the CoreBluetooth central at launch instead of lazily on
    /// first connect correlates with the strap not showing HR at session
    /// start. Keep the init lazy on the Record/connect path unless the connect
    /// flow is verified on a device.
    @MainActor
    func boot() {
        guard didBootBaseline.setIfClear() else { return }
        guard baselineTracker.daysCollected == 0, !archive.store.entries.isEmpty else { return }
        baselineRebuild.rebuildOffMain()
    }

    @ObservationIgnored private let didBootBaseline = OSAllocatedUnfairLock(initialState: false)

    /// A collector over the services of `dependencies`. `makeDefault` builds
    /// the app's with it; SwiftUI `#Preview` blocks and tests that don't care
    /// about individual dependencies build one directly. Callers that need a
    /// different wiring (tests with stubs) go through the designated
    /// `init(polarManager:healthKit:...)` below instead.
    /// Baseline rebuild from CloudKit-restored archive entries is deferred
    /// to boot() (called from RootView.task after first frame). Done
    /// synchronously here it would walk every archive entry from disk — on
    /// iPhone 11 with a big restored archive that's a measurable chunk of the
    /// splash delay. Initial state with an
    /// empty tracker is correct (no baseline shown until rebuild completes);
    /// the dashboard already tolerates that path.
    ///
    /// The baseline tracker, archive signal and scoring context are the
    /// composition root's, the instances saved-session reanalysis
    /// (`SessionReanalysisCoordinator`) is built with, so a rescore updates
    /// the baseline this collector scores against and bumps the signal its
    /// views observe.
    convenience init(dependencies: AppDependencies) {
        let collection = dependencies.collection
        self.init(
            polarManager: PolarManager(),
            healthKit: collection.healthKitManager,
            archive: dependencies.storage.sessionArchive,
            rawBackup: RawRRBackup.app(),
            artifactDetector: ArtifactDetector(),
            windowSelector: WindowSelector(),
            baselineTracker: collection.baselineTracker,
            settingsManager: dependencies.app.settingsManager,
            archiveSignal: collection.archiveSignal,
            scoring: collection.sessionScoring,
            services: CollectorServices(dependencies)
        )
    }

    // spec:long-function Twenty injected dependencies, one assignment each,
    // with `?? Self.makeX(...)` resolving the ones the caller left nil. The
    // three services with non-trivial construction live in static factories;
    // what is left is pure assignment with no branching and nothing
    // further to extract. Swift also forbids calling a helper on `self` before
    // every stored property is initialized, so the body cannot be split even
    // mechanically. Post-assignment wiring already lives in
    // `wireCollaborators()`.
    /// Create an RRCollector with injected dependencies (for testing). The
    /// archive, settings manager and `services` are always the caller's; the
    /// CloudKit sync manager left out is the one `services` resolves, so a
    /// test that must not touch it injects its own. An injected `scoring`
    /// must hold the same baseline tracker and settings manager; left out,
    /// one is built from them.
    init(
        polarManager: PolarManager,
        healthKit: HealthKitManager,
        archive: SessionArchive,
        rawBackup: RawRRBackup = RawRRBackup.app(),
        artifactDetector: ArtifactDetector = ArtifactDetector(),
        windowSelector: WindowSelector = WindowSelector(),
        baselineTracker: BaselineTracker = BaselineTracker(),
        settingsManager: SettingsManager,
        cloudSyncManager: CloudKitSyncManager? = nil,
        reconciliation: ReconciliationManager? = nil,
        analysisPipeline: HRVAnalysisPipeline? = nil,
        sleepBoundaryResolver: SleepBoundaryResolver? = nil,
        acceptanceService: SessionAcceptanceService? = nil,
        morningProcessingService: MorningProcessingService? = nil,
        archiveSignal: ArchiveSignal? = nil,
        deviceStatus: DeviceStatus? = nil,
        streamingLifecycle: StreamingLifecycle? = nil,
        morningCoordination: MorningCoordination? = nil,
        sessionState: SessionState? = nil,
        scoring: SessionScoringContext? = nil,
        services: CollectorServices
    ) {
        self.services = services
        self.polarManager = polarManager
        self.healthKit = healthKit
        self.archive = archive
        self.rawBackup = rawBackup
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.baselineTracker = baselineTracker
        self.settingsManager = settingsManager
        self.baselineRebuild = BaselineRebuilder(
            archive: archive, baselineTracker: baselineTracker, settingsManager: settingsManager
        )
        self.archiveSignal = archiveSignal ?? ArchiveSignal()
        self.deviceStatus = deviceStatus ?? DeviceStatus()
        self.streamingLifecycle = streamingLifecycle ?? StreamingLifecycle()
        self.morningCoordination = morningCoordination ?? MorningCoordination()
        self.sessionState = sessionState ?? SessionState()
        self.scoring = scoring ?? SessionScoringContext(
            settingsManager: settingsManager, healthKit: healthKit.service, baselineTracker: baselineTracker
        )
        let resolvedCloudSyncManager = cloudSyncManager ?? services.cloudKitSyncManager
        self.cloudSyncManager = resolvedCloudSyncManager
        self.reconciliation = reconciliation ?? ReconciliationManager(archive: archive)
        let resolvedPipeline = analysisPipeline ?? Self.makePipeline(
            artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit.service
        )
        self.analysisPipeline = resolvedPipeline
        self.sleepBoundaryResolver = sleepBoundaryResolver ?? SleepBoundaryResolver(healthKit: healthKit.service)
        self.acceptanceService = acceptanceService ?? Self.makeAcceptanceService(
            archive: archive, healthKit: healthKit.service, baselineTracker: baselineTracker,
            rawBackup: rawBackup, cloudSync: resolvedCloudSyncManager
        )
        self.morningProcessingService = morningProcessingService ?? Self.makeMorningProcessingService(
            MorningProcessingDependencies(
                archive: archive, healthKit: healthKit.service, pipeline: resolvedPipeline,
                windowSelector: windowSelector, artifactDetector: artifactDetector,
                verification: verification, baselineTracker: baselineTracker, rawBackup: rawBackup
            )
        )
        wireCollaborators()
    }

    /// The three services the collector builds when the caller does not inject
    /// one. Kept out of the initializer — each is a wiring decision with its
    /// own argument list, and inline they would dominate the 19-parameter
    /// `init`.
    private static func makePipeline(
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        healthKit: any HealthKitServiceProtocol
    ) -> HRVAnalysisPipeline {
        HRVAnalysisPipeline(
            artifactDetector: artifactDetector,
            windowSelector: windowSelector,
            healthKit: healthKit
        )
    }

    private static func makeAcceptanceService(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        cloudSync: CloudKitSyncManager
    ) -> SessionAcceptanceService {
        SessionAcceptanceService(
            archive: archive,
            healthKit: healthKit,
            baselineTracker: baselineTracker,
            rawBackup: rawBackup,
            onCloudSync: { session in
                await cloudSync.uploadSession(session)
            },
            onCloudDelete: { sessionId in
                await cloudSync.deleteLiveBackup(sessionId: sessionId)
            }
        )
    }

    /// The collaborators the morning pipeline needs, grouped so the factory
    /// stays inside `function_parameter_count`.
    struct MorningProcessingDependencies {
        let archive: SessionArchive
        let healthKit: any HealthKitServiceProtocol
        let pipeline: HRVAnalysisPipeline
        let windowSelector: WindowSelector
        let artifactDetector: ArtifactDetector
        let verification: Verification
        let baselineTracker: BaselineTracker
        let rawBackup: RawRRBackup
    }

    private static func makeMorningProcessingService(
        _ dependencies: MorningProcessingDependencies
    ) -> MorningProcessingService {
        MorningProcessingService(
            archive: dependencies.archive,
            healthKit: dependencies.healthKit,
            analysisPipeline: dependencies.pipeline,
            windowSelector: dependencies.windowSelector,
            artifactDetector: dependencies.artifactDetector,
            verification: dependencies.verification,
            baselineTracker: dependencies.baselineTracker,
            rawBackup: dependencies.rawBackup
        )
    }

    /// Everything the initializer does after its stored properties are in
    /// place: observation, the archived-copy listener, cache binding, state
    /// restoration and the one-time migration.
    ///
    /// This runs synchronously on the launch path — `EmuquApp` keeps
    /// `collector` eager because the first frame needs it — so anything added
    /// here is cold-start cost. The disk-touching parts already hop off the
    /// main actor (`restorePausedStateIfNeeded` defers to `Task.detached`).
    private func wireCollaborators() {
        bindings.setupBindings()
        setupDataRescueCallback()
        setupLifecycleObservers()
        // Wire the Beat Consistency priors cache to the
        // archive change signal. Cache invalidates on add/delete/merge
        // so stale features can't survive past a session-list change.
        // Reads during HRV view open are zero-archive after first warm.
        services.beatConsistencyPriorsCache.bindToArchiveSignal(self.archiveSignal, archive: self.archive)
        installArchivedCopyListener()
        control.restorePausedStateIfNeeded()
        control.refreshRecentPausedSession()
        bindings.publishLiveHRVSnapshotsToAssistant()
        bindings.armObservationLoops()
        bindings.runMergeDataLossMigrationIfNeeded()
    }

    // MARK: - Types

    /// The collector's errors (`RRCollectorError`), named from inside it.
    typealias CollectorError = RRCollectorError

    // Leak guard. RRCollector installs a `streamingTimer` and
    // block-based NotificationCenter observers (`notificationObservers`); without
    // teardown every collector built in a test/preview leaks its
    // timer and observers (and the `self` they captured); both must be
    // released by hand.
    // A timer is invalidated on the thread whose run loop it was scheduled
    // on (the main one); deinit can run elsewhere, so it hops there.
    deinit {
        notificationObservers.removeAll()
    }
}

/// What a recording, import or morning fetch can fail with, as
/// `RRCollector.CollectorError`. Kept outside the class: it holds no collector
/// state and only describes the failure to the user.
enum RRCollectorError: Error, LocalizedError, Equatable {
    case notConnected
    case alreadyRecording
    case sessionExists
    case insufficientData
    case noSessionToAccept
    case noSessionToRecover
    case dataAlreadyExists
    /// An imported reading the archive already holds a copy of (same type, overlapping time).
    case duplicateImport
    /// An imported file that holds no complete, analysed reading.
    case importNotAnalyzed
    /// The strap's own recording could not be read and the live stream
    /// is missing this many minutes of the night.
    case strapStillHoldsNight(missingMinutes: Int)
    /// Recover was asked for a recording the app already downloaded and
    /// saved; the strap only keeps it as a backup.
    case strapRecordingAlreadySaved

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Polar device not connected", bundle: LanguageManager.appBundle)
        case .alreadyRecording:
            return String(localized: "A recording is already in progress on the device", bundle: LanguageManager.appBundle)
        case .sessionExists:
            return String(localized: "A session with this ID already exists", bundle: LanguageManager.appBundle)
        case .insufficientData:
            return String(localized: "Not enough RR data collected (need at least 120 beats)", bundle: LanguageManager.appBundle)
        case .noSessionToAccept:
            return String(localized: "No completed session to accept", bundle: LanguageManager.appBundle)
        case .noSessionToRecover:
            return String(localized: "No session found to recover data into", bundle: LanguageManager.appBundle)
        case .dataAlreadyExists, .strapRecordingAlreadySaved:
            return String(localized: "Session already has this RR data - no recovery needed", bundle: LanguageManager.appBundle)
        case .duplicateImport, .importNotAnalyzed, .strapStillHoldsNight:
            return outcomeDescription
        }
    }

    /// The import and morning-fetch outcomes, kept apart so each switch
    /// stays short.
    private var outcomeDescription: String? {
        switch self {
        case .duplicateImport:
            return String(localized: "A reading from the same time is already in your history, so this one wasn't saved.", bundle: LanguageManager.appBundle)
        case .importNotAnalyzed:
            return String(localized: "This file has no complete reading that could be analyzed, so it wasn't saved.", bundle: LanguageManager.appBundle)
        case let .strapStillHoldsNight(missingMinutes):
            let gap = LocalizedDuration.hoursMinutes(minutes: missingMinutes)
            return String(localized: "Couldn't read your strap's own recording, and the live stream is missing about \(gap) of this night. The strap still holds the full night: recover it from the Record screen before starting a new recording, which clears it.", bundle: LanguageManager.appBundle)
        default:
            return nil
        }
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `RRCollector` and calls nothing on it, so none needs
// to be inside the type.

/// The services the recording collector's parts read beyond what its
/// initializer takes, and nothing else. Each accessor resolves on use, as
/// the container's do, so building a collector constructs none of them.
struct CollectorServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    @MainActor
    var beatConsistencyPriorsCache: BeatConsistencyPriorsCache { container.analysis.beatConsistencyPriorsCache }
    var breadcrumbStore: BreadcrumbStore { container.location.breadcrumbStore }
    @MainActor
    var cloudKitSyncManager: CloudKitSyncManager { container.storage.cloudKitSyncManager }
    var liveHRVBroker: LiveHRVBroker { container.assistant.liveHRVBroker }
    @MainActor
    var morningNotificationScheduler: MorningNotificationScheduler { container.services.morningNotificationScheduler }
    @MainActor
    var recorderBox: RecorderBox { container.app.recorderBox }
    @MainActor
    var savedRouteStore: SavedRouteStore { container.location.savedRouteStore }
    var systemDiagnosticsManager: SystemDiagnosticsManager { container.app.systemDiagnosticsManager }
    var workoutTrackBackup: WorkoutTrackBackup { container.storage.workoutTrackBackup }
}
