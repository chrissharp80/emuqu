import Foundation
import os

/// RR interval collector - orchestrates Polar device recording and analysis.
///
/// The collector holds the dependencies and the shared state; most of the
/// behaviour lives on coordinators it builds on demand and reaches through
/// forwarders (`+…Forwarding`, and the forwarders below):
///   control (CollectorSessionControl) – +Bindings, +Streaming, +PauseResume
///   overnightStreaming (OvernightStreamingCoordinator) – +OvernightStreaming,
///     +OvernightArming, +OvernightGather
///   deviceRecording (DeviceRecordingSession) – +DeviceRecording
///   morning (MorningSessionPipeline) – +MorningProcessing
///   recovery (SessionRecoveryCoordinator) – +Recovery, +BackupRecovery
///   import (SessionImport) – +Import
/// Extensions on the collector itself: +Lifecycle (persisted recording
/// state, data rescue, emergency backup), +Acceptance, +Analysis.
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

    /// Set by UI to control device fetch during morning processing.
    var deviceFetchPolicy: DeviceFetchPolicy = .automatic

    /// True when overnight streaming should also use H10 internal memory as backup.
    /// False means true streaming-only behavior (no internal recording + no morning fetch).
    var useDeviceBackupForOvernight: Bool = true

    /// True once the H10's internal recording has actually STARTED for the
    /// current overnight session (the `.both` capture mode on an H10). While
    /// this holds, the strap is capturing the full night to its own flash
    /// memory independently of the BLE link — so a mid-night reconnect
    /// exhaustion (transient iOS BLE reset, out-of-range trip) must NOT pause
    /// and fetch, because fetching STOPS the recording and ends the night
    /// early. It gates the `reconnectExhausted` auto-pause in
    /// `RRCollector+Bindings` so those nights stay alive and are recovered from
    /// the strap at wake instead. Reset at the start of every session and
    /// once the ending's strap gate has read it (`fetchNightFromStrap`), which
    /// downloads only a night that armed the strap.
    var overnightDeviceBackupActive: Bool = false

    /// Set first thing when a night begins to end (the morning stop or a
    /// pause), before streaming stops or the link changes, and cleared when
    /// a night or a resumed segment starts. The arming loop and
    /// `startFreshRecording` refuse to arm while it is set.
    var isOvernightEnding = false

    /// The night's arming loop, so the end of the night can cancel it and
    /// wait for it before the strap is stopped and downloaded.
    @ObservationIgnored var overnightArmingTask: Task<Void, Never>?

    /// How long the arming loop waits, on a link that does not change,
    /// before trying again after a refusal that can clear up.
    @ObservationIgnored var armingRetryInterval: TimeInterval = StrapRecordingPolicy.armingRetryIntervalSeconds

    // Archive update trigger — moved to a dedicated `ArchiveSignal` object so
    // views that only care about archive changes don't observe the full
    // collector (whose state also changes on BLE + streaming +
    // recording updates).
    //
    // Back-compat accessor so non-SwiftUI internals and tests can still read
    // the value via `collector.archiveVersion`. SwiftUI views read
    // `archiveSignal` directly from the environment.
    var archiveVersion: Int { archiveSignal.version }

    // Proxied PolarManager state moved to a dedicated `DeviceStatus` object
    // so views that only care about BLE connection / battery / device
    // recording state don't re-render on every archive / streaming /
    // morning-processing property the collector also publishes.
    //
    // Writers: `RRCollector+Bindings.setupBindings()` pushes PolarManager
    // updates into `deviceStatus`. Back-compat computed getters below
    // forward existing `collector.isDeviceConnected` / `collector.batteryLevel`
    // etc. reads through to the new object. SwiftUI views read
    // `deviceStatus` directly from the environment.
    var fetchProgress: PolarManager.FetchProgress? { deviceStatus.fetchProgress }
    var isDeviceConnected: Bool { deviceStatus.isDeviceConnected }
    var isStreaming: Bool { deviceStatus.isStreaming }
    var hasStoredExercise: Bool { deviceStatus.hasStoredExercise }
    var batteryLevel: Int? { deviceStatus.batteryLevel }
    var isRecordingOnDevice: Bool { deviceStatus.isRecordingOnDevice }
    var connectedDeviceType: PolarDeviceType? { deviceStatus.connectedDeviceType }
    var recordingState: PolarManager.RecordingState { deviceStatus.recordingState }
    var connectionState: PolarManager.ConnectionState { deviceStatus.connectionState }

    /// Cached result of `findRecentPausedSession()`, updated on every
    /// `archiveSignal` bump. Forwarded from `SessionState` for back-compat.
    var recentPausedSession: HRVSession? {
        get { sessionState.recentPausedSession }
        set { sessionState.recentPausedSession = newValue }
    }

    /// Callback when streaming auto-completes
    var onStreamingComplete: (() -> Void)?

    // MARK: - Internal State (accessed by extension files)

    /// The timer lives inside a lock so `deinit` can invalidate it without
    /// touching a non-`Sendable` stored property from a nonisolated context.
    @ObservationIgnored private let streamingTimerBox = OSAllocatedUnfairLock<Timer?>(uncheckedState: nil)
    var streamingTimer: Timer? {
        get { streamingTimerBox.withLockUnchecked { $0 } }
        set { streamingTimerBox.withLockUnchecked { $0 = newValue } }
    }
    var sessionStartTime: Date?

    /// Tokens for the block-based NotificationCenter observers the
    /// collector registers (app lifecycle in `+Lifecycle`, the archived-copy
    /// listener in `+Acceptance`). Stored so `deinit` can remove them;
    /// discarding the `addObserver` return value leaks the observer (and the
    /// captured `self`) in tests/previews that build many collectors. Block
    /// observers are not released with the collector — they must be
    /// removed explicitly.
    @ObservationIgnored let notificationObservers = NotificationTokens()
    var lastSeenReconnectCount: Int = 0
    /// The current (as-of-today) training load, held by `scoring`.
    var cachedTrainingLoad: HealthKitManager.TrainingLoad? {
        get { scoring.cachedTrainingLoad }
        set { scoring.cachedTrainingLoad = newValue }
    }
    var lastEmergencyFlush: Date?

    /// Backing storage for the lazy `recoveryService` computed property in +Recovery.
    var _recoveryService: SessionRecoveryService?

    /// Streaming sessions, pause/resume, and the view bindings.
    var control: CollectorSessionControl {
        CollectorSessionControl(collector: self)
    }

    func setupBindings() { control.setupBindings() }
    func armObservationLoops() { control.armObservationLoops() }
    func runMergeDataLossMigrationIfNeeded() { control.runMergeDataLossMigrationIfNeeded() }
    func publishLiveHRVSnapshotsToAssistant() { control.publishLiveHRVSnapshotsToAssistant() }
    func startStreamingSession(durationSeconds: Int = 180) throws {
        try control.startStreamingSession(durationSeconds: durationSeconds)
    }
    func stopStreamingSession() async -> HRVSession? { await control.stopStreamingSession() }
    func stopStreamingTimer() { control.stopStreamingTimer() }
    func pauseOvernightStreaming() async -> HRVSession? { await control.pauseOvernightStreaming() }
    func resumeOvernightStreaming(linkedSessionId: UUID) throws {
        try control.resumeOvernightStreaming(linkedSessionId: linkedSessionId)
    }
    func finalizeFromPause() { control.finalizeFromPause() }
    func persistPausedSessionState(sessionId: UUID) { control.persistPausedSessionState(sessionId: sessionId) }
    func clearPausedSessionState() { control.clearPausedSessionState() }
    func restorePausedStateIfNeeded() { control.restorePausedStateIfNeeded() }
    func refreshRecentPausedSession() { control.refreshRecentPausedSession() }

    nonisolated static func findRecentPausedSessionOffMain(
        archive: SessionArchive, maxGap: TimeInterval
    ) -> HRVSession? {
        CollectorSessionControl.findRecentPausedSessionOffMain(archive: archive, maxGap: maxGap)
    }

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

    /// Thread-safe mirror of the live HRV snapshot. Written
    /// only from MainActor (via `refreshLiveHRVSnapshotMirror` on every
    /// sessionState change). Read from any thread by the
    /// `LiveHRVBroker` provider closure WITHOUT crossing actors. The
    /// `OSAllocatedUnfairLock` holds the value, so every read and write
    /// goes through `withLock` and the compiler checks the Sendable fields.
    @ObservationIgnored nonisolated let liveHRVSnapshotMirror = OSAllocatedUnfairLock<LiveHRVSnapshotMirror?>(initialState: nil)

    /// Sendable inputs captured on MainActor; the broker provider
    /// recomputes `elapsedSeconds` / `snapshotAt` at read time (those
    /// are clock-derived and would go stale otherwise).
    struct LiveHRVSnapshotMirror: Sendable {
        let phaseLabel: String
        let phaseDescription: String
        let isCollecting: Bool
        let beatCount: Int
        let sessionStartAt: Date?
        let lastErrorDescription: String?
    }

    /// Data quality verification (overnight sessions - strict)
    let verification = Verification()

    /// Data quality verification (streaming - relaxed for short readings)
    let streamingVerification = Verification(config: Verification.Config(
        minPoints: CollectorSessionControl.minimumQuickReadingBeats,
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
        let allEntries = archive.entries
        let entries = limit.map { Array(allEntries.prefix($0)) } ?? allEntries
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            await Self.decodeInParallel(entries, archive: archive)
        }.value
    }

    /// Every archived session (lightweight), for a screen that charts the
    /// whole history. Cancelling the calling task cancels the load: no new
    /// read starts, and nil comes back rather than part of the history, so a
    /// caller never shows or acts on an incomplete list.
    func allSessionsAsync() async -> [HRVSession]? {
        let entries = archive.entries
        let archive = self.archive
        let work = Task.detached(priority: .userInitiated) {
            await Self.decodeInParallel(entries, archive: archive)
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
        await withTaskGroup(of: (Int, HRVSession?).self) { group in
            let first = min(decodeWidth, entries.count)
            for index in 0 ..< first {
                addDecodeTask(&group, index: index, entry: entries[index], archive: archive)
            }
            return await drainRefilling(&group, entries: entries, next: first, archive: archive)
        }
    }

    /// Collect each finished read and start the next unread entry in its
    /// place, until every started read has finished. No new read starts
    /// once the task is cancelled. Returns the decoded sessions in the
    /// entries' order.
    nonisolated private static func drainRefilling(
        _ group: inout TaskGroup<(Int, HRVSession?)>,
        entries: [SessionArchiveEntry],
        next start: Int,
        archive: SessionArchive
    ) async -> [HRVSession] {
        var next = start
        var indexed: [(Int, HRVSession)] = []
        indexed.reserveCapacity(entries.count)
        while let finished = await group.next() {
            finished.1.map { indexed.append((finished.0, $0)) }
            guard next < entries.count, !Task.isCancelled else { continue }
            addDecodeTask(&group, index: next, entry: entries[next], archive: archive)
            next += 1
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
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

    /// True when the strap holds a recording the app has never downloaded
    /// (`StrapRecordingPolicy.holdsUnrecoveredRecording`). The strap keeps
    /// every downloaded recording as a backup, so holding one is not enough.
    var hasUnrecoveredData: Bool {
        guard polarManager.hasStoredExercise, let start = polarManager.storedExerciseDate else { return false }
        return !isStrapRecordingSaved(startedAt: start)
    }

    /// Whether the app holds the strap recording that began at `start`
    /// (`StrapRecordingPolicy.recordingIsSaved`). The strap's start sequence
    /// asks the same question before it clears the strap. On disk: an
    /// archived night or nap that was running when the recording began
    /// (starting up to 30 minutes after it, and not ended before it), or a
    /// rescue backup within 30 minutes of its start. A strap armed late in a
    /// night is filed into that night, whose start can be hours before the
    /// recording's; a quick reading or workout that ended just before the
    /// recording does not hold it.
    func isStrapRecordingSaved(startedAt start: Date) -> Bool {
        let ledger = polarManager.downloadLedger
        return StrapRecordingPolicy.recordingIsSaved(
            alreadyDownloaded: ledger.wasDownloaded(recordingStartedAt: start),
            predatesDownloadRecord: ledger.predatesRecord(start),
            heldOnDisk: archiveHoldsSession(runningAt: start, slackMinutes: 30, in: archive)
                || rawBackup.holdsBackup(capturedWithin: 30 * 60, of: start)
        )
    }

    /// What the Record screen's Recover card offers: a recording the app has
    /// never downloaded, or one still running on the strap that no session of
    /// this app owns (left by a crash, or started on the strap). Recover stops
    /// a running one before it downloads.
    var offersStrapRecovery: Bool {
        hasUnrecoveredData || recovery.strapHoldsOrphanedRecording
    }

    /// A TrainingContext from the training load as of `referenceDate`
    /// (`SessionScoringContext.createTrainingContext(relativeTo:)`).
    func createTrainingContext(relativeTo referenceDate: Date = Date()) -> TrainingContext? {
        scoring.createTrainingContext(relativeTo: referenceDate)
    }

    /// The training context as of `referenceDate`, fetched from HealthKit when
    /// none is held (`SessionScoringContext.createTrainingContextEnsuringFresh`).
    func createTrainingContextEnsuringFresh(relativeTo referenceDate: Date = Date()) async -> TrainingContext? {
        await scoring.createTrainingContextEnsuringFresh(relativeTo: referenceDate)
    }

    /// The stored nights before `session`'s own, its scoring baseline
    /// (`SessionScoringContext.scoringBaselineStats(for:)`).
    func scoringBaselineStats(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        scoring.scoringBaselineStats(for: session)
    }

    /// Current scoring configuration for RecoveryScoreCalculator, from the settings.
    var currentScoringConfig: RecoveryScoreCalculator.ScoringConfiguration {
        scoring.currentScoringConfig
    }

    /// Current ANS configuration: today's training load, every stored night as baseline.
    var currentANSConfig: HRVAnalysisPipeline.ANSConfiguration {
        scoring.currentANSConfig
    }

    /// ANS configuration for analysing `session`
    /// (`SessionScoringContext.ansConfig(for:)`).
    func ansConfig(for session: HRVSession) -> HRVAnalysisPipeline.ANSConfiguration {
        scoring.ansConfig(for: session)
    }

    // MARK: - Initialization

    /// Wiring-layer factory: resolves the app's shared managers and returns a
    /// fully-configured collector. This is the canonical production entry
    /// point — the explicit-dependency-wiring principle calls for a
    /// single wiring layer that is allowed to touch `.shared` instances,
    /// rather than business logic reaching for the world inside its own init.
    /// The main app scene calls this; every other layer receives the collector
    /// through the environment or initializer injection so tests and previews
    /// can swap dependencies without monkey-patching singletons.
    static func makeDefault() -> RRCollector {
        let collector = RRCollector(defaultsFromShared: ())
        // Register as the canonical "current" collector so read-only
        // surfaces (the AI fact resolver, in particular) can reach live
        // device state — Polar battery, connection, recording-hours,
        // active workout — without us threading the collector through
        // every layer that needs to peek at it. Weak so this never
        // accidentally extends the lifetime of an old instance during
        // tests / previews. Strictly read-only: callers MUST NOT use
        // this to invoke behavior on the collector (start streaming,
        // archive a session) — that path stays through environment
        // injection so dependency wiring stays explicit.
        Self.current = collector
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
    /// **Behaviour parity.** The user-visible state at "I just opened the
    /// app and the first frame painted" is identical: the dashboard's
    /// recovery-score path doesn't read baseline numbers until after a new
    /// reading is processed, and `runLaunchTask` already starts well after
    /// boot() has a chance to run. The rebuild was always best-effort
    /// recovery from CloudKit-restored state — pushing it a frame later
    /// doesn't change correctness.
    ///
    /// NOTE — no Polar BLE prewarm (`ensureApiReady()` shortly after launch)
    /// here: initializing the CoreBluetooth central at launch instead of
    /// lazily on first connect correlated with the strap not showing HR at
    /// session start. The long-stable behavior is lazy init on the
    /// Record/connect path — do not add a launch-time BLE init without
    /// on-device verification of the connect flow.
    @MainActor
    func boot() {
        guard didBootBaseline.setIfClear() else { return }
        guard baselineTracker.daysCollected == 0, !archive.entries.isEmpty else { return }
        rebuildBaselineOffMain()
    }

    /// Decrypt the archive OFF the main actor. `boot()` runs
    /// synchronously on the main actor right after first paint
    /// (`EmuquApp.runDeferredBoot` → `timedBoot("collector")`), and this walk
    /// does an AES-GCM decrypt + JSON decode PER archived session — a field
    /// trace measured it stalling the main thread ~6.3s on a full archive,
    /// freezing the dashboard until it finished. It's the LAST main-actor
    /// decrypt of the launch path (the `fromAppArchive` /
    /// `calculateTrainingMetrics` decrypts were already moved off-main). The
    /// rebuild is best-effort recovery from CloudKit-restored state (see the
    /// note on `boot()`), so deferring it a few frames off-main is
    /// correctness-neutral. Decrypt on a utility task, then hop back to mutate
    /// the MainActor-isolated `baselineTracker`.
    /// Also the rebuild after a CloudKit pull into an empty baseline
    /// (`CollectorSessionControl.bindCloudSyncBaseline`).
    @MainActor
    func rebuildBaselineOffMain(replacing: Bool = false) {
        rebuildBaselineOffMain(replacing: replacing, reusing: [:])
    }

    /// Rebuild the baseline from what the archive holds now. Used after a
    /// night the baseline had already taken in is discarded.
    @MainActor
    func rebuildBaselineFromArchive() {
        rebuildBaselineOffMain(replacing: true)
    }

    /// A replacing rebuild starts from an empty tracker; one whose archive
    /// changed while it decoded starts over instead, so a night archived or
    /// rewritten (a newer iCloud copy under the same id) in the meantime is
    /// neither wiped from the baseline nor scored from its old copy. The pass
    /// that starts over reuses what this one decoded whose stored file is
    /// unchanged (`ArchivedCopy`: id and file hash) and decrypts only what is
    /// new or rewritten, so an archive that keeps changing (a run of iCloud
    /// pulls) costs a few sessions per pass, not the whole archive again. A
    /// boot rebuild re-checks: if a live session landed while we were
    /// decrypting, it already seeded the tracker, so the rebuild must not
    /// clobber it.
    @MainActor
    private func commitRebuiltBaseline(_ sessions: [HRVSession], decoded: [ArchivedCopy: HRVSession], copies: [ArchivedCopy], replacing: Bool) {
        if replacing {
            guard archive.entries.map(ArchivedCopy.init) == copies else { return restartReplacingRebuild(reusing: decoded) }
            baselineTracker.reset()
        } else if baselineTracker.daysCollected > 0 {
            return
        }
        baselineTracker.rebuildFromSessions(
            sessions,
            sleepSchedule: settingsManager.settings.sleepSchedule // injected, never resolved here
        )
    }

    @ObservationIgnored private let didBootBaseline = OSAllocatedUnfairLock(initialState: false)

    /// Weak reference to the production collector. Set by `makeDefault()`.
    /// Nil in `#Preview` blocks and tests that instantiate via the
    /// designated init. Read-only access only — see `makeDefault()` for
    /// the contract.
    static weak var current: RRCollector?

    /// Preview / test convenience. SwiftUI `#Preview` blocks and lightweight
    /// tests that don't care about dependencies use `RRCollector()`; real
    /// runtime wiring prefers `RRCollector.makeDefault()` so the dependency
    /// on shared singletons is visible at the call site.
    convenience init() {
        self.init(defaultsFromShared: ())
    }

    /// Single source of truth for "real production dependencies". Both the
    /// public factory and the convenience init funnel through here so the
    /// `.shared` lookups live in exactly one place. Callers that need a
    /// different wiring (tests, UI previews with stubs) go through the
    /// designated `init(polarManager:healthKit:...)` below instead.
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
    private convenience init(defaultsFromShared _: Void) {
        let collection = AppDependencies.current.collection
        self.init(
            polarManager: PolarManager(),
            healthKit: collection.healthKitManager,
            archive: AppDependencies.current.storage.sessionArchive,
            rawBackup: RawRRBackup(),
            artifactDetector: ArtifactDetector(),
            windowSelector: WindowSelector(),
            baselineTracker: collection.baselineTracker,
            settingsManager: AppDependencies.current.app.settingsManager,
            archiveSignal: collection.archiveSignal,
            scoring: collection.sessionScoring
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
    /// Create an RRCollector with injected dependencies (for testing). Any
    /// left out resolve to the app's own: the settings and CloudKit sync
    /// managers are the shared instances, so a test that must not touch them
    /// injects its own. An injected `scoring` must hold the same baseline
    /// tracker and settings manager; left out, one is built from them.
    init(
        polarManager: PolarManager,
        healthKit: HealthKitManager,
        archive: SessionArchive = SessionArchive(),
        rawBackup: RawRRBackup = RawRRBackup(),
        artifactDetector: ArtifactDetector = ArtifactDetector(),
        windowSelector: WindowSelector = WindowSelector(),
        baselineTracker: BaselineTracker = BaselineTracker(),
        settingsManager: SettingsManager = AppDependencies.current.app.settingsManager,
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
        scoring: SessionScoringContext? = nil
    ) {
        self.polarManager = polarManager
        self.healthKit = healthKit
        self.archive = archive
        self.rawBackup = rawBackup
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.baselineTracker = baselineTracker
        self.settingsManager = settingsManager
        self.archiveSignal = archiveSignal ?? ArchiveSignal()
        self.deviceStatus = deviceStatus ?? DeviceStatus()
        self.streamingLifecycle = streamingLifecycle ?? StreamingLifecycle()
        self.morningCoordination = morningCoordination ?? MorningCoordination()
        self.sessionState = sessionState ?? SessionState()
        self.scoring = scoring ?? SessionScoringContext(
            settingsManager: settingsManager, healthKit: healthKit, baselineTracker: baselineTracker
        )
        let resolvedCloudSyncManager = cloudSyncManager ?? AppDependencies.current.storage.cloudKitSyncManager
        self.cloudSyncManager = resolvedCloudSyncManager
        self.reconciliation = reconciliation ?? ReconciliationManager(archive: archive)
        let resolvedPipeline = analysisPipeline ?? Self.makePipeline(
            artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit
        )
        self.analysisPipeline = resolvedPipeline
        self.sleepBoundaryResolver = sleepBoundaryResolver ?? SleepBoundaryResolver(healthKit: healthKit)
        self.acceptanceService = acceptanceService ?? Self.makeAcceptanceService(
            archive: archive, healthKit: healthKit, baselineTracker: baselineTracker,
            rawBackup: rawBackup, cloudSync: resolvedCloudSyncManager
        )
        self.morningProcessingService = morningProcessingService ?? Self.makeMorningProcessingService(
            MorningProcessingDependencies(
                archive: archive, healthKit: healthKit, pipeline: resolvedPipeline,
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
        healthKit: HealthKitManager
    ) -> HRVAnalysisPipeline {
        HRVAnalysisPipeline(
            artifactDetector: artifactDetector,
            windowSelector: windowSelector,
            healthKit: healthKit
        )
    }

    private static func makeAcceptanceService(
        archive: SessionArchive,
        healthKit: HealthKitManager,
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
        let healthKit: HealthKitManager
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
        setupBindings()
        setupDataRescueCallback()
        setupLifecycleObservers()
        // Wire the Beat Consistency priors cache to the
        // archive change signal. Cache invalidates on add/delete/merge
        // so stale features can't survive past a session-list change.
        // Reads during HRV view open are zero-archive after first warm.
        AppDependencies.current.analysis.beatConsistencyPriorsCache.bindToArchiveSignal(self.archiveSignal, archive: self.archive)
        installArchivedCopyListener()
        restorePausedStateIfNeeded()
        refreshRecentPausedSession()
        publishLiveHRVSnapshotsToAssistant()
        armObservationLoops()
        runMergeDataLossMigrationIfNeeded()
    }

    /// Write the snapshot mirror so the off-main provider
    /// closure can read it without crossing actors. Called from
    /// `CollectorSessionControl.onSessionStateChanged`, which the
    /// self-re-arming observation of `sessionState` schedules on the main
    /// actor after every mutation. Cheap: pure value reads + one
    /// lock-protected pointer write.
    @MainActor
    func refreshLiveHRVSnapshotMirror() {
        let phase = sessionState.recordingPhase
        guard phase != .idle else {
            liveHRVSnapshotMirror.withLock { $0 = nil }
            return
        }
        let mirror = LiveHRVSnapshotMirror(
            phaseLabel: phaseMachineLabel(phase),
            phaseDescription: phaseHumanLabel(phase),
            isCollecting: sessionState.isCollecting,
            beatCount: sessionState.collectedPoints.count,
            sessionStartAt: sessionState.currentSession?.startDate,
            lastErrorDescription: sessionState.lastError.map { ($0 as NSError).localizedDescription }
        )
        liveHRVSnapshotMirror.withLock { $0 = mirror }
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
        let timerBox = streamingTimerBox
        if Thread.isMainThread {
            timerBox.withLockUnchecked { $0?.invalidate() }
        } else {
            DispatchQueue.main.async { timerBox.withLockUnchecked { $0?.invalidate() } }
        }
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

extension RRCollector {
    /// One stored copy of an archived session: its id and the hash of its
    /// file, which every rewrite of the session changes.
    struct ArchivedCopy: Hashable, Sendable {
        let sessionId: UUID
        let fileHash: String

        init(_ entry: SessionArchiveEntry) {
            sessionId = entry.sessionId
            fileHash = entry.fileHash
        }
    }

    /// A replacing rebuild whose archive changed while it decoded starts
    /// over, handing on what it decoded by stored copy.
    @MainActor
    fileprivate func restartReplacingRebuild(reusing decoded: [ArchivedCopy: HRVSession]) {
        rebuildBaselineOffMain(replacing: true, reusing: decoded)
    }

    /// The off-main decode behind `rebuildBaselineOffMain(replacing:)`.
    /// Sessions in `decoded` (an earlier pass's, by id and file hash) are
    /// taken as they are; the archive's other entries, new or rewritten since,
    /// are decrypted.
    @MainActor
    fileprivate func rebuildBaselineOffMain(replacing: Bool, reusing decoded: [ArchivedCopy: HRVSession]) {
        let archive = self.archive
        let copies = archive.entries.map(ArchivedCopy.init)
        Task.detached(priority: .utility) {
            let read = Self.decodedSessions(of: copies, reusing: decoded, from: archive)
            let sessions = read.map { $0.1 }
            let byCopy = Dictionary(read, uniquingKeysWith: { first, _ in first })
            await MainActor.run { [weak self] in
                self?.commitRebuiltBaseline(sessions, decoded: byCopy, copies: copies, replacing: replacing)
            }
        }
    }

    /// Each copy's session: the one decoded earlier for that same copy, else
    /// decrypted lightweight; an unreadable copy is left out.
    nonisolated private static func decodedSessions(
        of copies: [ArchivedCopy], reusing decoded: [ArchivedCopy: HRVSession], from archive: SessionArchive
    ) -> [(ArchivedCopy, HRVSession)] {
        copies.compactMap { copy in
            (decoded[copy] ?? archive.retrieveLightweightOrLog(copy.sessionId, caller: "baselineRebuild")).map { (copy, $0) }
        }
    }
}

// MARK: - File-scope helpers
//
// Kept outside RRCollector. Each names no member of the type and calls
// nothing inside it, so none needs to be a member. `private` at file
// scope is fileprivate, so every call site in this file resolves.

/// Whether the archive holds a night or nap, the only sessions a strap
/// recording is saved into, that was running at `date`: one that started no
/// more than `slackMinutes` after it and had not ended before it. One with no
/// end, or ending sooner, counts as running for `slackMinutes` after its
/// start. A quick reading or a workout that ended just before is not one.
private func archiveHoldsSession(runningAt date: Date, slackMinutes: Int, in archive: SessionArchive) -> Bool {
    let slack = TimeInterval(slackMinutes * 60)
    return archive.entries.contains { entry in
        guard entry.sessionType == .overnight || entry.sessionType == .nap else { return false }
        let runsUntil = max(entry.endDate ?? entry.date, entry.date.addingTimeInterval(slack))
        return entry.date.addingTimeInterval(-slack) <= date && date <= runsUntil
    }
}

@MainActor
private func phaseMachineLabel(_ phase: RecordingPhase) -> String {
    switch phase {
    case .idle: "idle"
    case .streaming: "streaming"
    case .overnightStreaming: "overnight"
    case .deviceRecording: "deviceRecording"
    case .paused: "paused"
    case .analyzing: "analyzing"
    case .awaitingAcceptance: "awaitingAcceptance"
    }
}

/// In the app language: the assistant is told to quote it to the user.
@MainActor
private func phaseHumanLabel(_ phase: RecordingPhase) -> String {
    let bundle = LanguageManager.appBundle
    switch phase {
    case .idle: return String(localized: "Idle", bundle: bundle)
    case let .streaming(target):
        return String(localized: "Quick streaming (target \(LocalizedDuration.minutes(target / 60)))", bundle: bundle)
    case .overnightStreaming: return String(localized: "Overnight recording", bundle: bundle)
    case .deviceRecording: return String(localized: "Device-internal recording", bundle: bundle)
    case .paused: return String(localized: "Paused", bundle: bundle)
    case .analyzing: return String(localized: "Analyzing", bundle: bundle)
    case .awaitingAcceptance: return String(localized: "Awaiting session review", bundle: bundle)
    }
}
