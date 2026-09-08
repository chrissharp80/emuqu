import Combine
import Foundation
import os

/// RR interval collector - orchestrates Polar device recording and analysis.
///
/// Responsibilities are split across extension files by concern:
///   +Bindings         – PolarManager state forwarding
///   +Lifecycle        – Persisted recording state, data rescue, emergency backup
///   +DeviceRecording  – H10/Verity Sense internal recording start/stop
///   +Streaming        – Quick streaming mode (3-5 min)
///   +OvernightStreaming – Background overnight streaming with hybrid data
///   +PauseResume      – Pause, resume, finalize overnight recording
///   +MorningProcessing – Thin wrapper delegating to MorningProcessingService
///   +Acceptance       – Accept/reject session, HealthKit export
///   +Analysis         – HRV analysis helpers, recovery score computation
///   +Recovery         – Device recovery, backup recovery, corrupted sessions
///   +Reanalysis       – Re-analyze sessions, manual window selection
///   +Import           – Save imported sessions
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

    // MARK: - Device Refinement Notification

    /// Published when background device fetch produces a different result.
    /// The user can choose to apply or dismiss the refinement.
    struct DeviceRefinement: Equatable {
        let refinedSession: HRVSession
        let originalReadiness: Double
        let refinedReadiness: Double
        let improved: Bool

        static func == (lhs: DeviceRefinement, rhs: DeviceRefinement) -> Bool {
            lhs.refinedSession.id == rhs.refinedSession.id &&
            lhs.originalReadiness == rhs.originalReadiness &&
            lhs.refinedReadiness == rhs.refinedReadiness &&
            lhs.improved == rhs.improved
        }
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
    /// the strap at wake instead. Reset at the start/stop of every session.
    var overnightDeviceBackupActive: Bool = false

    // Archive update trigger — moved to a dedicated `ArchiveSignal` object so
    // views that only care about archive changes don't observe the full
    // collector (whose state also changes on BLE + streaming +
    // recording updates).
    //
    // Back-compat accessor so non-SwiftUI internals and tests can still read
    // the value via `collector.archiveVersion`. SwiftUI views should observe
    // `archiveSignal` directly via `@EnvironmentObject` / `@ObservedObject`.
    var archiveVersion: Int { archiveSignal.version }

    // Proxied PolarManager state moved to a dedicated `DeviceStatus` object
    // so views that only care about BLE connection / battery / device
    // recording state don't re-render on every archive / streaming /
    // morning-processing property the collector also publishes.
    //
    // Writers: `RRCollector+Bindings.setupBindings()` pushes PolarManager
    // updates into `deviceStatus`. Back-compat computed getters below
    // forward existing `collector.isDeviceConnected` / `collector.batteryLevel`
    // etc. reads through to the new object. SwiftUI views should observe
    // `deviceStatus` directly via `@EnvironmentObject`.
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
    var cancellables = Set<AnyCancellable>()

    /// Tokens for the block-based NotificationCenter observers
    /// registered in `+Reanalysis` (rescore listener + CloudKit snapshot
    /// backfill). Stored so `deinit` can remove them; discarding the
    /// `addObserver` return value leaks the observer (and the captured
    /// `self`) in tests/previews that build many collectors.
    /// Combine subscriptions in `cancellables` auto-cancel on dealloc, but
    /// block observers do not — they must be removed explicitly.
    @ObservationIgnored let notificationObservers = NotificationTokens()
    var lastSeenReconnectCount: Int = 0
    var cachedTrainingLoad: HealthKitManager.TrainingLoad?
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
    let backgroundAudioManager: BackgroundAudioManager
    let backgroundLocationManager: BackgroundLocationManager
    let acceptanceService: SessionAcceptanceService
    let morningProcessingService: MorningProcessingService
    let archiveSignal: ArchiveSignal
    let deviceStatus: DeviceStatus
    let streamingLifecycle: StreamingLifecycle
    let morningCoordination: MorningCoordination
    let sessionState: SessionState

    /// Thread-safe mirror of the live HRV snapshot. Written
    /// only from MainActor (via `refreshLiveHRVSnapshotMirror` on every
    /// sessionState change). Read from any thread by the
    /// `LiveHRVBroker` provider closure WITHOUT crossing actors — no
    /// more `DispatchQueue.main.sync` from off-main. The lock protects
    /// the struct write/read; the struct itself only contains Sendable
    /// fields. `nonisolated(unsafe)` is honest: the compiler isn't
    /// verifying the lock discipline; the maintainer is. Every read or
    /// write of `_liveHRVSnapshotMirror` MUST be paired with
    /// `liveHRVSnapshotMirrorLock.lock()` / `.unlock()`.
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

    /// Cached reanalysis service — created lazily on first access in the extension.
    var _reanalysisService: ReanalysisService?

    /// Re-entrancy guard. Multiple paths can trigger
    /// `reanalyzeSession` for the same session in quick succession:
    /// pull-to-refresh, the sleep-delta rescore notification, the
    /// training-cache-heal notification. Without this guard each one
    /// fires its own reanalysis pass — the user sees back-to-back
    /// re-runs in the log and the 8-second pull-to-refresh timer
    /// often loses its race because reanalysis #1 finishes but #2
    /// starts and competes. Sessions in this set are currently being
    /// reanalyzed; subsequent calls for the same id no-op until the
    /// in-flight one finishes.
    var inFlightReanalyses: Set<UUID> = []

    /// Reentrancy guard for `autoRefreshTodaysSleepIfImproved`. Apple writes
    /// sleep in STAGES (each bumps `sleepDataVersion`), so without this the
    /// overlapping invocations each read the session before any sibling wrote,
    /// all detect the source upgrade, and all post a rescore → a redundant
    /// double reanalysis. `…Pending` records that a bump arrived mid-run so we
    /// do exactly one trailing pass against the freshly-written state.
    var isAutoRefreshingSleep = false
    var autoRefreshSleepPending = false

    /// Data quality verification (overnight sessions - strict)
    let verification = Verification()

    /// Data quality verification (streaming - relaxed for short readings)
    let streamingVerification = Verification(config: Verification.Config(
        minPoints: 120,
        minDurationHours: 0.025,
        maxArtifactPercent: 20.0,
        warnArtifactPercent: 10.0
    ))

    // MARK: - Computed Properties

    /// All archived sessions for trend analysis.
    /// WARNING: Loads every session from disk. Prefer `recentSessions(limit:)` for UI paths.
    var archivedSessions: [HRVSession] {
        recentSessions(limit: nil)
    }

    /// Load the most recent `limit` sessions from the archive (sorted newest-first).
    /// Uses the lightweight in-memory index to pick entries, then only deserializes
    /// the selected subset from disk. Pass `nil` for no limit (loads all).
    ///
    /// **Prefer `recentSessionsAsync(limit:)` from UI code** — it moves the disk
    /// I/O off the main thread.
    func recentSessions(limit: Int?) -> [HRVSession] {
        let allEntries = archive.entries  // already sorted newest-first
        let entries = limit.map { Array(allEntries.prefix($0)) } ?? allEntries
        debugLog("[RRCollector] recentSessions(limit: \(limit.map(String.init) ?? "all")): Loading \(entries.count) of \(allEntries.count) entries from archive")
        var sessions: [HRVSession] = []
        var errorCount = 0
        for entry in entries {
            if let session = retrieveLoggingFailure(entry.sessionId) {
                sessions.append(session)
            } else {
                errorCount += 1
            }
        }
        debugLog("[RRCollector] recentSessions: Loaded \(sessions.count) sessions (\(errorCount) errors)")
        return sessions
    }

    /// Nil covers both "not in the archive" and "failed to decode"; both are
    /// logged and counted as errors by the caller.
    private func retrieveLoggingFailure(_ sessionId: UUID) -> HRVSession? {
        do {
            guard let session = try archive.retrieve(sessionId) else {
                debugLog("[RRCollector] WARNING: Session \(sessionId) not found in archive (nil)")
                return nil
            }
            return session
        } catch {
            debugLog("[RRCollector] ERROR: Failed to retrieve session \(sessionId): \(error)")
            return nil
        }
    }

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

    /// Decrypt the sessions in PARALLEL. `retrieveLightweight` holds
    /// `archiveLock` only for the index lookup, not across the file
    /// read+decrypt, so a TaskGroup fans the ~35-session decode across cores
    /// instead of a one-at-a-time loop that leaves the dashboard lingering on
    /// empty placeholders. Order is preserved by index.
    private static func decodeInParallel(_ entries: [SessionArchiveEntry], archive: SessionArchive) async -> [HRVSession] {
        await withTaskGroup(of: (Int, HRVSession?).self) { group in
            addDecodeTasks(&group, entries: entries, archive: archive)
            return await collectIndexed(group, capacity: entries.count)
        }
    }

    private static func addDecodeTasks(
        _ group: inout TaskGroup<(Int, HRVSession?)>,
        entries: [SessionArchiveEntry],
        archive: SessionArchive
    ) {
        for (i, entry) in entries.enumerated() {
            group.addTask { (i, archive.retrieveLightweightOrLog(entry.sessionId)) }
        }
    }

    /// Drain the group, dropping the sessions that failed to decode and
    /// restoring the caller's original ordering.
    private static func collectIndexed(
        _ group: TaskGroup<(Int, HRVSession?)>,
        capacity: Int
    ) async -> [HRVSession] {
        var indexed: [(Int, HRVSession)] = []
        indexed.reserveCapacity(capacity)
        for await (i, session) in group {
            session.map { indexed.append((i, $0)) }
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Load a single full session (with rrSeries) on a background thread.
    /// Use this after picking the dashboard's active session to get chart data.
    func retrieveFullSessionAsync(_ id: UUID) async -> HRVSession? {
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(id)
        }.value
    }

    /// Load a single session WITHOUT rrSeries on a background thread.
    /// Use this for the dashboard hero — the rrSeries payload is the
    /// heaviest part of a session file (~700 KB – 1.5 MB) and isn't
    /// needed for the score / snapshots / analysisResult that the hero
    /// renders. Chart-level views (RecoveryScoreDetailView,
    /// OvernightChartsView, HRVDetailView) already detect rrSeries == nil
    /// and lazy-load the full session themselves.
    ///
    /// This collapses the dashboard cold-load cost
    /// from ~15-50 ms per session (SHA256 + decrypt + full JSON decode
    /// under archiveLock) to a fraction of that — the lightweight path
    /// skips the hash check and tells the decoder to drop the rrSeries
    /// payload.
 
    /// True if H10 has stored data not already in the archive
    var hasUnrecoveredData: Bool {
        guard polarManager.hasStoredExercise,
              let exerciseDate = polarManager.storedExerciseDate else {
            return false
        }
        return !archive.hasSessionNear(date: exerciseDate, toleranceMinutes: 30)
    }

    /// Create a TrainingContext snapshot from cached training load
    func createTrainingContext(relativeTo referenceDate: Date = Date()) -> TrainingContext? {
        guard let load = cachedTrainingLoad else { return nil }
        guard var context = TrainingContext(from: load, relativeTo: referenceDate) else { return nil }
        // Apply user VO2max override — TrainingContext.init copies the HealthKit
        // value from TrainingLoad, but the user's manual entry takes priority.
        let settings = settingsManager.settings
        if let override = settings.vo2MaxOverride {
            context.vo2Max = override
        } else if !settings.useHealthKitVO2Max {
            context.vo2Max = nil
        }
        return context
    }

    /// Async sibling of `createTrainingContext` that guarantees a fresh
    /// fetch when the cache is empty. Use this before freezing a session's
    /// recovery score so we can't accidentally freeze a Tier 2 number
    /// just because `cachedTrainingLoad` hadn't populated yet (cold-launch
    /// race after wake-up, seen in a real-user report).
    ///
    /// Behaviour:
    ///   • If `cachedTrainingLoad` is set → behave like `createTrainingContext`.
    ///   • If cache is nil AND training-load integration is enabled →
    ///     fetch via HealthKit, populate the cache, build the context.
    ///   • If integration is disabled → return nil (Tier 2 scoring is
    ///     intentional in that mode).
    func createTrainingContextEnsuringFresh(relativeTo referenceDate: Date = Date()) async -> TrainingContext? {
        if let context = createTrainingContext(relativeTo: referenceDate) {
            return context
        }
        guard settingsManager.settings.enableTrainingLoadIntegration else {
            return nil
        }
        debugLog("[RRCollector] createTrainingContext returned nil with training-load integration ON — fetching live HealthKit training load to ensure Tier 3 freeze (relativeTo \(referenceDate))", level: .info)
        let load = await healthKit.calculateTrainingLoad(relativeTo: referenceDate)
        cachedTrainingLoad = load
        return createTrainingContext(relativeTo: referenceDate)
    }

    /// Current scoring configuration for RecoveryScoreCalculator.
    /// Built at the boundary (imperative shell) from SettingsManager.
    var currentScoringConfig: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(from: settingsManager.settings)
    }

    /// Current ANS configuration for analysis pipeline.
    /// Built at the boundary (imperative shell) from SettingsManager + cached training load.
    var currentANSConfig: HRVAnalysisPipeline.ANSConfiguration {
        let settings = settingsManager.settings
        // Use the CANONICAL geometric baseline the recovery score
        // uses (exp(lnRmssdMean), 60-day) so readiness and recovery start from
        // ONE "your typical RMSSD" value; each still transforms it differently
        // (age-norm/DFA for readiness, personal-delta for recovery). This
        // retires the 5th baseline — `settings.baselineRMSSD` was a separate
        // 14-day ARITHMETIC morning mean (higher than the geometric mean by
        // Jensen), so readiness was normalised against a different number than
        // recovery. Falls back to the legacy settings baseline, then population,
        // until BaselineTracker has accumulated enough data.
        let baselineRMSSD = baselineTracker.recoveryBaselineStats.map { exp($0.lnRmssdMean) }
            ?? settings.baselineRMSSD ?? settings.populationBaselineRMSSD

        return HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: baselineRMSSD,
            vo2Max: configuredVO2Max,
            trainingLoadAdjustment: configuredTrainingLoadAdjustment
        )
    }

    /// Explicit override wins, then the HealthKit-derived value when the user
    /// opted into it, else nothing.
    private var configuredVO2Max: Double? {
        let settings = settingsManager.settings
        if let override = settings.vo2MaxOverride {
            return override
        }
        return settings.useHealthKitVO2Max ? cachedTrainingLoad?.vo2Max : nil
    }

    private var configuredTrainingLoadAdjustment: Double {
        guard settingsManager.settings.enableTrainingLoadIntegration,
              let load = cachedTrainingLoad else { return 0 }
        return load.readinessAdjustment
    }

    // MARK: - Initialization

    /// Wiring-layer factory: resolves the app's shared managers and returns a
    /// fully-configured collector. This is the canonical production entry
    /// point — refactor spec §10 ("Explicit Dependency Wiring") calls for a
    /// single wiring layer that is allowed to touch `.shared` instances,
    /// rather than business logic reaching for the world inside its own init.
    /// The main app scene calls this; every other layer receives the collector
    /// via `@EnvironmentObject` / initializer injection so tests and previews
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
        // archive a session) — that path stays through @EnvironmentObject
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
        guard !didBootBaseline.withLock({ $0 }) else { return }
        didBootBaseline.withLock { $0 = true }
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
    @MainActor
    private func rebuildBaselineOffMain() {
        let archive = self.archive
        let entries = archive.entries
        Task.detached(priority: .utility) {
            let sessions = entries.compactMap {
                archive.retrieveLightweightOrLog($0.sessionId, caller: "baselineRebuild")
            }
            await MainActor.run { [weak self] in self?.commitRebuiltBaseline(sessions) }
        }
    }

    /// Re-check: if a live session landed while we were decrypting, it already
    /// seeded the tracker — don't clobber it with the rebuild.
    @MainActor
    private func commitRebuiltBaseline(_ sessions: [HRVSession]) {
        guard baselineTracker.daysCollected == 0 else { return }
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
    private convenience init(defaultsFromShared _: Void) {
        let settingsManager = AppDependencies.current.app.settingsManager
        let archive = AppDependencies.current.storage.sessionArchive
        let tracker = BaselineTracker(onBaselineUpdated: { rmssd, hr in
            settingsManager.updateBaseline(rmssd: rmssd, hr: hr)
        })
        self.init(
            polarManager: PolarManager(),
            healthKit: AppDependencies.current.collection.healthKitManager,
            archive: archive,
            rawBackup: RawRRBackup(),
            artifactDetector: ArtifactDetector(),
            windowSelector: WindowSelector(),
            baselineTracker: tracker,
            settingsManager: settingsManager
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
    /// Create an RRCollector with injected dependencies (for testing).
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
        backgroundAudioManager: BackgroundAudioManager? = nil,
        // Default `nil` instead of `AppDependencies.current.location.backgroundLocationManager`
        // because Swift 6 evaluates default-parameter expressions in a
        // nonisolated context and `.shared` is `@MainActor`-isolated.
        // We resolve to `.shared` inside the init body (which IS
        // MainActor-isolated by the class annotation).
        backgroundLocationManager: BackgroundLocationManager? = nil,
        reconciliation: ReconciliationManager? = nil,
        analysisPipeline: HRVAnalysisPipeline? = nil,
        sleepBoundaryResolver: SleepBoundaryResolver? = nil,
        acceptanceService: SessionAcceptanceService? = nil,
        morningProcessingService: MorningProcessingService? = nil,
        archiveSignal: ArchiveSignal? = nil,
        deviceStatus: DeviceStatus? = nil,
        streamingLifecycle: StreamingLifecycle? = nil,
        morningCoordination: MorningCoordination? = nil,
        sessionState: SessionState? = nil
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
        let resolvedCloudSyncManager = cloudSyncManager ?? AppDependencies.current.storage.cloudKitSyncManager
        self.cloudSyncManager = resolvedCloudSyncManager
        self.backgroundAudioManager = backgroundAudioManager ?? AppDependencies.current.collection.backgroundAudioManager
        self.backgroundLocationManager = backgroundLocationManager ?? AppDependencies.current.location.backgroundLocationManager
        self.reconciliation = reconciliation ?? ReconciliationManager(archive: archive)
        let resolvedPipeline = analysisPipeline ?? Self.makePipeline(
            artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit
        )
        self.analysisPipeline = resolvedPipeline
        self.sleepBoundaryResolver = sleepBoundaryResolver ?? SleepBoundaryResolver(healthKit: healthKit)
        self.acceptanceService = acceptanceService ?? Self.makeAcceptanceService(
            archive: archive, healthKit: healthKit, baselineTracker: baselineTracker,
            rawBackup: rawBackup, polarManager: polarManager, cloudSync: resolvedCloudSyncManager
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
    /// own argument list, and inline they would dominate the 20-parameter
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
        polarManager: PolarManager,
        cloudSync: CloudKitSyncManager
    ) -> SessionAcceptanceService {
        SessionAcceptanceService(
            archive: archive,
            healthKit: healthKit,
            baselineTracker: baselineTracker,
            rawBackup: rawBackup,
            onDiscardExercise: { [weak polarManager] in
                polarManager?.discardPendingExercise()
            },
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
    /// place: observation, listeners, cache binding, state restoration and the
    /// one-time migration.
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
        installRescoreListener()
        installCloudKitSnapshotBackfillListener()
        restorePausedStateIfNeeded()
        refreshRecentPausedSession()
        publishLiveHRVSnapshotsToAssistant()
        armObservationLoops()
        runMergeDataLossMigrationIfNeeded()
    }

    /// Write the snapshot mirror so the off-main provider
    /// closure can read it without crossing actors. Called from a
    /// MainActor Combine sink on every sessionState mutation. Cheap:
    /// pure value reads + one lock-protected pointer write.
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

    enum CollectorError: Error, LocalizedError {
        case notConnected
        case alreadyRecording
        case sessionExists
        case insufficientData
        case noSessionToAccept
        case noSessionToRecover
        case dataAlreadyExists

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Polar device not connected"
            case .alreadyRecording:
                return "A recording is already in progress on the device"
            case .sessionExists:
                return "A session with this ID already exists"
            case .insufficientData:
                return "Not enough RR data collected (need at least 120 beats)"
            case .noSessionToAccept:
                return "No completed session to accept"
            case .noSessionToRecover:
                return "No session found to recover data into"
            case .dataAlreadyExists:
                return "Session already has this RR data - no recovery needed"
            }
        }
    }

    // Leak guard. RRCollector installs a `streamingTimer` and
    // block-based NotificationCenter observers (in `+Reanalysis`); without
    // teardown every collector built in a test/preview leaks its
    // timer and observers (and the `self` they captured). Combine
    // subscriptions in `cancellables` clean themselves up on dealloc; the
    // timer and block observers must be released by hand.
    deinit {
        streamingTimerBox.withLockUnchecked { $0?.invalidate() }
        notificationObservers.removeAll()
    }
}

// MARK: - File-scope helpers
//
// Kept outside RRCollector. Each names no member of the type and calls
// nothing inside it, so none needs to be a member. `private` at file
// scope is fileprivate, so every call site in this file resolves.

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

@MainActor
private func phaseHumanLabel(_ phase: RecordingPhase) -> String {
    switch phase {
    case .idle: "Idle"
    case let .streaming(target): "Quick streaming (target \(target / 60)m)"
    case .overnightStreaming: "Overnight recording"
    case .deviceRecording: "Device-internal recording"
    case .paused: "Paused"
    case .analyzing: "Analyzing"
    case .awaitingAcceptance: "Awaiting session review"
    }
}
