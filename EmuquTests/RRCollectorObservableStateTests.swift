import Combine
@testable import Emuqu
import Observation
import XCTest

/// Characterization tests for RRCollector's observable surface (`@Observable` state and its sub-observables).
///
/// These tests pin down current behavior of the state/signal layer so that
/// structural refactors (splitting RRCollector into narrower observables)
/// do not silently change semantics. They are intentionally behavior-level,
/// not implementation-level — they would remain meaningful if the underlying
/// property lives on a sub-object rather than the collector.
@MainActor
final class RRCollectorObservableStateTests: XCTestCase {
    /// `lazy`, not an inline initialiser: `setUp` sets the host's persisted
    /// state aside first, and a stored property would be constructed before
    /// that runs — handing the collector the very state the test just asked
    /// to be rid of. Deferring to first use inside the test body keeps the
    /// original ordering.
    ///
    /// Wired like the app's own collector, except that the archive, the raw
    /// backups and the baseline tracker live in this test's temporary
    /// directory instead of the host app's App Group container. The settings manager is still the
    /// host's: `SettingsManager` cannot be made a second time, so the ANS tests
    /// restore what they change.
    lazy var collector = RRCollector(
        polarManager: PolarManager(),
        healthKit: AppDependencies.current.collection.healthKitManager,
        archive: SessionArchive(directory: storageDirectory),
        rawBackup: RawRRBackup(directory: storageDirectory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
        baselineTracker: BaselineTracker(baselineFile: storageDirectory.appendingPathComponent("HRVBaseline.json")),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )
    var cancellables: Set<AnyCancellable> = []

    nonisolated private let storageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RRCollectorObservableState-\(UUID().uuidString)", isDirectory: true)

    /// The host's persisted recording state, set aside for the test and put
    /// back in `tearDown`, so a recording the host was interrupted in keeps
    /// its recovery marker.
    private var hostRecordingState: HostDefaults?

    override func setUp() async throws {
        try await super.setUp()
        hostRecordingState = HostDefaults.setAside(HostDefaults.recordingState)
        cancellables = []
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        if let session = collector.sessionState.currentSession {
            _ = try? collector.archive.delete(session.id)
        }
        hostRecordingState?.restore()
        try FileManager.default.removeItem(at: storageDirectory)
        try await super.tearDown()
    }

    // MARK: - archiveVersion

    /// `ArchiveSignal` COALESCES version bumps: a `notifyChanged()` does not
    /// increment `version` synchronously — it schedules a single bump at the
    /// end of an 80 ms window (`ArchiveSignal.coalesceWindow`, which
    /// exists because a CloudKit full-sync pull can fire 37 back-to-back
    /// archive notifications). Two notifies inside one window fold into ONE
    /// bump, so tests that need N distinct bumps must wait each one out
    /// before firing the next. This helper polls (yielding the main actor so
    /// the coalesce task can run) until `version` reaches the expectation.
    /// Wait for `signal.version` to reach `expected`, then assert it did.
    ///
    /// The timeout is a safety net, not a pace: the loop returns the moment the
    /// version lands, so a generous deadline costs a passing test nothing and
    /// only changes how long a genuinely broken one waits before failing.
    ///
    /// A 1.0 s deadline against an 80 ms coalescing window
    /// is ample on a developer Mac and not ample under Thread Sanitizer, where
    /// everything runs several times slower and the debounce may simply not
    /// have fired yet. Ten seconds is still ~125x the window.
    private func waitForVersion(
        _ signal: ArchiveSignal,
        toReach expected: Int,
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while signal.version < expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms; window is 80 ms
        }
        XCTAssertEqual(
            signal.version, expected,
            "ArchiveSignal.version did not settle at \(expected) within \(timeout)s",
            file: file, line: line
        )
    }

    /// Deadline for the notification/observation waits in this suite.
    ///
    /// Sized for the Thread Sanitizer job, where everything runs several times
    /// slower — see `waitForVersion` for the run that proved a one-second
    /// deadline is not enough there. A waiting test returns as soon as its
    /// expectation is fulfilled, so this only bounds how long a real failure
    /// takes to report.
    private var sanitizerSafeTimeout: TimeInterval { 10.0 }

    func testArchiveVersionStartsAtZero() {
        let collector = isolatedCollector()
        XCTAssertEqual(collector.archiveVersion, 0)
    }

    func testNotifyArchiveChangedIncrementsVersion() async {
        let collector = isolatedCollector()
        let initial = collector.archiveVersion
        collector.archiveSignal.notifyChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 1)
        XCTAssertEqual(collector.archiveVersion, initial + 1)
        collector.archiveSignal.notifyChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 2)
        XCTAssertEqual(collector.archiveVersion, initial + 2)
    }

    func testNotifyArchiveChangedPostsFlowRecoveryArchiveChangedNotification() {
        let exp = expectation(forNotification: .flowRecoveryArchiveChanged, object: nil)
        collector.archiveSignal.notifyChanged()
        wait(for: [exp], timeout: sanitizerSafeTimeout)
    }

    func testArchiveVersionPublishesWhenMutated() async {
        let collector = isolatedCollector()
        // ArchiveSignal is @Observable — no `$version` publisher. Verify the
        // observable `version` increments after a mutation (via the existing
        // coalesce-aware helper).
        let initial = collector.archiveSignal.version
        collector.archiveSignal.notifyChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 1)
        XCTAssertEqual(collector.archiveSignal.version, initial + 1)
    }

    // MARK: - ArchiveSignal back-compat forwarding

    /// A collector whose archive signal listens on a PRIVATE notification
    /// centre, so the exact-count assertions below see only the posts the
    /// test itself makes.
    ///
    /// `ArchiveSignal` observes `.flowRecoveryArchiveChanged`
    /// with `object: nil`. On `NotificationCenter.default` that is every
    /// archive write in the test process — a previous test's tearDown
    /// delete, a collector's launch-time repair — and each one is a bump.
    /// `waitForVersion(toReach: 1)` returns on `>= 1`, so a stray bump made
    /// the follow-up `== 1` fail once in a while. Isolating the centre is
    /// the fix; widening the assertion would only hide it.
    private func isolatedCollector() -> RRCollector {
        RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            archiveSignal: ArchiveSignal(center: NotificationCenter()),
            services: CollectorServices(.current)
        )
    }

    func testArchiveVersionReadsThroughArchiveSignal() async {
        let collector = isolatedCollector()
        XCTAssertEqual(collector.archiveVersion, collector.archiveSignal.version)
        collector.archiveSignal.notifyChanged()
        // The bump lands at the end of the coalesce window, not synchronously.
        await waitForVersion(collector.archiveSignal, toReach: 1)
        XCTAssertEqual(collector.archiveVersion, collector.archiveSignal.version)
        XCTAssertEqual(collector.archiveVersion, 1)
    }

    func testNotifyArchiveChangedForwardsToArchiveSignal() async {
        let collector = isolatedCollector()
        collector.archiveSignal.notifyChanged()
        await waitForVersion(collector.archiveSignal, toReach: 1)
        XCTAssertEqual(collector.archiveSignal.version, 1)
    }

    func testArchiveSignalIsInjectable() async {
        let customSignal = ArchiveSignal(center: NotificationCenter())
        // Coalescing contract: two notifies inside one 80 ms window fold
        // into a SINGLE bump. The intent here is "a pre-incremented signal's
        // version is visible through the injected collector", so wait each
        // bump out to genuinely land version 2 before injecting.
        customSignal.notifyChanged()
        await waitForVersion(customSignal, toReach: 1)
        customSignal.notifyChanged()
        await waitForVersion(customSignal, toReach: 2)
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            archiveSignal: customSignal,
            services: CollectorServices(.current)
        )
        XCTAssertEqual(injected.archiveVersion, 2)
        XCTAssertTrue(injected.archiveSignal === customSignal)
    }

    // MARK: - DeviceStatus back-compat forwarding

    func testDeviceStatusProxiesMatchCollectorGetters() {
        XCTAssertEqual(collector.deviceStatus.isDeviceConnected, collector.deviceStatus.isDeviceConnected)
        XCTAssertEqual(collector.deviceStatus.isStreaming, collector.deviceStatus.isStreaming)
        XCTAssertEqual(collector.deviceStatus.hasStoredExercise, collector.deviceStatus.hasStoredExercise)
        XCTAssertEqual(collector.deviceStatus.batteryLevel, collector.deviceStatus.batteryLevel)
        XCTAssertEqual(collector.deviceStatus.isRecordingOnDevice, collector.deviceStatus.isRecordingOnDevice)
        XCTAssertEqual(collector.deviceStatus.connectedDeviceType, collector.deviceStatus.connectedDeviceType)
        XCTAssertEqual(collector.deviceStatus.recordingState, collector.deviceStatus.recordingState)
        XCTAssertEqual(collector.deviceStatus.connectionState, collector.deviceStatus.connectionState)
        // fetchProgress is a struct — just check both resolve to the same optional state.
        XCTAssertEqual(collector.deviceStatus.fetchProgress == nil, collector.deviceStatus.fetchProgress == nil)
    }

    func testDeviceStatusWriteReflectsInCollectorGetter() {
        collector.deviceStatus.isDeviceConnected = true
        collector.deviceStatus.batteryLevel = 75
        collector.deviceStatus.connectionState = .connected
        XCTAssertTrue(collector.deviceStatus.isDeviceConnected)
        XCTAssertEqual(collector.deviceStatus.batteryLevel, 75)
        XCTAssertEqual(collector.deviceStatus.connectionState, .connected)
    }

    func testDeviceStatusIsInjectable() {
        let customStatus = DeviceStatus()
        customStatus.batteryLevel = 42
        customStatus.isDeviceConnected = true
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            deviceStatus: customStatus,
            services: CollectorServices(.current)
        )
        XCTAssertEqual(injected.deviceStatus.batteryLevel, 42)
        XCTAssertTrue(injected.deviceStatus.isDeviceConnected)
        XCTAssertTrue(injected.deviceStatus === customStatus)
    }

    func testDeviceStatusPublishesWhenBatteryChanges() {
        // DeviceStatus is @Observable — no `$batteryLevel` publisher. Verify the
        // property is observable: a mutation fires the tracking onChange.
        let exp = expectation(description: "deviceStatus.batteryLevel change observed")
        withObservationTracking {
            _ = collector.deviceStatus.batteryLevel
        } onChange: {
            exp.fulfill()
        }
        collector.deviceStatus.batteryLevel = 60
        wait(for: [exp], timeout: sanitizerSafeTimeout)
        XCTAssertEqual(collector.deviceStatus.batteryLevel, 60)
    }

    func testDeviceStatusDefaultInitialValues() {
        let status = DeviceStatus()
        XCTAssertFalse(status.isDeviceConnected)
        XCTAssertFalse(status.isStreaming)
        XCTAssertFalse(status.hasStoredExercise)
        XCTAssertNil(status.batteryLevel)
        XCTAssertFalse(status.isRecordingOnDevice)
        XCTAssertNil(status.connectedDeviceType)
        XCTAssertEqual(status.recordingState, .idle)
        XCTAssertEqual(status.connectionState, .disconnected)
        XCTAssertNil(status.fetchProgress)
    }

    // MARK: - StreamingLifecycle back-compat forwarding

    func testStreamingLifecycleDefaults() {
        let lifecycle = StreamingLifecycle()
        XCTAssertFalse(lifecycle.isStreamingMode)
        XCTAssertEqual(lifecycle.streamingTargetSeconds, 180)
        XCTAssertEqual(lifecycle.streamingElapsedSeconds, 0)
        XCTAssertFalse(lifecycle.isOvernightStreaming)
        XCTAssertFalse(lifecycle.isPaused)
        XCTAssertNil(lifecycle.pausedSession)
        XCTAssertEqual(lifecycle.pausedBeatCount, 0)
    }

    /// The 1 Hz ticks publish the wall clock since the session started, not
    /// a count of themselves: a tick missed while the app was suspended does
    /// not hold the elapsed time back.
    func testTheStreamingClockIsTheWallClockSinceTheStart() {
        collector.streamingLifecycle.streamingElapsedSeconds = 3
        collector.streamingLifecycle.sessionStartTime = Date().addingTimeInterval(-125)
        XCTAssertEqual(collector.streamingLifecycle.streamingElapsedNow, 125, accuracy: 1)

        collector.streamingLifecycle.sessionStartTime = nil
        XCTAssertEqual(collector.streamingLifecycle.streamingElapsedNow, 4, "with no start time a tick counts one on")
    }

    func testStreamingLifecycleForwardsThroughCollector() {
        collector.streamingLifecycle.isStreamingMode = true
        collector.streamingLifecycle.streamingTargetSeconds = 300
        collector.streamingLifecycle.streamingElapsedSeconds = 42
        collector.streamingLifecycle.isOvernightStreaming = true
        collector.streamingLifecycle.isPaused = true
        collector.streamingLifecycle.pausedBeatCount = 1024

        XCTAssertTrue(collector.streamingLifecycle.isStreamingMode)
        XCTAssertEqual(collector.streamingLifecycle.streamingTargetSeconds, 300)
        XCTAssertEqual(collector.streamingLifecycle.streamingElapsedSeconds, 42)
        XCTAssertTrue(collector.streamingLifecycle.isOvernightStreaming)
        XCTAssertTrue(collector.streamingLifecycle.isPaused)
        XCTAssertEqual(collector.streamingLifecycle.pausedBeatCount, 1024)
    }

    func testStreamingLifecycleWritesFromCollectorSetter() {
        collector.streamingLifecycle.isStreamingMode = true
        collector.streamingLifecycle.streamingTargetSeconds = 240
        XCTAssertTrue(collector.streamingLifecycle.isStreamingMode)
        XCTAssertEqual(collector.streamingLifecycle.streamingTargetSeconds, 240)
    }

    func testStreamingLifecycleInjectable() {
        let custom = StreamingLifecycle()
        custom.streamingTargetSeconds = 999
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            streamingLifecycle: custom,
            services: CollectorServices(.current)
        )
        XCTAssertEqual(injected.streamingLifecycle.streamingTargetSeconds, 999)
        XCTAssertTrue(injected.streamingLifecycle === custom)
    }

    // MARK: - MorningCoordination back-compat forwarding

    func testMorningCoordinationDefaults() {
        let coord = MorningCoordination()
        XCTAssertNil(coord.morningStatus)
        XCTAssertEqual(coord.sleepDataVersion, 0)
    }

    func testMorningCoordinationForwardsThroughCollector() {
        collector.morningCoordination.morningStatus = .saving(beats: 500)
        collector.morningCoordination.sleepDataVersion = 7

        XCTAssertEqual(collector.morningCoordination.morningStatus, .saving(beats: 500))
        XCTAssertEqual(collector.morningCoordination.sleepDataVersion, 7)
    }

    func testMorningCoordinationInjectable() {
        let custom = MorningCoordination()
        custom.sleepDataVersion = 42
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            morningCoordination: custom,
            services: CollectorServices(.current)
        )
        XCTAssertEqual(injected.morningCoordination.sleepDataVersion, 42)
        XCTAssertTrue(injected.morningCoordination === custom)
    }

    // MARK: - SessionState back-compat forwarding

    func testSessionStateDefaults() {
        let state = SessionState()
        XCTAssertEqual(state.recordingPhase, .idle)
        XCTAssertFalse(state.isCollecting)
        XCTAssertNil(state.currentSession)
        XCTAssertTrue(state.collectedPoints.isEmpty)
        XCTAssertNil(state.lastError)
        XCTAssertNil(state.verificationResult)
        XCTAssertNil(state.recoveryWindow)
        XCTAssertFalse(state.needsAcceptance)
        XCTAssertNil(state.baselineDeviation)
        XCTAssertNil(state.recentPausedSession)
    }

    func testSessionStateForwardsThroughCollector() {
        let session = HRVSession(sessionType: .nap)
        collector.sessionState.currentSession = session
        collector.sessionState.needsAcceptance = true
        collector.sessionState.recordingPhase = .overnightStreaming

        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
        XCTAssertTrue(collector.sessionState.needsAcceptance)
        XCTAssertEqual(collector.sessionState.recordingPhase, .overnightStreaming)
    }

    func testSessionStateWritesFromCollectorSetter() {
        let session = HRVSession(sessionType: .quick)
        collector.sessionState.currentSession = session
        collector.sessionState.needsAcceptance = true
        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
        XCTAssertTrue(collector.sessionState.needsAcceptance)
    }

    func testSessionStateInjectable() {
        let custom = SessionState()
        custom.recordingPhase = .analyzing
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager.forTests(),
            archive: AppDependencies.current.storage.sessionArchive,
            settingsManager: AppDependencies.current.app.settingsManager,
            sessionState: custom,
            services: CollectorServices(.current)
        )
        XCTAssertEqual(injected.sessionState.recordingPhase, .analyzing)
        XCTAssertTrue(injected.sessionState === custom)
    }

    // MARK: - resetSession

    func testResetSessionClearsSessionAndAcceptanceState() {
        let session = HRVSession(sessionType: .overnight)
        collector.sessionState.currentSession = session
        collector.sessionState.collectedPoints = [RRPoint(t_ms: 0, rr_ms: 800)]
        collector.sessionState.needsAcceptance = true
        collector.streamingLifecycle.isPaused = true

        collector.control.resetSession()

        XCTAssertNil(collector.sessionState.currentSession)
        XCTAssertTrue(collector.sessionState.collectedPoints.isEmpty)
        XCTAssertFalse(collector.sessionState.needsAcceptance)
        XCTAssertFalse(collector.streamingLifecycle.isPaused)
        XCTAssertNil(collector.streamingLifecycle.pausedSession)
        XCTAssertNil(collector.sessionState.verificationResult)
        XCTAssertNil(collector.sessionState.recoveryWindow)
        XCTAssertNil(collector.sessionState.baselineDeviation)
        XCTAssertEqual(collector.sessionState.recordingPhase, .idle)
    }

    // MARK: - MorningProcessingStatus Equatable

    func testMorningProcessingStatusSavingEquality() {
        XCTAssertEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.saving(beats: 100)
        )
        XCTAssertNotEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.saving(beats: 200)
        )
    }

    func testMorningProcessingStatusDifferentCasesAreInequal() {
        XCTAssertNotEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.fetchingDevice(streamingBeats: 100)
        )
    }

    func testMorningProcessingStatusAnalyzingEquality() {
        let a: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "hybrid"
        )
        let b: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "hybrid"
        )
        let c: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "stream"
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - createTrainingContext

    func testCreateTrainingContextReturnsNilWithoutCachedLoad() {
        collector.scoring.cachedTrainingLoad = nil
        XCTAssertNil(collector.scoring.createTrainingContext(relativeTo: Date()))
    }

    // MARK: - ANS configuration

    func testCurrentANSConfigUsesOverrideVO2MaxWhenPresent() {
        let originalOverride = collector.settingsManager.settings.vo2MaxOverride
        let originalUseHK = collector.settingsManager.settings.useHealthKitVO2Max
        defer {
            collector.settingsManager.settings.vo2MaxOverride = originalOverride
            collector.settingsManager.settings.useHealthKitVO2Max = originalUseHK
        }

        collector.settingsManager.settings.vo2MaxOverride = 52.0
        collector.settingsManager.settings.useHealthKitVO2Max = true  // override must still win

        let config = collector.scoring.currentANSConfig
        XCTAssertEqual(config.vo2Max, 52.0)
    }

    func testCurrentANSConfigReturnsNilVO2MaxWhenNoOverrideAndHealthKitDisabled() {
        let originalOverride = collector.settingsManager.settings.vo2MaxOverride
        let originalUseHK = collector.settingsManager.settings.useHealthKitVO2Max
        defer {
            collector.settingsManager.settings.vo2MaxOverride = originalOverride
            collector.settingsManager.settings.useHealthKitVO2Max = originalUseHK
        }

        collector.settingsManager.settings.vo2MaxOverride = nil
        collector.settingsManager.settings.useHealthKitVO2Max = false
        collector.scoring.cachedTrainingLoad = nil

        let config = collector.scoring.currentANSConfig
        XCTAssertNil(config.vo2Max)
    }

    func testCurrentANSConfigZeroAdjustmentWhenTrainingLoadDisabled() {
        let originalFlag = collector.settingsManager.settings.enableTrainingLoadIntegration
        defer { collector.settingsManager.settings.enableTrainingLoadIntegration = originalFlag }

        collector.settingsManager.settings.enableTrainingLoadIntegration = false

        let config = collector.scoring.currentANSConfig
        XCTAssertEqual(config.trainingLoadAdjustment, 0)
    }

    // MARK: - findRecentPausedSessionOffMain (pure static)

    func testFindRecentPausedSessionReturnsNilWhenMaxGapIsZero() {
        let result = CollectorSessionControl.findRecentPausedSessionOffMain(
            archive: collector.archive,
            maxGap: 0
        )
        XCTAssertNil(result)
    }

    func testFindRecentPausedSessionReturnsNilWhenMaxGapIsNegative() {
        let result = CollectorSessionControl.findRecentPausedSessionOffMain(
            archive: collector.archive,
            maxGap: -1
        )
        XCTAssertNil(result)
    }

    // MARK: - Initial published state (pins the current surface shape)

    func testInitialPublishedStateIsQuiescent() {
        XCTAssertEqual(collector.archiveVersion, 0)
        XCTAssertEqual(collector.morningCoordination.sleepDataVersion, 0)
        XCTAssertEqual(collector.streamingLifecycle.streamingElapsedSeconds, 0)
        XCTAssertEqual(collector.streamingLifecycle.pausedBeatCount, 0)
        XCTAssertNil(collector.morningCoordination.morningStatus)
        XCTAssertFalse(collector.deviceStatus.isDeviceConnected)
        XCTAssertFalse(collector.deviceStatus.isStreaming)
        XCTAssertFalse(collector.deviceStatus.hasStoredExercise)
        XCTAssertNil(collector.deviceStatus.batteryLevel)
        XCTAssertFalse(collector.deviceStatus.isRecordingOnDevice)
        XCTAssertNil(collector.deviceStatus.connectedDeviceType)
        XCTAssertEqual(collector.deviceStatus.connectionState, .disconnected)
        XCTAssertEqual(collector.deviceStatus.recordingState, .idle)
        XCTAssertNil(collector.sessionState.recentPausedSession)
        XCTAssertNil(collector.deviceStatus.fetchProgress)
        XCTAssertNil(collector.sessionState.lastError)
        XCTAssertNil(collector.sessionState.verificationResult)
        XCTAssertNil(collector.sessionState.recoveryWindow)
        XCTAssertNil(collector.sessionState.baselineDeviation)
    }

    func testDeviceFetchPolicyDefaultsToAutomatic() {
        if case .automatic = collector.overnightRun.deviceFetchPolicy {
            // OK
        } else {
            XCTFail("deviceFetchPolicy must default to .automatic")
        }
    }

    func testUseDeviceInternalBackupForOvernightStreamingDefaultsTrue() {
        XCTAssertTrue(collector.overnightRun.usesDeviceBackup)
    }
}
