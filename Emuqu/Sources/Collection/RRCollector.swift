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
    /// The current (as-of-today) training load. Never holds a past day's.
    var cachedTrainingLoad: HealthKitManager.TrainingLoad?
    /// Loads fetched as of a past day, keyed by that day's start, for the
    /// duration of a reanalysis of a session from that day.
    var pastDayTrainingLoads: [Date: HealthKitManager.TrainingLoad] = [:]
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

    /// True when the strap holds a recording the app has never downloaded
    /// (`StrapRecordingPolicy.holdsUnrecoveredRecording`). The strap keeps
    /// every downloaded recording as a backup, so holding one is not enough.
    var hasUnrecoveredData: Bool {
        guard polarManager.hasStoredExercise, let start = polarManager.storedExerciseDate else { return false }
        return !isStrapRecordingSaved(startedAt: start)
    }

    /// Whether the app holds the strap recording that began at `start`
    /// (`StrapRecordingPolicy.recordingIsSaved`). The strap's start sequence
    /// asks the same question before it clears the strap.
    func isStrapRecordingSaved(startedAt start: Date) -> Bool {
        let ledger = polarManager.downloadLedger
        return StrapRecordingPolicy.recordingIsSaved(
            alreadyDownloaded: ledger.wasDownloaded(recordingStartedAt: start),
            predatesDownloadRecord: ledger.predatesRecord(start),
            archiveHasSessionNearStart: archive.hasSessionNear(date: start, toleranceMinutes: 30)
        )
    }

    /// What the Record screen's Recover card offers: a recording the app has
    /// never downloaded, or one still running on the strap that no session of
    /// this app owns (left by a crash, or started on the strap). Recover stops
    /// a running one before it downloads.
    var offersStrapRecovery: Bool {
        hasUnrecoveredData || recovery.strapHoldsOrphanedRecording
    }

    /// Create a TrainingContext snapshot from the training load as of
    /// `referenceDate`. Nil for a past day whose load has not been fetched:
    /// today's load must never stand in for an earlier day's.
    func createTrainingContext(relativeTo referenceDate: Date = Date()) -> TrainingContext? {
        guard let load = trainingLoad(asOf: referenceDate) else { return nil }
        return trainingContext(from: load, relativeTo: referenceDate)
    }

    /// Today reads the shared current-load cache; a past day reads only a
    /// load fetched for that day.
    func trainingLoad(asOf date: Date) -> HealthKitManager.TrainingLoad? {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return cachedTrainingLoad }
        return pastDayTrainingLoads[calendar.startOfDay(for: date)]
    }

    private func trainingContext(from load: HealthKitManager.TrainingLoad, relativeTo referenceDate: Date) -> TrainingContext? {
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
    ///   • If a load as of `referenceDate` is held (the shared cache for
    ///     today, a fetched past-day load otherwise) → use it.
    ///   • Else, with training-load integration enabled → fetch via HealthKit
    ///     as of that date and build the context. The fetch fills the shared
    ///     cache only when it is as of today: the cache is the current load,
    ///     and a past day's load left there would be read as today's.
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
        if Calendar.current.isDateInToday(referenceDate) { cachedTrainingLoad = load }
        return trainingContext(from: load, relativeTo: referenceDate)
    }

    /// Baseline to score `session` against: the stored nights before the
    /// session's own, so a reading is never compared with itself or with
    /// nights recorded after it.
    func scoringBaselineStats(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session, sleepSchedule: settingsManager.settings.sleepSchedule
        )
    }

    /// Current scoring configuration for RecoveryScoreCalculator.
    /// Built at the boundary (imperative shell) from SettingsManager.
    var currentScoringConfig: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(from: settingsManager.settings)
    }

    /// Current ANS configuration for analysis pipeline.
    /// Built at the boundary (imperative shell) from SettingsManager + cached training load.
    var currentANSConfig: HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: Date())
    }

    /// ANS configuration with the training load as of `date` — a past
    /// session's analysis reads that day's load, not today's. The baseline is
    /// every stored night; scoring a specific session uses
    /// `ansConfig(for:)` instead.
    func ansConfig(asOf date: Date) -> HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: date, baseline: baselineTracker.recoveryBaselineStats)
    }

    /// ANS configuration for analysing `session`: the training load as of its
    /// end (now, for a session still being recorded) and the same prior-nights
    /// baseline its recovery score uses (`scoringBaselineStats(for:)`), so
    /// re-analysing an old night never normalises readiness against nights
    /// recorded after it.
    func ansConfig(for session: HRVSession) -> HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: session.endDate ?? Date(), baseline: scoringBaselineStats(for: session))
    }

    private func ansConfig(
        asOf date: Date,
        baseline: BaselineTracker.RecoveryBaselineStats?
    ) -> HRVAnalysisPipeline.ANSConfiguration {
        let settings = settingsManager.settings
        let load = trainingLoad(asOf: date)
        // Readiness starts from the same geometric baseline the recovery score
        // uses (exp(lnRmssdMean), last 60 stored nights), so both read ONE "your typical
        // RMSSD" value; each still transforms it differently (age-norm/DFA for
        // readiness, personal-delta for recovery). Falls back to the legacy
        // settings baseline, then population, until BaselineTracker has
        // accumulated enough data.
        let baselineRMSSD = baseline.map { exp($0.lnRmssdMean) }
            ?? settings.baselineRMSSD ?? settings.populationBaselineRMSSD

        return HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: baselineRMSSD,
            vo2Max: configuredVO2Max(load),
            trainingLoadAdjustment: configuredTrainingLoadAdjustment(load)
        )
    }

    /// Explicit override wins, then the HealthKit-derived value when the user
    /// opted into it, else nothing.
    private func configuredVO2Max(_ load: HealthKitManager.TrainingLoad?) -> Double? {
        let settings = settingsManager.settings
        if let override = settings.vo2MaxOverride {
            return override
        }
        return settings.useHealthKitVO2Max ? load?.vo2Max : nil
    }

    private func configuredTrainingLoadAdjustment(_ load: HealthKitManager.TrainingLoad?) -> Double {
        guard settingsManager.settings.enableTrainingLoadIntegration, let load else { return 0 }
        return load.readinessAdjustment
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
    private func rebuildBaselineOffMain(replacing: Bool = false) {
        let archive = self.archive
        let entries = archive.entries
        Task.detached(priority: .utility) {
            let sessions = entries.compactMap {
                archive.retrieveLightweightOrLog($0.sessionId, caller: "baselineRebuild")
            }
            await MainActor.run { [weak self] in self?.commitRebuiltBaseline(sessions, replacing: replacing) }
        }
    }

    /// Rebuild the baseline from what the archive holds now. Used after a
    /// night the baseline had already taken in is discarded.
    @MainActor
    func rebuildBaselineFromArchive() {
        rebuildBaselineOffMain(replacing: true)
    }

    /// A replacing rebuild starts from an empty tracker. A boot rebuild
    /// re-checks instead: if a live session landed while we were decrypting,
    /// it already seeded the tracker, so the rebuild must not clobber it.
    @MainActor
    private func commitRebuiltBaseline(_ sessions: [HRVSession], replacing: Bool) {
        if replacing {
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

    /// The collector's errors (`RRCollectorError`), named from inside it.
    typealias CollectorError = RRCollectorError

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
